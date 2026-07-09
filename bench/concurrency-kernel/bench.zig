//! E1 re-measurement benchmark on the REAL Phase 1 concurrency kernel.
//!
//! Phase 1 exit-gate job P1-J6 of `docs/concurrency-implementation-plan.md`
//! (gate table row E1, "re-run 1"): the Phase 0 E1 spike measured the
//! fork's `std.Io` backends; this benchmark measures the landed bespoke
//! kernel (`src/runtime/concurrency/`) through its REAL paths — scheduler
//! spawn (pid acquire + PCB init + pooled stack + fiber init + ready
//! enqueue), envelope send/receive through real mailboxes, and the futex
//! wake path. Results are recorded in the E1 section of
//! `docs/concurrency-bench-results.md`.
//!
//! ## Benchmarks
//!
//! | Mode | What it does | Per-op meaning |
//! |---|---|---|
//! | `spawn` | timed batches of 256 spawns (pool-hit steady state), untimed run-to-quiescence between batches | spawn admission only |
//! | `spawn-serial` | spawn one trivial process, run to quiescence, repeat | full spawn→run→exit→teardown round trip |
//! | `spawn-lifecycle` | timed (spawn 256 + run all to quiescence) batches | amortized full lifecycle |
//! | `pingpong` | two kernel processes exchange envelopes via `ProcessContext.send`/`receive` through the real scheduler | one message round trip (RTT) |
//! | `wake` | a producer THREAD pushes to a parked scheduler's waiting receiver; wake-to-receive latency | one parked-wake delivery |
//!
//! The spawn batch size (256) matches the stack pool's cache ceiling
//! (`CACHE_RETAIN_CEILING`), and a 512-process warmup wave raises the
//! pool's live peak so the cap is fully available — every timed spawn is
//! then the pool-only hot path the plan's 1.4 item describes. The bench
//! asserts this (`pool_miss_batches` must be 0) rather than assuming it.
//!
//! ## Protocol (E1/E9 ledger conventions)
//!
//! One measurement at a time, foreground. Timing via `CLOCK_UPTIME_RAW`
//! directly (never through kernel code under test). One unrecorded
//! warmup pass (workload/10, min 1000 ops for the spawn modes) then 5
//! timed repetitions; per-rep totals printed, then a `RESULT` line with
//! median + min per-op nanoseconds (wake mode adds the p99 range across
//! reps, per the E9 wakeup convention). Record `uptime` immediately
//! before every timed invocation (the runner's job; see README).
//!
//! ## Manager caveat (honesty note)
//!
//! Per-process managers here are the Phase 1 TEST manager shape (arena +
//! byte accounting, as in the kernel's own tests) — the real per-spawn
//! manager ABI binding is Phase 3. Spawn numbers therefore measure the
//! kernel path with a cheap manager init/teardown, not the eventual
//! ARC-manager cost.
//!
//! ## Toolchain
//!
//! MUST be compiled with the Zap Zig fork (≥ `6a425dbaeb`): optimized
//! builds of fiber code miscompile under stock Zig 0.16.0 (dropped
//! aarch64 x30 clobber — E9 FORK BUG). See README for the exact command.

const std = @import("std");
const builtin = @import("builtin");
const concurrency = @import("concurrency");

const Scheduler = concurrency.Scheduler;
const SchedulerPool = concurrency.SchedulerPool;
const ProcessContext = concurrency.ProcessContext;
const PidTable = concurrency.PidTable;
const EnvelopePool = concurrency.EnvelopePool;
const Pid = concurrency.Pid;
const process_module = concurrency.process;
const envelope_pool_module = concurrency.envelope_pool;
const mailbox_module = concurrency.mailbox;

/// Io-independent monotonic nanosecond clock (CLOCK_UPTIME_RAW), so
/// timing never routes through kernel code under test (E1 convention).
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const repetition_count: usize = 5;

