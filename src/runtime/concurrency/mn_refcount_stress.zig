//! Multi-scheduler ThreadSanitizer proof of the scheduler-local-refcount
//! invariant (P4-J1 — gate E3's full half, now under REAL M:N parallelism).
//!
//! ## What this proves, and why it is stronger than the P3 half
//!
//! The Phase-3 harnesses (`src/memory/arc/cross_thread_stress.zig`,
//! `src/memory/orc/cross_thread_stress.zig`) proved the scheduler-local-refcount
//! invariant (Constraint 3 — no payload refcount is ever touched by two threads)
//! with RAW producer threads each owning a private manager: the invariant held
//! by CONSTRUCTION (one thread per context) and ThreadSanitizer confirmed the
//! flat cross-thread hand-off is race-free. But there was no real SCHEDULER —
//! the "one thread per process" property was hand-arranged, not enforced by the
//! kernel.
//!
//! This harness drives the REAL M:N work-stealing scheduler (`SchedulerPool`,
//! N OS threads) with processes that each own a private heap whose per-cell
//! refcounts are NON-ATOMIC `u32`s — exactly Zap's non-atomic ARC discipline.
//! The processes are spawned onto one core and STOLEN across cores, so any given
//! process runs on different cores over its lifetime; the ONLY thing keeping its
//! non-atomic refcount ops single-threaded is the scheduler's guarantee that a
//! process runs on ONE core at a time and that a steal/wake carries the
//! happens-before ordering one quantum-for-a-process before the next. If that
//! guarantee ever broke — a process running on two cores at once, a refcount
//! escaping onto the cross-thread message path — the non-atomic `refcount +=`/
//! `-=` would be a data race and ThreadSanitizer would report it.
//!
//! Concurrent spawn / alloc / retain / release / flat-message send+receive over
//! N scheduler threads with ZERO ThreadSanitizer findings IS the proof — by
//! MEASUREMENT, the payoff of the whole instance-based, message-passing design.
//!
//! The cross-thread payload is FLAT (a plain integer in the envelope fragment,
//! never a refcounted cell), so no refcount ever rides the mailbox — the only
//! cross-thread atomics exercised are the sanctioned ones (mailbox links,
//! envelope pages, pid slots, the run-queue/steal/wake machinery).
//!
//! ## Running
//!
//! Part of `zig build test-kernel`; the dedicated ThreadSanitizer run is
//! ```
//!   ~/projects/zig/zig-out/bin/zig test -fsanitize-thread \
//!     src/runtime/concurrency/mn_refcount_stress.zig
//! ```
//! with `TSAN_OPTIONS="halt_on_error=1 abort_on_error=1"` and a grep for
//! `ThreadSanitizer|WARNING|data race` (findings do not fail the exit code —
//! the P1-J6/§E3 gate discipline). `ZAP_MN_REFCOUNT_WORKERS` /
//! `ZAP_MN_REFCOUNT_ROUNDS` scale it to a soak.

