//! Cross-thread ARC race validation with REAL per-process manager instances
//! (E3 full-half seam, P3-J1 deliverable 4).
//!
//! ## What this proves (and how it differs from E3's Phase-1 half)
//!
//! E3's Phase-1 half (P1-J6) proved the kernel's SHARED machinery — mailbox
//! links, envelope page ownership, pid-table transitions, park/wake — races
//! zero under adversarial concurrency, but its payloads were OPAQUE stamped
//! words: there was no real memory manager per process, so the
//! scheduler-local-REFCOUNT invariant (Constraint 3 — no refcount is ever
//! touched by two threads) held only BY CONSTRUCTION, untestable by TSan
//! (implementation-plan item 3.1's "Phase-3 TSan seam"; the Phase-1 §E3 verdict
//! scheduled the refcount half for "E3's full half (Phase 3)").
//!
//! P3-J1 lands per-process manager INSTANCES: each process owns its OWN ARC
//! context (a private slab pool with side-table refcounts;
//! `src/memory/arc/manager.zig`). This harness exercises that with REAL OS
//! threads under ThreadSanitizer, so the invariant is proven by MEASUREMENT,
//! not just argument:
//!
//!   * N producer threads, EACH owning its OWN real ARC context, concurrently
//!     allocate refcounted cells (`allocate_refcounted`, rc=1), exercise the
//!     ATOMIC refcount ops (`retain_sized`/`release_sized`) on their own cells,
//!     read each cell's DATA into a flat message (carrying ZERO live refcount —
//!     the item-3.1 zero-live-refcount-in-flight design), release the cell
//!     (rc→0, freed back into that producer's private slab pool), and hand the
//!     flat message across threads;
//!   * the consumer (this thread) owns a SEPARATE real ARC context and ADOPTS
//!     each flat message by allocating a FRESH rc=1 cell in ITS OWN pool,
//!     verifying data integrity, then releasing it.
//!
//! Because every context is thread-exclusive and the cross-thread payload is
//! flat data (never a refcounted cell), no two threads ever touch the same slab
//! pool or the same cell's refcount — the scheduler-local-refcount invariant.
//! TSan asserting zero races over ~real refcount atomics and ~real slab
//! alloc/free is the proof. Exact accounting (every mapped slab of every
//! context unmapped at its `deinit`) proves leak-freedom across the run.
//!
//! ## Concurrency shape tested, and what remains for Phase 4 (M:N)
//!
//! Phase 3's scheduler is SINGLE-threaded (one run queue), so a process's own
//! allocation/adoption always runs on the one scheduler thread; the genuinely
//! cross-thread actors are the SENDERS (the mailbox push side is any-thread by
//! design — `mailbox.zig`). This harness tests exactly that shape: N sender
//! THREADS, each with its own private manager, concurrently producing +
//! handing off; the receiver adopts on its own thread. **Phase 4's M:N
//! scheduler** adds the remaining axis — multiple SCHEDULER threads each
//! running receivers that adopt into their own per-process contexts
//! concurrently — which the Phase-4 Linux CI leg of E3 (plan gate table) will
//! cover once processes migrate across scheduler threads. The invariant is the
//! same (per-process contexts ⇒ no shared refcount); Phase 4 widens the set of
//! threads that can run the adopt.
//!
//! ## Location / toolchain / TSan
//!
//! Lives beside the real ARC manager (`src/memory/arc/`) — not in the kernel
//! subtree — because it depends on the manager, not on the (runtime-free)
//! kernel modules; the kernel test module cannot import across the
//! `src/runtime/concurrency/` module boundary. It is aggregated into
//! `src/root.zig`, so its correctness + leak-exact accounting run in the normal
//! `zig build test`. The dedicated ThreadSanitizer run is:
//!
//! ```
//! TSAN_OPTIONS="halt_on_error=1 abort_on_error=1" \
//!   ~/projects/zig/zig-out/bin/zig test --zig-lib-dir ~/projects/zig/lib \
//!   -fsanitize-thread src/memory/arc/cross_thread_stress.zig
//! ```
//!
//! E3 established `-fsanitize-thread` availability on the fork (P1-J6 §E3); the
//! run sets `TSAN_OPTIONS` so findings SIGABRT, and the output is grepped for
//! `ThreadSanitizer|WARNING|data race`. Soak knob: `ZAP_ARC_XTHREAD_ROUNDS`.

const std = @import("std");
const builtin = @import("builtin");

