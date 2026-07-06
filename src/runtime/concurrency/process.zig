//! Process control block (PCB) for the Zap concurrency kernel.
//!
//! Phase 1 item 1.1 of `docs/concurrency-implementation-plan.md` (job
//! P1-J1), implementing the plan §3 process definition: *a process is a
//! fiber (fixed guard-paged lazy-commit stack reservation) + a manager
//! context (vtable + state pointer in the process control block) + a
//! mailbox + a preemption budget + a drop-list of external resources + a
//! pid table slot.* This module defines the control block and its state
//! machine; spawn/exit/teardown orchestration is Phase 1 item 1.4, the pid
//! table is P1-J2, and the mailbox is P1-J3.
//!
//! ## Manager binding (placeholder discipline)
//!
//! `ManagerContext` carries an opaque state pointer plus a minimal vtable —
//! enough for Phase 1 kernel tests, which drive it with a std-allocator-
//! backed test manager. Binding the REAL manager ABI
//! (`docs/memory-manager-abi.md`: `ZapManagerDescriptor`, capability
//! vtables, `zap_active_manager` symbol families) is a later wiring job in
//! this phase; when it lands, this vtable is replaced by (not layered over)
//! the manager-ABI entry points, per the no-fallbacks rule.
//!
//! ## Per-quantum current-process discipline (plan A.2.4 / A.3)
//!
//! Kernel entry points receive the `*ProcessControlBlock` as a parameter;
//! nothing in this module reads scheduler thread-local state. The scheduler
//! resolves the current process once per scheduling quantum and threads the
//! pointer through — E10 measured per-site TLV reads at +13.8% on the
//! pure-alloc shape, so re-resolution per call site is banned by design.

const std = @import("std");
const fiber_context = @import("fiber_context.zig");

/// Process identifier — PLACEHOLDER.
///
/// TODO(P1-J2): replace with the real generational pid: model bits a
/// function of {slot, generation} plus reserved node bits, backed by the
/// pid table with scalable iteration (plan Phase 1 item 1.2, locked design
/// decision 4). Until then this is an opaque 64-bit handle so PCB layout
/// and tests do not churn when the real type lands.
pub const Pid = enum(u64) {
    /// Sentinel for "no process" while the real pid table does not exist.
    invalid = 0,
    _,
};

/// Scheduling/lifecycle state of a process (plan §3). The legal
/// transitions are encoded in `isLegalTransition`; `transitionTo` enforces
/// them.
pub const ProcessState = enum(u8) {
    /// Allocated by spawn but not yet admitted to a run queue.
    embryo,
    /// Admitted; waiting in a run queue for a scheduler.
    runnable,
    /// Executing on a scheduler right now.
    running,
    /// Suspended awaiting an event (receive/timer/IO); off the run queues.
    waiting,
    /// Tearing down (normal exit, crash, or kill). Terminal.
    exiting,
};

/// Whether a process may move from `from` to `to`.
///
/// * `embryo → runnable` — spawn admission (Phase 1.4).
/// * `embryo → exiting` — spawn-path failure aborts the embryo before
///   admission.
/// * `runnable → running` — a scheduler picked the process up.
/// * `runnable → exiting` — killed while queued (untrappable `kill`).
/// * `running → runnable` — preempted (budget exhausted) or yielded.
/// * `running → waiting` — suspended in receive/timer/IO.
/// * `running → exiting` — returned from its entry, crashed, or was
///   killed at a safepoint.
/// * `waiting → runnable` — woken by message/timer/IO completion.
/// * `waiting → exiting` — killed while suspended.
/// * `exiting` is terminal — nothing leaves it.
pub fn isLegalTransition(from: ProcessState, to: ProcessState) bool {
    return switch (from) {
        .embryo => to == .runnable or to == .exiting,
        .runnable => to == .running or to == .exiting,
        .running => to == .runnable or to == .waiting or to == .exiting,
        .waiting => to == .runnable or to == .exiting,
        .exiting => false,
    };
}