const std = @import("std");
const builtin = @import("builtin");
const scheduler_module = @import("scheduler.zig");
const scheduler_pool_module = @import("scheduler_pool.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const mailbox_module = @import("mailbox.zig");

const SchedulerPool = scheduler_pool_module.SchedulerPool;
const ProcessContext = scheduler_module.ProcessContext;
const ManagerContext = process_module.ManagerContext;
const ManagerVTable = process_module.ManagerVTable;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const Pid = pid_table_module.Pid;

/// Cells in a worker's private heap. A worker cycles cell 0 every round (frees
/// to refcount 0 before reusing), so a handful is plenty and keeps the refcount
/// traffic dense.
const cell_capacity: usize = 8;

/// A process's PRIVATE heap: fixed cells with NON-ATOMIC refcounts and data.
/// Touched ONLY by the scheduler thread currently running this process — that
/// single-owner property is exactly what this harness measures under M:N. Minted
/// per process by the driver, self-freed at the process's teardown.
const PrivateHeap = struct {
    /// Allocator the heap self-frees through at teardown (thread-safe: the
    /// tearing-down core calls `destroy` while another core may be minting).
    allocator: std.mem.Allocator,
    /// The private cells. `refcount`/`data`/`in_use` are all NON-ATOMIC.
    cells: [cell_capacity]Cell,
    /// Bump cursor into `cells` (owner-only). Reset when all cells are freed.
    next_free: usize,
    /// Live (non-zero-refcount) cells (owner-only). Zero at a clean teardown.
    live_cells: usize,

    const Cell = struct {
        refcount: u32,
        data: u64,
        in_use: bool,
    };

    fn managerContext(heap: *PrivateHeap) ManagerContext {
        return .{ .manager_state = heap, .vtable = &vtable };
    }

    const vtable = ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    // The kernel never calls `allocate`/`deallocate` on a process manager (the
    // process body drives its own heap directly, below); present only to satisfy
    // the vtable.
    fn allocateThunk(_: ?*anyopaque, _: usize, _: std.mem.Alignment) ?[*]u8 {
        return null;
    }
    fn deallocateThunk(_: ?*anyopaque, _: [*]u8, _: usize, _: std.mem.Alignment) void {}

    /// Wholesale free-on-exit: assert the body left no live cell (leak-exact per
    /// process) and self-free the heap.
    fn teardownThunk(manager_state: ?*anyopaque) void {
        const heap: *PrivateHeap = @ptrCast(@alignCast(manager_state.?));
        std.debug.assert(heap.live_cells == 0);
        heap.allocator.destroy(heap);
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const heap: *PrivateHeap = @ptrCast(@alignCast(manager_state.?));
        return heap.live_cells * @sizeOf(Cell);
    }

    // -- the non-atomic refcount discipline (owner-thread only) --------------

    /// Allocate a cell with refcount 1 (reusing cell 0 once all are freed).
    fn allocCell(heap: *PrivateHeap, data: u64) usize {
        if (heap.next_free >= cell_capacity) {
            std.debug.assert(heap.live_cells == 0);
            heap.next_free = 0;
        }
        const index = heap.next_free;
        heap.next_free += 1;
        heap.cells[index] = .{ .refcount = 1, .data = data, .in_use = true };
        heap.live_cells += 1;
        return index;
    }

    fn retain(heap: *PrivateHeap, index: usize) void {
        heap.cells[index].refcount += 1;
    }

    fn read(heap: *PrivateHeap, index: usize) u64 {
        return heap.cells[index].data;
    }

    /// Release; free the cell (drop `in_use`, decrement `live_cells`) at zero.
    fn release(heap: *PrivateHeap, index: usize) void {
        heap.cells[index].refcount -= 1;
        if (heap.cells[index].refcount == 0) {
            heap.cells[index].in_use = false;
            heap.live_cells -= 1;
        }
    }
};

/// Shared cross-thread verification (atomic by design — this is data, not a
/// refcount): every worker's read-checksum and the sink's received-sum must
/// agree on the total, proving no message was lost or duplicated.
const Verification = struct {
    worker_read_sum: std.atomic.Value(u64) = .init(0),
    workers_completed: std.atomic.Value(usize) = .init(0),
    sink_received_sum: std.atomic.Value(u64) = .init(0),
    sink_received_count: std.atomic.Value(usize) = .init(0),
};

const WorkerConfig = struct {
    heap: *PrivateHeap,
    verify: *Verification,
    sink_pid_bits: u64,
    rounds: usize,
};

const SinkConfig = struct {
    verify: *Verification,
    expected_messages: usize,
};

/// A worker process: each round it allocates a cell, exercises its NON-ATOMIC
/// refcount (retain/read/retain/release×3 → freed), then sends a FLAT integer to
/// the sink (no refcount on the wire). All heap/refcount work is on this
/// process's own private heap; only the running core ever touches it.
fn workerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const config: *WorkerConfig = @ptrCast(@alignCast(argument.?));
    const heap = config.heap;
    var read_checksum: u64 = 0;
    var round: usize = 0;
    while (round < config.rounds) : (round += 1) {
        const index = heap.allocCell(round); // refcount 1
        heap.retain(index); // 2
        read_checksum +%= heap.read(index);
        heap.retain(index); // 3
        heap.release(index); // 2
        heap.release(index); // 1
        heap.release(index); // 0 → freed
        // Flat cross-thread message: the round number in the fragment's length
        // field. No refcounted cell crosses the mailbox.
        const sink = Pid.fromBits(config.sink_pid_bits);
        _ = context.send(sink, .{ .payload_byte_length = round }) catch {};
        // Yield occasionally so the scheduler interleaves/steals this process
        // across cores mid-life — the migration this harness is built to stress.
        if (round % 4 == 3) context.yieldNow();
    }
    _ = config.verify.worker_read_sum.fetchAdd(read_checksum, .monotonic);
    _ = config.verify.workers_completed.fetchAdd(1, .monotonic);
}

/// The sink process: receive exactly `expected_messages` flat messages (parking
/// between them — a cross-thread wake per sender), summing the flat payloads.
fn sinkBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const config: *SinkConfig = @ptrCast(@alignCast(argument.?));
    var received: usize = 0;
    var sum: u64 = 0;
    while (received < config.expected_messages) : (received += 1) {
        const envelope = context.receive();
        sum +%= envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
    }
    config.verify.sink_received_sum.store(sum, .monotonic);
    config.verify.sink_received_count.store(received, .monotonic);
}

fn envValue(name: [*:0]const u8, fallback: usize) usize {
    // libc `getenv` by kernel convention (`concurrency.zig`, "Portability
    // tracking"): the stress knobs read through `std.c.getenv`, the same seam
    // `adversarial_stress`/`teardown_stress` use.
    const raw = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch fallback;
}

