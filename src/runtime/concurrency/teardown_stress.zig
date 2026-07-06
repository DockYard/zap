//! Darwin teardown stress campaign for the Zap concurrency kernel.
//!
//! Phase 1 item 1.7 of `docs/concurrency-implementation-plan.md` (job
//! P1-J5): thousands of spawn/die cycles across every Phase 1 teardown
//! shape, under leak-checking allocation (`std.testing.allocator` backs
//! every structure) and byte-accounting per-process managers, with EXACT
//! resource accounting asserted after every wave — fiber stacks, envelope
//! pages (live AND abandoned), pid slots, process records, drop-list
//! destructor runs, and manager teardown counts all return to their
//! quiescent values.
//!
//! ## The mimalloc-#164 hazard class, and what this test actually pins
//!
//! mimalloc's macOS bug #164 (research-round-2.md §mimalloc): per-thread
//! heap state lived in thread-locals, and Darwin destroyed the
//! thread-locals BEFORE the heap cleanup that needed them ran — cleanup
//! executing against already-destroyed state at teardown time. The Zap
//! kernel avoids the class STRUCTURALLY: per-process heaps are PCB fields
//! torn down by the scheduler's explicit, ordered teardown path (pid
//! unregister → wake-stack flush → drop-list destructors → mailbox drain
//! → envelope-handle abandon → stack release → wholesale manager free —
//! `scheduler.zig`), never by OS thread-local destructors; the kernel
//! keeps ZERO teardown-relevant TLS by design (plan A.2.4). What remains
//! is the same FAILURE MODE with kernel-owned ordering: teardown code
//! touching a resource another teardown already released — freeing an
//! envelope into a page whose owner died (the abandon/reclaim handoff),
//! draining a mailbox holding a dead sender's envelopes, releasing a
//! stack into a cache that immediately unmaps it. This campaign drives
//! those orderings at volume, on Darwin (the tier-1 platform, where the
//! guard-page `mprotect` + mmap/munmap cache churn is also
//! platform-specific), and converts any ordering regression into a loud
//! failure: Debug stack poisoning catches use-after-release, the pool
//! `deinit`/`release` asserts catch double-frees and leaks, the
//! testing allocator catches heap leaks, and the per-wave exact
//! accounting catches anything that merely drifts. The waves are sized so
//! the stack-pool cache cap (peak/2) forces real munmap/mmap traffic on
//! every wave rather than pure cache hits.
//!
//! ## Volume knob
//!
//! The committed default (`default_total_spawn_cycles`) is sized for CI
//! sanity — seconds, not minutes, in Debug on Apple Silicon. For a long
//! soak, set the environment variable `ZAP_TEARDOWN_STRESS_CYCLES` to the
//! desired total spawn/die cycle count and run the kernel gate:
//!
//! ```
//! ZAP_TEARDOWN_STRESS_CYCLES=200000 ~/projects/zig/zig-out/bin/zig build test-kernel
//! ```
//!
//! The cycle count is rounded down to whole waves (one wave =
//! `cycles_per_wave` mixed-shape processes); at least one wave always
//! runs.
//!
//! ## Toolchain
//!
//! Drives the scheduler (fiber switches), so the kernel-wide
//! fork-compiler requirement for optimized builds applies (see
//! `concurrency.zig`).