/// Spawn batch size — the stack pool's `CACHE_RETAIN_CEILING`, so a
/// warmed pool serves every batch spawn from cache (module doc).
const spawn_batch_size: usize = 256;

/// Warmup wave that raises the stack pool's live peak to twice the
/// batch, making the full cache ceiling available.
const warmup_live_process_count: usize = 2 * spawn_batch_size;

const Mode = enum {
    spawn,
    @"spawn-serial",
    @"spawn-lifecycle",
    pingpong,
    @"pingpong-pool",
    wake,

    fn defaultOperationCount(mode: Mode) usize {
        return switch (mode) {
            .spawn, .@"spawn-lifecycle" => 102_400, // 400 batches of 256
            .@"spawn-serial" => 102_400,
            .pingpong, .@"pingpong-pool" => 100_000,
            .wake => 100_000,
        };
    }
};

/// Cores for the `pingpong-pool` cross-scheduler mode: two — the minimal
/// genuinely-M:N pool, so the cross-scheduler question ("does a communicating
/// pair collocate on one core, or does the message cross a core boundary and
/// pay a parked wake each round?") is isolated from many-idle-core noise.
const pingpong_pool_core_count: usize = 2;

// -- per-process manager (the Phase 1 test-manager shape; module doc) ---------------------

/// Deliberately a LOCAL copy of the kernel's test-manager shape rather
/// than `src/runtime/concurrency/test_support.zig`'s shared decl: the
/// bench compiles the kernel as a module (`-Mconcurrency=…`), which does
/// not export test support, and this copy drops the teardown counter the
/// tests need but a benchmark must not pay for.
const BenchManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,

    fn managerContext(manager: *BenchManager) process_module.ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *BenchManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *BenchManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *BenchManager = @ptrCast(@alignCast(manager_state.?));
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *BenchManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

// -- kernel wiring -------------------------------------------------------------------------

const BenchKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,

    fn init(kernel: *BenchKernel, allocator: std.mem.Allocator, options: Scheduler.Options) !void {
        kernel.pid_table = try PidTable.init(allocator, .{ .capacity = 4096 });
        kernel.envelope_pool = EnvelopePool.init(allocator, .{});
        kernel.scheduler = Scheduler.init(allocator, &kernel.pid_table, &kernel.envelope_pool, options);
    }

    fn deinit(kernel: *BenchKernel) void {
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }
};

fn trivialEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    _ = argument;
}

// -- spawn modes -----------------------------------------------------------------------------

const SpawnTiming = enum {
    /// Time only the spawn calls; run to quiescence untimed.
    admission_only,
    /// Time spawn + run-to-quiescence together (full lifecycle).
    full_lifecycle,
};

/// One timed repetition of a spawn mode. Returns total timed nanoseconds
/// and bumps `pool_miss_batches` for every batch that could not be
/// served entirely from the stack-pool cache.
fn runSpawnRepetition(
    kernel: *BenchKernel,
    managers: []BenchManager,
    operation_count: usize,
    batch_size: usize,
    timing: SpawnTiming,
    pool_miss_batches: *usize,
) !u64 {
    var timed_ns: u64 = 0;
    var operations_done: usize = 0;
    while (operations_done < operation_count) {
        const this_batch = @min(batch_size, operation_count - operations_done);
        if (kernel.scheduler.stackPoolStatistics().cached_stack_count < this_batch) {
            pool_miss_batches.* += 1;
        }
        const batch_start = nowNanoseconds();
        var spawned: usize = 0;
        while (spawned < this_batch) : (spawned += 1) {
            _ = try kernel.scheduler.spawn(.{
                .entry = trivialEntry,
                .manager = managers[spawned].managerContext(),
            });
        }
        switch (timing) {
            .admission_only => {
                timed_ns += nowNanoseconds() - batch_start;
                try kernel.scheduler.runUntilQuiescent();
            },
            .full_lifecycle => {
                try kernel.scheduler.runUntilQuiescent();
                timed_ns += nowNanoseconds() - batch_start;
            },
        }
        operations_done += this_batch;
    }
    return timed_ns;
}

