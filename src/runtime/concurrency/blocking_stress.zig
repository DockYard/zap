//! End-to-end tests for the blocking / dirty-scheduler pool + the
//! `Process.blocking` fiber-evacuation handoff (P4-J3, plan item 4.3).
//!
//! These exercise the WHOLE path — a green process yields `.blocking_offload`,
//! its fiber is evacuated to a blocking-pool OS thread, the op runs off-core,
//! and the process re-attaches onto a core — through a real `SchedulerPool`
//! (which owns the real `BlockingPool`). `blocking_pool.zig`'s own tests cover
//! the pool's queue/park/growth mechanics in isolation; here the fiber
//! evacuation is real.
//!
//! ## The load-bearing property (deliverable 5, "co-scheduled progress")
//!
//! The first test is a LIVENESS proof that a `Process.blocking` call does NOT
//! stall its core: on a ONE-CORE pool, a process that blocks yields its fiber to
//! the pool, freeing that single core to run a co-scheduled process — and the
//! run only completes if that co-scheduled process makes progress WHILE the
//! first is blocked (the blocking op spins until it observes that progress). If
//! the block stalled the core (a broken mechanism, or the inline degradation),
//! the co-scheduled process would never run, no progress would be observed, and
//! the op would spin to its safety deadline — failing the progress assertion.
//!
//! ## ThreadSanitizer posture
//!
//! The fiber-evacuation tests RESUME a fiber on a blocking-pool thread, and
//! TSan's trace machinery faults (SEGV/ILL inside `__tsan::`) on manual fiber
//! context-switch volume — a documented TSan-runtime limitation, NOT a kernel
//! race (see `mn_refcount_stress.zig`). They are therefore skipped under
//! `-fsanitize-thread` and proven at high volume under the normal build. The
//! detach/re-attach HANDOFF's scheduler-local invariant is proven TSan-clean by
//! TWO instrumentable ingredients that carry no fiber switch: (a) the
//! `handoffEdge` test below — the pool's submit → execute → quiesce chain
//! establishes happens-before for NON-ATOMIC data, TSan-clean; and (b) the
//! re-attach edge, which reuses the very `wake_stack` Treiber + `wake()`
//! eventcount pattern `mn_refcount_stress.zig` already proves TSan-clean for
//! message wakes (`pushReattach`/`drainReattachStack` mirror `pushWake`/
//! `drainWakeStack`). Together they cover both halves of the core → pool → core
//! handoff without hitting the fiber-switch limitation.

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const scheduler_pool_module = @import("scheduler_pool.zig");
const blocking_pool_module = @import("blocking_pool.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const process_module = @import("process.zig");

const testing = std.testing;
const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const SchedulerPool = scheduler_pool_module.SchedulerPool;
const BlockingPool = blocking_pool_module.BlockingPool;
const ProcessContext = scheduler_module.ProcessContext;
const ProcessRecord = scheduler_module.ProcessRecord;
const ManagerContext = process_module.ManagerContext;
const ManagerVTable = process_module.ManagerVTable;

const tsan = @import("builtin").sanitize_thread;

/// Monotonic nanoseconds (the fork's std has no `std.time.Timer`; mirrors the
/// E8/blocking-pool clock helper).
fn nowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Thread-safe no-allocation test manager: process bodies here touch only
/// shared atomics (never the manager heap), so `allocate` is a no-op and the
/// only per-manager state is an ATOMIC teardown counter — safe to share across
/// cores because teardown runs on whichever core last ran each process. One
/// teardown per spawn is the leak-exactness signal (mirrors the `PoolTestManager`
/// in `scheduler_pool.zig`).
const BlockingTestManager = struct {
    teardown_count: std.atomic.Value(usize) = .init(0),

    fn managerContext(manager: *BlockingTestManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(_: ?*anyopaque, _: usize, _: std.mem.Alignment) ?[*]u8 {
        return null;
    }
    fn deallocateThunk(_: ?*anyopaque, _: [*]u8, _: usize, _: std.mem.Alignment) void {}
    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *BlockingTestManager = @ptrCast(@alignCast(manager_state.?));
        _ = manager.teardown_count.fetchAdd(1, .monotonic);
    }
    fn heapByteCountThunk(_: ?*anyopaque) usize {
        return 0;
    }
};

// ===========================================================================
// Test 1 — co-scheduled progress during a block (the load-bearing liveness proof)
// ===========================================================================

const CoScheduledState = struct {
    /// How much progress the co-scheduled process must make while the first is
    /// blocked for the block to be released.
    target: u64,
    /// Advanced by the co-scheduled process each loop iteration.
    other_progress: std.atomic.Value(u64) = .init(0),
    /// Set once the blocking process has returned from its `Process.blocking`.
    blocker_done: std.atomic.Value(bool) = .init(false),
};

/// The blocking op (runs on a blocking-pool thread): spin until the co-scheduled
/// process has advanced `target` steps — which can ONLY happen if the core the
/// blocker came from is free to run it. A generous wall-clock deadline makes a
/// broken mechanism fail via the progress assertion instead of hanging forever.
fn spinUntilOtherProgresses(operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *CoScheduledState = @ptrCast(@alignCast(operation_argument.?));
    const deadline = nowNanoseconds() + 10 * std.time.ns_per_s;
    while (state.other_progress.load(.acquire) < state.target) {
        if (nowNanoseconds() >= deadline) break;
        std.atomic.spinLoopHint();
    }
    return null;
}

fn coScheduledBlockerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *CoScheduledState = @ptrCast(@alignCast(argument.?));
    _ = context.blocking(spinUntilOtherProgresses, argument);
    state.blocker_done.store(true, .release);
}

