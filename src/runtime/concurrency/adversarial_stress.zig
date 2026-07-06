//! Adversarial cross-thread send/teardown stress for the Zap concurrency
//! kernel — the Phase 1 half of exit gate E3.
//!
//! Phase 1 exit-gate job P1-J6 of `docs/concurrency-implementation-plan.md`
//! (gate table row E3, "same-model" scope): Phase 1 payloads are opaque
//! (the ARC deep-copy walker is Phase 2), so this campaign's target is the
//! kernel's SHARED machinery under adversarial concurrency — mailbox
//! links, envelope page ownership/abandon/reclaim, pid-table slot
//! transitions, and scheduler wake/park — with the payload-refcount rule
//! (never touched cross-thread; `mailbox.zig` module doc) preserved by
//! construction: payloads here are opaque stamped words, and NOTHING in
//! this test (or the kernel) dereferences a payload cross-thread.
//!
//! ## The adversarial shapes (one round)
//!
//! Six producer THREADS run against one scheduler thread, every round:
//!
//! 1. **Stale-pid dead-letter storm racing slot transitions.** Producers
//!    hammer `lookup` with the PREVIOUS round's (all-dead) pids while the
//!    scheduler thread is CONCURRENTLY spawning the current round's
//!    processes into the same LIFO-reused slots — generation validation
//!    races acquire-side slot writes. Every stale lookup MUST miss
//!    (a resolve would be a generation-reuse kernel bug → panic), and
//!    every miss must be a `generation_mismatch`/`slot_not_occupied`
//!    dead-letter, tallied exactly.
//! 2. **Senders dying mid-flight (abandon/reclaim churn).** Producers
//!    interleave a round-lifetime envelope handle with EPHEMERAL handles
//!    abandoned immediately after each push — pages flip `.abandoned`
//!    with one in-flight envelope, and the receiving process's (or
//!    teardown's) free must reclaim them. Every producer also abandons
//!    its round handle at round end while receivers are still freeing
//!    from its pages.
//! 3. **Receivers torn down with populated mailboxes, concurrent with
//!    live traffic.** Sink processes consume a few envelopes then stop;
//!    the controller process kills them — killed `.runnable` with their
//!    remaining envelopes queued — WHILE producers are still pushing to
//!    the round's consumers (the kill/teardown drain and its
//!    abandoned-page reclaims overlap live cross-thread pushes to other
//!    mailboxes). Victim processes are killed while `.waiting` (the
//!    non-cooperative teardown point) under the same concurrent load.
//! 4. **Wake/park pressure.** Consumers block on `receive` mid-round, so
//!    the scheduler parks on its futex whenever producers lag; every
//!    empty→nonempty push wakes it cross-thread. Producers additionally
//!    spray spurious `wake()` and `requestWatchdogPreemption()` calls
//!    (both documented thread-safe) and walk the lock-free live-process
//!    iterator (WITHOUT dereferencing PCBs — the documented Phase 4
//!    lifetime caveat) against concurrent spawn/exit.
//!
//! ## Contract discipline (what this test deliberately does NOT do)
//!
//! A foreign thread's push racing the TARGET's teardown after passing
//! `lookup` is the documented out-of-contract Phase 4 PCB-lifetime caveat
//! (`scheduler.zig` module doc). Every push here targets a process that
//! is provably alive across the whole lookup→push window: consumers
//! cannot exit before their full budget arrives (the last push
//! happens-before the budget-completing receive), sinks and the
//! controller are killed/exit only AFTER every producer's pushes to them
//! completed (the controller waits for all "done" envelopes, and
//! producers send "done" only after their sink sends), and victims never
//! receive pushes at all. Stale-pid traffic — the in-contract shape of
//! "sending to exiting/dead processes" — never passes `lookup`.
//!
//! ## Exactness
//!
//! Every round ends with a full barrier (scheduler quiescent AND all
//! producers finished) and asserts EXACT accounting: consumer receipts
//! (count and per-producer pairwise-FIFO order), sink receipts, kill
//! outcomes by state (`.killed` for waiting victims, `.kill_pending` for
//! runnable sinks), crash-report mailbox depths at death (sinks die with
//! exactly their leftover envelopes; everyone else dies/exits empty),
//! the pid table's dead-letter counter (delta == the producers' locally
//! observed miss count), dead-letter reasons (only the two stale-pid
//! reasons), and pool/table/stack/scheduler quiescence (zero live pages,
//! zero abandoned pages, zero live stacks, zero live processes).
//!
//! ## Volume knob
//!
//! The committed default (`default_round_count`) is sized for CI sanity —
//! seconds, not minutes, in Debug on Apple Silicon. For a minutes-scale
//! soak set `ZAP_ADVERSARIAL_STRESS_ROUNDS`:
//!
//! ```
//! ZAP_ADVERSARIAL_STRESS_ROUNDS=20000 ~/projects/zig/zig-out/bin/zig build test-kernel
//! ```
//!
//! ## Toolchain
//!
//! Drives the scheduler (fiber switches), so the kernel-wide
//! fork-compiler requirement for optimized builds applies (see
//! `concurrency.zig`). Run it under ThreadSanitizer for the E3 gate:
//!
//! ```
//! TSAN_OPTIONS="halt_on_error=1 abort_on_error=1" \
//!   ~/projects/zig/zig-out/bin/zig test -fsanitize-thread \
//!   src/runtime/concurrency/concurrency.zig
//! ```