fn runSpawnMode(
    allocator: std.mem.Allocator,
    operation_count: usize,
    batch_size: usize,
    timing: SpawnTiming,
    mode_name: []const u8,
) !void {
    var kernel: BenchKernel = undefined;
    try kernel.init(allocator, .{});
    defer kernel.deinit();

    const manager_count = @max(batch_size, warmup_live_process_count);
    const managers = try allocator.alloc(BenchManager, manager_count);
    defer allocator.free(managers);
    for (managers) |*manager| {
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }
    defer for (managers) |*manager| manager.arena.deinit();

    // Warmup wave: raise the stack-pool live peak to 2× the batch so the
    // cache ceiling is fully available (module doc), then an unrecorded
    // pass of the measured shape.
    {
        var spawned: usize = 0;
        while (spawned < warmup_live_process_count) : (spawned += 1) {
            _ = try kernel.scheduler.spawn(.{
                .entry = trivialEntry,
                .manager = managers[spawned].managerContext(),
            });
        }
        try kernel.scheduler.runUntilQuiescent();
    }
    var warmup_misses: usize = 0;
    _ = try runSpawnRepetition(
        &kernel,
        managers,
        @max(operation_count / 10, 1000),
        batch_size,
        timing,
        &warmup_misses,
    );

    var per_op_ns: [repetition_count]f64 = undefined;
    var pool_miss_batches: usize = 0;
    for (&per_op_ns, 0..) |*result, repetition| {
        const timed_ns = try runSpawnRepetition(
            &kernel,
            managers,
            operation_count,
            batch_size,
            timing,
            &pool_miss_batches,
        );
        result.* = @as(f64, @floatFromInt(timed_ns)) / @as(f64, @floatFromInt(operation_count));
        std.debug.print("rep {d}: total_ns={d} per_op_ns={d:.1}\n", .{ repetition, timed_ns, result.* });
    }
    printResult(mode_name, &per_op_ns);
    std.debug.print(
        "pool_miss_batches={d} (must be 0 for the pool-only claim) spawn_total={d}\n",
        .{ pool_miss_batches, kernel.scheduler.statistics().spawn_total },
    );
}

// -- pingpong ---------------------------------------------------------------------------------

const PingPongPlan = struct {
    peer: Pid = Pid.invalid,
    rounds: usize,
    completed_rounds: usize = 0,
};

fn pingerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const plan: *PingPongPlan = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < plan.rounds) : (round += 1) {
        const outcome = context.send(plan.peer, .{ .payload_byte_length = round }) catch
            @panic("pinger: envelope allocation failed");
        if (outcome != .delivered) @panic("pinger: send dead-lettered");
        const envelope = context.receive();
        envelope_pool_module.free(envelope);
        plan.completed_rounds += 1;
    }
}

fn pongerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const plan: *PingPongPlan = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < plan.rounds) : (round += 1) {
        const envelope = context.receive();
        envelope_pool_module.free(envelope);
        const outcome = context.send(plan.peer, .{ .payload_byte_length = round }) catch
            @panic("ponger: envelope allocation failed");
        if (outcome != .delivered) @panic("ponger: send dead-lettered");
        plan.completed_rounds += 1;
    }
}

/// One ping-pong repetition: spawn the pair (lazy start — pids can be
/// cross-wired after both spawns because no code runs until the first
/// quantum), then run N round trips to quiescence. The timed region
/// includes the two spawns and teardowns, amortized over ≥100k rounds.
fn runPingPongRepetition(kernel: *BenchKernel, managers: *[2]BenchManager, rounds: usize) !u64 {
    var pinger_plan = PingPongPlan{ .rounds = rounds };
    var ponger_plan = PingPongPlan{ .rounds = rounds };

    const start = nowNanoseconds();
    const pinger_pid = try kernel.scheduler.spawn(.{
        .entry = pingerEntry,
        .argument = &pinger_plan,
        .manager = managers[0].managerContext(),
    });
    const ponger_pid = try kernel.scheduler.spawn(.{
        .entry = pongerEntry,
        .argument = &ponger_plan,
        .manager = managers[1].managerContext(),
    });
    pinger_plan.peer = ponger_pid;
    ponger_plan.peer = pinger_pid;
    try kernel.scheduler.runUntilQuiescent();
    const elapsed = nowNanoseconds() - start;

    if (pinger_plan.completed_rounds != rounds or ponger_plan.completed_rounds != rounds) {
        @panic("pingpong: round accounting mismatch");
    }
    return elapsed;
}

