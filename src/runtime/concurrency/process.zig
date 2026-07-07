//! Process control block (PCB) for the Zap concurrency kernel.
//!
//! Phase 1 item 1.1 of `docs/concurrency-implementation-plan.md` (job
//! P1-J1), implementing the plan §3 process definition: *a process is a
//! fiber (fixed guard-paged lazy-commit stack reservation) + a manager
//! context (vtable + state pointer in the process control block) + a
//! mailbox + a preemption budget + a drop-list of external resources + a
//! pid table slot.* This module defines the control block and its state
//! machine; spawn/exit/teardown orchestration is Phase 1 item 1.4 and the
//! mailbox is P1-J3.
//!
//! ## Pid identity (P1-J2 wiring)
//!
//! Identity lives in the generational pid table (`pid_table.zig`). A PCB
//! is born with `Pid.invalid`; the spawn path registers it (`register`)
//! to obtain its pid at creation, and the exit path unregisters it
//! (`unregister`) in the `.exiting` state — BEFORE manager teardown, so
//! every subsequent lookup dead-letters instead of observing a heap that
//! is being torn down. Those two calls are the creation/finish seams the
//! 1.4 spawn/exit orchestration will drive.
//!
//! ## Mailbox ownership and the teardown seam (P1-J3)
//!
//! The PCB owns its mailbox by value: a Vyukov intrusive MPSC queue
//! (`mailbox.zig`) whose empty state references its own embedded stub
//! envelope — which is why `init` constructs the PCB IN PLACE at its
//! final address (the same pinning `register` already demanded). Senders
//! resolve the pid (`pid_table.lookup`) and push envelopes drawn from
//! the shared envelope page pool (`envelope_pool.zig`); only the owning
//! process pops.
//!
//! Teardown seam (wired by 1.4/J4, in this order): (1) `unregister` the
//! pid — new senders dead-letter from that instant; (2) drain the
//! mailbox (`pop` until `.empty`, bounded-retrying `.transient_gap`) and
//! `envelope_pool.free` every envelope — dead-lettering the payloads;
//! (3) `abandon()` the process's envelope-pool `Handle` — its sender
//! side — so pages with still-in-flight envelopes are reclaimed by
//! their receivers (mimalloc-style abandon/reclaim, `envelope_pool.zig`);
//! (4) `manager.teardown()`. The pool `Handle` is created by the 1.4
//! spawn path and is deliberately NOT a PCB field yet: whether handles
//! bind per-process or per-scheduler-thread is a Phase 4 decision
//! (`envelope_pool.zig`, "Multi-producer posture").
//!
//! ## Manager binding (placeholder discipline)
//!
//! `ManagerContext` carries an opaque state pointer plus a minimal vtable —
//! enough for Phase 1 kernel tests, which drive it with a std-allocator-
//! backed test manager. Binding the REAL manager ABI
//! (`docs/memory-manager-abi.md`: `ZapManagerDescriptor`, capability
//! vtables, `zap_active_manager` symbol families) lands in later phases
//! of the plan: Phase 2 item 2.4 binds the real manifest manager (ARC)
//! with adoption semantics; Phase 3 items 3.1/3.3 add the per-spawn
//! manager families. When each landing arrives, this vtable is replaced
//! by (not layered over) the manager-ABI entry points, per the
//! no-fallbacks rule.
//!
//! ## Per-quantum current-process discipline (plan A.2.4 / A.3)
//!
//! Kernel entry points receive the `*ProcessControlBlock` as a parameter;
//! nothing in this module reads scheduler thread-local state. The scheduler
//! resolves the current process once per scheduling quantum and threads the
//! pointer through — E10 measured per-site TLV reads at +13.8% on the
//! pure-alloc shape, so re-resolution per call site is banned by design.
//!
//! ## Concurrency: PCB fields are owner-only
//!
//! Every PCB field is OWNER-ONLY: it is read and mutated only by the
//! owning process's own execution, or by the scheduler thread while the
//! process is not running (in Phase 1 these are the same thread; the
//! phrasing is the Phase 4 contract). Nothing in the PCB is thread-safe
//! by itself — the one deliberate exception is the mailbox, whose PUSH
//! side is any-thread by design (`mailbox.zig`). Foreign threads that
//! hold a PCB pointer from `pid_table.lookup` may push to the mailbox
//! and nothing else; `introspection.zig`'s cross-thread snapshots read
//! `state` on the documented best-effort basis.
//!
//! Phase 4 (M:N schedulers) tracking line: atomicize `ProcessState` (or
//! fence the introspection reads) before a second scheduler thread can
//! observe a PCB — the owner-only contract above is what makes plain
//! (non-atomic) fields correct today.