const std = @import("std");
const builtin = @import("builtin");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const mailbox_module = @import("mailbox.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const scheduler_module = @import("scheduler.zig");
const crash_report_module = @import("crash_report.zig");

const testing = std.testing;

const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const Scheduler = scheduler_module.Scheduler;
const ProcessContext = scheduler_module.ProcessContext;
const ManagerContext = process_module.ManagerContext;
const TestDeadline = mailbox_module.TestDeadline;

// -- volume ---------------------------------------------------------------------------

/// Committed default rounds (CI-sanity sizing — module doc). Overridden
/// by `ZAP_ADVERSARIAL_STRESS_ROUNDS`.
const default_round_count: usize = 120;

/// Environment variable overriding the round count (module doc).
const stress_rounds_environment_variable = "ZAP_ADVERSARIAL_STRESS_ROUNDS";

/// Producer threads (job spec: 4–8 concurrent producers).
const producer_thread_count: usize = 6;

/// Per-round process roster.
const consumer_count_per_round: usize = 4;
const sink_count_per_round: usize = 4;
const victim_count_per_round: usize = 2;
/// consumers + sinks + victims + 1 controller.
const processes_per_round: usize =
    consumer_count_per_round + sink_count_per_round + victim_count_per_round + 1;

/// Envelopes each producer sends to each consumer and to each sink.
const envelopes_per_producer_per_target: usize = 4;
/// Every consumer's receive budget (it exits after exactly this many).
const consumer_receive_budget: usize = producer_thread_count * envelopes_per_producer_per_target;
/// A sink consumes this many envelopes, then stops receiving and spins
/// until killed — the rest stay queued for the teardown drain.
const sink_receive_budget: usize = 8;
/// Envelopes still queued in every sink's mailbox at its kill.
const sink_leftover_envelope_count: usize =
    producer_thread_count * envelopes_per_producer_per_target - sink_receive_budget;
/// Stale lookups per dead pid per producer per round.
const stale_probe_repeats: usize = 3;
/// Every Nth live push is made from an ephemeral, immediately-abandoned
/// handle (abandon/reclaim churn — module doc shape 2).
const ephemeral_handle_stride: usize = 4;

/// Bound on every cross-thread wait in this test (loud failure, never a
/// silent hang).
const barrier_timeout_nanoseconds: u64 = 120 * std.time.ns_per_s;

comptime {
    std.debug.assert(sink_receive_budget < producer_thread_count * envelopes_per_producer_per_target);
}

/// Total rounds for this run: the environment knob, or the committed
/// default. Fails loudly on an unparsable knob value.
fn configuredRoundCount() !usize {
    const raw_value = std.c.getenv(stress_rounds_environment_variable) orelse
        return default_round_count;
    const value_slice = std.mem.span(raw_value);
    const parsed = std.fmt.parseInt(usize, value_slice, 10) catch
        return error.InvalidStressRoundKnob;
    if (parsed == 0) return error.InvalidStressRoundKnob;
    return parsed;
}

// -- payload stamping -------------------------------------------------------------------

/// Payloads are OPAQUE words stamped into `Fragment.payload_byte_length`
/// (the Phase 1 opaque-payload posture): `{marker, producer, sequence}`.
/// Nothing dereferences them; receivers only decode the stamp.
const payload_stamp = struct {
    /// High-byte marker distinguishing data envelopes from "done"
    /// control envelopes (and catching corrupted stamps).
    const data_marker: usize = 0xDA << 56;
    const done_marker: usize = 0xD0 << 56;
    const marker_mask: usize = @as(usize, 0xFF) << 56;

    fn encodeData(producer_index: usize, sequence_number: usize) usize {
        return data_marker | (producer_index << 32) | sequence_number;
    }

    fn encodeDone(producer_index: usize) usize {
        return done_marker | producer_index;
    }

    fn marker(stamp: usize) usize {
        return stamp & marker_mask;
    }

    fn producerIndex(stamp: usize) usize {
        return (stamp >> 32) & 0xFF;
    }

    fn sequence(stamp: usize) usize {
        return stamp & 0xFFFF_FFFF;
    }
};

// -- per-process manager -------------------------------------------------------------

/// Byte-accounting arena manager (the standard Phase 1 test-manager
/// shape; see `scheduler.zig`/`teardown_stress.zig`). Reused across
/// rounds — teardown re-arms the arena — but never shared between
/// concurrently-live processes.
const StressManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    fn managerContext(manager: *StressManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *StressManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *StressManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *StressManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *StressManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

// -- shared coordination state ----------------------------------------------------------

/// Everything the producer threads share with the scheduler thread.
/// Roster arrays are plain memory published via the release-stores on
/// the phase words and read after the producers' acquire-loads (each
/// phase word's release/acquire pair is the happens-before edge for the
/// roster written before it); the round barrier (`completed_round`)
/// guarantees no producer reads a roster while the next round overwrites
/// it.
const SharedState = struct {
    pid_table: *PidTable,
    envelope_pool: *EnvelopePool,
    scheduler: *Scheduler,

    /// Round whose STALE storm may begin (previous-round roster is
    /// published; the scheduler is concurrently spawning this round).
    stale_phase_round: std.atomic.Value(u64) = .init(0),
    /// Round whose LIVE roster is published (sends may begin).
    live_phase_round: std.atomic.Value(u64) = .init(0),
    /// Per-producer "finished round N" word.
    completed_round: [producer_thread_count]std.atomic.Value(u64) =
        @splat(std.atomic.Value(u64).init(0)),
    /// Producers stop when this is set and no further round is published.
    stop_requested: std.atomic.Value(bool) = .init(false),

    /// ALL pids of the previous round (all dead by publication time) —
    /// the stale-storm roster.
    previous_round_pids: [processes_per_round]Pid = @splat(Pid.invalid),
    /// Live roster of the current round.
    consumer_pids: [consumer_count_per_round]Pid = @splat(Pid.invalid),
    sink_pids: [sink_count_per_round]Pid = @splat(Pid.invalid),
    controller_pid: Pid = Pid.invalid,

    /// Dead-letter reason tallies (hook runs on producer threads —
    /// atomic). Any reason other than the two stale-pid ones is a kernel
    /// bug (module doc) and is asserted zero every round.
    dead_letter_generation_mismatch: std.atomic.Value(u64) = .init(0),
    dead_letter_slot_not_occupied: std.atomic.Value(u64) = .init(0),
    dead_letter_other: std.atomic.Value(u64) = .init(0),

    fn deadLetterHook(context: ?*anyopaque, stale_pid: Pid, reason: pid_table_module.DeadLetterReason) void {
        _ = stale_pid;
        const shared: *SharedState = @ptrCast(@alignCast(context.?));
        switch (reason) {
            .generation_mismatch => _ = shared.dead_letter_generation_mismatch.fetchAdd(1, .monotonic),
            .slot_not_occupied => _ = shared.dead_letter_slot_not_occupied.fetchAdd(1, .monotonic),
            .remote_node, .slot_out_of_range, .model_mismatch => _ = shared.dead_letter_other.fetchAdd(1, .monotonic),
        }
    }
};

// -- process bodies ---------------------------------------------------------------------

/// Consumer: receive exactly `consumer_receive_budget` envelopes,
/// asserting the per-producer pairwise-FIFO order (`mailbox.zig`'s
/// ordering guarantee), then exit normally.
const ConsumerProbe = struct {
    received_count: usize = 0,
    next_sequence_per_producer: [producer_thread_count]usize = @splat(0),
};

fn consumerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ConsumerProbe = @ptrCast(@alignCast(argument.?));
    while (probe.received_count < consumer_receive_budget) {
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        if (payload_stamp.marker(stamp) != payload_stamp.data_marker) {
            @panic("consumer received a non-data envelope");
        }
        const producer_index = payload_stamp.producerIndex(stamp);
        const sequence = payload_stamp.sequence(stamp);
        if (sequence != probe.next_sequence_per_producer[producer_index]) {
            @panic("pairwise-FIFO violation observed by a consumer");
        }
        probe.next_sequence_per_producer[producer_index] += 1;
        probe.received_count += 1;
        context.yieldCheck();
    }
}

/// Sink: receive `sink_receive_budget` envelopes (same order check),
/// bump the scheduler-thread-only drained counter, then spin-yield until
/// killed. The remaining envelopes stay queued — teardown drains them.
const SinkProbe = struct {
    /// Scheduler-thread-only: how many sinks finished their budget (the
    /// controller waits on it before killing — same thread, no atomics).
    sinks_drained_count: *usize,
    received_count: usize = 0,
    next_sequence_per_producer: [producer_thread_count]usize = @splat(0),
};

fn sinkEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SinkProbe = @ptrCast(@alignCast(argument.?));
    while (probe.received_count < sink_receive_budget) {
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        if (payload_stamp.marker(stamp) != payload_stamp.data_marker) {
            @panic("sink received a non-data envelope");
        }
        const producer_index = payload_stamp.producerIndex(stamp);
        const sequence = payload_stamp.sequence(stamp);
        // A sink receives a PREFIX of the interleaved streams, and each
        // producer's subsequence arrives in send order — so the received
        // part of every producer's stream is exactly 0, 1, 2, …
        if (sequence != probe.next_sequence_per_producer[producer_index]) {
            @panic("pairwise-FIFO violation observed by a sink");
        }
        probe.next_sequence_per_producer[producer_index] = sequence + 1;
        probe.received_count += 1;
        context.yieldCheck();
    }
    probe.sinks_drained_count.* += 1;
    // Stop receiving; the leftover envelopes stay queued until the
    // controller's kill tears this process down (`.kill_pending` — the
    // spin keeps it `.runnable`, never `.waiting`).
    while (true) {
        context.yieldCheck();
        context.yieldNow();
    }
}