/// Self-verification tolerance on one ping-pong repetition's quantum
/// count above the 2×rounds steady state. The exact expected shape is
/// 2×rounds + 1 (one quantum per process per round trip, plus the
/// pinger's entry quantum that sends round 0 before its first wait); the
/// slack additionally absorbs a few boundary quanta should the
/// scheduler's yield classification ever legitimately shift, while still
/// failing loudly on anything structural (double scheduling, lost wakes,
/// busy-poll receive would all blow far past it).
const pingpong_quantum_slack: u64 = 8;

fn runPingPongMode(allocator: std.mem.Allocator, rounds: usize) !void {
    var kernel: BenchKernel = undefined;
    try kernel.init(allocator, .{});
    defer kernel.deinit();

    var managers: [2]BenchManager = undefined;
    for (&managers) |*manager| {
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }
    defer for (&managers) |*manager| manager.arena.deinit();

    _ = try runPingPongRepetition(&kernel, &managers, @max(rounds / 10, 1000));

    var per_op_ns: [repetition_count]f64 = undefined;
    for (&per_op_ns, 0..) |*result, repetition| {
        const quanta_before = kernel.scheduler.statistics().quantum_total;
        const timed_ns = try runPingPongRepetition(&kernel, &managers, rounds);
        // Self-verification: a round trip is one quantum per process, so
        // the per-op number is only "one message RTT" if this repetition
        // executed ≈ 2×rounds quanta (see `pingpong_quantum_slack`).
        const quanta_this_repetition = kernel.scheduler.statistics().quantum_total - quanta_before;
        if (quanta_this_repetition < 2 * rounds or
            quanta_this_repetition > 2 * rounds + pingpong_quantum_slack)
        {
            std.debug.print(
                "pingpong self-verification FAILED: rep {d} executed {d} quanta, expected [{d}, {d}]\n",
                .{ repetition, quanta_this_repetition, 2 * rounds, 2 * rounds + pingpong_quantum_slack },
            );
            return error.PingPongQuantumAccountingBroken;
        }
        result.* = @as(f64, @floatFromInt(timed_ns)) / @as(f64, @floatFromInt(rounds));
        std.debug.print("rep {d}: total_ns={d} per_rtt_ns={d:.1}\n", .{ repetition, timed_ns, result.* });
    }
    printResult("pingpong", &per_op_ns);
    const stats = kernel.scheduler.statistics();
    // Self-verification: a same-scheduler run must never park — a parked
    // wake (~900 ns) inside the timed region would contaminate the RTT.
    if (stats.park_count != 0) {
        std.debug.print(
            "pingpong self-verification FAILED: park_count={d}, expected 0 for a same-scheduler run\n",
            .{stats.park_count},
        );
        return error.PingPongParked;
    }
    std.debug.print(
        "quantum_total={d} park_count={d} (self-verified: ~2 quanta per round trip, zero parks)\n",
        .{ stats.quantum_total, stats.park_count },
    );
}

// -- pingpong-pool (collocated communicating pair on the M:N pool; Phase-4 E1) -----------------