/// The REAL production ARC manager — the same per-instance manager Phase 3
/// binds per process. Imported directly (not through the runtime's singleton
/// `test_only_arc`, which returns one shared context) so this test drives
/// genuinely INDEPENDENT per-process instances, which only exist off the real
/// manager (project memory: multiple real ARC instances do not exist in the
/// host runtime singleton).
const arc = @import("manager.zig");

/// A "rich" refcounted cell payload (32 bytes → a real intermediate slab
/// class, not the minimum). `seq` identifies the cell; `checksum` is a
/// function of `seq` so the consumer can verify end-to-end data integrity.
const CellPayload = extern struct {
    seq: u64,
    checksum: u64,
    filler: u64,
    tag: u64,
};

const cell_class_index: u32 = arc.refcountSlabClassIndex(@sizeOf(CellPayload), @alignOf(CellPayload)).?;

/// The FLAT cross-thread message — a plain value with NO refcount and NO
/// pointer into any producer's heap (the zero-live-refcount-in-flight design).
const FlatMessage = struct {
    seq: u64,
    checksum: u64,
};

fn checksumFor(seq: u64) u64 {
    // A cheap, order-independent mix so a corrupted/torn value is caught.
    return (seq *% 0x9E3779B97F4A7C15) ^ (seq << 7) ^ (seq >> 3);
}

/// Committed default rounds per producer (CI-sanity sizing — seconds under
/// TSan). Overridden by `ZAP_ARC_XTHREAD_ROUNDS` for a long soak.
const default_rounds_per_producer: usize = 2_000;
const rounds_environment_variable = "ZAP_ARC_XTHREAD_ROUNDS";
const producer_count: usize = 4;

