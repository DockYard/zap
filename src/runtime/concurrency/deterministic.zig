//! Seeded deterministic scheduler mode for the Zap concurrency kernel.
//!
//! Phase 1 item 1.5 of `docs/concurrency-implementation-plan.md` (job
//! P1-J4), implementing locked design decision 11 and research.md §6.11
//! (FoundationDB's core trick): ALL scheduler nondeterminism is funneled
//! through injectable seams, so a seeded single-threaded run is FULLY
//! reproducible — same seed ⇒ byte-identical event trace — and a failing
//! seeded test prints its seed for exact replay.
//!
//! ## What is seeded (the seam inventory)
//!
//! The scheduler's `Decisions` seam (`scheduler.zig`) owns every decision
//! point with more than one legal answer; `SeededDecisions` drives both
//! of them from one PRNG:
//!
//! * **next-runnable choice** — a uniformly random index into the ready
//!   queue whenever more than one process is runnable (production: FIFO);
//! * **per-quantum preemption budget** — uniform in `[1, configured]`,
//!   which moves every budget-driven preemption point (production: the
//!   configured value).
//!
//! Everything else a deterministic run does is already a pure function of
//! those choices: the run is single-threaded (no producer threads, no
//! races), parking is FORBIDDEN (`IdleStrategy.forbid_parking` — a
//! deterministic run that would park is a deadlocked scenario and
//! surfaces as `error.AllProcessesWaiting`, never as a real futex sleep),
//! and the wake stack, ready queue, pid table, and pools are all
//! deterministic under a single thread. Phase 4 extends the seam
//! inventory to multi-scheduler interleaving and timer firing (plan 4.4);
//! the contract stays the same: adding a nondeterministic mechanism to
//! the kernel REQUIRES adding its decision to the seam.
//!
//! ## Trace recording and replay
//!
//! `TraceRecorder` captures the scheduler's `TraceEvent` stream
//! (spawn/schedule/yield/wait/wake/exit/kill, each with the pid) through
//! the trace seam, append-only and in program order. Two runs of the same
//! scenario are equivalent iff `tracesIdentical` — the property the
//! same-seed test asserts and seed sweeps rely on.
//!
//! ## The failing-seed contract
//!
//! `runScenario` prints the seed to stderr on ANY failure (scenario
//! setup, scheduling deadlock, invariant verification) before returning
//! the error — the plan 1.5 contract: any seeded kernel test that fails
//! must print its seed for exact replay. `runSeedSweep` runs a scenario
//! across a seed range (verona-rt-style), so interleaving-dependent bugs
//! surface with a replayable seed instead of a flaky CI run.
//!
//! ## Harness
//!
//! `Harness` bundles one deterministic kernel instance (pid table +
//! envelope pool + scheduler wired for seeded decisions, forbidden
//! parking, and trace recording) plus per-process arena managers, so a
//! scenario is just "spawn bodies, run, verify". This is the substrate
//! the Phase 2.7 Zest concurrency wrappers (`lib/zest/…`) will layer on.
//!
//! ## Toolchain
//!
//! Drives the scheduler (fiber switches), so the kernel-wide
//! fork-compiler requirement for optimized builds applies (see
//! `concurrency.zig`).

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const mailbox_module = @import("mailbox.zig");
const process_module = @import("process.zig");

const Scheduler = scheduler_module.Scheduler;
const TraceEvent = scheduler_module.TraceEvent;
const Decisions = scheduler_module.Decisions;
const ProcessContext = scheduler_module.ProcessContext;
const ProcessEntry = scheduler_module.ProcessEntry;
const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;