const std = @import("std");
const fiber_context = @import("fiber_context.zig");
const pid_table = @import("pid_table.zig");
const mailbox_module = @import("mailbox.zig");

/// Process identifier — the generational pid of `pid_table.zig` (plan
/// Phase 1 item 1.2, locked design decision 4): `{slot, generation,
/// model bits, node bits}` packed into 64 bits. Re-exported here because
/// the PCB carries it; the table module owns the definition.
pub const Pid = pid_table.Pid;

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

/// The per-quantum reduction budget the compiler-emitted safepoints see
/// (plan item 2.5, P2-J6). The scheduler publishes it at quantum entry
/// (`runQuantum`); it seeds the layer-2 bare-back-edge poll's loop-local
/// reduction counter that the ZIR builder emits into alloc-free loops.
/// Read-only from compiled code. `pub export` so a ZIR-emitted safepoint
/// in a user binary links against this symbol; with the concurrency gate
/// OFF no compiled code references it, so it costs nothing (plan §3
/// zero-cost guarantee). Homed here — the leaf module both `scheduler`
/// (writer) and `abi` (the slow-path reader) import — to avoid a
/// scheduler↔abi import cycle.
pub export var zap_proc_reductions_budget: u32 = default_preemption_budget;

/// The layer-1 alloc-piggyback running reduction counter (plan item 2.5,
/// P2-J6). The runtime's allocation hot path decrements it once per cell
/// allocation and takes the slow path (`zap_proc_safepoint_slow`) when it
/// reaches zero; the slow path refreshes it from `zap_proc_reductions_budget`
/// via `refreshReductionCounter`. Distinct from the layer-2 loop-local
/// counter, which lives in the emitted loop's frame (a register after
/// LLVM promotion) so a tight numeric loop pays only a register decrement.
/// `pub export` for the same linkage reason as `zap_proc_reductions_budget`.
pub export var zap_proc_reductions_remaining: u32 = default_preemption_budget;

/// Refresh the layer-1 alloc running counter to a fresh quantum's budget.
/// Called by the C-ABI slow path (`zap_proc_safepoint_slow`) — including
/// when no process is current (allocations during runtime bootstrap reach
/// the slow path before the root process is scheduled), so pre-process
/// allocations do not re-enter the slow path on every call.
pub fn refreshReductionCounter() void {
    zap_proc_reductions_remaining = zap_proc_reductions_budget;
}