/// Victim: waits forever on an empty mailbox nobody sends to — killed at
/// the non-cooperative `.waiting` point.
fn victimEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("victim received a message nobody should have sent");
}

/// Controller: collect one "done" envelope from every producer (each
/// sent AFTER that producer finished its sink pushes), wait for the
/// sinks to finish their budgets, kill sinks (runnable → kill_pending)
/// and victims (waiting → killed), then exit — all while producers are
/// still pushing to this round's consumers.
const ControllerProbe = struct {
    sink_pids: *const [sink_count_per_round]Pid,
    victim_pids: *const [victim_count_per_round]Pid,
    sinks_drained_count: *usize,
    done_seen_per_producer: [producer_thread_count]bool = @splat(false),
    done_received_count: usize = 0,
};

fn controllerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ControllerProbe = @ptrCast(@alignCast(argument.?));
    while (probe.done_received_count < producer_thread_count) {
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        if (payload_stamp.marker(stamp) != payload_stamp.done_marker) {
            @panic("controller received a non-done envelope");
        }
        const producer_index = payload_stamp.sequence(stamp);
        if (probe.done_seen_per_producer[producer_index]) {
            @panic("controller received a duplicate done envelope");
        }
        probe.done_seen_per_producer[producer_index] = true;
        probe.done_received_count += 1;
    }
    // Sinks may still be consuming their budget; killing early would
    // change the leftover-depth exactness. Same-thread counter wait.
    while (probe.sinks_drained_count.* < sink_count_per_round) {
        context.yieldNow();
    }
    for (probe.sink_pids) |sink_pid| {
        // Sinks spin `.runnable` by construction after their budget.
        if (context.kill(sink_pid) != .kill_pending) {
            @panic("sink kill did not resolve kill_pending");
        }
    }
    for (probe.victim_pids) |victim_pid| {
        // Victims wait forever on an empty mailbox by construction.
        if (context.kill(victim_pid) != .killed) {
            @panic("victim kill did not resolve killed (non-cooperative point)");
        }
    }
}