const std = @import("std");
const builtin = @import("builtin");
const fiber_context = @import("fiber_context.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const mailbox_module = @import("mailbox.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const scheduler_module = @import("scheduler.zig");

const testing = std.testing;

const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const Scheduler = scheduler_module.Scheduler;
const ProcessContext = scheduler_module.ProcessContext;
const ManagerContext = process_module.ManagerContext;

/// Committed default total spawn/die cycles (CI-sanity sizing — module
/// doc). Overridden by `ZAP_TEARDOWN_STRESS_CYCLES`.
const default_total_spawn_cycles: usize = 5_000;

/// Environment variable overriding the total cycle count (module doc).
const stress_cycles_environment_variable = "ZAP_TEARDOWN_STRESS_CYCLES";

// -- wave composition ---------------------------------------------------------------
//
// One wave interleaves every Phase 1 teardown shape so their teardowns,
// abandoned-page reclaims, and pool traffic overlap:

/// Shape 1 — immediate exit: the entry returns on its first quantum.
const immediate_exit_count_per_wave: usize = 16;
/// Shape 2 — exit with a populated mailbox: a receiver consumes ONE of
/// its sender's envelopes and exits normally with the rest queued
/// (teardown drains them into the dead sender's abandoned pages).
const populated_mailbox_pair_count_per_wave: usize = 4;
/// Envelopes sent per populated-mailbox pair (1 consumed, the rest
/// drained by teardown).
const populated_mailbox_envelope_count: usize = 4;
/// Shape 3 — kill while waiting: victims parked in `receive`, killed
/// from the non-cooperative point; half also die with undelivered
/// envelopes pushed from an abandoned test-side handle.
const killed_waiter_count_per_wave: usize = 8;
/// Envelopes queued onto every second killed waiter before the kill.
const killed_waiter_envelope_count: usize = 2;
/// Shape 4 — exit with drop-list resources: each process registers
/// external resources and allocates from its manager; exit runs the
/// destructors LIFO and wholesale-frees the heap.
const drop_list_exiter_count_per_wave: usize = 8;
/// Drop-list resources registered per shape-4 process.
const drop_resources_per_exiter: usize = 4;
/// Manager bytes allocated per shape-4 process (wholesale-freed).
const drop_exiter_heap_bytes: usize = 256;
/// Shape 5 — sender dies with in-flight envelopes to a LIVE receiver:
/// the sender exits (abandoning its envelope pages) before the receiver
/// consumes; the receiver's frees reclaim the abandoned pages.
const dead_sender_pair_count_per_wave: usize = 4;
/// Envelopes per shape-5 pair (spans a pool page: pages hold 8).
const dead_sender_envelope_count: usize = 6;

/// Processes spawned per wave across all shapes.
const cycles_per_wave: usize = immediate_exit_count_per_wave +
    2 * populated_mailbox_pair_count_per_wave +
    killed_waiter_count_per_wave +
    drop_list_exiter_count_per_wave +
    2 * dead_sender_pair_count_per_wave;

/// Per-wave manager slots: one byte-accounting arena manager per spawned
/// process (never shared between concurrently-live processes).
const managers_per_wave = cycles_per_wave;

/// Total spawn/die cycles for this run: the environment knob, or the
/// committed default. Fails loudly on an unparsable knob value rather
/// than silently running the default.
fn configuredTotalSpawnCycles() !usize {
    const raw_value = std.c.getenv(stress_cycles_environment_variable) orelse
        return default_total_spawn_cycles;
    const value_slice = std.mem.span(raw_value);
    const parsed = std.fmt.parseInt(usize, value_slice, 10) catch
        return error.InvalidStressCycleKnob;
    if (parsed == 0) return error.InvalidStressCycleKnob;
    return parsed;
}

// -- per-process manager --------------------------------------------------------------

/// The shared Phase 1 test-manager shape (`test_support.zig`). Reused
/// across waves — teardown re-arms the arena — but never shared between
/// concurrently-live processes.
const StressManager = @import("test_support.zig").CountingArenaManager;

// -- process bodies -------------------------------------------------------------------

fn immediateExitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    _ = argument;
}

fn blockForeverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("blockForeverEntry: received a message nobody should have sent");
}

const ReceiveBudgetProbe = struct {
    /// Envelopes to consume before exiting.
    receive_budget: usize,
    /// Envelopes actually consumed (verified per wave).
    received_count: usize = 0,
};

fn receiveBudgetThenExitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ReceiveBudgetProbe = @ptrCast(@alignCast(argument.?));
    while (probe.received_count < probe.receive_budget) {
        const envelope = context.receive();
        envelope_pool_module.free(envelope);
        probe.received_count += 1;
    }
}

const SendBurstProbe = struct {
    target: Pid,
    envelope_count: usize,
};