/// Minimal per-process memory-manager binding for Phase 1 kernel tests.
/// See the module doc's "Manager binding" section: the real manager-ABI
/// wiring replaces this vtable in Phase 2 item 2.4 (manifest ARC manager,
/// adoption semantics) and Phase 3 items 3.1/3.3 (per-spawn manager
/// families).
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
    /// Bytes currently live in this process's heap (plan Phase 1 item
    /// 1.6, the per-process "heap bytes" observability surface). The
    /// value is payload bytes — allocated minus deallocated request
    /// sizes — with manager-defined exactness: the Phase 1 test managers
    /// count requested bytes exactly; a real manager may report its
    /// internal accounting granularity instead. Advisory, never
    /// load-bearing; `teardown` returns it to zero.
    heapByteCount: *const fn (manager_state: ?*anyopaque) usize,
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

    /// Bytes currently live in the process heap, through the vtable
    /// (observability, plan item 1.6 — see `ManagerVTable.heapByteCount`
    /// for the exactness contract).
    pub fn heapByteCount(manager: ManagerContext) usize {
        return manager.vtable.heapByteCount(manager.manager_state);
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
    /// Process identity. `Pid.invalid` from `init` until `register`
    /// acquires a pid-table slot; `Pid.invalid` again after `unregister`.
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
    /// The process's mailbox (P1-J3): Vyukov intrusive MPSC over pool
    /// envelopes — any thread pushes, only this process pops. Owned by
    /// value; its embedded stub makes the PCB pinned from `init` on.
    /// See the module doc's "Mailbox ownership and the teardown seam".
    mailbox: mailbox_module.Mailbox,
    /// Head of the external-resource drop-list (see `DropListNode`).
    drop_list_head: ?*DropListNode,

    /// Assemble a PCB IN PLACE — at its final address, which the mailbox
    /// pins from this call on (its empty state references its embedded
    /// stub envelope; `register` already required the same pinning) —
    /// in the `.embryo` state with no identity (`Pid.invalid` — identity
    /// is acquired by `register`), an empty mailbox, an empty drop-list,
    /// and a full default preemption budget. The caller provides the
    /// created fiber (see `fiber_context.init`) and the manager binding;
    /// spawn orchestration on top is Phase 1.4.
    pub fn init(
        process: *ProcessControlBlock,
        kernel_fiber: fiber_context.KernelFiber,
        manager: ManagerContext,
    ) void {
        process.pid = .invalid;
        process.state = .embryo;
        process.preemption_budget = default_preemption_budget;
        process.fiber = kernel_fiber;
        process.manager = manager;
        process.mailbox.init();
        process.drop_list_head = null;
    }

    /// Creation seam (Phase 1.4 spawn path): acquire a pid-table slot
    /// for this process under `model` and record the pid in the PCB. The
    /// PCB must be at its final address (the table stores the pointer),
    /// in the `.embryo` state, and not already registered — violations
    /// are kernel bugs and panic in every build mode, matching
    /// `transitionTo`'s discipline. On `error.ProcessTableExhausted` the
    /// PCB is untouched and the spawn path surfaces the failure.
    pub fn register(
        process: *ProcessControlBlock,
        table: *pid_table.PidTable,
        model: pid_table.ReclamationModel,
    ) pid_table.PidTable.AcquireError!Pid {
        if (process.pid.toBits() != Pid.invalid.toBits()) {
            @branchHint(.cold);
            @panic("ProcessControlBlock.register: process already registered — kernel bug");
        }
        if (process.state != .embryo) {
            @branchHint(.cold);
            @panic("ProcessControlBlock.register: identity must be acquired in the embryo state — kernel bug");
        }
        const pid = try table.acquire(process, model);
        process.pid = pid;
        return pid;
    }

    /// Finish seam (Phase 1.4 exit path): release this process's pid —
    /// instantly dead-lettering every outstanding copy of it — and reset
    /// the PCB's pid to `Pid.invalid`. Must run in the `.exiting` state
    /// and BEFORE `manager.teardown()`, so no lookup can resolve to a
    /// process whose heap is being torn down. Calling it unregistered or
    /// outside `.exiting` is a kernel bug and panics in every build mode.
    pub fn unregister(
        process: *ProcessControlBlock,
        table: *pid_table.PidTable,
    ) void {
        if (process.pid.toBits() == Pid.invalid.toBits()) {
            @branchHint(.cold);
            @panic("ProcessControlBlock.unregister: process is not registered — kernel bug");
        }
        if (process.state != .exiting) {
            @branchHint(.cold);
            @panic("ProcessControlBlock.unregister: identity must be released in the exiting state — kernel bug");
        }
        table.release(process.pid);
        process.pid = .invalid;
    }

    /// Register an external (non-heap) resource for destruction at process
    /// exit: push `node` onto the drop-list head. LIFO by design —
    /// exit-time teardown (P1-J4) walks the list head-first, so
    /// destructors run newest-first, mirroring scope-exit `defer`
    /// ordering (research.md §6.5: the drop-list is the kernel analogue
    /// of BEAM resource destructors). The node is owned by the resource
    /// it destroys; the kernel never allocates or frees it. The list is
    /// owner-only like every PCB field (module doc, "Concurrency: PCB
    /// fields are owner-only").
    pub fn registerDropResource(process: *ProcessControlBlock, node: *DropListNode) void {
        node.next = process.drop_list_head;
        process.drop_list_head = node;
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
const envelope_pool = @import("envelope_pool.zig");
const test_support = @import("test_support.zig");

/// The shared Phase 1 test-manager shape (`test_support.zig`).
const TestManager = test_support.CountingArenaManager;

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

test "PCB: manager vtable heap-byte accounting tracks live bytes and resets on teardown" {
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();
    const manager = test_manager.managerContext();

    try testing.expectEqual(@as(usize, 0), manager.heapByteCount());
    const first = manager.allocate(64, .of(u64)) orelse return error.TestUnexpectedResult;
    _ = manager.allocate(100, .of(u8)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 164), manager.heapByteCount());

    manager.deallocate(first, 64, .of(u64));
    try testing.expectEqual(@as(usize, 100), manager.heapByteCount());

    // Wholesale exit teardown zeroes the live-byte accounting.
    manager.teardown();
    try testing.expectEqual(@as(usize, 0), manager.heapByteCount());
}

test "PCB: init defaults — embryo state, empty mailbox and drop-list, full budget" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();

    const kernel_fiber = try fiber_context.init(&pool, noopEntry, null);
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());

    try testing.expectEqual(Pid.invalid.toBits(), process.pid.toBits());
    try testing.expectEqual(ProcessState.embryo, process.state);
    try testing.expectEqual(default_preemption_budget, process.preemption_budget);
    try testing.expectEqual(mailbox_module.PopOutcome.empty, process.mailbox.pop());
    try testing.expectEqual(@as(usize, 0), process.mailbox.depth());
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
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());

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
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());
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

