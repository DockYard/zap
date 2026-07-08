//! Cross-thread ORC race validation with REAL per-process ORC manager instances
//! (the ORC arm of the P3-J1 / P3-R1a "scheduler-local-refcount" TSan seam).
//!
//! This is the ORC counterpart to `src/memory/arc/cross_thread_stress.zig`. The
//! P3-R1a per-process retain/release dispatch fix routes an ORC process's
//! refcount ops to ORC's OWN vtable on ITS OWN context; this harness proves the
//! thing that dispatch relies on — that ORC's per-process refcount machinery is
//! itself race-free across threads, so the routed ops never introduce a
//! cross-thread refcount touch.
//!
//! Shape (identical invariant to the ARC harness): N producer threads, EACH
//! owning its OWN real ORC context (a private side-table refcount map + private
//! backing heap; `src/memory/orc/manager.zig`), concurrently:
//!   * allocate a refcounted cell (`allocate_refcounted`, rc=1) in their private
//!     heap,
//!   * exercise the refcount ops (`retain_sized`/`release_sized`) on their OWN
//!     cell (a retain/release pair leaves rc at 1 — owner-only, no other thread
//!     touches this cell's side-table entry),
//!   * read the cell's DATA into a FLAT message carrying ZERO live refcount (the
//!     zero-live-refcount-in-flight design), release the cell (rc→0, freed back
//!     into that producer's heap), and hand the flat message across threads.
//! The consumer (this thread) owns a SEPARATE ORC context and ADOPTS each flat
//! message by allocating a FRESH rc=1 cell in ITS OWN heap, verifying integrity,
//! then releasing it.
//!
//! Because every ORC context is thread-exclusive and the cross-thread payload is
//! flat data (never a refcounted cell), no two threads ever touch the same
//! side-table entry, the same cell's inline atomics, or the same backing heap —
//! the scheduler-local-refcount invariant. TSan asserting zero races over the
//! real ORC refcount ops is the proof; every producer/consumer context's
//! DebugAllocator `deinit` (the `builtin.is_test` backing) asserting zero leaked
//! cells is the leak-exactness proof (a residual cell would surface as a
//! `log.err` that fails the test runner).
//!
//! ## ORC declines the O(1) move, so there is no move variant here
//!
//! The ARC harness's third shape — a large cell crossing by pointer via
//! detach/adopt — has no ORC analogue: `orcDetachRegion` declines every move
//! (returns false), so ORC same-model sends are ALWAYS the flat copy above. The
//! detach/adopt slots exist for ABI completeness only; there is no cross-thread
//! pointer hand-off of an ORC cell to race.
//!
//! ## Location / toolchain / TSan
//!
//! Lives beside the real ORC manager (`src/memory/orc/`) and imports it as a
//! same-directory sibling (`manager.zig`) — the standalone `zig test` module
//! root forbids a cross-directory manager import, exactly as the ARC harness
//! documents. Aggregated into `src/root.zig`, so its correctness + leak-exact
//! teardown run in the normal `zig build test`. The dedicated ThreadSanitizer
//! run is:
//!
//! ```
//! TSAN_OPTIONS="halt_on_error=1 abort_on_error=1" \
//!   ~/projects/zig/zig-out/bin/zig test --zig-lib-dir ~/projects/zig/lib \
//!   -fsanitize-thread src/memory/orc/cross_thread_stress.zig
//! ```
//!
//! Soak knob: `ZAP_ORC_XTHREAD_ROUNDS`.

const std = @import("std");
const builtin = @import("builtin");

/// The REAL production ORC manager — the same per-instance manager Phase 3 binds
/// per ORC process. Imported directly so this test drives genuinely INDEPENDENT
/// per-process ORC instances.
const orc = @import("manager.zig");