// -- crash-report tally --------------------------------------------------------------------

/// Scheduler-thread-only teardown tally (the hook runs synchronously on
/// the scheduler thread): counts + mailbox depths by exit reason.
const TeardownTally = struct {
    killed_count: usize = 0,
    killed_mailbox_depth_total: usize = 0,
    normal_count: usize = 0,
    normal_mailbox_depth_total: usize = 0,

    fn hook(report_context: ?*anyopaque, report: *const crash_report_module.CrashReport) void {
        const tally: *TeardownTally = @ptrCast(@alignCast(report_context.?));
        switch (report.reason) {
            .killed => {
                tally.killed_count += 1;
                tally.killed_mailbox_depth_total += report.mailbox_depth_at_death;
            },
            .normal => {
                tally.normal_count += 1;
                tally.normal_mailbox_depth_total += report.mailbox_depth_at_death;
            },
        }
    }
};

// -- producer thread ---------------------------------------------------------------------

/// One producer thread's campaign state and per-round work.
const Producer = struct {
    shared: *SharedState,
    producer_index: usize,
    round_count: usize,
    /// Seeded per-producer PRNG for spurious wake/watchdog spray points
    /// (interleaving variety only — assertions never depend on it).
    prng: std.Random.DefaultPrng,
    /// Local dead-letter observations (lookup misses this producer
    /// caused); summed across producers == the table counter delta.
    observed_lookup_miss_count: u64 = 0,
    /// Loud-failure flag read after join.
    failed: bool = false,

    fn run(producer: *Producer) void {
        producer.runOrFail() catch {
            producer.failed = true;
        };
    }

    fn runOrFail(producer: *Producer) !void {
        const shared = producer.shared;
        var round: u64 = 1;
        while (round <= producer.round_count) : (round += 1) {
            // Phase A — stale storm, concurrent with the scheduler
            // spawning this round into recycled slots.
            try producer.awaitPhaseWord(&shared.stale_phase_round, round);
            if (round > 1) {
                var repeat: usize = 0;
                while (repeat < stale_probe_repeats) : (repeat += 1) {
                    for (shared.previous_round_pids) |dead_pid| {
                        if (shared.pid_table.lookup(dead_pid) != null) {
                            // A dead pid must NEVER resolve — generation
                            // reuse would break the §2.4 invariant.
                            return error.StalePidResolved;
                        }
                        producer.observed_lookup_miss_count += 1;
                    }
                    producer.maybeSprayControlSignals();
                }
            }

            // Phase B — live traffic.
            try producer.awaitPhaseWord(&shared.live_phase_round, round);
            var round_handle = EnvelopePool.Handle.init(shared.envelope_pool);

            // Sinks first: the controller's kills become legal the moment
            // every producer's done-envelope (sent below) has arrived.
            for (shared.sink_pids) |sink_pid| {
                try producer.sendBurst(&round_handle, sink_pid);
            }
            try producer.sendDone(&round_handle, shared.controller_pid);

            // Consumer pushes now overlap the controller's kills, the
            // sink teardown drains, and their abandoned-page reclaims.
            for (shared.consumer_pids) |consumer_pid| {
                try producer.sendBurst(&round_handle, consumer_pid);
                producer.maybeSprayControlSignals();
            }

            // Lock-free live iteration under concurrent spawn/exit —
            // pids only, never dereferencing a PCB (module doc).
            var live_iterator = shared.pid_table.iterateLiveProcesses();
            var observed_live_count: usize = 0;
            while (live_iterator.next()) |_| observed_live_count += 1;
            if (observed_live_count > processes_per_round) {
                return error.LiveIterationOvercount;
            }

            // Exit-race lookups: consumers may be mid-teardown right now;
            // both outcomes are legal, misses are dead-letters we count.
            for (shared.consumer_pids) |consumer_pid| {
                if (shared.pid_table.lookup(consumer_pid) == null) {
                    producer.observed_lookup_miss_count += 1;
                }
            }

            // Abandon while receivers are still freeing from our pages.
            round_handle.abandon();
            shared.completed_round[producer.producer_index].store(round, .release);
        }
    }

    /// Send `envelopes_per_producer_per_target` stamped envelopes to a
    /// live target, every `ephemeral_handle_stride`-th from a fresh
    /// immediately-abandoned handle (mid-flight sender death).
    fn sendBurst(producer: *Producer, round_handle: *EnvelopePool.Handle, target: Pid) !void {
        var sequence: usize = 0;
        while (sequence < envelopes_per_producer_per_target) : (sequence += 1) {
            const stamp = payload_stamp.encodeData(producer.producer_index, sequence);
            if (sequence % ephemeral_handle_stride == ephemeral_handle_stride - 1) {
                var ephemeral_handle = EnvelopePool.Handle.init(producer.shared.envelope_pool);
                try producer.pushStamped(&ephemeral_handle, target, stamp);
                ephemeral_handle.abandon();
            } else {
                try producer.pushStamped(round_handle, target, stamp);
            }
        }
    }

    fn sendDone(producer: *Producer, round_handle: *EnvelopePool.Handle, controller: Pid) !void {
        try producer.pushStamped(round_handle, controller, payload_stamp.encodeDone(producer.producer_index));
    }

    /// The cross-thread send path: lookup (must resolve — every target
    /// is alive across the whole window by the contract discipline in
    /// the module doc), allocate, stamp, push (wake seam fires on
    /// empty→nonempty).
    fn pushStamped(producer: *Producer, handle: *EnvelopePool.Handle, target: Pid, stamp: usize) !void {
        const target_pcb = producer.shared.pid_table.lookup(target) orelse
            return error.LiveTargetLookupFailed;
        const envelope = handle.allocate() catch return error.EnvelopeAllocationFailed;
        envelope.fragment = .{ .payload_byte_length = stamp };
        _ = target_pcb.mailbox.push(envelope);
    }

    /// Spray the documented thread-safe control surface at random points:
    /// spurious wakes (park-protocol pressure) and watchdog preemption
    /// requests (quantum-flag pressure).
    fn maybeSprayControlSignals(producer: *Producer) void {
        const random = producer.prng.random();
        if (random.uintLessThan(u8, 4) == 0) producer.shared.scheduler.wake();
        if (random.uintLessThan(u8, 4) == 0) producer.shared.scheduler.requestWatchdogPreemption();
        _ = producer.shared.scheduler.parkCount();
    }

    fn awaitPhaseWord(producer: *Producer, word: *const std.atomic.Value(u64), round: u64) !void {
        const deadline = TestDeadline.init(barrier_timeout_nanoseconds);
        while (word.load(.acquire) < round) {
            if (producer.shared.stop_requested.load(.acquire)) return error.StoppedMidCampaign;
            if (deadline.expired()) return error.BarrierTimeout;
            std.atomic.spinLoopHint();
        }
    }
};