/// One ping-pong repetition on the REAL M:N pool (P4-J1). Two processes are
/// admitted to the primary core; the pool's worker threads then run them. The
/// timed region includes the pool's per-run worker spawn/join (amortized over
/// ≥100k rounds — negligible per RTT). Returns elapsed nanoseconds.
fn runPingPongPoolRepetition(pool: *SchedulerPool, managers: *[2]BenchManager, rounds: usize) !u64 {
    var pinger_plan = PingPongPlan{ .rounds = rounds };
    var ponger_plan = PingPongPlan{ .rounds = rounds };

    const start = nowNanoseconds();
    const pinger_pid = try pool.primaryCore().spawn(.{
        .entry = pingerEntry,
        .argument = &pinger_plan,
        .manager = managers[0].managerContext(),
    });
    const ponger_pid = try pool.primaryCore().spawn(.{
        .entry = pongerEntry,
        .argument = &ponger_plan,
        .manager = managers[1].managerContext(),
    });
    pinger_plan.peer = ponger_pid;
    ponger_plan.peer = pinger_pid;
    pool.runUntilQuiescent();
    const elapsed = nowNanoseconds() - start;

    if (pinger_plan.completed_rounds != rounds or ponger_plan.completed_rounds != rounds) {
        @panic("pingpong-pool: round accounting mismatch");
    }
    return elapsed;
}

/// The Phase-4 E1 communicating-pair re-measurement (plan Phase-4 exit gate): a
/// two-process ping-pong on a real 2-core M:N pool. Both processes are admitted
/// to the primary core with NO pinning, so — as the reported per-core quantum
/// split and park count confirm — the wake-locality LIFO slot (research.md
/// §6.1) COLLOCATES the pair onto one core (~96 % of RTTs same-core, ~15–23
/// parks per 500k). This mode therefore measures the COLLOCATED-pair RTT (≈ the
/// same-scheduler hot path), which is what the M:N scheduler actually does with
/// a chatty pair — it does NOT measure a sustained cross-core RTT (that would
/// require pinning the pair apart and defeating the wake locality the scheduler
/// exists to provide). The genuine per-hop cross-core cost is measured directly
/// by the `wake` mode (a parked cross-core wake); a forced-cross sustained RTT
/// is the analytic 2×-parked-wake bound. See docs/concurrency-bench-results.md
/// E1 for the honest decomposition.
fn runPingPongPoolMode(allocator: std.mem.Allocator, rounds: usize) !void {
    var pid_table = try PidTable.init(allocator, .{ .capacity = 4096 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(allocator, .{});
    defer envelope_pool.deinit();

    var managers: [2]BenchManager = undefined;
    for (&managers) |*manager| {
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }
    defer for (&managers) |*manager| manager.arena.deinit();

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, allocator, &pid_table, &envelope_pool, .{
        .scheduler_count = pingpong_pool_core_count,
    });
    defer pool.deinit();

    // Warmup (unrecorded): raises per-core stack pool / record caches.
    _ = try runPingPongPoolRepetition(&pool, &managers, @max(rounds / 10, 1000));

    var per_op_ns: [repetition_count]f64 = undefined;
    for (&per_op_ns, 0..) |*result, repetition| {
        const stats_before = pool.statistics();
        const timed_ns = try runPingPongPoolRepetition(&pool, &managers, rounds);
        const stats_after = pool.statistics();
        result.* = @as(f64, @floatFromInt(timed_ns)) / @as(f64, @floatFromInt(rounds));
        std.debug.print("rep {d}: total_ns={d} per_rtt_ns={d:.1} parks_this_rep={d}\n", .{
            repetition,
            timed_ns,
            result.*,
            stats_after.park_count - stats_before.park_count,
        });
    }
    printResult("pingpong-pool", &per_op_ns);

    // The decomposition: per-core quanta (collocation ⇒ one core carries ≈ all
    // the RTT quanta; genuine crossing ⇒ the two cores split them) and total
    // parks (collocation ⇒ the idle sibling parks; per-round crossing ⇒ parks
    // scale with rounds).
    const stats = pool.statistics();
    std.debug.print("cores={d} total_parks={d} total_quanta={d}\n", .{
        pool.coreCount(),
        stats.park_count,
        stats.quantum_total,
    });
    for (pool.cores, 0..) |*core, core_index| {
        std.debug.print("  core {d}: quanta={d} parks={d}\n", .{
            core_index,
            core.statistics().quantum_total,
            core.statistics().park_count,
        });
    }
}

// -- wake path ---------------------------------------------------------------------------------

/// Shared producer↔receiver state for the wake benchmark. `sent_at_ns`
/// is written by the producer thread strictly before its mailbox push
/// (the push's release edge publishes it to the receiver's pop).
const WakeShared = struct {
    scheduler: *Scheduler,
    envelope_pool: *EnvelopePool,
    receiver_mailbox: *mailbox_module.Mailbox = undefined,
    latencies_ns: []u64,
    sent_at_ns: std.atomic.Value(u64) = .init(0),
    producer_failed: bool = false,
};

const WakeReceiverProbe = struct {
    shared: *WakeShared,
    message_count: usize,
};

fn wakeReceiverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *WakeReceiverProbe = @ptrCast(@alignCast(argument.?));
    var received: usize = 0;
    while (received < probe.message_count) : (received += 1) {
        const envelope = context.receive();
        const received_at = nowNanoseconds();
        envelope_pool_module.free(envelope);
        probe.shared.latencies_ns[received] = received_at - probe.shared.sent_at_ns.load(.acquire);
    }
}