/// The seeded implementation of the scheduler's `Decisions` seam: one
/// PRNG (xoshiro256++, `std.Random.DefaultPrng` — a pure function of the
/// seed) drives every decision. PINNED once handed to a scheduler (the
/// `Decisions` value carries a pointer to this struct).
pub const SeededDecisions = struct {
    /// The seed-deterministic generator.
    prng: std.Random.DefaultPrng,
    /// Whether quantum budgets are randomized in `[1, configured]`
    /// (moving every preemption point) or left at the configured value.
    randomize_quantum_budget: bool,

    /// Create the seeded decision source.
    pub fn init(seed: u64, randomize_quantum_budget: bool) SeededDecisions {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .randomize_quantum_budget = randomize_quantum_budget,
        };
    }

    /// The `Decisions` view to install into `Scheduler.Options`. The
    /// returned value points at `seeded`, which must stay pinned.
    pub fn decisions(seeded: *SeededDecisions) Decisions {
        return .{ .decision_context = seeded, .vtable = &seeded_vtable };
    }

    const seeded_vtable = Decisions.VTable{
        .chooseNextReadyIndex = chooseNextReadyIndexThunk,
        .chooseQuantumBudget = chooseQuantumBudgetThunk,
    };

    fn chooseNextReadyIndexThunk(decision_context: ?*anyopaque, ready_count: usize) usize {
        const seeded: *SeededDecisions = @ptrCast(@alignCast(decision_context.?));
        std.debug.assert(ready_count > 0);
        return seeded.prng.random().uintLessThan(usize, ready_count);
    }

    fn chooseQuantumBudgetThunk(decision_context: ?*anyopaque, configured_budget: u32) u32 {
        const seeded: *SeededDecisions = @ptrCast(@alignCast(decision_context.?));
        std.debug.assert(configured_budget > 0);
        if (!seeded.randomize_quantum_budget) return configured_budget;
        return 1 + seeded.prng.random().uintLessThan(u32, configured_budget);
    }
};

/// Append-only recorder for the scheduler's trace seam. Records every
/// event in program order; two runs compare with `tracesIdentical`.
/// Panics on out-of-memory — the trace hook cannot return errors and a
/// truncated trace would silently break replay comparison, so the
/// recorder fails loudly instead (test-harness posture, plan 1.5).
pub const TraceRecorder = struct {
    /// Allocator backing the event log.
    allocator: std.mem.Allocator,
    /// The recorded events, oldest first.
    events: std.ArrayList(TraceEvent),

    /// Create an empty recorder.
    pub fn init(allocator: std.mem.Allocator) TraceRecorder {
        return .{ .allocator = allocator, .events = .empty };
    }

    /// Free the event log.
    pub fn deinit(recorder: *TraceRecorder) void {
        recorder.events.deinit(recorder.allocator);
        recorder.* = undefined;
    }

    /// The recorded event sequence (borrowed; valid until the next
    /// record or deinit).
    pub fn recorded(recorder: *const TraceRecorder) []const TraceEvent {
        return recorder.events.items;
    }

    /// The `TraceHook` thunk to install into `Scheduler.Options`
    /// (`trace_context` = the recorder).
    pub fn hookThunk(trace_context: ?*anyopaque, event: TraceEvent) void {
        const recorder: *TraceRecorder = @ptrCast(@alignCast(trace_context.?));
        recorder.events.append(recorder.allocator, event) catch
            @panic("TraceRecorder: out of memory recording a trace event");
    }
};

/// Whether two traces are byte-identical (same events, same pids, same
/// order) — the equality the same-seed reproducibility contract is
/// stated in.
pub fn tracesIdentical(first: []const TraceEvent, second: []const TraceEvent) bool {
    if (first.len != second.len) return false;
    for (first, second) |first_event, second_event| {
        if (!std.meta.eql(first_event, second_event)) return false;
    }
    return true;
}

/// A scenario body: spawns processes (and may stash context for
/// post-run verification). Runs BEFORE the scheduler starts; the spawned
/// processes run when `Harness.run` is called.
pub const ScenarioFunction = *const fn (harness: *Harness, scenario_context: ?*anyopaque) anyerror!void;

/// Errors surfaced by `Harness.verifyExactAccounting`.
pub const AccountingError = error{
    /// Processes remained live after the run.
    LiveProcessesRemain,
    /// Envelope pages remained in service (leak).
    EnvelopePagesLeaked,
    /// Envelope pages remained abandoned (reclaim never happened).
    EnvelopePagesAbandoned,
    /// Fiber stacks remained acquired (leak).
    FiberStacksLeaked,
    /// Some process's manager was not torn down exactly once.
    ManagerTeardownMismatch,
};

