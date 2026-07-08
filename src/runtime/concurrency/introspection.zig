//! Per-process and scheduler introspection for the Zap concurrency kernel.
//!
//! Phase 1 item 1.6 of `docs/concurrency-implementation-plan.md` (job
//! P1-J5), implementing research.md §6.9's "build from day one" surface:
//! per-process snapshots (state, mailbox depth, heap bytes, last-suspend
//! pc/fp), a scalable process listing built on the pid table's
//! snapshot-free lock-free iterator (the OTP-28 iteration model,
//! `pid_table.zig`), and the scheduler counter roster (run-queue depth,
//! quanta executed, parks/wakes, dead letters, spawn/exit totals). Per
//! §6.9's closing rule, these hooks double as the testing hooks — the
//! kernel test suites and the Phase 1.7 teardown-stress campaign assert
//! against exactly these surfaces.
//!
//! ## Consistency contract (read this before trusting a number)
//!
//! * **Per-snapshot, point-in-time, per process — never globally
//!   atomic.** `ProcessListIterator` visits live pid-table slots with the
//!   iterator's documented guarantees (every process live for the whole
//!   walk is yielded exactly once; concurrent spawns/exits may or may not
//!   appear); each yielded `ProcessSnapshot` is assembled from one
//!   process's fields at its visit instant, so two snapshots from one
//!   walk may straddle a state change. There is no stop-the-world.
//! * **Mailbox depth is approximate** by the mailbox counter's documented
//!   semantics (`mailbox.zig`): it may momentarily over-count in-flight
//!   pushes; exact at quiescence.
//! * **Heap bytes** are the manager's own accounting
//!   (`process.ManagerVTable.heapByteCount`): payload bytes with
//!   manager-defined exactness, advisory under concurrency.
//! * **Counters** mix scheduler-thread-exact values (run-queue depth,
//!   quanta, spawn/exit totals — exact when read on the scheduler thread)
//!   with cross-thread atomics (parks, wake signals, dead letters —
//!   monotonic, momentarily behind a racing writer). `kernelCounters` is
//!   scheduler-thread discipline for full fidelity, same as
//!   `Scheduler.statistics`.
//! * **Phase 1 threading posture:** everything here is exercised from the
//!   single scheduler thread (including from inside process bodies, which
//!   run on it). Cross-thread listing inherits the pid table's documented
//!   Phase 4 PCB-lifetime caveat and the per-field races above; Phase 4's
//!   multi-scheduler work owns tightening that contract.
//!
//! ## Stack high-water: deliberately absent (Phase 6)
//!
//! A per-process stack high-water estimate is NOT cheaply available from
//! the Phase 1 pool/guard design: stacks are fixed lazy-commit
//! reservations (`stack_pool.zig`) with no per-page residency tracking,
//! so measuring would need page-table queries (`mincore`-class syscalls)
//! or Debug-poison scans per snapshot — neither is a cheap counter read,
//! and both belong to the machinery Phase 6's hibernation work
//! (stack shrink/rewrite, plan 6.x) must build anyway. It lands there,
//! on per-fiber accounting, not here as a syscall-per-snapshot.
//!
//! ## Toolchain
//!
//! Exercised through the scheduler (fiber switches), so the kernel-wide
//! fork-compiler requirement for optimized builds applies (see
//! `concurrency.zig`).