// -- the campaign ------------------------------------------------------------------------

const StressKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,
    teardown_tally: TeardownTally,

    fn init(kernel: *StressKernel) !void {
        kernel.teardown_tally = .{};
        kernel.pid_table = try PidTable.init(testing.allocator, .{ .capacity = 64 });
        // Small pages (8 slots) so bursts span pages and the
        // abandon/reclaim machinery churns for real.
        kernel.envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
        kernel.scheduler = Scheduler.init(testing.allocator, &kernel.pid_table, &kernel.envelope_pool, .{
            .stack_usable_size = 64 * 1024,
            // Small budget so budget preemption interleaves with the
            // producers' watchdog spray.
            .preemption_budget = 16,
            // Short spin so real futex parks happen whenever producers
            // lag; short timeout bounds every park.
            .spin_iterations_before_park = 64,
            .park_timeout_nanoseconds = 10 * std.time.ns_per_ms,
            .idle_strategy = .futex_park,
        });
        kernel.scheduler.options.crash_report_hook = TeardownTally.hook;
        kernel.scheduler.options.crash_report_context = &kernel.teardown_tally;
    }

    fn deinit(kernel: *StressKernel) void {
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }

    fn expectExactQuiescentAccounting(kernel: *StressKernel) !void {
        try testing.expectEqual(@as(u32, 0), kernel.pid_table.statistics().live_process_count);
        const envelope_statistics = kernel.envelope_pool.statistics();
        try testing.expectEqual(@as(u32, 0), envelope_statistics.live_page_count);
        try testing.expectEqual(@as(u32, 0), envelope_statistics.abandoned_page_count);
        const stack_statistics = kernel.scheduler.stackPoolStatistics();
        try testing.expectEqual(@as(u32, 0), stack_statistics.live_stack_count);
        const scheduler_statistics = kernel.scheduler.statistics();
        try testing.expectEqual(@as(u32, 0), scheduler_statistics.live_process_count);
        try testing.expectEqual(@as(usize, 0), scheduler_statistics.ready_queue_depth);
    }
};