/// One deterministic kernel instance: pid table + envelope pool +
/// scheduler wired for seeded decisions, forbidden parking, and trace
/// recording, plus arena-backed per-process managers so scenarios need
/// no manager plumbing. Heap-allocated (`create`) because the scheduler
/// and decision seam hold internal pointers.
pub const Harness = struct {
    /// Allocator backing every harness structure.
    allocator: std.mem.Allocator,
    /// The seed this harness runs under (printed on failure).
    seed: u64,
    /// The seeded decision source (pinned; the scheduler points at it).
    seeded_decisions: SeededDecisions,
    /// The trace recorder (pinned; the scheduler points at it).
    trace_recorder: TraceRecorder,
    /// The kernel structures.
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,
    /// One arena manager per spawned process (torn down by process
    /// teardown; freed by `destroy`).
    process_managers: std.ArrayList(*HarnessProcessManager),

    /// Harness construction options.
    pub const Options = struct {
        /// Pid-table capacity (= max concurrent processes).
        pid_capacity: u32 = 64,
        /// Configured preemption budget (the seeded seam randomizes each
        /// quantum in `[1, this]` unless disabled).
        preemption_budget: u32 = 32,
        /// Randomize per-quantum budgets (see `SeededDecisions`).
        randomize_quantum_budget: bool = true,
        /// Usable bytes per fiber stack.
        stack_usable_size: usize = 64 * 1024,
        /// Envelope slots per pool page (small default so scenarios
        /// exercise page growth/abandon/reclaim).
        envelopes_per_page: u32 = 8,
    };

    /// Build a deterministic kernel for `seed`.
    pub fn create(allocator: std.mem.Allocator, seed: u64, options: Options) !*Harness {
        const harness = try allocator.create(Harness);
        errdefer allocator.destroy(harness);

        harness.allocator = allocator;
        harness.seed = seed;
        harness.seeded_decisions = SeededDecisions.init(seed, options.randomize_quantum_budget);
        harness.trace_recorder = TraceRecorder.init(allocator);
        errdefer harness.trace_recorder.deinit();
        harness.pid_table = try PidTable.init(allocator, .{ .capacity = options.pid_capacity });
        errdefer harness.pid_table.deinit();
        harness.envelope_pool = EnvelopePool.init(allocator, .{
            .envelopes_per_page = options.envelopes_per_page,
        });
        harness.process_managers = .empty;
        harness.scheduler = Scheduler.init(allocator, &harness.pid_table, &harness.envelope_pool, .{
            .preemption_budget = options.preemption_budget,
            .idle_strategy = .forbid_parking,
            .decisions = harness.seeded_decisions.decisions(),
            .trace_hook = TraceRecorder.hookThunk,
            .trace_context = &harness.trace_recorder,
            .stack_usable_size = options.stack_usable_size,
        });
        return harness;
    }

    /// Tear the harness down. Any processes a failed/deadlocked scenario
    /// left behind are killed first (`shutdownAllProcesses`), so destroy
    /// is safe on every path and manager teardown stays exactly-once.
    pub fn destroy(harness: *Harness) void {
        harness.scheduler.shutdownAllProcesses();
        harness.scheduler.deinit();
        harness.envelope_pool.deinit();
        harness.pid_table.deinit();
        for (harness.process_managers.items) |manager| {
            std.debug.assert(manager.teardown_count == 1);
            harness.allocator.destroy(manager);
        }
        harness.process_managers.deinit(harness.allocator);
        harness.trace_recorder.deinit();
        const allocator = harness.allocator;
        allocator.destroy(harness);
    }

    /// Spawn a process with a fresh arena-backed manager.
    pub fn spawnProcess(harness: *Harness, entry: ProcessEntry, argument: ?*anyopaque) !Pid {
        try harness.process_managers.ensureUnusedCapacity(harness.allocator, 1);
        const manager = try harness.allocator.create(HarnessProcessManager);
        errdefer harness.allocator.destroy(manager);
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(harness.allocator) };
        const pid = try harness.scheduler.spawn(.{
            .entry = entry,
            .argument = argument,
            .manager = manager.managerContext(),
        });
        harness.process_managers.appendAssumeCapacity(manager);
        return pid;
    }

    /// Run the scenario to quiescence. `error.AllProcessesWaiting` is
    /// the deterministic-idle outcome: the scenario deadlocked.
    pub fn run(harness: *Harness) scheduler_module.RunError!void {
        return harness.scheduler.runUntilQuiescent();
    }

    /// The recorded trace so far (borrowed).
    pub fn trace(harness: *const Harness) []const TraceEvent {
        return harness.trace_recorder.recorded();
    }

    /// Assert the post-run exact-accounting invariant (plan 1.4: leak
    /// accounting balances EXACTLY after every teardown): no live
    /// processes, no live or abandoned envelope pages, no acquired
    /// stacks, and every spawned process's manager torn down exactly
    /// once.
    pub fn verifyExactAccounting(harness: *Harness) AccountingError!void {
        if (harness.pid_table.statistics().live_process_count != 0) return error.LiveProcessesRemain;
        if (harness.scheduler.statistics().live_process_count != 0) return error.LiveProcessesRemain;
        const envelope_statistics = harness.envelope_pool.statistics();
        if (envelope_statistics.live_page_count != 0) return error.EnvelopePagesLeaked;
        if (envelope_statistics.abandoned_page_count != 0) return error.EnvelopePagesAbandoned;
        if (harness.scheduler.stackPoolStatistics().live_stack_count != 0) return error.FiberStacksLeaked;
        for (harness.process_managers.items) |manager| {
            if (manager.teardown_count != 1) return error.ManagerTeardownMismatch;
        }
    }
};