const WakeProducer = struct {
    shared: *WakeShared,
    message_count: usize,

    /// Busy-wait after observing a park so the scheduler is inside (not
    /// merely entering) the futex wait — the E9 wakeup-bench discipline.
    const settle_nanoseconds: u64 = 20 * std.time.ns_per_us;

    fn run(producer: *WakeProducer) void {
        const shared = producer.shared;
        var handle = EnvelopePool.Handle.init(shared.envelope_pool);
        defer handle.abandon();
        var observed_park_count = shared.scheduler.parkCount();
        var sent: usize = 0;
        while (sent < producer.message_count) : (sent += 1) {
            // Wait for the scheduler to park (bounded loudly).
            const deadline_ns = nowNanoseconds() + 30 * std.time.ns_per_s;
            while (shared.scheduler.parkCount() <= observed_park_count) {
                if (nowNanoseconds() > deadline_ns) {
                    shared.producer_failed = true;
                    return;
                }
                std.atomic.spinLoopHint();
            }
            observed_park_count = shared.scheduler.parkCount();
            const settle_until = nowNanoseconds() + settle_nanoseconds;
            while (nowNanoseconds() < settle_until) std.atomic.spinLoopHint();

            const envelope = handle.allocate() catch {
                shared.producer_failed = true;
                return;
            };
            envelope.fragment = .{ .payload_byte_length = sent };
            shared.sent_at_ns.store(nowNanoseconds(), .release);
            _ = shared.receiver_mailbox.push(envelope);
        }
    }
};

fn runWakeRepetition(
    kernel: *BenchKernel,
    manager: *BenchManager,
    latencies_ns: []u64,
) !void {
    var shared = WakeShared{
        .scheduler = &kernel.scheduler,
        .envelope_pool = &kernel.envelope_pool,
        .latencies_ns = latencies_ns,
    };
    var probe = WakeReceiverProbe{ .shared = &shared, .message_count = latencies_ns.len };
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = wakeReceiverEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    shared.receiver_mailbox = &kernel.pid_table.lookup(receiver_pid).?.mailbox;

    var producer = WakeProducer{ .shared = &shared, .message_count = latencies_ns.len };
    const producer_thread = try std.Thread.spawn(.{}, WakeProducer.run, .{&producer});
    try kernel.scheduler.runUntilQuiescent();
    producer_thread.join();
    if (shared.producer_failed) return error.WakeProducerTimedOut;
}