fn sendBurstEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SendBurstProbe = @ptrCast(@alignCast(argument.?));
    var sent: usize = 0;
    while (sent < probe.envelope_count) : (sent += 1) {
        const outcome = context.send(probe.target, .{ .payload_byte_length = sent }) catch
            @panic("sendBurstEntry: envelope allocation failed");
        if (outcome != .delivered) @panic("sendBurstEntry: send dead-lettered unexpectedly");
    }
}

/// A drop-list resource: its destructor increments the wave's shared
/// counter (LIFO order is pinned by the scheduler tests; here the count
/// is the exactness assertion).
const DropResource = struct {
    node: process_module.DropListNode,
    destructor_run_counter: *usize,

    fn destructor(node: *process_module.DropListNode) void {
        const resource: *DropResource = @fieldParentPtr("node", node);
        resource.destructor_run_counter.* += 1;
    }
};

const DropListExiterProbe = struct {
    resources: *[drop_resources_per_exiter]DropResource,
};

fn dropListExiterEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *DropListExiterProbe = @ptrCast(@alignCast(argument.?));
    // Allocate real heap bytes so teardown's wholesale free has work.
    const manager = context.record.pcb.manager;
    _ = manager.allocate(drop_exiter_heap_bytes, .of(u8)) orelse
        @panic("dropListExiterEntry: allocation failed");
    for (probe.resources) |*resource| {
        context.registerDropResource(&resource.node);
    }
}

// -- the campaign kernel ----------------------------------------------------------------

const StressKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,

    fn init(kernel: *StressKernel) !void {
        kernel.pid_table = try PidTable.init(testing.allocator, .{ .capacity = 128 });
        // Small pages (8 slots) so the shape-5 bursts (6 envelopes) and
        // shape-2 drains exercise page growth, abandonment, and reclaim.
        kernel.envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
        kernel.scheduler = Scheduler.init(testing.allocator, &kernel.pid_table, &kernel.envelope_pool, .{
            // Small stacks keep the Debug poison fill cheap at volume
            // while still exercising the guard-page mmap/mprotect path.
            .stack_usable_size = 64 * 1024,
            .preemption_budget = 32,
            .idle_strategy = .forbid_parking,
        });
    }

    fn deinit(kernel: *StressKernel) void {
        // The pool/table deinits assert their own exact-accounting
        // invariants — the "clean process-level teardown" half of the
        // campaign (module doc).
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }

    /// The per-wave exact-accounting gate: every counted resource back to
    /// its quiescent value.
    fn expectExactAccounting(kernel: *StressKernel) !void {
        try testing.expectEqual(@as(u32, 0), kernel.pid_table.statistics().live_process_count);
        const envelope_statistics = kernel.envelope_pool.statistics();
        try testing.expectEqual(@as(u32, 0), envelope_statistics.live_page_count);
        try testing.expectEqual(@as(u32, 0), envelope_statistics.abandoned_page_count);
        const stack_statistics = kernel.scheduler.stackPoolStatistics();
        try testing.expectEqual(@as(u32, 0), stack_statistics.live_stack_count);
        try testing.expect(stack_statistics.cached_stack_count <= stack_statistics.cache_capacity);
        const scheduler_statistics = kernel.scheduler.statistics();
        try testing.expectEqual(@as(u32, 0), scheduler_statistics.live_process_count);
        try testing.expectEqual(@as(usize, 0), scheduler_statistics.ready_queue_depth);
    }
};