/// Arena-backed per-process manager for harness scenarios: `teardown` is
/// the wholesale free-on-exit shape (plan 1.4), counted so exactly-once
/// teardown is verifiable.
const HarnessProcessManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    fn managerContext(manager: *HarnessProcessManager) process_module.ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *HarnessProcessManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *HarnessProcessManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *HarnessProcessManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        manager.arena.deinit();
        // Leave the arena in a deinit-safe state (destroy() only asserts
        // and frees the struct; a double teardown is caught by the count).
        manager.arena = std.heap.ArenaAllocator.init(manager.arena.child_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *HarnessProcessManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

/// Options for `runScenario`/`runSeedSweep`.
pub const ScenarioOptions = struct {
    /// Harness construction options.
    harness: Harness.Options = .{},
    /// Optional post-run verification (runs after quiescence and the
    /// exact-accounting check; its error fails the scenario and prints
    /// the seed).
    verify_after_run: ?ScenarioFunction = null,
};

/// Run `scenario` under `seed` to quiescence, verify exact accounting
/// (and the optional scenario verifier), and return the owned trace
/// (caller frees with `allocator.free`).
///
/// THE FAILING-SEED CONTRACT (plan 1.5): on ANY failure this prints the
/// seed to stderr before propagating the error, so the exact run is
/// replayable by passing the printed seed back in.
pub fn runScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    scenario: ScenarioFunction,
    scenario_context: ?*anyopaque,
    options: ScenarioOptions,
) ![]TraceEvent {
    errdefer std.debug.print(
        "\n[deterministic] scenario FAILED under seed {d} (0x{x}) — rerun with this seed for an exact replay\n",
        .{ seed, seed },
    );
    var harness = try Harness.create(allocator, seed, options.harness);
    defer harness.destroy();

    try scenario(harness, scenario_context);
    try harness.run();
    try harness.verifyExactAccounting();
    if (options.verify_after_run) |verify| try verify(harness, scenario_context);

    return allocator.dupe(TraceEvent, harness.trace());
}