fn runWakeMode(allocator: std.mem.Allocator, message_count: usize) !void {
    var kernel: BenchKernel = undefined;
    try kernel.init(allocator, .{
        // Long park bound so timeout re-parks cannot contaminate the
        // parked-wake distribution (still bounded; module doc).
        .park_timeout_nanoseconds = 1 * std.time.ns_per_s,
    });
    defer kernel.deinit();

    var manager = BenchManager{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer manager.arena.deinit();

    const latencies_ns = try allocator.alloc(u64, message_count);
    defer allocator.free(latencies_ns);

    // Warmup (unrecorded).
    try runWakeRepetition(&kernel, &manager, latencies_ns[0..@max(message_count / 10, 100)]);

    var medians: [repetition_count]f64 = undefined;
    var p99s: [repetition_count]u64 = undefined;
    var global_min: u64 = std.math.maxInt(u64);
    for (&medians, 0..) |*rep_median, repetition| {
        try runWakeRepetition(&kernel, &manager, latencies_ns);
        std.mem.sort(u64, latencies_ns, {}, std.sort.asc(u64));
        rep_median.* = @floatFromInt(latencies_ns[latencies_ns.len / 2]);
        p99s[repetition] = latencies_ns[(latencies_ns.len * 99) / 100];
        global_min = @min(global_min, latencies_ns[0]);
        std.debug.print("rep {d}: median_ns={d:.0} min_ns={d} p99_ns={d} max_ns={d}\n", .{
            repetition,
            rep_median.*,
            latencies_ns[0],
            p99s[repetition],
            latencies_ns[latencies_ns.len - 1],
        });
    }
    std.mem.sort(f64, &medians, {}, std.sort.asc(f64));
    std.mem.sort(u64, &p99s, {}, std.sort.asc(u64));
    std.debug.print(
        "RESULT bench=wake median_ns={d:.0} min_ns={d} p99_range_ns={d}-{d} parks={d}\n",
        .{
            medians[repetition_count / 2],
            global_min,
            p99s[0],
            p99s[repetition_count - 1],
            kernel.scheduler.parkCount(),
        },
    );
}

// -- reporting -----------------------------------------------------------------------------------

fn printResult(mode_name: []const u8, per_op_ns: *[repetition_count]f64) void {
    var sorted = per_op_ns.*;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    std.debug.print(
        "RESULT bench={s} median_per_op_ns={d:.1} min_per_op_ns={d:.1}\n",
        .{ mode_name, sorted[repetition_count / 2], sorted[0] },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `Init.Minimal` hands over argv without start.zig constructing an
    // implicit Io instance (the E1-spike convention).
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    var arguments: std.process.Args.Iterator = .init(init.args);
    _ = arguments.next(); // program name
    const mode_text = arguments.next() orelse {
        std.debug.print(
            "usage: bench <spawn|spawn-serial|spawn-lifecycle|pingpong|pingpong-pool|wake> [ops]\n",
            .{},
        );
        return error.MissingMode;
    };
    const mode = std.meta.stringToEnum(Mode, mode_text) orelse return error.UnknownMode;
    const operation_count = if (arguments.next()) |ops_text|
        try std.fmt.parseInt(usize, ops_text, 10)
    else
        mode.defaultOperationCount();

    std.debug.print("mode={s} ops={d} reps={d} build={s}\n", .{
        mode_text,
        operation_count,
        repetition_count,
        @tagName(builtin.mode),
    });

    switch (mode) {
        .spawn => try runSpawnMode(allocator, operation_count, spawn_batch_size, .admission_only, "spawn"),
        .@"spawn-serial" => try runSpawnMode(allocator, operation_count, 1, .full_lifecycle, "spawn-serial"),
        .@"spawn-lifecycle" => try runSpawnMode(allocator, operation_count, spawn_batch_size, .full_lifecycle, "spawn-lifecycle"),
        .pingpong => try runPingPongMode(allocator, operation_count),
        .@"pingpong-pool" => try runPingPongPoolMode(allocator, operation_count),
        .wake => try runWakeMode(allocator, operation_count),
    }
}