/// Scheduler-side round driver. See the module doc for the round shape.
fn runOneRound(
    kernel: *StressKernel,
    shared: *SharedState,
    managers: *[processes_per_round]StressManager,
    producers: *[producer_thread_count]Producer,
    campaign_dead_letter_baseline: u64,
    round: u64,
) !void {
    const tally_killed_at_start = kernel.teardown_tally.killed_count;
    const tally_normal_at_start = kernel.teardown_tally.normal_count;

    // Phase A: publish the previous round's (dead) roster and open the
    // stale storm BEFORE spawning, so stale lookups race this round's
    // slot acquisitions.
    shared.stale_phase_round.store(round, .release);

    var manager_cursor: usize = 0;
    const nextManager = struct {
        fn take(pool: *[processes_per_round]StressManager, cursor: *usize) *StressManager {
            const manager = &pool[cursor.*];
            cursor.* += 1;
            return manager;
        }
    }.take;

    var consumer_probes: [consumer_count_per_round]ConsumerProbe = undefined;
    var sink_probes: [sink_count_per_round]SinkProbe = undefined;
    var victim_pids: [victim_count_per_round]Pid = undefined;
    var sinks_drained_count: usize = 0;

    for (&consumer_probes, 0..) |*probe, consumer_index| {
        probe.* = .{};
        shared.consumer_pids[consumer_index] = try kernel.scheduler.spawn(.{
            .entry = consumerEntry,
            .argument = probe,
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }
    for (&sink_probes, 0..) |*probe, sink_index| {
        probe.* = .{ .sinks_drained_count = &sinks_drained_count };
        shared.sink_pids[sink_index] = try kernel.scheduler.spawn(.{
            .entry = sinkEntry,
            .argument = probe,
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }
    for (&victim_pids) |*victim_pid| {
        victim_pid.* = try kernel.scheduler.spawn(.{
            .entry = victimEntry,
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }
    var controller_probe = ControllerProbe{
        .sink_pids = &shared.sink_pids,
        .victim_pids = &victim_pids,
        .sinks_drained_count = &sinks_drained_count,
    };
    shared.controller_pid = try kernel.scheduler.spawn(.{
        .entry = controllerEntry,
        .argument = &controller_probe,
        .manager = nextManager(managers, &manager_cursor).managerContext(),
    });
    std.debug.assert(manager_cursor == processes_per_round);

    // Phase B: live roster is complete — open the send phase and run.
    shared.live_phase_round.store(round, .release);
    try kernel.scheduler.runUntilQuiescent();

    // Full round barrier: every producer finished (their post-"done"
    // consumer pushes all landed before the consumers' final receives —
    // quiescence proves delivery — but the exit-race lookups, ephemeral
    // abandons, and the round-handle abandon may trail it).
    {
        const deadline = TestDeadline.init(barrier_timeout_nanoseconds);
        for (&shared.completed_round) |*producer_word| {
            while (producer_word.load(.acquire) < round) {
                if (deadline.expired()) return error.ProducerBarrierTimeout;
                std.atomic.spinLoopHint();
            }
        }
    }

    // -- exactness (module doc) --

    // Consumers: full budget, per-producer FIFO already asserted inline.
    for (&consumer_probes) |*probe| {
        try testing.expectEqual(consumer_receive_budget, probe.received_count);
        for (probe.next_sequence_per_producer) |next_sequence| {
            try testing.expectEqual(envelopes_per_producer_per_target, next_sequence);
        }
    }
    // Sinks: exactly their budget, then killed.
    for (&sink_probes) |*probe| {
        try testing.expectEqual(sink_receive_budget, probe.received_count);
    }
    try testing.expectEqual(sink_count_per_round, sinks_drained_count);
    // Controller: one done per producer (asserted inline; count here).
    try testing.expectEqual(producer_thread_count, controller_probe.done_received_count);

    // Teardown reports: sinks + victims killed; sinks die with exactly
    // their leftovers, victims and normal exits die empty.
    try testing.expectEqual(
        sink_count_per_round + victim_count_per_round,
        kernel.teardown_tally.killed_count - tally_killed_at_start,
    );
    try testing.expectEqual(
        sink_count_per_round * sink_leftover_envelope_count,
        kernel.teardown_tally.killed_mailbox_depth_total,
    );
    try testing.expectEqual(
        consumer_count_per_round + 1, // consumers + controller
        kernel.teardown_tally.normal_count - tally_normal_at_start,
    );
    try testing.expectEqual(@as(usize, 0), kernel.teardown_tally.normal_mailbox_depth_total);
    kernel.teardown_tally.killed_mailbox_depth_total = 0;

    // Dead letters: the table's counter moved by exactly the misses the
    // producers observed (readable race-free after the completed-round
    // barrier), and every reason was a legal stale-pid reason.
    var observed_miss_total: u64 = 0;
    for (producers) |*producer| {
        observed_miss_total += producer.observed_lookup_miss_count;
    }
    try testing.expectEqual(
        observed_miss_total,
        kernel.pid_table.statistics().dead_letter_count - campaign_dead_letter_baseline,
    );
    try testing.expectEqual(@as(u64, 0), shared.dead_letter_other.load(.acquire));

    // Pool/table/stack/scheduler quiescence.
    try kernel.expectExactQuiescentAccounting();

    // Managers: exactly one teardown per spawn this round.
    for (managers) |*manager| {
        try testing.expectEqual(@as(usize, round), manager.teardown_count);
        try testing.expectEqual(@as(usize, 0), manager.live_heap_bytes);
    }

    // Preserve this round's roster as the next round's stale storm.
    var roster_cursor: usize = 0;
    for (shared.consumer_pids) |pid| {
        shared.previous_round_pids[roster_cursor] = pid;
        roster_cursor += 1;
    }
    for (shared.sink_pids) |pid| {
        shared.previous_round_pids[roster_cursor] = pid;
        roster_cursor += 1;
    }
    for (victim_pids) |pid| {
        shared.previous_round_pids[roster_cursor] = pid;
        roster_cursor += 1;
    }
    shared.previous_round_pids[roster_cursor] = shared.controller_pid;
    roster_cursor += 1;
    std.debug.assert(roster_cursor == processes_per_round);
}

test "AdversarialStress: cross-thread send/teardown storms hold every kernel invariant" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const round_count = try configuredRoundCount();

    var kernel: StressKernel = undefined;
    try kernel.init();
    defer kernel.deinit();

    var shared = SharedState{
        .pid_table = &kernel.pid_table,
        .envelope_pool = &kernel.envelope_pool,
        .scheduler = &kernel.scheduler,
    };
    kernel.pid_table.dead_letter_hook = SharedState.deadLetterHook;
    kernel.pid_table.dead_letter_context = &shared;
    const campaign_dead_letter_baseline = kernel.pid_table.statistics().dead_letter_count;

    var managers: [processes_per_round]StressManager = undefined;
    for (&managers) |*manager| {
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    defer for (&managers) |*manager| manager.arena.deinit();

    var producers: [producer_thread_count]Producer = undefined;
    for (&producers, 0..) |*producer, producer_index| {
        producer.* = .{
            .shared = &shared,
            .producer_index = producer_index,
            .round_count = round_count,
            .prng = std.Random.DefaultPrng.init(0xADE5_7E55 + producer_index),
        };
    }

    var producer_threads: [producer_thread_count]std.Thread = undefined;
    var spawned_thread_count: usize = 0;
    errdefer {
        // A round assertion failed: release the producers (they check
        // stop_requested inside their phase waits) and join before the
        // kernel deinits under them.
        shared.stop_requested.store(true, .release);
        for (producer_threads[0..spawned_thread_count]) |thread| thread.join();
        kernel.scheduler.shutdownAllProcesses();
    }
    for (&producer_threads, 0..) |*thread, producer_index| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{&producers[producer_index]});
        spawned_thread_count += 1;
    }

    var round: u64 = 1;
    while (round <= round_count) : (round += 1) {
        try runOneRound(&kernel, &shared, &managers, &producers, campaign_dead_letter_baseline, round);
    }

    shared.stop_requested.store(true, .release);
    for (producer_threads) |thread| thread.join();
    spawned_thread_count = 0;

    for (&producers) |*producer| {
        try testing.expect(!producer.failed);
    }

    // Campaign totals.
    const statistics = kernel.scheduler.statistics();
    try testing.expectEqual(@as(u64, round_count * processes_per_round), statistics.spawn_total);
    try testing.expectEqual(
        @as(u64, round_count * (sink_count_per_round + victim_count_per_round)),
        statistics.kill_total,
    );
    try testing.expectEqual(
        @as(u64, round_count * (consumer_count_per_round + 1)),
        statistics.normal_exit_total,
    );
}