/// Run `scenario` under `seed_count` consecutive seeds starting at
/// `first_seed` (verona-rt-style seed sweep, plan decision 11). Any
/// failing seed is printed by `runScenario` before the error propagates.
pub fn runSeedSweep(
    allocator: std.mem.Allocator,
    first_seed: u64,
    seed_count: u64,
    scenario: ScenarioFunction,
    scenario_context: ?*anyopaque,
    options: ScenarioOptions,
) !void {
    var seed_offset: u64 = 0;
    while (seed_offset < seed_count) : (seed_offset += 1) {
        const trace = try runScenario(allocator, first_seed + seed_offset, scenario, scenario_context, options);
        allocator.free(trace);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// -- ping-pong pairs: ≥5 processes with message exchanges ------------------------

const ping_pong_pair_count = 3; // 6 processes
const ping_pong_rounds = 4;

const PingPongPair = struct {
    pinger_pid: Pid = Pid.invalid,
    ponger_pid: Pid = Pid.invalid,
    rounds_completed: usize = 0,
    protocol_violation: bool = false,
};

const PingPongScenarioState = struct {
    pairs: [ping_pong_pair_count]PingPongPair = @splat(.{}),
};

fn pingerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const pair: *PingPongPair = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < ping_pong_rounds) : (round += 1) {
        const outcome = context.send(pair.ponger_pid, .{ .payload_byte_length = round }) catch
            @panic("pinger send failed");
        if (outcome != .delivered) {
            pair.protocol_violation = true;
            return;
        }
        const reply = context.receive();
        if (reply.fragment.payload_byte_length != round) pair.protocol_violation = true;
        envelope_pool_module.free(reply);
        pair.rounds_completed += 1;
    }
}

fn pongerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const pair: *PingPongPair = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < ping_pong_rounds) : (round += 1) {
        const ping = context.receive();
        const echoed_stamp = ping.fragment.payload_byte_length;
        envelope_pool_module.free(ping);
        const outcome = context.send(pair.pinger_pid, .{ .payload_byte_length = echoed_stamp }) catch
            @panic("ponger send failed");
        if (outcome != .delivered) {
            pair.protocol_violation = true;
            return;
        }
    }
}

fn pingPongScenario(harness: *Harness, scenario_context: ?*anyopaque) anyerror!void {
    const state: *PingPongScenarioState = @ptrCast(@alignCast(scenario_context.?));
    for (&state.pairs) |*pair| {
        pair.* = .{};
        pair.ponger_pid = try harness.spawnProcess(pongerEntry, pair);
        pair.pinger_pid = try harness.spawnProcess(pingerEntry, pair);
    }
}

fn pingPongVerify(harness: *Harness, scenario_context: ?*anyopaque) anyerror!void {
    _ = harness;
    const state: *PingPongScenarioState = @ptrCast(@alignCast(scenario_context.?));
    for (&state.pairs) |*pair| {
        if (pair.protocol_violation) return error.PingPongProtocolViolation;
        if (pair.rounds_completed != ping_pong_rounds) return error.PingPongIncomplete;
    }
}

test "Deterministic: same seed twice yields byte-identical traces (6 processes, message exchanges)" {
    var first_state = PingPongScenarioState{};
    const first_trace = try runScenario(testing.allocator, 0x5EED, pingPongScenario, &first_state, .{
        .verify_after_run = pingPongVerify,
    });
    defer testing.allocator.free(first_trace);

    var second_state = PingPongScenarioState{};
    const second_trace = try runScenario(testing.allocator, 0x5EED, pingPongScenario, &second_state, .{
        .verify_after_run = pingPongVerify,
    });
    defer testing.allocator.free(second_trace);

    try testing.expect(tracesIdentical(first_trace, second_trace));

    // The trace is substantial and exercised the whole event vocabulary:
    // 6 spawns, 6 exits, and real suspension traffic.
    var spawn_count: usize = 0;
    var exit_count: usize = 0;
    var wait_count: usize = 0;
    var wake_count: usize = 0;
    for (first_trace) |event| {
        switch (event.kind) {
            .spawn => spawn_count += 1,
            .exit => exit_count += 1,
            .wait => wait_count += 1,
            .wake => wake_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2 * ping_pong_pair_count), spawn_count);
    try testing.expectEqual(@as(usize, 2 * ping_pong_pair_count), exit_count);
    try testing.expect(wait_count > 0);
    try testing.expectEqual(wait_count, wake_count);
}