test "PCB: register/unregister wire pid identity through the table across the process lifecycle" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();
    var table = try pid_table.PidTable.init(testing.allocator, .{ .capacity = 4 });
    defer table.deinit();

    const kernel_fiber = try fiber_context.init(&pool, noopEntry, null);
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());

    // Creation seam: the embryo gains its identity from the table.
    const pid = try process.register(&table, .refcounted);
    try testing.expectEqual(pid.toBits(), process.pid.toBits());
    try testing.expect(pid.isLocal());
    try testing.expectEqual(pid_table.ReclamationModel.refcounted, pid.model);
    try testing.expectEqual(@as(?*ProcessControlBlock, &process), table.lookup(pid));
    try testing.expectEqual(@as(u32, 1), table.statistics().live_process_count);

    // Run the process to completion through a legal lifecycle.
    var scheduler = fiber_context.SchedulerContext{};
    process.transitionTo(.runnable);
    process.transitionTo(.running);
    try testing.expectEqual(fiber_context.ResumeOutcome.finished, fiber_context.resumeFiber(&scheduler, &process.fiber));
    process.transitionTo(.exiting);

    // Finish seam: unregister BEFORE manager teardown; the pid dies with
    // the registration and every outstanding copy dead-letters.
    process.unregister(&table);
    try testing.expectEqual(Pid.invalid.toBits(), process.pid.toBits());
    try testing.expectEqual(@as(?*ProcessControlBlock, null), table.lookup(pid));
    try testing.expectEqual(@as(u32, 0), table.statistics().live_process_count);
    try testing.expectEqual(@as(u64, 1), table.statistics().dead_letter_count);

    process.manager.teardown();
    try testing.expectEqual(@as(usize, 1), test_manager.teardown_count);
}

const DropOrderProbe = struct {
    node: DropListNode,
    log: *[4]u8,
    log_cursor: *usize,
    identity: u8,

    fn destructor(node: *DropListNode) void {
        const probe: *DropOrderProbe = @fieldParentPtr("node", node);
        probe.log[probe.log_cursor.*] = probe.identity;
        probe.log_cursor.* += 1;
    }
};