/// A bounded MPSC hand-off of flat messages, guarded by the kernel-convention
/// `std.atomic.Mutex` spinlock (the fork drops the libc-coupled
/// `std.Thread.Mutex`/`Condition`; `envelope_pool.zig`/`tracking/manager.zig`
/// use the same spinlock). Deliberately NOT lock-free: the hand-off mechanism
/// is not what this test validates (the kernel mailbox is already TSan-proven,
/// E3 Phase 1) — the per-process ARC contexts are. The spinlock makes the queue
/// itself race-free so any finding TSan reports is an ARC-context/refcount
/// race, not queue noise; when the queue is full/empty the waiter spins.
const FlatQueue = struct {
    lock: std.atomic.Mutex = .unlocked,
    buffer: [1024]FlatMessage = undefined,
    head: usize = 0,
    count: usize = 0,
    live_producers: usize,

    fn acquire(queue: *FlatQueue) void {
        while (!queue.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn push(queue: *FlatQueue, message: FlatMessage) void {
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

    /// Pop the next message, or null once every producer has finished and the
    /// buffer is drained.
    fn pop(queue: *FlatQueue) ?FlatMessage {
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

    fn producerFinished(queue: *FlatQueue) void {
        queue.acquire();
        queue.live_producers -= 1;
        queue.lock.unlock();
    }
};

const ProducerConfig = struct {
    queue: *FlatQueue,
    rounds: usize,
    base_seq: u64,
};

/// One producer thread: owns its OWN private ARC context for its whole life,
/// builds + refcount-exercises + sends flat, and tears the context down.
fn producerMain(config: ProducerConfig) void {
    const context = arc.init(null) orelse @panic("arc-xthread: producer manager init failed");
    defer arc.deinit(context); // wholesale free of this producer's private heap

    var round: usize = 0;
    while (round < config.rounds) : (round += 1) {
        const seq = config.base_seq + round;

        // Allocate a refcounted cell in THIS producer's private pool (rc=1).
        const raw = arc.allocateRefcountedClass(context, cell_class_index) orelse
            @panic("arc-xthread: producer cell alloc failed");
        const cell: *CellPayload = @ptrCast(@alignCast(raw));
        cell.* = .{ .seq = seq, .checksum = checksumFor(seq), .filler = seq *% 3, .tag = round };

        // Exercise the ATOMIC refcount ops on this OWNER'S own cell: a
        // retain/release pair leaves rc at 1 (owner-only — no other thread
        // touches this cell's side-table refcount).
        arc.retainSizedClass(context, cell, cell_class_index); // rc 1 -> 2
        arc.releaseSizedClass(context, cell, cell_class_index, null); // rc 2 -> 1

        // Serialize the cell's DATA into a flat message (zero live refcount in
        // flight), then release the cell (rc 1 -> 0, freed back into this
        // producer's pool).
        const message = FlatMessage{ .seq = cell.seq, .checksum = cell.checksum };
        arc.releaseSizedClass(context, cell, cell_class_index, null); // rc 1 -> 0, freed

        config.queue.push(message);
    }
    config.queue.producerFinished();
}

/// Run the cross-thread ARC stress: `producer_count` producer threads against a
/// single adopting consumer (this thread), each side on its own private ARC
/// context. Asserts every adopted message's data integrity and leak-exact slab
/// accounting (every mapped slab of every context unmapped at teardown).
pub fn runCrossThreadArcStress(rounds_per_producer: usize) !void {
    // Baseline the (atomic) slab map/unmap counters before any thread runs;
    // read single-threaded here, and again after join, so the delta is the
    // exact per-run mapping traffic (every mapped slab must be unmapped).
    const mmap_baseline = @atomicLoad(usize, &arc.test_slab_mmap_total, .monotonic);
    const unmap_baseline = @atomicLoad(usize, &arc.test_slab_unmap_total, .monotonic);

    var queue = FlatQueue{ .live_producers = producer_count };

    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        // On a spawn failure, let the already-spawned producers finish so we
        // never join a partially-started set.
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

    // Consumer: this thread owns a SEPARATE private ARC context and ADOPTS each
    // flat message by allocating a fresh rc=1 cell in its own pool.
    const consumer_context = arc.init(null) orelse @panic("arc-xthread: consumer manager init failed");
    var adopted: usize = 0;
    while (queue.pop()) |message| {
        const raw = arc.allocateRefcountedClass(consumer_context, cell_class_index) orelse
            @panic("arc-xthread: consumer adopt alloc failed");
        const cell: *CellPayload = @ptrCast(@alignCast(raw));
        // Adopt: reconstruct the cell from the flat data in the CONSUMER's heap.
        cell.* = .{ .seq = message.seq, .checksum = message.checksum, .filler = message.seq *% 3, .tag = adopted };
        // End-to-end data integrity: a torn / raced value fails here.
        if (cell.checksum != checksumFor(cell.seq)) {
            arc.releaseSizedClass(consumer_context, cell, cell_class_index, null);
            arc.deinit(consumer_context);
            for (&threads) |*thread| thread.join();
            return error.CrossThreadDataCorruption;
        }
        arc.releaseSizedClass(consumer_context, cell, cell_class_index, null); // rc 1 -> 0, freed
        adopted += 1;
    }
    arc.deinit(consumer_context); // wholesale free of the consumer's private heap

    for (&threads) |*thread| thread.join();

    // Exactly one message per producer round was produced and adopted.
    try std.testing.expectEqual(producer_count * rounds_per_producer, adopted);

    // Leak-exact: every slab any context mapped during the run was unmapped by
    // that context's teardown (read after join — happens-before makes the plain
    // delta race-free and TSan-clean).
    const mmap_total = @atomicLoad(usize, &arc.test_slab_mmap_total, .monotonic);
    const unmap_total = @atomicLoad(usize, &arc.test_slab_unmap_total, .monotonic);
    try std.testing.expectEqual(mmap_total - mmap_baseline, unmap_total - unmap_baseline);
    // The run must have actually mapped slabs (else the workload was elided).
    try std.testing.expect(mmap_total - mmap_baseline > 0);
}

/// Run the CROSS-MODEL send/receive stress (P3-J4): `producer_count` REFCOUNTED
/// (ARC) sender threads — each on its OWN private ARC context, exercising the
/// atomic refcount ops on its OWN cells — hand flat messages to a single
/// consumer (this thread) that adopts each into a BULK_OR_NEVER receiver heap of
/// a DIFFERENT reclamation model. This is the cross-model half of the sacred
/// scheduler-local-refcount invariant: the refcount atomics live ENTIRELY on
/// the ARC senders' side (never touched by the bulk receiver, which maintains
/// NO refcount), the cross-thread payload is FLAT (zero live refcount), and the
/// receiver reconstructs each cell into ITS OWN heap — reclaimed WHOLESALE at
/// the receiver's `deinit`, never per-cell. No two threads touch the same
/// refcount or the same heap, ACROSS models. TSan asserting zero races over the
/// senders' real refcount atomics — while a foreign-model receiver concurrently
/// adopts — is the cross-model proof; the ARC senders' leak-exact slab
/// accounting proves their heaps are reclaimed, and the bulk receiver's
/// wholesale `deinit` reclaims the receiver's.
///
/// The receiver heap is a `std.heap.ArenaAllocator` over the page allocator —
/// the exact reclamation SHAPE of `Memory.Arena` (BULK_OR_NEVER): allocate
/// grows, nothing is freed per-cell, and `deinit` reclaims the whole heap in one
/// go. It stands in for the real Arena manager here so the file stays a single
/// self-contained standalone-`zig test` module (the documented ThreadSanitizer
/// invocation compiles one file, whose module root forbids a cross-directory
/// manager import); the invariant under test — a foreign-MODEL receiver that
/// touches no refcount while ARC senders exercise refcount atomics concurrently
/// — is identical for the real manager, and the gate-ON `:test_concurrency`
/// suite exercises the REAL Arena manager end-to-end through the walker.
pub fn runCrossModelSendReceiveStress(rounds_per_producer: usize) !void {
    const mmap_baseline = @atomicLoad(usize, &arc.test_slab_mmap_total, .monotonic);
    const unmap_baseline = @atomicLoad(usize, &arc.test_slab_unmap_total, .monotonic);

    var queue = FlatQueue{ .live_producers = producer_count };

    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < spawned) : (index += 1) threads[index].join();
    }
    while (spawned < producer_count) : (spawned += 1) {
        // The senders are the SAME real ARC producers — the refcount-exercising
        // side whose atomics TSan watches for cross-thread races.
        threads[spawned] = try std.Thread.spawn(.{}, producerMain, .{ProducerConfig{
            .queue = &queue,
            .rounds = rounds_per_producer,
            .base_seq = @as(u64, spawned) *% 0x1_0000_0000,
        }});
    }

    // Cross-model receiver: this thread owns a private BULK_OR_NEVER heap (an
    // arena/bump allocator, the `Memory.Arena` reclamation shape) and adopts
    // each flat message by allocating a FRESH cell in it — NO refcount header
    // maintained, NO per-cell free.
    var receiver_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const receiver_allocator = receiver_arena.allocator();
    var adopted: usize = 0;
    while (queue.pop()) |message| {
        const cell = receiver_allocator.create(CellPayload) catch
            @panic("xmodel: bulk receiver adopt alloc failed");
        // Adopt: reconstruct the cell from the flat data in the receiver's OWN
        // heap (the cross-model copy). A torn / raced value fails the integrity
        // check.
        cell.* = .{ .seq = message.seq, .checksum = message.checksum, .filler = message.seq *% 3, .tag = adopted };
        if (cell.checksum != checksumFor(cell.seq)) {
            receiver_arena.deinit();
            for (&threads) |*thread| thread.join();
            return error.CrossModelDataCorruption;
        }
        // No per-cell free: the bulk heap reclaims WHOLESALE at deinit
        // (bulk_or_never — the receiver-model adoption discipline, §2.4).
        adopted += 1;
    }
    receiver_arena.deinit(); // wholesale free of the receiver's bulk heap

    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(producer_count * rounds_per_producer, adopted);

    // Leak-exact on the ARC SENDER side: every slab any producer mapped was
    // unmapped by that producer's teardown (read after join — happens-before
    // makes the plain delta race-free and TSan-clean). The bulk receiver's heap
    // is reclaimed wholesale by its `deinit` above.
    const mmap_total = @atomicLoad(usize, &arc.test_slab_mmap_total, .monotonic);
    const unmap_total = @atomicLoad(usize, &arc.test_slab_unmap_total, .monotonic);
    try std.testing.expectEqual(mmap_total - mmap_baseline, unmap_total - unmap_baseline);
    try std.testing.expect(mmap_total - mmap_baseline > 0);
}

fn roundsFromEnvironment() usize {
    // Fork-convention env read (libc `std.c.getenv`; macOS always links
    // libSystem), mirroring `adversarial_stress.zig`/`teardown_stress.zig`.
    const raw_value = std.c.getenv(rounds_environment_variable) orelse
        return default_rounds_per_producer;
    return std.fmt.parseInt(usize, std.mem.span(raw_value), 10) catch default_rounds_per_producer;
}

test "ArcCrossThreadStress: concurrent per-process ARC managers hold the scheduler-local-refcount invariant" {
    try runCrossThreadArcStress(roundsFromEnvironment());
}

test "ArcCrossThreadStress: cross-model send/receive (ARC senders → Arena receiver) holds the scheduler-local-refcount invariant" {
    try runCrossModelSendReceiveStress(roundsFromEnvironment());
}