test "Deterministic: different seeds can diverge (trace inequality across a seed range)" {
    const seed_count = 12;
    var traces: [seed_count][]TraceEvent = undefined;
    var collected: usize = 0;
    defer for (traces[0..collected]) |trace| testing.allocator.free(trace);

    for (0..seed_count) |seed_index| {
        var state = PingPongScenarioState{};
        traces[seed_index] = try runScenario(
            testing.allocator,
            1000 + @as(u64, seed_index),
            pingPongScenario,
            &state,
            .{ .verify_after_run = pingPongVerify },
        );
        collected += 1;
    }

    // Divergence is possible, not guaranteed pairwise — assert that the
    // seed range produced at least two distinct schedules.
    var found_divergence = false;
    for (traces[1..]) |trace| {
        if (!tracesIdentical(traces[0], trace)) found_divergence = true;
    }
    try testing.expect(found_divergence);
}

// -- race-prone sweep scenario: producers + consumer + a killed waiter ------------

const sweep_producer_count = 4;
const sweep_messages_per_producer = 8;

const SweepProducerState = struct {
    consumer_pid: Pid = Pid.invalid,
    producer_index: usize = 0,
};

const SweepScenarioState = struct {
    producers: [sweep_producer_count]SweepProducerState = @splat(.{}),
    consumer_pid: Pid = Pid.invalid,
    victim_pid: Pid = Pid.invalid,
    received_total: usize = 0,
    expected_sequence: [sweep_producer_count]usize = @splat(0),
    fifo_violation: bool = false,
    kill_outcome: scheduler_module.KillOutcome = .not_found,
};

fn sweepProducerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const producer: *SweepProducerState = @ptrCast(@alignCast(argument.?));
    var sequence: usize = 0;
    while (sequence < sweep_messages_per_producer) : (sequence += 1) {
        const stamp = (producer.producer_index << 16) | sequence;
        const outcome = context.send(producer.consumer_pid, .{ .payload_byte_length = stamp }) catch
            @panic("sweep producer send failed");
        std.debug.assert(outcome == .delivered);
        // Safepoint between sends: seeded budgets preempt mid-burst.
        context.yieldCheck();
    }
}

fn sweepConsumerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *SweepScenarioState = @ptrCast(@alignCast(argument.?));
    const expected_total = sweep_producer_count * sweep_messages_per_producer;
    while (state.received_total < expected_total) {
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        const producer_index = stamp >> 16;
        const sequence = stamp & 0xFFFF;
        // Pairwise FIFO: each producer's sequence numbers arrive in order.
        if (sequence != state.expected_sequence[producer_index]) state.fifo_violation = true;
        state.expected_sequence[producer_index] += 1;
        state.received_total += 1;
    }
}

fn sweepVictimEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("the sweep victim must be killed while waiting, never resumed");
}

fn sweepKillerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *SweepScenarioState = @ptrCast(@alignCast(argument.?));
    // Let some traffic interleave first, then kill the waiter.
    context.yieldNow();
    state.kill_outcome = context.kill(state.victim_pid);
}

fn sweepScenario(harness: *Harness, scenario_context: ?*anyopaque) anyerror!void {
    const state: *SweepScenarioState = @ptrCast(@alignCast(scenario_context.?));
    state.* = .{};
    state.consumer_pid = try harness.spawnProcess(sweepConsumerEntry, state);
    state.victim_pid = try harness.spawnProcess(sweepVictimEntry, null);
    for (&state.producers, 0..) |*producer, producer_index| {
        producer.* = .{ .consumer_pid = state.consumer_pid, .producer_index = producer_index };
        _ = try harness.spawnProcess(sweepProducerEntry, producer);
    }
    _ = try harness.spawnProcess(sweepKillerEntry, state);
}