/// A "rich" refcounted cell payload (32 bytes). `seq` identifies the cell;
/// `checksum` is a function of `seq` so the consumer can verify end-to-end data
/// integrity across the thread boundary.
const CellPayload = extern struct {
    seq: u64,
    checksum: u64,
    filler: u64,
    tag: u64,
};

const cell_size: usize = @sizeOf(CellPayload);
const cell_align: u32 = @alignOf(CellPayload);

/// The FLAT cross-thread message — a plain value with NO refcount and NO pointer
/// into any producer's heap (the zero-live-refcount-in-flight design).
const FlatMessage = struct {
    seq: u64,
    checksum: u64,
};

fn checksumFor(seq: u64) u64 {
    return (seq *% 0x9E3779B97F4A7C15) ^ (seq << 7) ^ (seq >> 3);
}

/// Committed default rounds per producer (CI-sanity sizing — seconds under
/// TSan). Overridden by `ZAP_ORC_XTHREAD_ROUNDS` for a long soak.
const default_rounds_per_producer: usize = 2_000;
const rounds_environment_variable = "ZAP_ORC_XTHREAD_ROUNDS";
const producer_count: usize = 4;

/// A bounded MPSC hand-off guarded by the kernel-convention `std.atomic.Mutex`
/// spinlock (the fork drops the libc-coupled `std.Thread.Mutex`). The hand-off
/// is deliberately NOT what this test validates — the per-process ORC contexts
/// are — so the spinlock keeps the queue itself race-free (any TSan finding is
/// then an ORC-context/refcount race, not queue noise). Its lock/unlock pair is
/// also the release/acquire edge ordering a producer's last touch of a
/// handed-off value BEFORE the consumer's first.
const HandoffQueue = struct {
    lock: std.atomic.Mutex = .unlocked,
    buffer: [1024]FlatMessage = undefined,
    head: usize = 0,
    count: usize = 0,
    live_producers: usize,

    fn acquire(queue: *HandoffQueue) void {
        while (!queue.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn push(queue: *HandoffQueue, message: FlatMessage) void {
        while (true) {
            queue.acquire();
            if (queue.count < queue.buffer.len) {
                const tail = (queue.head + queue.count) % queue.buffer.len;
                queue.buffer[tail] = message;
                queue.count += 1;
                queue.lock.unlock();
                return;
            }
            queue.lock.unlock(); // full — release and spin
            std.atomic.spinLoopHint();
        }
    }

    fn pop(queue: *HandoffQueue) ?FlatMessage {
        while (true) {
            queue.acquire();
            if (queue.count > 0) {
                const message = queue.buffer[queue.head];
                queue.head = (queue.head + 1) % queue.buffer.len;
                queue.count -= 1;
                queue.lock.unlock();
                return message;
            }
            if (queue.live_producers == 0) {
                queue.lock.unlock();
                return null; // drained and every producer has finished
            }
            queue.lock.unlock(); // empty but producers live — release and spin
            std.atomic.spinLoopHint();
        }
    }

    fn producerFinished(queue: *HandoffQueue) void {
        queue.acquire();
        queue.live_producers -= 1;
        queue.lock.unlock();
    }
};

const ProducerConfig = struct {
    queue: *HandoffQueue,
    rounds: usize,
    base_seq: u64,
};

/// One producer thread: owns its OWN private ORC context for its whole life,
/// builds + refcount-exercises + sends flat, and tears the context down
/// (wholesale free of its private heap).
fn producerMain(config: ProducerConfig) void {
    const context = orc.init(null) orelse @panic("orc-xthread: producer manager init failed");
    defer orc.deinit(context);

    var round: usize = 0;
    while (round < config.rounds) : (round += 1) {
        const seq = config.base_seq + round;

        // Allocate a refcounted cell in THIS producer's private heap (rc=1).
        const raw = orc.allocateRefcounted(context, cell_size, cell_align) orelse
            @panic("orc-xthread: producer cell alloc failed");
        const cell: *CellPayload = @ptrCast(@alignCast(raw));
        cell.* = .{ .seq = seq, .checksum = checksumFor(seq), .filler = seq *% 3, .tag = round };

        // Exercise the refcount ops on this OWNER'S own cell: a retain/release
        // pair leaves rc at 1 (owner-only — no other thread touches this cell's
        // side-table entry).
        orc.retainSized(context, cell, cell_size, cell_align); // rc 1 -> 2
        orc.releaseSized(context, cell, cell_size, cell_align, null); // rc 2 -> 1

        // Serialize the cell's DATA into a flat message (zero live refcount in
        // flight), then release the cell (rc 1 -> 0, freed back into this
        // producer's heap).
        const message = FlatMessage{ .seq = cell.seq, .checksum = cell.checksum };
        orc.releaseSized(context, cell, cell_size, cell_align, null); // rc 1 -> 0, freed

        config.queue.push(message);
    }
    config.queue.producerFinished();
}

/// Run the cross-thread ORC stress: `producer_count` producer threads against a
/// single adopting consumer (this thread), each side on its own private ORC
/// context. Asserts every adopted message's data integrity; every context's
/// DebugAllocator teardown asserts leak-exactness (a residual cell fails the run
/// via the allocator's leak `log.err`).
pub fn runCrossThreadOrcStress(rounds_per_producer: usize) !void {
    var queue = HandoffQueue{ .live_producers = producer_count };

    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < spawned) : (index += 1) threads[index].join();
    }
    while (spawned < producer_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, producerMain, .{ProducerConfig{
            .queue = &queue,
            .rounds = rounds_per_producer,
            .base_seq = @as(u64, spawned) *% 0x1_0000_0000, // disjoint seq ranges per producer
        }});
    }

    // Consumer: this thread owns a SEPARATE private ORC context and ADOPTS each
    // flat message by allocating a fresh rc=1 cell in its own heap.
    const consumer_context = orc.init(null) orelse @panic("orc-xthread: consumer manager init failed");
    var adopted: usize = 0;
    while (queue.pop()) |message| {
        const raw = orc.allocateRefcounted(consumer_context, cell_size, cell_align) orelse
            @panic("orc-xthread: consumer adopt alloc failed");
        const cell: *CellPayload = @ptrCast(@alignCast(raw));
        cell.* = .{ .seq = message.seq, .checksum = message.checksum, .filler = message.seq *% 3, .tag = adopted };
        // End-to-end data integrity: a torn / raced value fails here.
        if (cell.checksum != checksumFor(cell.seq)) {
            orc.releaseSized(consumer_context, cell, cell_size, cell_align, null);
            orc.deinit(consumer_context);
            for (&threads) |*thread| thread.join();
            return error.CrossThreadDataCorruption;
        }
        orc.releaseSized(consumer_context, cell, cell_size, cell_align, null); // rc 1 -> 0, freed
        adopted += 1;
    }
    orc.deinit(consumer_context); // wholesale free of the consumer's private heap

    for (&threads) |*thread| thread.join();

    // Exactly one message per producer round was produced and adopted.
    try std.testing.expectEqual(producer_count * rounds_per_producer, adopted);
    // The run must have actually done work (else the workload was elided).
    try std.testing.expect(adopted > 0);
}

fn roundsFromEnvironment() usize {
    // Fork-convention env read (libc `std.c.getenv`; macOS always links
    // libSystem), mirroring the ARC harness / `adversarial_stress.zig`.
    const raw_value = std.c.getenv(rounds_environment_variable) orelse
        return default_rounds_per_producer;
    return std.fmt.parseInt(usize, std.mem.span(raw_value), 10) catch default_rounds_per_producer;
}

test "OrcCrossThreadStress: concurrent per-process ORC managers hold the scheduler-local-refcount invariant" {
    if (builtin.single_threaded) return error.SkipZigTest;
    try runCrossThreadOrcStress(roundsFromEnvironment());
}