const std = @import("std");
const fiber_context = @import("fiber_context.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const scheduler_module = @import("scheduler.zig");

const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const Scheduler = scheduler_module.Scheduler;

/// The last-suspend location of a suspended process: where it will
/// resume, as saved by its final context switch away (the research.md
/// §6.9 "current function from the green thread's saved PC" surface;
/// symbol resolution is the consumer's concern — see
/// `crash_report.CrashReport.render` for the symbolizing renderer).
pub const SuspendPoint = struct {
    /// Saved program counter (the suspend instruction).
    program_counter: usize,
    /// Saved frame pointer (the head of the fiber's frame-record chain;
    /// `crash_report.zig` walks it).
    frame_pointer: usize,
};

/// One process's observable state at its snapshot instant (consistency
/// contract in the module doc).
pub const ProcessSnapshot = struct {
    /// The process's pid at the snapshot instant.
    pid: Pid,
    /// Scheduling/lifecycle state.
    state: process_module.ProcessState,
    /// Mailbox depth — APPROXIMATE (module doc).
    mailbox_depth: usize,
    /// Live process-heap bytes per the manager's accounting (module doc).
    heap_byte_count: usize,
    /// The last-suspend pc/fp when the process's fiber is suspended
    /// (`.waiting`, or `.runnable` between quanta); null when there is no
    /// walkable suspend point — never ran, currently running, or already
    /// finished (`fiber_context.savedRegisters`).
    last_suspend: ?SuspendPoint,
};

/// Snapshot one live process as yielded by the pid-table iterator.
/// Point-in-time per the module doc's consistency contract.
pub fn snapshotLiveProcess(live: pid_table_module.LiveProcess) ProcessSnapshot {
    const pcb = live.pcb;
    const suspend_point: ?SuspendPoint = if (fiber_context.savedRegisters(&pcb.fiber)) |saved|
        .{
            .program_counter = saved.program_counter,
            .frame_pointer = saved.frame_pointer,
        }
    else
        null;
    return .{
        .pid = live.pid,
        .state = pcb.currentState(),
        .mailbox_depth = pcb.mailbox.depth(),
        .heap_byte_count = pcb.manager.heapByteCount(),
        .last_suspend = suspend_point,
    };
}

/// Process listing: the pid table's snapshot-free lock-free live-process
/// iterator (OTP-28 model — no table lock, no global snapshot), each
/// visit materialized as a `ProcessSnapshot`. Obtain via `listProcesses`.
pub const ProcessListIterator = struct {
    /// The underlying slot walk.
    live_iterator: pid_table_module.LiveProcessIterator,

    /// Yield the next live process's snapshot, or null when the walk is
    /// complete.
    pub fn next(iterator: *ProcessListIterator) ?ProcessSnapshot {
        const live = iterator.live_iterator.next() orelse return null;
        return snapshotLiveProcess(live);
    }
};

/// Begin a process listing over `table` (module doc: per-snapshot
/// consistency, never globally atomic).
pub fn listProcesses(table: *PidTable) ProcessListIterator {
    return .{ .live_iterator = table.iterateLiveProcesses() };
}

/// The plan-1.6 scheduler counter roster, composed from the scheduler's
/// own statistics and the pid table's dead-letter counter. Consistency
/// per the module doc (scheduler-thread discipline for full fidelity).
pub const KernelCounters = struct {
    /// Processes currently live on this scheduler.
    live_process_count: u32,
    /// High-watermark of `live_process_count`.
    live_process_peak: u32,
    /// Current ready-queue depth.
    run_queue_depth: usize,
    /// Quanta executed (process switch-ins).
    quantum_total: u64,
    /// Futex parks entered by the idle scheduler.
    park_count: u64,
    /// Wake signals issued (`Scheduler.wake`).
    wake_signal_count: u64,
    /// Failed pid resolutions routed to the dead-letter path (shared
    /// pid table — a Phase 4 multi-scheduler total, not per-scheduler).
    dead_letter_count: u64,
    /// Successful spawns.
    spawn_total: u64,
    /// Normal exits.
    normal_exit_total: u64,
    /// Kill teardowns.
    kill_total: u64,
};

/// Snapshot the counter roster for `scheduler` (and its shared pid
/// table).
pub fn kernelCounters(scheduler: *const Scheduler) KernelCounters {
    const scheduler_statistics = scheduler.statistics();
    const table_statistics = scheduler.pid_table.statistics();
    return .{
        .live_process_count = scheduler_statistics.live_process_count,
        .live_process_peak = scheduler_statistics.live_process_peak,
        .run_queue_depth = scheduler_statistics.ready_queue_depth,
        .quantum_total = scheduler_statistics.quantum_total,
        .park_count = scheduler_statistics.park_count,
        .wake_signal_count = scheduler_statistics.wake_signal_count,
        .dead_letter_count = table_statistics.dead_letter_count,
        .spawn_total = scheduler_statistics.spawn_total,
        .normal_exit_total = scheduler_statistics.normal_exit_total,
        .kill_total = scheduler_statistics.kill_total,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const envelope_pool_module = @import("envelope_pool.zig");
const deterministic = @import("deterministic.zig");

const ProcessContext = scheduler_module.ProcessContext;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const ManagerContext = process_module.ManagerContext;

/// Byte-accounting arena manager (the standard Phase 1 test-manager
/// shape; see `scheduler.zig`).
const IntrospectionTestManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    fn init(backing_allocator: std.mem.Allocator) IntrospectionTestManager {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    fn deinitBacking(manager: *IntrospectionTestManager) void {
        manager.arena.deinit();
    }

    fn managerContext(manager: *IntrospectionTestManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *IntrospectionTestManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *IntrospectionTestManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *IntrospectionTestManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *IntrospectionTestManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

/// One deterministic (forbid-parking) kernel instance for these tests.
const IntrospectionTestKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,

    fn init(kernel: *IntrospectionTestKernel) !void {
        kernel.pid_table = try PidTable.init(testing.allocator, .{ .capacity = 64 });
        kernel.envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
        kernel.scheduler = Scheduler.init(testing.allocator, &kernel.pid_table, &kernel.envelope_pool, .{
            .stack_usable_size = 64 * 1024,
            .preemption_budget = 16,
            .idle_strategy = .forbid_parking,
        });
    }

    fn deinit(kernel: *IntrospectionTestKernel) void {
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }
};

// -- process bodies -------------------------------------------------------------

const AllocateThenWaitProbe = struct {
    allocation_byte_lengths: []const usize,
};

fn allocateThenWaitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *AllocateThenWaitProbe = @ptrCast(@alignCast(argument.?));
    const manager = context.record.pcb.manager;
    for (probe.allocation_byte_lengths) |byte_length| {
        _ = manager.allocate(byte_length, .of(u8)) orelse
            @panic("allocateThenWaitEntry: allocation failed");
    }
    _ = context.receive();
    @panic("allocateThenWaitEntry: received a message nobody should have sent");
}

fn blockForeverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("blockForeverEntry: received a message nobody should have sent");
}

fn immediateExitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    _ = argument;
}

const SendBurstProbe = struct {
    target: Pid,
    envelope_count: usize,
    observed_outcome: scheduler_module.SendOutcome = .delivered,
};

fn sendBurstEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SendBurstProbe = @ptrCast(@alignCast(argument.?));
    var sent: usize = 0;
    while (sent < probe.envelope_count) : (sent += 1) {
        probe.observed_outcome = context.send(probe.target, .{ .payload_byte_length = sent }) catch
            @panic("sendBurstEntry: envelope allocation failed");
    }
}