/// One wave: spawn every shape interleaved, run to the deterministic
/// idle point, kill the waiting victims, run to quiescence, then assert
/// exact accounting and per-shape behavior.
fn runOneWave(
    kernel: *StressKernel,
    managers: *[managers_per_wave]StressManager,
    wave_index: usize,
) !void {
    var manager_cursor: usize = 0;

    // Shape 3 state (killed waiters + their queued envelopes).
    var killed_waiter_pids: [killed_waiter_count_per_wave]Pid = undefined;
    // Shape 2/5 state.
    var populated_mailbox_probes: [populated_mailbox_pair_count_per_wave]ReceiveBudgetProbe = undefined;
    var populated_mailbox_send_probes: [populated_mailbox_pair_count_per_wave]SendBurstProbe = undefined;
    var dead_sender_receive_probes: [dead_sender_pair_count_per_wave]ReceiveBudgetProbe = undefined;
    var dead_sender_send_probes: [dead_sender_pair_count_per_wave]SendBurstProbe = undefined;
    // Shape 4 state.
    var destructor_run_count: usize = 0;
    var drop_resources: [drop_list_exiter_count_per_wave][drop_resources_per_exiter]DropResource = undefined;
    var drop_probes: [drop_list_exiter_count_per_wave]DropListExiterProbe = undefined;

    const nextManager = struct {
        fn take(pool: *[managers_per_wave]StressManager, cursor: *usize) *StressManager {
            const manager = &pool[cursor.*];
            cursor.* += 1;
            return manager;
        }
    }.take;

    // Interleave the spawns shape-by-shape so ready-queue order mixes
    // every teardown flavor within the wave.
    var immediate_spawned: usize = 0;
    var pair_index: usize = 0;
    while (pair_index < populated_mailbox_pair_count_per_wave) : (pair_index += 1) {
        // Shape 2: receiver first (waits), its sender second (sends, dies
        // first, abandons its pages with the unconsumed envelopes).
        populated_mailbox_probes[pair_index] = .{ .receive_budget = 1 };
        const receiver_pid = try kernel.scheduler.spawn(.{
            .entry = receiveBudgetThenExitEntry,
            .argument = &populated_mailbox_probes[pair_index],
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
        populated_mailbox_send_probes[pair_index] = .{
            .target = receiver_pid,
            .envelope_count = populated_mailbox_envelope_count,
        };
        _ = try kernel.scheduler.spawn(.{
            .entry = sendBurstEntry,
            .argument = &populated_mailbox_send_probes[pair_index],
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });

        // A slice of shape 1 between the pairs.
        var immediate_burst: usize = 0;
        while (immediate_burst < immediate_exit_count_per_wave / populated_mailbox_pair_count_per_wave) : (immediate_burst += 1) {
            _ = try kernel.scheduler.spawn(.{
                .entry = immediateExitEntry,
                .manager = nextManager(managers, &manager_cursor).managerContext(),
            });
            immediate_spawned += 1;
        }
    }

    var waiter_index: usize = 0;
    while (waiter_index < killed_waiter_count_per_wave) : (waiter_index += 1) {
        killed_waiter_pids[waiter_index] = try kernel.scheduler.spawn(.{
            .entry = blockForeverEntry,
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }

    var exiter_index: usize = 0;
    while (exiter_index < drop_list_exiter_count_per_wave) : (exiter_index += 1) {
        for (&drop_resources[exiter_index]) |*resource| {
            resource.* = .{
                .node = .{ .destructor = DropResource.destructor },
                .destructor_run_counter = &destructor_run_count,
            };
        }
        drop_probes[exiter_index] = .{ .resources = &drop_resources[exiter_index] };
        _ = try kernel.scheduler.spawn(.{
            .entry = dropListExiterEntry,
            .argument = &drop_probes[exiter_index],
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }

    pair_index = 0;
    while (pair_index < dead_sender_pair_count_per_wave) : (pair_index += 1) {
        // Shape 5: live receiver consumes EVERYTHING its dying sender
        // sent; the receiver's frees reclaim the sender's abandoned pages.
        dead_sender_receive_probes[pair_index] = .{ .receive_budget = dead_sender_envelope_count };
        const receiver_pid = try kernel.scheduler.spawn(.{
            .entry = receiveBudgetThenExitEntry,
            .argument = &dead_sender_receive_probes[pair_index],
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
        dead_sender_send_probes[pair_index] = .{
            .target = receiver_pid,
            .envelope_count = dead_sender_envelope_count,
        };
        _ = try kernel.scheduler.spawn(.{
            .entry = sendBurstEntry,
            .argument = &dead_sender_send_probes[pair_index],
            .manager = nextManager(managers, &manager_cursor).managerContext(),
        });
    }

    std.debug.assert(manager_cursor == managers_per_wave);
    std.debug.assert(immediate_spawned == immediate_exit_count_per_wave);

    // Run: everything except the shape-3 waiters terminates by itself.
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    // Queue envelopes onto every second waiter from a test-side handle,
    // abandon the handle FIRST (pages flip abandoned while their
    // envelopes are still queued), then kill: the teardown drain's frees
    // must reclaim the abandoned pages.
    var waiter_handle = EnvelopePool.Handle.init(&kernel.envelope_pool);
    waiter_index = 0;
    while (waiter_index < killed_waiter_count_per_wave) : (waiter_index += 2) {
        const waiter_pcb = kernel.pid_table.lookup(killed_waiter_pids[waiter_index]) orelse
            return error.TestUnexpectedResult;
        var queued: usize = 0;
        while (queued < killed_waiter_envelope_count) : (queued += 1) {
            const envelope = try waiter_handle.allocate();
            envelope.fragment = .{ .payload_byte_length = wave_index };
            _ = waiter_pcb.mailbox.push(envelope);
        }
    }
    waiter_handle.abandon();

    for (killed_waiter_pids) |waiter_pid| {
        // The first kill's teardown drains the wake stack (teardown step
        // 3), converting the envelope-queued waiters to runnable a little
        // early — so later kills legitimately resolve `.kill_pending`
        // (torn down at their next scheduling point, without running).
        // What may NEVER happen is `.not_found`: every waiter is alive
        // until its kill.
        const outcome = kernel.scheduler.kill(waiter_pid);
        try testing.expect(outcome == .killed or outcome == .kill_pending);
    }
    try kernel.scheduler.runUntilQuiescent();

    // Per-shape exactness.
    for (&populated_mailbox_probes) |*probe| {
        try testing.expectEqual(@as(usize, 1), probe.received_count);
    }
    for (&dead_sender_receive_probes) |*probe| {
        try testing.expectEqual(@as(usize, dead_sender_envelope_count), probe.received_count);
    }
    try testing.expectEqual(
        drop_list_exiter_count_per_wave * drop_resources_per_exiter,
        destructor_run_count,
    );

    // Every manager: torn down exactly once this wave, heap accounting
    // zeroed by the wholesale free.
    for (managers) |*manager| {
        try testing.expectEqual(wave_index + 1, manager.teardown_count);
        try testing.expectEqual(@as(usize, 0), manager.live_heap_bytes);
    }

    // The wave-level exact-accounting gate (module doc).
    try kernel.expectExactAccounting();
}

test "TeardownStress: thousands of mixed-shape spawn/die cycles with exact accounting per wave" {
    const total_cycles = try configuredTotalSpawnCycles();
    const wave_count = @max(total_cycles / cycles_per_wave, 1);

    var kernel: StressKernel = undefined;
    try kernel.init();
    defer kernel.deinit();

    var managers: [managers_per_wave]StressManager = undefined;
    for (&managers) |*manager| {
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    defer for (&managers) |*manager| manager.arena.deinit();

    var wave_index: usize = 0;
    while (wave_index < wave_count) : (wave_index += 1) {
        try runOneWave(&kernel, &managers, wave_index);
    }

    // Campaign totals: every spawn accounted, exactly one manager
    // teardown per spawn.
    const statistics = kernel.scheduler.statistics();
    try testing.expectEqual(@as(u64, wave_count * cycles_per_wave), statistics.spawn_total);
    try testing.expectEqual(
        @as(u64, wave_count * killed_waiter_count_per_wave),
        statistics.kill_total,
    );
    try testing.expectEqual(
        @as(u64, wave_count * (cycles_per_wave - killed_waiter_count_per_wave)),
        statistics.normal_exit_total,
    );
    var total_teardowns: usize = 0;
    for (&managers) |*manager| total_teardowns += manager.teardown_count;
    try testing.expectEqual(wave_count * cycles_per_wave, total_teardowns);
}