test "PCB: registerDropResource pushes LIFO so exit-time destructors run newest-first" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();

    const kernel_fiber = try fiber_context.init(&pool, noopEntry, null);
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());

    var destruction_log: [4]u8 = @splat(0);
    var log_cursor: usize = 0;
    var probes: [3]DropOrderProbe = undefined;
    for (&probes, 0..) |*probe, index| {
        probe.* = .{
            .node = .{ .destructor = DropOrderProbe.destructor },
            .log = &destruction_log,
            .log_cursor = &log_cursor,
            .identity = @intCast('a' + index),
        };
        process.registerDropResource(&probe.node);
    }

    // LIFO: the most recently registered resource is the list head.
    try testing.expectEqual(@as(?*DropListNode, &probes[2].node), process.drop_list_head);
    try testing.expectEqual(@as(?*DropListNode, &probes[1].node), probes[2].node.next);
    try testing.expectEqual(@as(?*DropListNode, &probes[0].node), probes[1].node.next);
    try testing.expectEqual(@as(?*DropListNode, null), probes[0].node.next);

    // Walking the list head-first (what teardown does) runs newest-first.
    while (process.drop_list_head) |node| {
        process.drop_list_head = node.next;
        node.destructor(node);
    }
    try testing.expectEqual(@as(usize, 3), log_cursor);
    try testing.expectEqualSlices(u8, "cba", destruction_log[0..3]);

    // Drain the never-run fiber's stack through the pool directly (the
    // scheduler-side teardown path owns this once a scheduler exists).
    pool.release(process.fiber.stack);
}

const MailboxDeliveryProbe = struct {
    process: *ProcessControlBlock = undefined,
    received_payload_length: usize = 0,
    freed_envelope: bool = false,
};

fn receivingProcessBody(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    _ = execution;
    const probe: *MailboxDeliveryProbe = @ptrCast(@alignCast(argument.?));
    // The owning process is the single consumer of its own mailbox.
    switch (probe.process.mailbox.pop()) {
        .envelope => |received| {
            probe.received_payload_length = received.fragment.payload_byte_length;
            envelope_pool.EnvelopePool.free(received);
            probe.freed_envelope = true;
        },
        .empty, .transient_gap => {},
    }
}

test "PCB: pool envelope pushed to the PCB mailbox is delivered to the process body and freed" {
    var pool = stack_pool.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    var test_manager = TestManager.init(testing.allocator);
    defer test_manager.arena.deinit();
    var message_pool = envelope_pool.EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer message_pool.deinit();

    var probe = MailboxDeliveryProbe{};
    const kernel_fiber = try fiber_context.init(&pool, receivingProcessBody, &probe);
    var process: ProcessControlBlock = undefined;
    ProcessControlBlock.init(&process, kernel_fiber, test_manager.managerContext());
    probe.process = &process;

    // Sender side: draw an envelope from the shared pool and push it to
    // the process's mailbox (empty→nonempty: the wake signal fires).
    var sender_handle = envelope_pool.EnvelopePool.Handle.init(&message_pool);
    const envelope = try sender_handle.allocate();
    envelope.fragment.payload_byte_length = 0xC0FFEE;
    try testing.expect(process.mailbox.push(envelope));

    // Receiver side: run the process; its body pops and frees.
    var scheduler = fiber_context.SchedulerContext{};
    process.transitionTo(.runnable);
    process.transitionTo(.running);
    try testing.expectEqual(fiber_context.ResumeOutcome.finished, fiber_context.resumeFiber(&scheduler, &process.fiber));
    process.transitionTo(.exiting);

    try testing.expectEqual(@as(usize, 0xC0FFEE), probe.received_payload_length);
    try testing.expect(probe.freed_envelope);
    try testing.expectEqual(mailbox_module.PopOutcome.empty, process.mailbox.pop());
    try testing.expectEqual(@as(usize, 0), process.mailbox.depth());

    // Sender exit: the freed envelope left its page empty, so abandon
    // returns it — every page accounted.
    sender_handle.abandon();
    try testing.expectEqual(@as(u32, 0), message_pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 0), message_pool.statistics().abandoned_page_count);

    process.manager.teardown();
}