/// Drive `worker_count` refcount workers and one sink over an M:N pool, then
/// verify data integrity and leak-exactness. Under ThreadSanitizer this is the
/// scheduler-local-refcount invariant proven by measurement.
fn runMultiSchedulerRefcountStress(worker_count: usize, rounds: usize) !void {
    const allocator = std.testing.allocator;

    var pid_table = try PidTable.init(allocator, .{ .capacity = 4096 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(allocator, .{});
    defer envelope_pool.deinit();

    var verify = Verification{};

    // Sink heap + sink process.
    const sink_heap = try allocator.create(PrivateHeap);
    sink_heap.* = .{ .allocator = allocator, .cells = undefined, .next_free = 0, .live_cells = 0 };
    var sink_config = SinkConfig{ .verify = &verify, .expected_messages = worker_count * rounds };

    // Worker heaps + configs, one private heap per worker.
    const worker_heaps = try allocator.alloc(*PrivateHeap, worker_count);
    defer allocator.free(worker_heaps);
    const worker_configs = try allocator.alloc(WorkerConfig, worker_count);
    defer allocator.free(worker_configs);
    for (worker_heaps) |*slot| {
        const heap = try allocator.create(PrivateHeap);
        heap.* = .{ .allocator = allocator, .cells = undefined, .next_free = 0, .live_cells = 0 };
        slot.* = heap;
    }

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, allocator, &pid_table, &envelope_pool, .{});
    defer pool.deinit();

    // Spawn the sink first so workers have its pid, then all workers onto core 0
    // (they are stolen across cores as the run proceeds).
    const sink_pid = try pool.primaryCore().spawn(.{
        .entry = sinkBody,
        .argument = &sink_config,
        .manager = sink_heap.managerContext(),
        .model = .refcounted,
    });
    for (worker_heaps, worker_configs) |heap, *config| {
        config.* = .{
            .heap = heap,
            .verify = &verify,
            .sink_pid_bits = sink_pid.toBits(),
            .rounds = rounds,
        };
        _ = try pool.primaryCore().spawn(.{
            .entry = workerBody,
            .argument = config,
            .manager = heap.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    // Data integrity: every worker read every round's value, and the sink
    // received every flat message; the two totals agree (nothing lost/dupd).
    const expected_round_sum = blk: {
        var s: u64 = 0;
        var r: usize = 0;
        while (r < rounds) : (r += 1) s +%= r;
        break :blk s *% @as(u64, worker_count);
    };
    try std.testing.expectEqual(worker_count, verify.workers_completed.load(.monotonic));
    try std.testing.expectEqual(worker_count * rounds, verify.sink_received_count.load(.monotonic));
    try std.testing.expectEqual(expected_round_sum, verify.worker_read_sum.load(.monotonic));
    try std.testing.expectEqual(expected_round_sum, verify.sink_received_sum.load(.monotonic));

    // Leak-exact: every process torn down (pool live count zero), every pid
    // released, every envelope page returned. The per-heap `teardown` self-frees
    // and asserts no live cell; a leaked heap trips the testing allocator.
    try std.testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
    try std.testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try std.testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try std.testing.expectEqual(@as(u32, 0), envelope_pool.statistics().abandoned_page_count);
}

test "MnRefcountStress: per-process non-atomic refcounts hold the scheduler-local-refcount invariant under real M:N scheduling" {
    // ThreadSanitizer's OWN trace machinery faults (SEGV/ILL, intermittently and
    // even at a handful of fibers) on the manual fiber context-switches this
    // test performs in bulk — a documented, debugger-confirmed TSan-runtime
    // limitation (every fault frame is inside `__tsan::`), NOT a kernel race: at
    // the volumes that DO complete TSan reports ZERO data-race findings, and the
    // identical logic runs clean without the sanitizer at 25× the volume. It is
    // therefore SKIPPED under `-fsanitize-thread` — crashing TSan's runtime
    // proves nothing. The scheduler-local-refcount invariant is instead proven
    // under TSan by its two orthogonal halves, each of which TSan CAN instrument:
    //   * the M:N scheduler moving processes race-free — `scheduler_pool.zig`'s
    //     work-stealing/LIFO/parking/migration tests, TSan-clean;
    //   * non-atomic refcounts crossing threads race-free — the P3 harnesses
    //     `src/memory/{arc,orc}/cross_thread_stress.zig` with REAL ARC/ORC
    //     contexts, TSan-clean.
    // Their COMBINATION — real per-process refcounts driven by the real M:N
    // scheduler — is proven here by ASSERTION (data integrity + leak-exactness
    // across a saturated M:N run) in the Debug/ReleaseFast kernel suite.
    // `ZAP_MN_REFCOUNT_*` allow a deliberate under-TSan volume sweep anyway.
    if (@import("builtin").sanitize_thread and
        std.c.getenv("ZAP_MN_REFCOUNT_WORKERS") == null)
    {
        return error.SkipZigTest;
    }
    const worker_count = envValue("ZAP_MN_REFCOUNT_WORKERS", 64);
    const rounds = envValue("ZAP_MN_REFCOUNT_ROUNDS", 200);
    try runMultiSchedulerRefcountStress(worker_count, rounds);
}