// -- per-process snapshot ---------------------------------------------------------

test "Introspection: snapshot reflects state, mailbox depth, heap bytes, and the suspend point" {
    var kernel: IntrospectionTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = IntrospectionTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = AllocateThenWaitProbe{ .allocation_byte_lengths = &.{ 100, 64 } };
    const pid = try kernel.scheduler.spawn(.{
        .entry = allocateThenWaitEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    var listing = listProcesses(&kernel.pid_table);
    const snapshot = listing.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?ProcessSnapshot, null), listing.next());

    try testing.expectEqual(pid.toBits(), snapshot.pid.toBits());
    try testing.expectEqual(process_module.ProcessState.waiting, snapshot.state);
    try testing.expectEqual(@as(usize, 0), snapshot.mailbox_depth);
    try testing.expectEqual(@as(usize, 164), snapshot.heap_byte_count);

    // The suspend point matches the fiber's saved registers exactly.
    const pcb = kernel.pid_table.lookup(pid).?;
    const saved = fiber_context.savedRegisters(&pcb.fiber).?;
    const suspend_point = snapshot.last_suspend orelse return error.TestUnexpectedResult;
    try testing.expectEqual(saved.program_counter, suspend_point.program_counter);
    try testing.expectEqual(saved.frame_pointer, suspend_point.frame_pointer);

    _ = kernel.scheduler.kill(pid);
    try kernel.scheduler.runUntilQuiescent();
    try testing.expectEqual(@as(usize, 1), manager.teardown_count);
}