/// Default preemption budget granted to a process at every scheduling
/// quantum, counted in reductions (safepoint polls decrement it — plan
/// Phase 2 item 2.5). 4000 mirrors BEAM's `CONTEXT_REDS`; the value is a
/// starting point to be tuned by the E2 gate measurements, not a contract.
pub const default_preemption_budget: u32 = 4000;

/// Minimal per-process memory-manager binding for Phase 1 kernel tests.
/// See the module doc's "Manager binding" section: the real manager-ABI
/// wiring replaces this vtable later in Phase 1.
pub const ManagerVTable = struct {
    /// Allocate `byte_length` bytes at `alignment` from the process's
    /// manager. Returns null on exhaustion.
    allocate: *const fn (manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8,
    /// Release one allocation made by `allocate`.
    deallocate: *const fn (manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void,
    /// Wholesale teardown at process exit (plan Phase 1 item 1.4:
    /// "wholesale arena/slab free on exit") — releases every live
    /// allocation of this process in one call.
    teardown: *const fn (manager_state: ?*anyopaque) void,
};

/// A process's manager binding: opaque per-process manager state plus the
/// dispatch vtable (the plan §3 "manager context" PCB field; the plan
/// A.2.5 monomorphized hot paths bypass this vtable — it serves cold
/// paths and Phase 1 tests).
pub const ManagerContext = struct {
    /// Opaque per-process manager instance state.
    manager_state: ?*anyopaque,
    /// Dispatch table; see `ManagerVTable`.
    vtable: *const ManagerVTable,

    /// Allocate through the vtable. Convenience for cold paths and tests.
    pub fn allocate(manager: ManagerContext, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        return manager.vtable.allocate(manager.manager_state, byte_length, alignment);
    }

    /// Deallocate through the vtable. Convenience for cold paths and tests.
    pub fn deallocate(manager: ManagerContext, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        manager.vtable.deallocate(manager.manager_state, memory, byte_length, alignment);
    }

    /// Wholesale exit teardown through the vtable.
    pub fn teardown(manager: ManagerContext) void {
        manager.vtable.teardown(manager.manager_state);
    }
};

/// Intrusive node of a process's drop-list: external (non-heap) resources
/// — fds, FFI handles — registered for destruction at process exit
/// (plan §3). Population and the exit-time run are Phase 1 item 1.4; the
/// PCB carries the typed head from day one so the teardown path never
/// needs a layout change.
pub const DropListNode = struct {
    /// Next registered resource (LIFO — destructors run newest-first).
    next: ?*DropListNode = null,
    /// Destroys the resource owning this node.
    destructor: *const fn (node: *DropListNode) void,
};

/// The process control block (plan §3). One per process; owned by the
/// kernel. Field order groups the scheduler-hot fields (state, budget,
/// fiber) ahead of exit-path fields.
pub const ProcessControlBlock = struct {
    /// Process identity. Placeholder type — see `Pid`.
    pid: Pid,
    /// Lifecycle/scheduling state; mutate only via `transitionTo`.
    state: ProcessState,
    /// Preemption budget in reductions for the current quantum; refilled
    /// by the scheduler at quantum start, decremented by safepoint polls
    /// (Phase 2.5).
    preemption_budget: u32,
    /// The process's fiber (cpu context + pooled guard-paged stack).
    fiber: fiber_context.KernelFiber,
    /// Per-process memory-manager binding.
    manager: ManagerContext,
    /// Mailbox — PLACEHOLDER. TODO(P1-J3): becomes the Vyukov MPSC
    /// envelope-intrusive mailbox (plan Phase 1 item 1.3); opaque until
    /// that type exists so the PCB layout is stable for P1-J2's pid table.
    mailbox: ?*anyopaque,
    /// Head of the external-resource drop-list (see `DropListNode`).
    drop_list_head: ?*DropListNode,

    /// Assemble a PCB in the `.embryo` state with an empty mailbox slot,
    /// an empty drop-list, and a full default preemption budget. The
    /// caller provides the created fiber (see `fiber_context.init`) and
    /// the manager binding; spawn orchestration on top is Phase 1.4.
    pub fn init(
        pid: Pid,
        kernel_fiber: fiber_context.KernelFiber,
        manager: ManagerContext,
    ) ProcessControlBlock {
        return .{
            .pid = pid,
            .state = .embryo,
            .preemption_budget = default_preemption_budget,
            .fiber = kernel_fiber,
            .manager = manager,
            .mailbox = null,
            .drop_list_head = null,
        };
    }

    /// Move the process to `new_state`, enforcing `isLegalTransition`.
    /// Illegal transitions are kernel bugs and panic in every build mode —
    /// state-machine corruption must never propagate silently.
    pub fn transitionTo(process: *ProcessControlBlock, new_state: ProcessState) void {
        if (!isLegalTransition(process.state, new_state)) {
            @branchHint(.cold);
            @panic("ProcessControlBlock.transitionTo: illegal state transition");
        }
        process.state = new_state;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const stack_pool = @import("stack_pool.zig");

test "PCB: state-transition legality matrix" {
    const State = ProcessState;
    const all_states = [_]State{ .embryo, .runnable, .running, .waiting, .exiting };
    const legal_transitions = [_][2]State{
        .{ .embryo, .runnable },
        .{ .embryo, .exiting },
        .{ .runnable, .running },
        .{ .runnable, .exiting },
        .{ .running, .runnable },
        .{ .running, .waiting },
        .{ .running, .exiting },
        .{ .waiting, .runnable },
        .{ .waiting, .exiting },
    };

    for (all_states) |from| {
        for (all_states) |to| {
            const expected_legal = for (legal_transitions) |pair| {
                if (pair[0] == from and pair[1] == to) break true;
            } else false;
            if (isLegalTransition(from, to) != expected_legal) {
                std.debug.print("transition {t} -> {t}: expected legal={}\n", .{ from, to, expected_legal });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Arena-backed test manager: the Phase 1 stand-in for a real per-process
/// manager instance. `teardown` is the wholesale free-on-exit shape the
/// plan's item 1.4 prescribes.
const TestManager = struct {
    arena: std.heap.ArenaAllocator,
    allocation_count: usize = 0,
    teardown_count: usize = 0,

    fn init(backing_allocator: std.mem.Allocator) TestManager {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    fn managerContext(manager: *TestManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &test_manager_vtable };
    }

    const test_manager_vtable = ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *TestManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.allocation_count += 1;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *TestManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.allocation_count -= 1;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *TestManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        // Wholesale free-on-exit; re-arm the arena so the test's outer
        // `defer arena.deinit()` stays valid after teardown.
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.allocation_count = 0;
    }
};

test "PCB: manager vtable allocate/deallocate/teardown round-trip" {
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();
    const manager = test_manager.managerContext();

    const first = manager.allocate(64, .of(u64)) orelse return error.TestUnexpectedResult;
    const second = manager.allocate(128, .of(u8)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), test_manager.allocation_count);
    first[0] = 0xAB;
    second[127] = 0xCD;

    manager.deallocate(first, 64, .of(u64));
    try testing.expectEqual(@as(usize, 1), test_manager.allocation_count);

    // Wholesale exit teardown releases everything still live.
    manager.teardown();
    try testing.expectEqual(@as(usize, 1), test_manager.teardown_count);
}

fn noopEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    _ = execution;
    _ = argument;
}

test "PCB: init defaults — embryo state, empty mailbox and drop-list, full budget" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();

    const kernel_fiber = try fiber_context.init(&pool, noopEntry, null);
    var process = ProcessControlBlock.init(.invalid, kernel_fiber, test_manager.managerContext());

    try testing.expectEqual(Pid.invalid, process.pid);
    try testing.expectEqual(ProcessState.embryo, process.state);
    try testing.expectEqual(default_preemption_budget, process.preemption_budget);
    try testing.expectEqual(@as(?*anyopaque, null), process.mailbox);
    try testing.expectEqual(@as(?*DropListNode, null), process.drop_list_head);
    try testing.expectEqual(fiber_context.LifecycleState.ready, process.fiber.lifecycle_state);

    // Drain the embryo through a legal path so the stack returns to the pool.
    var scheduler = fiber_context.SchedulerContext{};
    process.transitionTo(.runnable);
    process.transitionTo(.running);
    try testing.expectEqual(fiber_context.ResumeOutcome.finished, fiber_context.resumeFiber(&scheduler, &process.fiber));
    process.transitionTo(.exiting);
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_stack_count);
}

test "PCB: transitionTo walks a full legal lifecycle" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();

    const kernel_fiber = try fiber_context.init(&pool, noopEntry, null);
    var process = ProcessControlBlock.init(.invalid, kernel_fiber, test_manager.managerContext());

    const lifecycle = [_]ProcessState{ .runnable, .running, .waiting, .runnable, .running, .exiting };
    for (lifecycle) |next_state| {
        process.transitionTo(next_state);
        try testing.expectEqual(next_state, process.state);
    }

    // Release the never-run fiber's stack through the pool directly — the
    // scheduler-side teardown path (1.4) will own this once it exists.
    pool.release(process.fiber.stack);
}

const ProcessBodyProbe = struct {
    process: *ProcessControlBlock = undefined,
    allocated_value_seen: u64 = 0,
    yields_completed: usize = 0,
};

fn allocatingProcessBody(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    const probe: *ProcessBodyProbe = @ptrCast(@alignCast(argument.?));
    const manager = probe.process.manager;
    // Allocate from this process's manager while running on the fiber
    // stack — the per-quantum discipline: the PCB pointer arrived as a
    // parameter (via the probe), not from thread-local state.
    const memory = manager.allocate(@sizeOf(u64), .of(u64)) orelse return;
    const value_pointer: *u64 = @ptrCast(@alignCast(memory));
    value_pointer.* = 0xFEEDFACE;
    execution.yield();
    probe.yields_completed += 1;
    probe.allocated_value_seen = value_pointer.*;
}

test "PCB: process body runs on its fiber, allocates from its manager, and exits with wholesale teardown" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();

    var probe = ProcessBodyProbe{};
    const kernel_fiber = try fiber_context.init(&pool, allocatingProcessBody, &probe);
    var process = ProcessControlBlock.init(.invalid, kernel_fiber, test_manager.managerContext());
    probe.process = &process;

    var scheduler = fiber_context.SchedulerContext{};
    process.transitionTo(.runnable);
    process.transitionTo(.running);
    try testing.expectEqual(fiber_context.ResumeOutcome.yielded, fiber_context.resumeFiber(&scheduler, &process.fiber));
    // The body suspended mid-quantum; model a receive-style wait.
    process.transitionTo(.waiting);
    process.transitionTo(.runnable);
    process.transitionTo(.running);
    try testing.expectEqual(fiber_context.ResumeOutcome.finished, fiber_context.resumeFiber(&scheduler, &process.fiber));

    // The manager-owned allocation survived the suspension.
    try testing.expectEqual(@as(u64, 0xFEEDFACE), probe.allocated_value_seen);
    try testing.expectEqual(@as(usize, 1), probe.yields_completed);

    // Exit: wholesale manager teardown, stack already reclaimed by the
    // scheduler-side release inside resumeFiber.
    process.transitionTo(.exiting);
    process.manager.teardown();
    try testing.expectEqual(@as(usize, 1), test_manager.teardown_count);
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_stack_count);
}