fn coScheduledPeerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *CoScheduledState = @ptrCast(@alignCast(argument.?));
    // Make progress until the blocker has finished (and thus been released),
    // yielding each step so the single core round-robins us with the blocker's
    // re-attach.
    while (!state.blocker_done.load(.acquire)) {
        _ = state.other_progress.fetchAdd(1, .monotonic);
        context.yieldNow();
    }
}

test "blocking: a Process.blocking call does NOT stall its core — a co-scheduled process keeps making progress (1-core liveness)" {
    if (tsan) return error.SkipZigTest; // fiber resume on a pool thread faults TSan (module doc)

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = BlockingTestManager{};
    var state = CoScheduledState{ .target = 2000 };

    // ONE core: the blocker's evacuation MUST free this single core for the peer.
    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 1 });
    defer pool.deinit();

    _ = try pool.primaryCore().spawn(.{
        .entry = coScheduledBlockerBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    _ = try pool.primaryCore().spawn(.{
        .entry = coScheduledPeerBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    // The peer made the required progress WHILE the blocker was blocked — proving
    // the single core was free the whole time (the whole point of the pool).
    try testing.expect(state.other_progress.load(.acquire) >= state.target);
    try testing.expect(state.blocker_done.load(.acquire));
    // The blocker genuinely went through the offload/re-attach path (not inline).
    const pool_stats = pool.statistics();
    try testing.expectEqual(@as(u64, 1), pool_stats.blocking_offload_total);
    try testing.expectEqual(@as(u64, 1), pool_stats.blocking_reattach_total);
    const blocking_stats = pool.blockingPoolStatistics();
    try testing.expectEqual(@as(u64, 1), blocking_stats.submit_total);
    try testing.expectEqual(@as(u64, 1), blocking_stats.execute_total);
    // Leak-exact: both processes torn down once, every pid and page reclaimed.
    try testing.expectEqual(@as(usize, 2), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// ===========================================================================
// Test 2 — the block returns the correct result across the re-attach
// ===========================================================================

const ResultState = struct {
    result_bits: std.atomic.Value(usize) = .init(0),
};

fn computeAnswerOffCore(operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = operation_argument;
    // A distinctive non-null sentinel the caller decodes; never dereferenced.
    return @ptrFromInt(0xA55E_7);
}

fn resultBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *ResultState = @ptrCast(@alignCast(argument.?));
    const result = context.blocking(computeAnswerOffCore, null);
    // `result` lives on this fiber's stack across BOTH migrations (core → pool →
    // core); it must survive intact.
    state.result_bits.store(@intFromPtr(result), .release);
}

test "blocking: the operation's result survives the off-core round trip and is returned after re-attach" {
    if (tsan) return error.SkipZigTest;

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = BlockingTestManager{};
    var state = ResultState{};

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 2 });
    defer pool.deinit();

    _ = try pool.primaryCore().spawn(.{
        .entry = resultBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 0xA55E_7), state.result_bits.load(.acquire));
    try testing.expectEqual(@as(usize, 1), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// ===========================================================================
// Test 3 — N processes each blocking run on the pool without stalling the cores
// ===========================================================================

const ManyBlockersState = struct {
    completed: std.atomic.Value(u64) = .init(0),
    busy_nanoseconds: u64,
};

fn briefBusyBlock(operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *ManyBlockersState = @ptrCast(@alignCast(operation_argument.?));
    const deadline = nowNanoseconds() + state.busy_nanoseconds;
    while (nowNanoseconds() < deadline) std.atomic.spinLoopHint();
    return null;
}

fn manyBlockersBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *ManyBlockersState = @ptrCast(@alignCast(argument.?));
    _ = context.blocking(briefBusyBlock, argument);
    _ = state.completed.fetchAdd(1, .monotonic);
}

test "blocking: N processes each blocking concurrently run on the pool (it grows) and all complete, leak-exact" {
    if (tsan) return error.SkipZigTest;

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 128 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = BlockingTestManager{};
    // Each op busy-blocks ~3 ms so the blocks genuinely overlap and the pool must
    // grow additional workers to run them in parallel.
    var state = ManyBlockersState{ .busy_nanoseconds = 3 * std.time.ns_per_ms };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    const blocker_count: usize = 24;
    for (0..blocker_count) |_| {
        _ = try pool.primaryCore().spawn(.{
            .entry = manyBlockersBody,
            .argument = &state,
            .manager = manager.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    try testing.expectEqual(@as(u64, blocker_count), state.completed.load(.monotonic));
    const pool_stats = pool.statistics();
    try testing.expectEqual(@as(u64, blocker_count), pool_stats.blocking_offload_total);
    try testing.expectEqual(@as(u64, blocker_count), pool_stats.blocking_reattach_total);
    // The concurrent blocks grew the blocking pool beyond its single eager worker.
    const blocking_stats = pool.blockingPoolStatistics();
    try testing.expectEqual(@as(u64, blocker_count), blocking_stats.execute_total);
    try testing.expect(blocking_stats.peak_thread_count > 1);
    try testing.expect(blocking_stats.peak_thread_count <= blocking_pool_module.default_max_thread_count);
    // Leak-exact.
    try testing.expectEqual(@as(usize, blocker_count), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// ===========================================================================
// Test 4 — a process killed WHILE blocking re-attaches, then tears down (killed)
// ===========================================================================

const KillWhileBlockingState = struct {
    manager: *BlockingTestManager,
    blocker_pid_bits: std.atomic.Value(u64) = .init(0),
    blocker_is_blocking: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    /// Set by the blocker's continuation — MUST stay false: the kill takes effect
    /// at re-attach, before the continuation runs (native code is never
    /// interrupted, so the block finishes, then teardown pre-empts the resume).
    blocker_survived_block: std.atomic.Value(bool) = .init(false),
};

fn blockUntilReleased(operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *KillWhileBlockingState = @ptrCast(@alignCast(operation_argument.?));
    state.blocker_is_blocking.store(true, .release);
    const deadline = nowNanoseconds() + 10 * std.time.ns_per_s;
    while (!state.release.load(.acquire)) {
        if (nowNanoseconds() >= deadline) break;
        std.atomic.spinLoopHint();
    }
    return null;
}

fn killWhileBlockingBlockerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *KillWhileBlockingState = @ptrCast(@alignCast(argument.?));
    _ = context.blocking(blockUntilReleased, argument);
    // Unreachable if killed while blocking — the kill pre-empts this resume.
    state.blocker_survived_block.store(true, .release);
}

fn killWhileBlockingKillerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *KillWhileBlockingState = @ptrCast(@alignCast(argument.?));
    // Wait until the blocker is genuinely blocking off-core, then kill it and
    // release the block. The kill therefore lands during the block; it takes
    // effect at re-attach.
    const deadline = nowNanoseconds() + 10 * std.time.ns_per_s;
    while (!state.blocker_is_blocking.load(.acquire)) {
        if (nowNanoseconds() >= deadline) break;
        context.yieldNow();
    }
    const blocker = Pid.fromBits(state.blocker_pid_bits.load(.acquire));
    _ = context.kill(blocker);
    state.release.store(true, .release);
}

test "blocking: a process killed while blocking finishes its op off-core, re-attaches, and tears down killed (leak-exact)" {
    if (tsan) return error.SkipZigTest;

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = BlockingTestManager{};
    var state = KillWhileBlockingState{ .manager = &manager };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 2 });
    defer pool.deinit();

    const blocker = try pool.primaryCore().spawn(.{
        .entry = killWhileBlockingBlockerBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    state.blocker_pid_bits.store(blocker.toBits(), .release);
    _ = try pool.primaryCore().spawn(.{
        .entry = killWhileBlockingKillerBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    // The kill landed during the block and took effect at re-attach — the
    // blocker's continuation never ran.
    try testing.expectEqual(false, state.blocker_survived_block.load(.acquire));
    // Both processes torn down exactly once; everything reclaimed.
    try testing.expectEqual(@as(usize, 2), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// ===========================================================================
// Test 5 — the scheduler-local invariant: a process's OWN non-atomic datum is
// touched core → pool → core across the handoff, never concurrently
// ===========================================================================

/// Per-process state with a deliberately NON-ATOMIC counter: the process touches
/// it on its core before the block, the blocking op touches it on a pool thread
/// during the block, and the process touches it on a core after re-attach. If
/// the detach/re-attach handoff failed to serialize these — if two threads ever
/// ran the process at once — an increment would be lost (or torn). A final value
/// of exactly 3 across many processes proves the invariant holds.
const InvariantState = struct {
    private_counter: u64 = 0, // NON-ATOMIC — single-owner across the whole episode
    completed: std.atomic.Value(u64) = .init(0),
    correct: std.atomic.Value(u64) = .init(0),
};

fn touchPrivateCounterOffCore(operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *InvariantState = @ptrCast(@alignCast(operation_argument.?));
    // Runs on a blocking-pool thread. The core's pre-block increment happens-
    // before this (submit → pop edge); this happens-before the core's post-block
    // increment (re-attach edge). So this non-atomic RMW is race-free.
    state.private_counter += 1;
    return null;
}

fn invariantBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *InvariantState = @ptrCast(@alignCast(argument.?));
    state.private_counter += 1; // on the core, before the block
    _ = context.blocking(touchPrivateCounterOffCore, argument); // on a pool thread
    state.private_counter += 1; // on a core, after re-attach
    _ = state.completed.fetchAdd(1, .monotonic);
    if (state.private_counter == 3) _ = state.correct.fetchAdd(1, .monotonic);
}

test "blocking: a process's own non-atomic datum is handed off core → pool → core intact (scheduler-local invariant)" {
    if (tsan) return error.SkipZigTest; // fiber resume on a pool thread faults TSan (module doc)

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 128 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = BlockingTestManager{};

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    // Each process owns its OWN `InvariantState` (its own private counter), so a
    // wrong final value could only come from the handoff running the process on
    // two threads at once — the exact violation this asserts against.
    const process_count: usize = 64;
    const states = try testing.allocator.alloc(InvariantState, process_count);
    defer testing.allocator.free(states);
    for (states) |*state| state.* = .{};

    for (states) |*state| {
        _ = try pool.primaryCore().spawn(.{
            .entry = invariantBody,
            .argument = state,
            .manager = manager.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    // Every process's own non-atomic counter reached exactly 3 — the three
    // touches (core, pool, core) were serialized by the handoff edges.
    var total_correct: u64 = 0;
    for (states) |*state| {
        try testing.expectEqual(@as(u64, 3), state.private_counter);
        total_correct += state.correct.load(.monotonic);
    }
    try testing.expectEqual(@as(u64, process_count), total_correct);
    try testing.expectEqual(@as(usize, process_count), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// ===========================================================================
// Test 6 — the handoff's happens-before edge for NON-ATOMIC data (TSan-clean)
// ===========================================================================

/// A non-atomic counter deliberately: TSan watches every access. The pool's
/// submit → pop → execute → signalQuiescent → quiesce chain must establish the
/// happens-before that makes the core-thread and worker-thread accesses to it
/// race-free WITHOUT any atomic on the datum itself.
const HandoffEdgeState = struct {
    counter: u64 = 0,
};

fn handoffEdgeExecute(execute_context: ?*anyopaque, record: *ProcessRecord) void {
    _ = record;
    const state: *HandoffEdgeState = @ptrCast(@alignCast(execute_context.?));
    // The value the submitting thread wrote before `submit` must be visible here
    // via the submit(release) → pop(acquire) edge — no atomic on `counter`.
    std.debug.assert(state.counter == 100);
    state.counter = 200;
}

test "blocking: the pool handoff establishes happens-before for non-atomic data (submit → execute → quiesce), TSan-clean" {
    // Runs UNDER ThreadSanitizer: no fiber switch here — this exercises only the
    // pool's release/acquire edges (`state_lock`, the work/idle eventcounts), the
    // core → pool half of the invariant handoff. The pool → core (re-attach) half
    // reuses the wake_stack Treiber + eventcount pattern that `mn_refcount_stress`
    // already proves TSan-clean.
    var state = HandoffEdgeState{};
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, handoffEdgeExecute, &state, .{});
    defer pool.deinit();

    const iterations: usize = if (tsan) 64 else 4096;
    for (0..iterations) |_| {
        state.counter = 100; // non-atomic write, happens-before submit
        var record: ProcessRecord = undefined;
        record.blocking_next = null;
        pool.submit(&record);
        pool.quiesce();
        try testing.expectEqual(@as(u64, 200), state.counter); // non-atomic read, after quiesce
    }
}