test "Introspection: snapshot mailbox depth counts queued undelivered envelopes" {
    var kernel: IntrospectionTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = IntrospectionTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = blockForeverEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    // Queue three envelopes without giving the victim a quantum to
    // consume them (pushes from the idle scheduler thread — the same
    // producer shape as the PCB mailbox tests).
    const victim_pcb = kernel.pid_table.lookup(victim_pid).?;
    var sender_handle = EnvelopePool.Handle.init(&kernel.envelope_pool);
    var sent: usize = 0;
    while (sent < 3) : (sent += 1) {
        const envelope = try sender_handle.allocate();
        envelope.fragment = .{ .payload_byte_length = sent };
        _ = victim_pcb.mailbox.push(envelope);
    }

    var found_victim = false;
    var listing = listProcesses(&kernel.pid_table);
    while (listing.next()) |snapshot| {
        if (snapshot.pid.toBits() != victim_pid.toBits()) continue;
        found_victim = true;
        try testing.expectEqual(@as(usize, 3), snapshot.mailbox_depth);
        // The wake signal is pending but no quantum has run: still
        // waiting, still snapshotted at its receive suspend point.
        try testing.expectEqual(process_module.ProcessState.waiting, snapshot.state);
        try testing.expect(snapshot.last_suspend != null);
    }
    try testing.expect(found_victim);

    // Kill drains the three undelivered envelopes back to their origin
    // page; abandoning the test handle returns the page — every page
    // accounted.
    try testing.expectEqual(scheduler_module.KillOutcome.killed, kernel.scheduler.kill(victim_pid));
    sender_handle.abandon();
    try kernel.scheduler.runUntilQuiescent();
    try testing.expectEqual(@as(u32, 0), kernel.envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 0), kernel.envelope_pool.statistics().abandoned_page_count);
}

// -- listing ------------------------------------------------------------------------

