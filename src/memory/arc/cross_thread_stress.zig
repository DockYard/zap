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
//! Three send shapes live here, all under the same ThreadSanitizer run:
//!   1. same-model COPY (`runCrossThreadArcStress`, P3-J1) — flat data, consumer
//!      rebuilds a fresh cell;
//!   2. cross-model COPY (`runCrossModelSendReceiveStress`, P3-J4) — ARC senders
//!      → a foreign-model (bulk) receiver, flat data;
//!   3. same-model O(1) MOVE (`runMoveSendArcStress`, P3-J5) — the ONE shape
//!      where a REAL heap cell crosses by pointer: a LARGE buffer is DETACHED
//!      from the sender's ARC context and ADOPTED in place by the receiver's,
//!      refcount untouched by the move itself (rc==1, uniquely owned), the
//!      sender's last touch ordered before the receiver's by the hand-off. It is
//!      the direct TSan proof of the detach/adopt region-move primitive.
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

/// A bounded MPSC hand-off of `Message` values, guarded by the kernel-convention
/// `std.atomic.Mutex` spinlock (the fork drops the libc-coupled
/// `std.Thread.Mutex`/`Condition`; `envelope_pool.zig`/`tracking/manager.zig`
/// use the same spinlock). Deliberately NOT lock-free: the hand-off mechanism
/// is not what these tests validate (the kernel mailbox is already TSan-proven,
/// E3 Phase 1) — the per-process ARC contexts are. The spinlock makes the queue
/// itself race-free so any finding TSan reports is an ARC-context/refcount
/// race, not queue noise; when the queue is full/empty the waiter spins. The
/// lock/unlock pair is also the release/acquire edge that orders a producer's
/// last touch of a handed-off value BEFORE the consumer's first — the same
/// happens-before the real mailbox provides for a moved cell.
fn HandoffQueue(comptime Message: type) type {
    return struct {
        lock: std.atomic.Mutex = .unlocked,
        buffer: [1024]Message = undefined,
        head: usize = 0,
        count: usize = 0,
        live_producers: usize,

        const Self = @This();

        fn acquire(queue: *Self) void {
            while (!queue.lock.tryLock()) std.atomic.spinLoopHint();
        }

        fn push(queue: *Self, message: Message) void {
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
        fn pop(queue: *Self) ?Message {
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

        fn producerFinished(queue: *Self) void {
            queue.acquire();
            queue.live_producers -= 1;
            queue.lock.unlock();
        }
    };
}

/// The copy hand-off (P3-J1 / P3-J4): carries FLAT data — no heap pointer ever
/// crosses the thread boundary.
const FlatQueue = HandoffQueue(FlatMessage);

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

// ---------------------------------------------------------------------------
// The O(1) region-move send path under ThreadSanitizer (P3-J5).
//
// The two harnesses above hand FLAT data across threads and the consumer
// reconstructs a fresh cell — no heap pointer ever crosses; that is the COPY
// send. The MOVE send is fundamentally different: a LARGE (page-allocator
// backed) container buffer is DETACHED from the sender's ARC context and handed
// to the receiver BY POINTER (zero copy), which ADOPTS it into its own context
// in place. The SAME physical cell crosses the thread boundary — so this is the
// one send shape where a real heap pointer, not flat data, is shared.
//
// What TSan proves here: cross-thread `detach → hand-off → adopt` is race-free.
// `arcDetachRegion` mutates only the SENDER context's `large_head` and the
// block's own `LargeHeader` links; `arcAdoptRegion` mutates only the RECEIVER
// context's `large_head` and the same links — each within one thread's exclusive
// ownership window, and the queue's release/acquire orders the sender's last
// touch before the receiver's first. The refcount the sender set at allocation
// (rc=1) and the receiver clears at release (rc→0) is therefore a SYNCHRONIZED
// ownership transfer of a uniquely-owned cell, never a data race — the
// scheduler-local-refcount invariant across the move primitive. (Same-model
// only: a slab-backed buffer, a `Map`, or a cross-model receiver degrades to the
// copy path above, already TSan-proven; `arcDetachRegion` returns `false` and
// `send_message_moved` falls back to the copy send. See `manager.zig`'s
// region-move unit tests + `move_send_test.zap`.)
// ---------------------------------------------------------------------------

/// The moved container buffer's size: 8 KiB, safely above the ARC manager's
/// 4096-byte hard slab ceiling (`manager.zig` `SLAB_CLASS_SIZES`), so every
/// allocation is a standalone `page_allocator` block — the exact shape the O(1)
/// region-move re-parents. Mirrors `move_send_test.zap`'s large-`List` case
/// (1000 × `i64` ≈ 8 KB).
const move_payload_bytes: usize = 8 * 1024;
const move_payload_alignment: u32 = 16;

/// The cross-thread MOVE message. Carries the detached cell's address (as a
/// `usize`, so it is a plain value in the queue) plus `seq` for end-to-end
/// integrity. Unlike `FlatMessage`, the address names a REAL heap cell that the
/// receiver adopts in place — the byte payload is never copied.
const MoveMessage = struct {
    cell_address: usize,
    seq: u64,
};

/// The move hand-off: carries a heap-cell POINTER across the thread boundary
/// (the receiver adopts it in place — no reconstruct).
const MoveQueue = HandoffQueue(MoveMessage);

const MoveProducerConfig = struct {
    queue: *MoveQueue,
    rounds: usize,
    base_seq: u64,
};

/// Stamp `seq`, its checksum, and a tail sentinel into a moved buffer so the
/// receiver can prove the SAME physical bytes survived the pointer hand-off — a
/// copy, a torn write, or a raced value would fail the receiver's check.
fn stampMovePayload(buffer: [*]u8, seq: u64) void {
    const words: [*]u64 = @ptrCast(@alignCast(buffer));
    words[0] = seq;
    words[1] = checksumFor(seq);
    buffer[move_payload_bytes - 1] = @truncate(seq);
}

/// One MOVE producer thread: owns its OWN private ARC context, and per round
/// allocates a LARGE refcounted cell (rc=1), stamps it, DETACHES it (unlinking
/// it from this context so the context teardown can never free it — the receiver
/// owns it after adopt), and hands the pointer across. After the loop it tears
/// its context down: the detached orphans MUST survive that teardown (they are
/// in no context's list), which is exactly what proves detach transferred
/// ownership OUT rather than merely aliasing.
fn moveProducerMain(config: MoveProducerConfig) void {
    const context = arc.init(null) orelse @panic("arc-xthread-move: producer manager init failed");

    var round: usize = 0;
    while (round < config.rounds) : (round += 1) {
        const seq = config.base_seq + round;

        const cell = arc.allocateRefcounted(context, move_payload_bytes, move_payload_alignment) orelse
            @panic("arc-xthread-move: producer large cell alloc failed");
        stampMovePayload(cell, seq);

        // Detach from THIS context's `large_head`. `true` == large-backed and
        // relocatable; `false` would be a slab-backed copy-fallback, impossible
        // at this size — so a `false` here is a real regression, not a skip.
        if (!arc.detachRegion(context, cell, move_payload_bytes, move_payload_alignment))
            @panic("arc-xthread-move: a large buffer must be region-move eligible");

        config.queue.push(.{ .cell_address = @intFromPtr(cell), .seq = seq });
    }

    // The sender exits after sending. Its detached cells are orphans (in no
    // context's list) and MUST survive this teardown: `arcDeinit` walks only this
    // context's `large_head`, which no longer holds them — so nothing here can
    // race the consumer's concurrent adopt/release of those same cells.
    arc.deinit(context);
    config.queue.producerFinished();
}

/// Run the O(1) region-move send stress (P3-J5): `producer_count` ARC sender
/// threads — each on its OWN private ARC context — allocate LARGE refcounted
/// cells, DETACH them, and hand them BY POINTER to a single consumer (this
/// thread) that ADOPTS each into its own ARC context, verifies the physical
/// bytes crossed intact, and releases it (rc 1 → 0, `munmap`). Under
/// ThreadSanitizer this proves the scheduler-local-refcount invariant across the
/// move primitive: a real cell crosses threads, ordered by the mailbox hand-off
/// — zero races. Leak-exact: every moved cell is mapped once and freed once, and
/// no detached orphan leaks through a producer teardown.
pub fn runMoveSendArcStress(rounds_per_producer: usize) !void {
    // Baseline the (atomic) large map/unmap counters before any thread runs; read
    // single-threaded here and again after join, so the delta is the exact
    // per-run large-block traffic.
    const large_alloc_baseline = @atomicLoad(usize, &arc.test_large_alloc_total, .monotonic);
    const large_free_baseline = @atomicLoad(usize, &arc.test_large_free_total, .monotonic);

    var queue = MoveQueue{ .live_producers = producer_count };

    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < spawned) : (index += 1) threads[index].join();
    }
    while (spawned < producer_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, moveProducerMain, .{MoveProducerConfig{
            .queue = &queue,
            .rounds = rounds_per_producer,
            .base_seq = @as(u64, spawned) *% 0x1_0000_0000, // disjoint seq ranges per producer
        }});
    }

    // Consumer: owns a SEPARATE private ARC context and ADOPTS each moved cell in
    // place (no reconstruct), then releases it through that context.
    const consumer_context = arc.init(null) orelse @panic("arc-xthread-move: consumer manager init failed");
    var adopted: usize = 0;
    while (queue.pop()) |message| {
        const cell: *anyopaque = @ptrFromInt(message.cell_address);
        // Adopt: re-parent the SAME physical block into the consumer's context
        // (O(1) list surgery, no copy).
        arc.adoptRegion(consumer_context, cell, move_payload_bytes, move_payload_alignment);

        // End-to-end integrity: the same bytes crossed — `seq`, checksum, and the
        // tail sentinel must all match, or a copy/torn/raced value slipped through.
        const words: [*]const u64 = @ptrCast(@alignCast(cell));
        const bytes: [*]const u8 = @ptrCast(cell);
        const intact = words[0] == message.seq and
            words[1] == checksumFor(message.seq) and
            bytes[move_payload_bytes - 1] == @as(u8, @truncate(message.seq));
        if (!intact) {
            arc.releaseSized(consumer_context, cell, move_payload_bytes, move_payload_alignment, null);
            arc.deinit(consumer_context);
            for (&threads) |*thread| thread.join();
            return error.MoveSendDataCorruption;
        }

        // The consumer now solely owns it: release drops rc 1 → 0 and `munmap`s it
        // via the consumer's `large_head` (where adopt linked it) — leak-exact.
        arc.releaseSized(consumer_context, cell, move_payload_bytes, move_payload_alignment, null);
        adopted += 1;
    }
    arc.deinit(consumer_context); // wholesale free of the consumer's own heap

    for (&threads) |*thread| thread.join();

    // Exactly one moved cell per producer round was adopted.
    try std.testing.expectEqual(producer_count * rounds_per_producer, adopted);

    // Leak-exact: every large block mapped during the run (one per moved cell)
    // was `munmap`ed exactly once — the moved cells by the consumer's release,
    // and NO detached orphan leaked through a producer teardown (read after join,
    // so the plain delta is race-free by happens-before and TSan-clean).
    const large_alloc_total = @atomicLoad(usize, &arc.test_large_alloc_total, .monotonic);
    const large_free_total = @atomicLoad(usize, &arc.test_large_free_total, .monotonic);
    try std.testing.expectEqual(producer_count * rounds_per_producer, large_alloc_total - large_alloc_baseline);
    try std.testing.expectEqual(large_alloc_total - large_alloc_baseline, large_free_total - large_free_baseline);
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

test "ArcCrossThreadStress: O(1) region-move send (detach → cross-thread pointer hand-off → adopt) holds the scheduler-local-refcount invariant" {
    try runMoveSendArcStress(roundsFromEnvironment());
}