fn sweepVerify(harness: *Harness, scenario_context: ?*anyopaque) anyerror!void {
    const state: *SweepScenarioState = @ptrCast(@alignCast(scenario_context.?));
    if (state.fifo_violation) return error.PairwiseFifoViolated;
    if (state.received_total != sweep_producer_count * sweep_messages_per_producer) {
        return error.MessagesLost;
    }
    for (state.expected_sequence) |sequence| {
        if (sequence != sweep_messages_per_producer) return error.MessagesLost;
    }
    // The victim was killed while waiting (immediate teardown) or, if the
    // killer's yield landed before the victim first ran, at its dequeue.
    switch (state.kill_outcome) {
        .killed, .kill_pending => {},
        .not_found => return error.VictimNeverKilled,
    }
    var kill_count: usize = 0;
    for (harness.trace()) |event| {
        if (event.kind == .kill) kill_count += 1;
    }
    if (kill_count != 1) return error.KillCountWrong;
}

test "Deterministic: 50-seed sweep of a race-prone scenario holds every invariant" {
    var state = SweepScenarioState{};
    try runSeedSweep(testing.allocator, 0xBA5E, 50, sweepScenario, &state, .{
        .verify_after_run = sweepVerify,
    });
}

// -- deterministic idle = deadlock error, cleaned up by the harness -----------------

fn deadlockedWaiterEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("nobody ever sends to the deadlocked waiter");
}

fn deadlockScenario(harness: *Harness, scenario_context: ?*anyopaque) anyerror!void {
    _ = scenario_context;
    _ = try harness.spawnProcess(deadlockedWaiterEntry, null);
}

test "Deterministic: idle with waiting processes surfaces AllProcessesWaiting (never parks)" {
    var harness = try Harness.create(testing.allocator, 42, .{});
    defer harness.destroy();

    try deadlockScenario(harness, null);
    try testing.expectError(error.AllProcessesWaiting, harness.run());
    // destroy() shuts the deadlocked waiter down and every pool balances
    // (the harness asserts manager teardown; testing.allocator asserts
    // the bytes).
}

test "Deterministic: a failing scenario propagates its error through runScenario" {
    // The deadlock scenario fails inside run(); runScenario must
    // propagate the error (after printing the seed, which lands on
    // stderr).
    var state: usize = 0;
    _ = &state;
    try testing.expectError(
        error.AllProcessesWaiting,
        runScenario(testing.allocator, 7, deadlockScenario, null, .{}),
    );
}

test "Deterministic: tracesIdentical distinguishes traces" {
    const base = [_]TraceEvent{
        .{ .kind = .spawn, .pid_bits = 1 },
        .{ .kind = .schedule, .pid_bits = 1 },
        .{ .kind = .exit, .pid_bits = 1 },
    };
    const same = base;
    const different_kind = [_]TraceEvent{
        .{ .kind = .spawn, .pid_bits = 1 },
        .{ .kind = .yield, .pid_bits = 1 },
        .{ .kind = .exit, .pid_bits = 1 },
    };
    const different_pid = [_]TraceEvent{
        .{ .kind = .spawn, .pid_bits = 1 },
        .{ .kind = .schedule, .pid_bits = 2 },
        .{ .kind = .exit, .pid_bits = 1 },
    };

    try testing.expect(tracesIdentical(&base, &same));
    try testing.expect(!tracesIdentical(&base, &different_kind));
    try testing.expect(!tracesIdentical(&base, &different_pid));
    try testing.expect(!tracesIdentical(&base, base[0..2]));
}

test "Deterministic: seeded budgets stay within [1, configured]" {
    var seeded = SeededDecisions.init(0xB0D6E7, true);
    const decisions_view = seeded.decisions();
    for (0..1000) |_| {
        const budget = decisions_view.vtable.chooseQuantumBudget(decisions_view.decision_context, 32);
        try testing.expect(budget >= 1 and budget <= 32);
        const index = decisions_view.vtable.chooseNextReadyIndex(decisions_view.decision_context, 7);
        try testing.expect(index < 7);
    }
}