test "Introspection: listing yields exactly the live set" {
    var kernel: IntrospectionTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = IntrospectionTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    var expected_pid_bits: [3]u64 = undefined;
    for (&expected_pid_bits) |*pid_bits| {
        const pid = try kernel.scheduler.spawn(.{
            .entry = blockForeverEntry,
            .manager = manager.managerContext(),
        });
        pid_bits.* = pid.toBits();
    }
    // One process that exits immediately must NOT appear afterwards.
    _ = try kernel.scheduler.spawn(.{
        .entry = immediateExitEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    var seen = [_]bool{ false, false, false };
    var snapshot_count: usize = 0;
    var listing = listProcesses(&kernel.pid_table);
    while (listing.next()) |snapshot| {
        snapshot_count += 1;
        try testing.expectEqual(process_module.ProcessState.waiting, snapshot.state);
        for (expected_pid_bits, 0..) |pid_bits, index| {
            if (snapshot.pid.toBits() == pid_bits) seen[index] = true;
        }
    }
    try testing.expectEqual(@as(usize, 3), snapshot_count);
    for (seen) |was_seen| try testing.expect(was_seen);

    kernel.scheduler.shutdownAllProcesses();
    var empty_listing = listProcesses(&kernel.pid_table);
    try testing.expectEqual(@as(?ProcessSnapshot, null), empty_listing.next());
    try testing.expectEqual(@as(usize, 4), manager.teardown_count);
}

// -- counters -----------------------------------------------------------------------

test "Introspection: kernelCounters compose scheduler totals with the dead-letter count" {
    var kernel: IntrospectionTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = IntrospectionTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    // First lifecycle: a process that exits; its pid then dead-letters.
    const dead_pid = try kernel.scheduler.spawn(.{
        .entry = immediateExitEntry,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    // Second lifecycle: a sender whose target is already dead.
    var sender_probe = SendBurstProbe{ .target = dead_pid, .envelope_count = 1 };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendBurstEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });
    // And a victim for the kill counter.
    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = blockForeverEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());
    _ = kernel.scheduler.kill(victim_pid);
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(scheduler_module.SendOutcome.dead_lettered, sender_probe.observed_outcome);

    const counters = kernelCounters(&kernel.scheduler);
    try testing.expectEqual(@as(u32, 0), counters.live_process_count);
    try testing.expectEqual(@as(u32, 2), counters.live_process_peak);
    try testing.expectEqual(@as(usize, 0), counters.run_queue_depth);
    try testing.expectEqual(@as(u64, 3), counters.spawn_total);
    try testing.expectEqual(@as(u64, 2), counters.normal_exit_total);
    try testing.expectEqual(@as(u64, 1), counters.kill_total);
    try testing.expectEqual(@as(u64, 1), counters.dead_letter_count);
    // Each of the three processes ran at least one quantum (the killed
    // waiter exactly one).
    try testing.expect(counters.quantum_total >= 3);
    // Deterministic mode forbids parking; the spawn-edge wake signals
    // still fire.
    try testing.expectEqual(@as(u64, 0), counters.park_count);
    try testing.expect(counters.wake_signal_count >= 3);
}

// -- listing from inside a running process (scheduler-thread discipline) -------------

const ObserverProbe = struct {
    self_pid: Pid = Pid.invalid,
    observed_total: usize = 0,
    observed_self: bool = false,
    self_state_was_running: bool = false,
    self_suspend_was_null: bool = false,
};

fn observerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ObserverProbe = @ptrCast(@alignCast(argument.?));
    probe.self_pid = context.selfPid();
    var listing = listProcesses(context.scheduler.pid_table);
    while (listing.next()) |snapshot| {
        probe.observed_total += 1;
        if (snapshot.pid.toBits() == probe.self_pid.toBits()) {
            probe.observed_self = true;
            probe.self_state_was_running = snapshot.state == .running;
            probe.self_suspend_was_null = snapshot.last_suspend == null;
        }
    }
}

const observer_worker_count = 2;

const ObserverScenarioState = struct {
    observer_probe: ObserverProbe = .{},
};

fn observerWorkerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    var remaining_yields: usize = 4;
    while (remaining_yields > 0) : (remaining_yields -= 1) {
        context.yieldNow();
    }
}

fn observerScenario(harness: *deterministic.Harness, scenario_context: ?*anyopaque) anyerror!void {
    const state: *ObserverScenarioState = @ptrCast(@alignCast(scenario_context.?));
    state.observer_probe = .{};
    _ = try harness.spawnProcess(observerEntry, &state.observer_probe);
    var worker_index: usize = 0;
    while (worker_index < observer_worker_count) : (worker_index += 1) {
        _ = try harness.spawnProcess(observerWorkerEntry, null);
    }
}

fn observerVerify(harness: *deterministic.Harness, scenario_context: ?*anyopaque) anyerror!void {
    _ = harness;
    const state: *ObserverScenarioState = @ptrCast(@alignCast(scenario_context.?));
    const probe = &state.observer_probe;
    // The observer always sees itself, running, with no suspend point
    // (its own fiber is on the CPU taking the snapshot); the rest of the
    // live set depends on the seed's interleaving but is bounded by the
    // spawn count.
    try testing.expect(probe.observed_self);
    try testing.expect(probe.self_state_was_running);
    try testing.expect(probe.self_suspend_was_null);
    try testing.expect(probe.observed_total >= 1);
    try testing.expect(probe.observed_total <= 1 + observer_worker_count);
}

test "Introspection: listing under seeded concurrent spawn/exit observes a consistent live set" {
    var state = ObserverScenarioState{};
    try deterministic.runSeedSweep(
        testing.allocator,
        1,
        8,
        observerScenario,
        &state,
        .{ .verify_after_run = observerVerify },
    );
}
