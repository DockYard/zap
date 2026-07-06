//! Shared envelope page pool for the Zap concurrency kernel.
//!
//! Phase 1 item 1.3 of `docs/concurrency-implementation-plan.md` (job
//! P1-J3), second half: the **third allocation domain** of
//! `zap-concurrency-research.md` §5.3 — in-flight envelopes are owned by
//! *neither* process's manager; they are message-system property drawn
//! from this shared page pool. The plan §3 send shape is: *copy into a
//! detachable fragment from the shared envelope page pool (owned by the
//! message system; abandon/reclaim on sender death) → one atomic exchange
//! onto the receiver's mailbox → wakeup.* The mailbox half is
//! `mailbox.zig`; this module is the pool.
//!
//! ## Ownership discipline (research.md §6.4/§6.6)
//!
//! * **Envelopes and pages belong to the message system**, never to a
//!   process's memory manager. A sender's manager and a receiver's
//!   manager are both non-atomic and strictly scheduler-local; the pool
//!   exists precisely so that neither manager is ever touched from two
//!   threads.
//! * **Payloads are opaque bytes here.** The `Fragment` a sender
//!   populates (Phase 2's deep-copy walker) carries freshly-copied cells
//!   whose refcounts are touched only by the sender before the mailbox
//!   push and only by the receiver after the pop — the mailbox's
//!   release/acquire edge is the sole synchronization. **No payload
//!   refcount is ever atomic and none is ever accessed cross-thread**;
//!   the only atomics in the message system are the mailbox queue links
//!   (`mailbox.zig`) and this pool's page bookkeeping, enumerated below.
//!
//! ## Structure
//!
//! ```
//!   EnvelopePool (shared reservoir, one per runtime)
//!     ├── spinlock-guarded bounded cache of empty pages (high-watermark
//!     │   policy, mirroring stack_pool.zig / src/memory/arc/manager.zig)
//!     └── issues pages to…
//!   EnvelopePool.Handle (one per producer — a process's sender side)
//!     └── owned pages (owner-only intrusive list); envelopes are carved
//!         from the head page (recycled slot first, then bump cursor)
//!   EnvelopePage
//!     ├── status: ONE atomic word packing {live_envelope_count, ownership}
//!     ├── recycled_slots: atomic MPSC free list (any thread frees,
//!     │   only the owner allocates)
//!     └── trailing array of Envelope slots
//! ```
//!
//! ## Abandon/reclaim (mimalloc precedent; zap-concurrency-research §2.4)
//!
//! When a process dies while envelopes it sent are still in flight, its
//! pages cannot be freed (the receivers still hold the envelopes) and
//! cannot be kept (the owner is gone). Following mimalloc's
//! abandoned-segment reclamation (research-round-2.md Q3: *"when a thread
//! exits, its heap's pages are abandoned and later reclaimed by other
//! threads that free blocks into them"*), `Handle.abandon`:
//!
//! * returns each owned page with **zero** live envelopes straight to the
//!   reservoir, and
//! * flips each page with live envelopes to `.abandoned` — an atomic
//!   ownership release. The freeing thread that returns the **last**
//!   envelope of an abandoned page reclaims the page into the reservoir.
//!
//! ### Which transitions are atomic, and why
//!
//! | atomic | op / ordering | why |
//! |---|---|---|
//! | `EnvelopePage.status` (packed `{count, ownership}`) | owner alloc: `fetchAdd(+1, .monotonic)`; any-thread free: `fetchSub(1, .acq_rel)`; owner abandon: `cmpxchg .acq_rel`; owner empty-check: `load .acquire` | the count is decremented by receiver threads while the owner allocates, and the *pair* `{count, ownership}` decides reclaim. Packing both in one word makes every decision a single atomic observation — see the reclaim proof below. Alloc can be `.monotonic` because envelope/page publication to receivers rides the mailbox push/pop release/acquire edge, never this counter. |
//! | `EnvelopePage.recycled_slots` head | free push: `cmpxchgWeak .release`; owner pop: `load .acquire` + `cmpxchgWeak .acq_rel` | receivers on other threads return slots while the owner pops them. Single-popper (the owner) means the classic Treiber pop ABA cannot occur: only the popper removes nodes, so the head cannot be popped-and-repushed behind its own back. |
//! | reservoir spinlock (`std.atomic.Mutex`) | page issue/return, abandon transition, statistics | cold path (≈ once per `envelopes_per_page` allocations). A spinlock over `std.atomic.Mutex` rather than `std.Thread.Mutex` for the same reason as `src/memory/tracking/manager.zig`: the kernel must stay free of libc-coupled OS-threading primitives, and every critical section is O(1). |
//!
//! **Never atomic:** payload bytes and payload refcounts (see above);
//! `bump_cursor` and `next_owned` (owner-only); `next_cached`
//! (spinlock-guarded); everything in `Handle` (single-owner).
//!
//! ### Reclaim uniqueness proof
//!
//! Frees push the slot to `recycled_slots` **before** decrementing the
//! count. Consequences:
//!
//! 1. `count == 0` ⇒ no free is mid-flight anywhere (every free's push
//!    precedes its decrement in program order, and all decrements have
//!    happened) ⇒ the page is quiescent and may leave service.
//! 2. The transition `count 1 → 0` happens exactly once per page life.
//!    The `fetchSub` that performs it returns the prior word; if that
//!    word says `.abandoned`, this freeing thread is the unique reclaimer
//!    (the owner published `.abandoned` before dying and never touches
//!    the page again; only the owner allocates, so the count can never
//!    rise after abandonment).
//! 3. If `Handle.abandon` observes `count == 0` (`.acquire`, pairing with
//!    the release half of the freeing `fetchSub` RMWs), by (1) the page
//!    is quiescent and the owner returns it directly — no `.abandoned`
//!    state, no rendezvous needed. Frees on the same `status` word form a
//!    release sequence, so the observation carries visibility of every
//!    freeing thread's slot-push writes.
//!
//! The abandoned-page counter and the ownership CAS run under the
//! reservoir spinlock so the counter cannot transiently underflow when a
//! racing last-free reclaims immediately after the CAS commits (the
//! reclaimer's own decrement also takes the lock inside
//! `returnEmptyPage`).
//!
//! ## Bounded empty-page cache (high-watermark policy)
//!
//! The reservoir's empty-page cache mirrors `stack_pool.zig` and the ARC
//! manager's empty-slab cache (`src/memory/arc/manager.zig`): the cap
//! derives from `live_page_peak`, the most pages ever simultaneously in
//! service, so cached pages only exist strictly below a live level real
//! demand already reached. `cap = clamp(peak / 2, 2, 64)`.
//!
//! A **handle's** owned-page set needs no separate policy: `allocate`
//! reuses owned pages (recycled slot or bump space) before ever taking a
//! reservoir page — walk-before-grow — so a handle's page count is
//! bounded by its own live-envelope high-watermark, and every page
//! returns to the reservoir at `abandon` time (empty ones immediately,
//! in-flight ones via abandon/reclaim).
//!
//! ## Multi-producer posture (what is exercised now vs deferred)
//!
//! Exercised now: **many handles over one shared reservoir from many
//! threads**, cross-thread frees into owned and abandoned pages, and
//! abandon racing in-flight frees (the stress test below). A `Handle` is
//! single-owner by contract — one process's send side — mirroring the
//! per-quantum current-process discipline (`process.zig`). Deferred to
//! Phase 4: whether handles bind per-process or per-scheduler-thread
//! (plan Appendix A.4), mid-life trimming of a live handle's empty pages
//! (bounded by the watermark argument above; revisit with Phase 4
//! observability), and NUMA/size-class shaping of the reservoir.
//!
//! ## Phase 2 seam
//!
//! Phase 1 envelopes carry an opaque `Fragment` (typed pointer + length +
//! payload-origin page, `mailbox.zig`). Phase 2's deep-copy walker (plan
//! item 2.4) will allocate *payload* fragments from this same domain and
//! populate `Fragment.payload_origin_page`; the pool's page/abandon
//! machinery is deliberately payload-agnostic so that lands without
//! layout change here.
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so this
//! file has no special compiler requirement; see `concurrency.zig` for
//! the kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");
const mailbox_module = @import("mailbox.zig");

pub const Envelope = mailbox_module.Envelope;

/// Whether the deterministic-interleaving test instrumentation is
/// compiled in. Test builds only — the hook, its field, and its call
/// site all vanish from non-test builds (same pattern as
/// `mailbox.PushInstrumentation`).
pub const enable_test_instrumentation = builtin.is_test;

/// Test-only free-path instrumentation (compiled out of non-test
/// builds): `between_slot_push_and_count_decrement` runs on the freeing
/// thread AFTER its recycled-slot push and BEFORE its count decrement —
/// exactly the window in which the owner can already re-allocate the
/// pushed slot while the count still includes the not-yet-decremented
/// free (see `noteEnvelopeAllocated` for why that transient over-count
/// is legal). Lets a test park a freeing thread there and exercise the
/// interleaving DETERMINISTICALLY.
pub const FreeInstrumentation = if (enable_test_instrumentation) struct {
    /// Hook invoked in the push→decrement window; null (default)
    /// disables.
    between_slot_push_and_count_decrement: ?*const fn (instrumentation_context: ?*anyopaque, envelope: *Envelope) void = null,
    /// Opaque context handed to the hook.
    instrumentation_context: ?*anyopaque = null,
} else struct {};

/// Default number of envelope slots carved from one page. At the current
/// envelope size this keeps a page in the low single-digit KiB — small
/// enough that short-lived senders don't strand memory, large enough
/// that the reservoir spinlock is touched roughly once per hundred
/// sends.
pub const default_envelopes_per_page: u32 = 128;

/// Page-cache cap = clamp(live_page_peak / PAGE_CACHE_PEAK_DIVISOR,
///                        PAGE_CACHE_RETAIN_FLOOR, PAGE_CACHE_RETAIN_CEILING).
///
/// * `PAGE_CACHE_PEAK_DIVISOR = 2` — retain at most half the demonstrated
///   peak, mirroring `EMPTY_CACHE_PEAK_DIVISOR` (ARC slabs) and
///   `CACHE_PEAK_DIVISOR` (stack pool).
/// * `PAGE_CACHE_RETAIN_FLOOR = 2` — small working sets whose peak/2
///   rounds to 0–1 still avoid allocator thrash when oscillating around
///   one page.
/// * `PAGE_CACHE_RETAIN_CEILING = 64` — bounds worst-case idle retention
///   to 64 pages (~a few hundred KiB at the default geometry).
const PAGE_CACHE_PEAK_DIVISOR: u32 = 2;
const PAGE_CACHE_RETAIN_FLOOR: u32 = 2;
const PAGE_CACHE_RETAIN_CEILING: u32 = 64;

/// Who is responsible for an `EnvelopePage` right now. The u2 values are
/// packed into `PageStatus` and are not ABI — internal only.
const PageOwnership = enum(u2) {
    /// A live `Handle` owns the page: only that handle allocates from it;
    /// any thread may free into it.
    handle_owned = 0,
    /// The owning handle died with envelopes still in flight
    /// (`Handle.abandon`). Nobody allocates; the free that returns the
    /// last envelope reclaims the page (module doc, reclaim proof).
    abandoned = 1,
};

/// The ONE atomic word that carries a page's reclaim-relevant state:
/// the live-envelope count and the ownership tag, observed and mutated
/// together so every reclaim decision is a single atomic read (module
/// doc, "Which transitions are atomic"). `fetchAdd(1)`/`fetchSub(1)` on
/// the packed u64 act on the count field alone: the count occupies the
/// low 32 bits and is bounded by `capacity` plus one per thread
/// concurrently inside `free`'s push→decrement window (the legal
/// transient over-count documented at `noteEnvelopeAllocated`) — still
/// astronomically below 2^32 for any real thread count, so a carry can
/// never reach the ownership bits, and underflow is a kernel bug caught
/// by assertion.
const PageStatus = packed struct(u64) {
    live_envelope_count: u32,
    ownership: PageOwnership,
    reserved: u30 = 0,
};

/// One page of envelope slots. The header is followed in the same
/// allocation by `capacity` `Envelope` slots (`envelopeSlots`). Pages are
/// created by, cached in, and destroyed by the `EnvelopePool` reservoir;
/// in between they are owned by exactly one `Handle` or abandoned.
pub const EnvelopePage = struct {
    /// The reservoir this page belongs to (used by `free`, which receives
    /// only an envelope; the pool must therefore not move once pages are
    /// issued — same pinned-by-use posture as `PidTable`).
    pool: *EnvelopePool,
    /// Packed `{live_envelope_count, ownership}` — see `PageStatus`.
    status: std.atomic.Value(u64),
    /// MPSC free list of recycled envelope slots: receivers push freed
    /// slots from any thread; only the owning handle pops. The links are
    /// the envelopes' own `next` fields (dead outside the mailbox).
    recycled_slots: std.atomic.Value(?*Envelope),
    /// Next never-yet-allocated slot index. Owner-only; no atomicity.
    bump_cursor: u32,
    /// Number of envelope slots in this page (fixed at pool init).
    capacity: u32,
    /// Owner-only intrusive link in the owning handle's page list.
    next_owned: ?*EnvelopePage,
    /// Reservoir-only intrusive link in the empty-page cache
    /// (spinlock-guarded).
    next_cached: ?*EnvelopePage,

    /// The page's envelope slot array (carved from the same allocation,
    /// immediately after the header).
    pub fn envelopeSlots(page: *EnvelopePage) []Envelope {
        const page_bytes: [*]u8 = @ptrCast(page);
        const slots_pointer: [*]Envelope = @ptrCast(@alignCast(page_bytes + page_header_byte_length));
        return slots_pointer[0..page.capacity];
    }

    /// Number of live (allocated, not yet freed) envelopes right now.
    /// Advisory under concurrency, exact at quiescence.
    pub fn liveEnvelopeCount(page: *const EnvelopePage) u32 {
        const status: PageStatus = @bitCast(page.status.load(.monotonic));
        return status.live_envelope_count;
    }
};

/// Header bytes preceding the envelope slot array, rounded up so the
/// first slot is `Envelope`-aligned.
const page_header_byte_length = std.mem.alignForward(usize, @sizeOf(EnvelopePage), @alignOf(Envelope));

/// Alignment of the whole page allocation: must satisfy both the header
/// and the slot array.
const page_allocation_alignment: std.mem.Alignment =
    .fromByteUnits(@max(@alignOf(EnvelopePage), @alignOf(Envelope)));

/// Reservoir statistics snapshot (tests + the Phase 1.6 observability
/// skeleton). Taken under the reservoir spinlock, so the counts are a
/// consistent snapshot; per-page live-envelope counts remain advisory.
pub const Statistics = struct {
    /// Pages currently in service: handle-owned + abandoned.
    live_page_count: u32,
    /// High-watermark of `live_page_count`; the cache cap derives from it.
    live_page_peak: u32,
    /// Empty pages currently cached in the reservoir.
    cached_page_count: u32,
    /// Current cache cap derived from the high-watermark.
    page_cache_capacity: u32,
    /// Pages currently abandoned (subset of `live_page_count`).
    abandoned_page_count: u32,
};

/// The shared envelope page reservoir. One per runtime (plan §3: "the
/// shared envelope page pool"); every producer's `Handle` draws pages
/// from it and every empty page returns to it. Must not move once pages
/// are issued (pages carry a back-pointer).
pub const EnvelopePool = struct {
    /// Backing allocator for page allocations. Pages are the ONLY thing
    /// this pool allocates.
    backing_allocator: std.mem.Allocator,
    /// Envelope slots per page, fixed at `init`.
    envelopes_per_page: u32,
    /// Guards every field below (module doc: cold path, O(1) critical
    /// sections, `std.atomic.Mutex` spinlock by kernel convention).
    reservoir_lock: std.atomic.Mutex,
    /// LIFO cache of empty pages (most recently returned — most likely
    /// cache-resident — on top). Guarded by `reservoir_lock`.
    cached_pages_head: ?*EnvelopePage,
    /// Length of `cached_pages_head`'s list. Guarded by `reservoir_lock`.
    cached_page_count: u32,
    /// Pages currently in service (handle-owned + abandoned). Guarded by
    /// `reservoir_lock`.
    live_page_count: u32,
    /// High-watermark of `live_page_count`. Guarded by `reservoir_lock`.
    live_page_peak: u32,
    /// Currently-abandoned pages. Guarded by `reservoir_lock` (module
    /// doc: the lock is what keeps this counter from transiently
    /// underflowing when a last-free races the abandon CAS).
    abandoned_page_count: u32,
    /// Test-only free-path instrumentation (zero-sized outside tests).
    free_instrumentation: FreeInstrumentation,

    /// Construction options.
    pub const Options = struct {
        /// Envelope slots per page. Must be non-zero.
        envelopes_per_page: u32 = default_envelopes_per_page,
    };

    /// Errors surfaced when the pool must grow.
    pub const AllocateError = error{
        /// The backing allocator could not provide a fresh page.
        OutOfMemory,
    };

    /// Create an empty reservoir. Performs no allocation; the first
    /// handle page-fault allocates the first page.
    pub fn init(backing_allocator: std.mem.Allocator, options: Options) EnvelopePool {
        std.debug.assert(options.envelopes_per_page > 0);
        return .{
            .backing_allocator = backing_allocator,
            .envelopes_per_page = options.envelopes_per_page,
            .reservoir_lock = .unlocked,
            .cached_pages_head = null,
            .cached_page_count = 0,
            .live_page_count = 0,
            .live_page_peak = 0,
            .abandoned_page_count = 0,
            .free_instrumentation = .{},
        };
    }

    /// Tear the reservoir down. Every page must already be back (no
    /// handle-owned and no abandoned pages — asserted: this is the
    /// "every page accounted" leak gate); all cached pages are destroyed.
    pub fn deinit(pool: *EnvelopePool) void {
        std.debug.assert(pool.live_page_count == 0);
        std.debug.assert(pool.abandoned_page_count == 0);
        pool.trim();
        pool.* = undefined;
    }

    /// Destroy every cached page, returning memory to the backing
    /// allocator. Live pages are unaffected. The high-watermark is
    /// deliberately NOT reset (demonstrated peak demand remains the
    /// cache bound), mirroring `StackPool.trim`.
    pub fn trim(pool: *EnvelopePool) void {
        pool.lockReservoir();
        var cached = pool.cached_pages_head;
        pool.cached_pages_head = null;
        pool.cached_page_count = 0;
        pool.unlockReservoir();
        while (cached) |page| {
            cached = page.next_cached;
            pool.destroyPage(page);
        }
    }

    /// Snapshot the reservoir counters (tests + Phase 1.6 observability).
    pub fn statistics(pool: *EnvelopePool) Statistics {
        pool.lockReservoir();
        defer pool.unlockReservoir();
        return .{
            .live_page_count = pool.live_page_count,
            .live_page_peak = pool.live_page_peak,
            .cached_page_count = pool.cached_page_count,
            .page_cache_capacity = pool.pageCacheCapacity(),
            .abandoned_page_count = pool.abandoned_page_count,
        };
    }

    /// A producer's private allocation front onto the shared reservoir —
    /// one per sending process (the "allocating process's pool handle").
    /// Single-owner by contract: exactly one thread drives a handle at a
    /// time (the same discipline as every other owner-only kernel
    /// structure). Envelopes allocated through a handle may be freed
    /// from ANY thread via `free`.
    pub const Handle = struct {
        /// The shared reservoir this handle draws pages from.
        pool: *EnvelopePool,
        /// Owner-only intrusive list of pages this handle owns; the head
        /// is the current allocation target.
        owned_pages: ?*EnvelopePage,
        /// Length of `owned_pages` (observability + tests).
        owned_page_count: u32,

        /// Create a handle over `pool`. Allocation-free.
        pub fn init(pool: *EnvelopePool) Handle {
            return .{ .pool = pool, .owned_pages = null, .owned_page_count = 0 };
        }

        /// Allocate one envelope for sending. Order: recycled slot or
        /// bump space from the head page → walk the remaining owned
        /// pages (move-to-front on a hit — walk-before-grow, see module
        /// doc) → take a page from the reservoir. The returned envelope
        /// is initialized (null link, empty fragment, origin page set);
        /// the caller populates `fragment` and pushes it to a mailbox.
        pub fn allocate(handle: *Handle) AllocateError!*Envelope {
            if (handle.owned_pages) |head_page| {
                if (tryAllocateFromPage(head_page)) |envelope| return envelope;

                var previous = head_page;
                var candidate = head_page.next_owned;
                while (candidate) |page| {
                    if (tryAllocateFromPage(page)) |envelope| {
                        // Move-to-front: this page has room; make it the
                        // allocation target so the walk stays rare.
                        previous.next_owned = page.next_owned;
                        page.next_owned = handle.owned_pages;
                        handle.owned_pages = page;
                        return envelope;
                    }
                    previous = page;
                    candidate = page.next_owned;
                }
            }

            const fresh_page = try handle.pool.acquirePage();
            fresh_page.next_owned = handle.owned_pages;
            handle.owned_pages = fresh_page;
            handle.owned_page_count += 1;
            // A freshly issued page always has bump space.
            return tryAllocateFromPage(fresh_page).?;
        }

        /// Release every owned page — the sender-death seam (plan item
        /// 1.3 "abandon/reclaim (mimalloc-style) for sender-death"; the
        /// process exit path calls this after the mailbox drain, see
        /// `process.zig`). Pages with zero live envelopes return to the
        /// reservoir immediately (they are provably quiescent — module
        /// doc, reclaim proof point 3); pages with in-flight envelopes
        /// are atomically flipped to `.abandoned` and will be reclaimed
        /// by whichever thread frees their last envelope. The handle is
        /// empty afterwards and may be reused or dropped.
        pub fn abandon(handle: *Handle) void {
            var current = handle.owned_pages;
            handle.owned_pages = null;
            handle.owned_page_count = 0;
            while (current) |page| {
                current = page.next_owned;
                page.next_owned = null;
                handle.pool.releaseOwnedPage(page);
            }
        }
    };

    // -- internal: envelope-level operations ------------------------------

    /// Allocate from one page the owner already holds: recycled slot
    /// first (cache-warm, and it is how bump-exhausted pages keep
    /// serving), then bump-carve a virgin slot. Null when the page is
    /// full. Owner-only.
    fn tryAllocateFromPage(page: *EnvelopePage) ?*Envelope {
        if (popRecycledSlot(page)) |slot| {
            noteEnvelopeAllocated(page);
            initializeEnvelope(slot, page);
            return slot;
        }
        if (page.bump_cursor < page.capacity) {
            const slot = &page.envelopeSlots()[page.bump_cursor];
            page.bump_cursor += 1;
            noteEnvelopeAllocated(page);
            initializeEnvelope(slot, page);
            return slot;
        }
        return null;
    }

    /// Owner-side pop of the page's MPSC recycled-slot list. The single-
    /// popper discipline makes the Treiber pop ABA-free (module doc).
    /// `.acquire` on the head load pairs with the freeing push's
    /// `.release` so the popped slot's link read is sound.
    fn popRecycledSlot(page: *EnvelopePage) ?*Envelope {
        var observed_head = page.recycled_slots.load(.acquire);
        while (observed_head) |slot| {
            const next_slot = slot.next.load(.monotonic);
            observed_head = page.recycled_slots.cmpxchgWeak(
                slot,
                next_slot,
                .acq_rel,
                .acquire,
            ) orelse return slot;
        }
        return null;
    }

    fn initializeEnvelope(envelope: *Envelope, page: *EnvelopePage) void {
        envelope.* = .{
            .next = .init(null),
            .origin_page = page,
            .fragment = .{},
        };
    }

    /// Owner-side count increment. `.monotonic` is sufficient: envelope
    /// publication to the receiver rides the mailbox release/acquire
    /// edge, and the owner's own abandon CAS (`.acq_rel`) orders all its
    /// increments for the reclaim path.
    ///
    /// The count is deliberately NOT asserted against `capacity` here:
    /// `free` pushes a slot onto `recycled_slots` BEFORE decrementing the
    /// count (the order the reclaim proof rests on), so the owner can
    /// legally pop and re-allocate that slot while the freeing thread is
    /// still between its push and its decrement — at that instant the
    /// count TRANSIENTLY exceeds the number of distinct live slots by
    /// one per mid-window free (each such free double-counts its slot:
    /// the re-allocation's increment lands before the free's decrement).
    /// The over-count is self-correcting (every pending decrement lands),
    /// bounded by the number of threads concurrently inside `free`'s
    /// two-step window, and never observed by the reclaim decision
    /// (`count == 0` still proves quiescence — a mid-window free keeps
    /// the count positive). Asserting `< capacity` was exactly the P1-J4
    /// ReleaseFast stress-crash bug; the deterministic regression test
    /// below pins the legal interleaving.
    fn noteEnvelopeAllocated(page: *EnvelopePage) void {
        const prior: PageStatus = @bitCast(page.status.fetchAdd(1, .monotonic));
        std.debug.assert(prior.ownership == .handle_owned);
    }

    /// Return one envelope to its origin page — callable from ANY thread
    /// (this is the receiver's side of the envelope life cycle). Slot
    /// push FIRST, count decrement SECOND: the reclaim proof (module
    /// doc) rests on that order. If this free returns the last envelope
    /// of an abandoned page, this thread reclaims the page.
    pub fn free(envelope: *Envelope) void {
        const page = envelope.origin_page orelse {
            @branchHint(.cold);
            @panic("EnvelopePool.free: envelope has no origin page (mailbox stub or corrupted envelope) — kernel bug");
        };

        // 1) Push the slot onto the page's recycled list (release
        //    publishes the link to the owner's popping acquire).
        var observed_head = page.recycled_slots.load(.monotonic);
        while (true) {
            envelope.next.store(observed_head, .monotonic);
            observed_head = page.recycled_slots.cmpxchgWeak(
                observed_head,
                envelope,
                .release,
                .monotonic,
            ) orelse break;
        }

        runBetweenSlotPushAndCountDecrementInstrumentation(page, envelope);

        // 2) Decrement the live count; the returned word is the whole
        //    reclaim decision (module doc, reclaim proof point 2).
        const prior: PageStatus = @bitCast(page.status.fetchSub(1, .acq_rel));
        std.debug.assert(prior.live_envelope_count > 0);
        if (prior.live_envelope_count == 1 and prior.ownership == .abandoned) {
            page.pool.reclaimAbandonedPage(page);
        }
    }

    inline fn runBetweenSlotPushAndCountDecrementInstrumentation(page: *EnvelopePage, envelope: *Envelope) void {
        if (comptime enable_test_instrumentation) {
            if (page.pool.free_instrumentation.between_slot_push_and_count_decrement) |instrument| {
                instrument(page.pool.free_instrumentation.instrumentation_context, envelope);
            }
        }
    }

    // -- internal: page-level operations ----------------------------------

    /// Issue a page to a handle: reuse a cached empty page or allocate a
    /// fresh one. The page leaves in the `{handle_owned, 0}` reset state.
    fn acquirePage(pool: *EnvelopePool) AllocateError!*EnvelopePage {
        pool.lockReservoir();
        if (pool.cached_pages_head) |cached_page| {
            pool.cached_pages_head = cached_page.next_cached;
            pool.cached_page_count -= 1;
            pool.notePageEnteredService();
            pool.unlockReservoir();
            resetPage(cached_page);
            return cached_page;
        }
        pool.notePageEnteredService();
        pool.unlockReservoir();

        const fresh_page = pool.allocatePageMemory() catch {
            pool.lockReservoir();
            pool.live_page_count -= 1;
            pool.unlockReservoir();
            return error.OutOfMemory;
        };
        resetPage(fresh_page);
        return fresh_page;
    }

    /// Owner-side release of one owned page (the `abandon` path). Empty
    /// pages return to the reservoir directly; pages with in-flight
    /// envelopes flip to `.abandoned` under the reservoir lock (module
    /// doc: the lock keeps `abandoned_page_count` maintenance ordered
    /// with respect to an immediately-racing last-free reclaim).
    fn releaseOwnedPage(pool: *EnvelopePool, page: *EnvelopePage) void {
        pool.lockReservoir();
        var observed = page.status.load(.acquire);
        while (true) {
            const status: PageStatus = @bitCast(observed);
            std.debug.assert(status.ownership == .handle_owned);
            if (status.live_envelope_count == 0) {
                // Quiescent (reclaim proof point 3): return directly.
                pool.returnEmptyPageLocked(page);
                pool.unlockReservoir();
                return;
            }
            observed = page.status.cmpxchgWeak(
                observed,
                @bitCast(PageStatus{
                    .live_envelope_count = status.live_envelope_count,
                    .ownership = .abandoned,
                }),
                .acq_rel,
                .acquire,
            ) orelse {
                pool.abandoned_page_count += 1;
                pool.unlockReservoir();
                return;
            };
        }
    }

    /// The unique last-freer of an abandoned page returns it (module
    /// doc, reclaim proof point 2 guarantees uniqueness; the freeing
    /// `fetchSub`'s acquire half plus the status word's release sequence
    /// guarantee every other thread's writes to the page are visible).
    fn reclaimAbandonedPage(pool: *EnvelopePool, page: *EnvelopePage) void {
        pool.lockReservoir();
        std.debug.assert(pool.abandoned_page_count > 0);
        pool.abandoned_page_count -= 1;
        pool.returnEmptyPageLocked(page);
        pool.unlockReservoir();
    }

    /// Take an empty page out of service: cache it below the
    /// high-watermark cap, destroy it otherwise. Caller holds the
    /// reservoir lock; the backing-allocator call under the lock happens
    /// only on the over-cap destroy path — the cold tail of a cold path
    /// (bulk cache destruction goes through `trim`, which unlocks first).
    fn returnEmptyPageLocked(pool: *EnvelopePool, page: *EnvelopePage) void {
        std.debug.assert(pool.live_page_count > 0);
        pool.live_page_count -= 1;
        if (pool.cached_page_count < pool.pageCacheCapacity()) {
            page.next_cached = pool.cached_pages_head;
            pool.cached_pages_head = page;
            pool.cached_page_count += 1;
        } else {
            pool.destroyPage(page);
        }
        std.debug.assert(pool.live_page_count + pool.cached_page_count <=
            @max(pool.live_page_peak, PAGE_CACHE_RETAIN_FLOOR));
    }

    /// Maximum number of empty pages the reservoir may cache, derived
    /// from the live-page high-watermark (see the constant block).
    fn pageCacheCapacity(pool: *const EnvelopePool) u32 {
        const peak_fraction = pool.live_page_peak / PAGE_CACHE_PEAK_DIVISOR;
        return @min(@max(peak_fraction, PAGE_CACHE_RETAIN_FLOOR), PAGE_CACHE_RETAIN_CEILING);
    }

    /// Record a page entering service: bump the live count and advance
    /// the high-watermark. Caller holds the reservoir lock. Mirrors
    /// `noteStackEnteredService` / `noteSlabEnteredService`.
    fn notePageEnteredService(pool: *EnvelopePool) void {
        pool.live_page_count += 1;
        if (pool.live_page_count > pool.live_page_peak) {
            pool.live_page_peak = pool.live_page_count;
        }
    }

    /// Reset a page to the fresh `{handle_owned, 0}` state before it is
    /// issued to a handle. The page is exclusively held here (freshly
    /// allocated, or cached — cached pages were quiescent when returned).
    fn resetPage(page: *EnvelopePage) void {
        page.status.store(@bitCast(PageStatus{
            .live_envelope_count = 0,
            .ownership = .handle_owned,
        }), .monotonic);
        page.recycled_slots.store(null, .monotonic);
        page.bump_cursor = 0;
        page.next_owned = null;
        page.next_cached = null;
    }

    /// Allocate the raw header+slots memory for one page and wire the
    /// header's immutable fields.
    fn allocatePageMemory(pool: *EnvelopePool) AllocateError!*EnvelopePage {
        const byte_length = pool.pageAllocationByteLength();
        const raw = pool.backing_allocator.rawAlloc(
            byte_length,
            page_allocation_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        const page: *EnvelopePage = @ptrCast(@alignCast(raw));
        page.pool = pool;
        page.status = .init(@bitCast(PageStatus{
            .live_envelope_count = 0,
            .ownership = .handle_owned,
        }));
        page.recycled_slots = .init(null);
        page.bump_cursor = 0;
        page.capacity = pool.envelopes_per_page;
        page.next_owned = null;
        page.next_cached = null;
        return page;
    }

    /// Return one page's memory to the backing allocator.
    fn destroyPage(pool: *EnvelopePool, page: *EnvelopePage) void {
        const raw: [*]u8 = @ptrCast(page);
        pool.backing_allocator.rawFree(
            raw[0..pool.pageAllocationByteLength()],
            page_allocation_alignment,
            @returnAddress(),
        );
    }

    fn pageAllocationByteLength(pool: *const EnvelopePool) usize {
        return page_header_byte_length + @as(usize, pool.envelopes_per_page) * @sizeOf(Envelope);
    }

    /// Reservoir spinlock (module doc: `std.atomic.Mutex` + spin, kernel
    /// convention; every critical section is O(1)).
    fn lockReservoir(pool: *EnvelopePool) void {
        while (!pool.reservoir_lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockReservoir(pool: *EnvelopePool) void {
        pool.reservoir_lock.unlock();
    }
};

/// Free one envelope back to its origin page — module-level re-export of
/// the canonical entry point so receivers need only the envelope (the
/// pool is reachable through the page back-pointer).
pub const free = EnvelopePool.free;

comptime {
    std.debug.assert(@bitSizeOf(PageStatus) == 64);
    // The slot array begins Envelope-aligned right after the header.
    std.debug.assert(page_header_byte_length % @alignOf(Envelope) == 0);
    std.debug.assert(page_allocation_alignment.toByteUnits() >= @alignOf(EnvelopePage));
    std.debug.assert(page_allocation_alignment.toByteUnits() >= @alignOf(Envelope));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "EnvelopePool: envelopes are carved from one page and freed slots are recycled LIFO" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    const first = try handle.allocate();
    const second = try handle.allocate();
    const third = try handle.allocate();

    // All three came from the same page, carved back to back.
    try testing.expectEqual(first.origin_page.?, second.origin_page.?);
    try testing.expectEqual(second.origin_page.?, third.origin_page.?);
    const page = first.origin_page.?;
    try testing.expectEqual(@as(u32, 3), page.liveEnvelopeCount());
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 1), handle.owned_page_count);

    // Freeing returns the slot to ITS page; the next allocation reuses
    // exactly that slot (LIFO recycled list) instead of bump-carving.
    EnvelopePool.free(second);
    try testing.expectEqual(@as(u32, 2), page.liveEnvelopeCount());
    const recycled = try handle.allocate();
    try testing.expectEqual(second, recycled);
    try testing.expectEqual(@as(u32, 3), page.liveEnvelopeCount());
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_page_count);

    // The fresh envelope is fully initialized for a new send.
    try testing.expectEqual(@as(?*Envelope, null), recycled.next.load(.monotonic));
    try testing.expectEqual(@as(?[*]const u8, null), recycled.fragment.payload_pointer);
    try testing.expectEqual(page, recycled.origin_page.?);

    EnvelopePool.free(first);
    EnvelopePool.free(recycled);
    EnvelopePool.free(third);
    try testing.expectEqual(@as(u32, 0), page.liveEnvelopeCount());

    // Everything freed → abandon returns the (empty) page to the cache.
    handle.abandon();
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_page_count);
    try testing.expectEqual(@as(u32, 0), stats.abandoned_page_count);
    try testing.expectEqual(@as(u32, 1), stats.cached_page_count);
}

test "EnvelopePool: bump exhaustion grows to a second page; abandon returns both when empty" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    var envelopes: [6]*Envelope = undefined;
    for (&envelopes) |*slot| slot.* = try handle.allocate();

    // 4 + 2 across two pages.
    const first_page = envelopes[0].origin_page.?;
    const second_page = envelopes[4].origin_page.?;
    try testing.expect(first_page != second_page);
    for (envelopes[0..4]) |envelope| try testing.expectEqual(first_page, envelope.origin_page.?);
    for (envelopes[4..6]) |envelope| try testing.expectEqual(second_page, envelope.origin_page.?);
    try testing.expectEqual(@as(u32, 2), pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 2), handle.owned_page_count);

    for (envelopes) |envelope| EnvelopePool.free(envelope);
    handle.abandon();

    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_page_count);
    try testing.expectEqual(@as(u32, 2), stats.cached_page_count);
    try testing.expectEqual(@as(u32, 2), stats.live_page_peak);
}

test "EnvelopePool: walk-before-grow — a handle reuses owned pages before taking reservoir pages" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    // Drive the handle to two pages, then free everything.
    var burst: [5]*Envelope = undefined;
    for (&burst) |*slot| slot.* = try handle.allocate();
    for (burst) |envelope| EnvelopePool.free(envelope);
    try testing.expectEqual(@as(u32, 2), handle.owned_page_count);

    // New traffic reuses the owned pages — the pool issues nothing new
    // (owned-page count and live-page count both hold).
    var reused: [5]*Envelope = undefined;
    for (&reused) |*slot| slot.* = try handle.allocate();
    try testing.expectEqual(@as(u32, 2), handle.owned_page_count);
    try testing.expectEqual(@as(u32, 2), pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 2), pool.statistics().live_page_peak);

    for (reused) |envelope| EnvelopePool.free(envelope);
    handle.abandon();
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_page_count);
}

test "EnvelopePool: page cache is bounded by the live-page high-watermark and trim destroys" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    // Drive the live peak to 6 pages (24 envelopes at 4 per page).
    var envelopes: [24]*Envelope = undefined;
    for (&envelopes) |*slot| slot.* = try handle.allocate();
    try testing.expectEqual(@as(u32, 6), pool.statistics().live_page_peak);
    try testing.expectEqual(@as(u32, 6), pool.statistics().live_page_count);

    // Free everything and abandon: cap = clamp(6/2, 2, 64) = 3, so three
    // pages are cached and three are destroyed.
    for (envelopes) |envelope| EnvelopePool.free(envelope);
    handle.abandon();
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.live_page_count);
        try testing.expectEqual(@as(u32, 3), stats.page_cache_capacity);
        try testing.expectEqual(@as(u32, 3), stats.cached_page_count);
        try testing.expectEqual(@as(u32, 6), stats.live_page_peak);
    }

    // Reuse pulls from the cache before allocating fresh pages.
    var second_handle = EnvelopePool.Handle.init(&pool);
    const reused = try second_handle.allocate();
    try testing.expectEqual(@as(u32, 2), pool.statistics().cached_page_count);
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_page_count);
    // The watermark survives (peak demand remains the bound).
    try testing.expectEqual(@as(u32, 6), pool.statistics().live_page_peak);
    EnvelopePool.free(reused);
    second_handle.abandon();

    // trim destroys every cached page.
    pool.trim();
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.cached_page_count);
        try testing.expectEqual(@as(u32, 0), stats.live_page_count);
        try testing.expectEqual(@as(u32, 6), stats.live_page_peak);
    }
}

test "EnvelopePool: abandon with in-flight envelopes marks pages abandoned; the last free reclaims" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    // Six in-flight envelopes across two pages; the sender dies now.
    var envelopes: [6]*Envelope = undefined;
    for (&envelopes) |*slot| slot.* = try handle.allocate();
    const first_page = envelopes[0].origin_page.?;
    const second_page = envelopes[4].origin_page.?;
    handle.abandon();

    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 2), stats.live_page_count);
        try testing.expectEqual(@as(u32, 2), stats.abandoned_page_count);
        try testing.expectEqual(@as(u32, 0), stats.cached_page_count);
    }

    // Freeing all but the last envelope of the first page reclaims
    // nothing.
    EnvelopePool.free(envelopes[0]);
    EnvelopePool.free(envelopes[1]);
    EnvelopePool.free(envelopes[2]);
    try testing.expectEqual(@as(u32, 1), first_page.liveEnvelopeCount());
    try testing.expectEqual(@as(u32, 2), pool.statistics().abandoned_page_count);

    // The LAST free of the first page reclaims it into the cache.
    EnvelopePool.free(envelopes[3]);
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 1), stats.live_page_count);
        try testing.expectEqual(@as(u32, 1), stats.abandoned_page_count);
        try testing.expectEqual(@as(u32, 1), stats.cached_page_count);
    }

    // Same for the second page.
    EnvelopePool.free(envelopes[4]);
    EnvelopePool.free(envelopes[5]);
    _ = second_page;
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.live_page_count);
        try testing.expectEqual(@as(u32, 0), stats.abandoned_page_count);
        try testing.expectEqual(@as(u32, 2), stats.cached_page_count);
    }
}

test "EnvelopePool: freeing into an owned page never reclaims it out from under its handle" {
    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    const only = try handle.allocate();
    const page = only.origin_page.?;

    // The free takes the page's count to zero while the handle still
    // owns it — the page must stay with the handle (only abandon or the
    // owner returns pages).
    EnvelopePool.free(only);
    try testing.expectEqual(@as(u32, 0), page.liveEnvelopeCount());
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 0), pool.statistics().cached_page_count);
    try testing.expectEqual(@as(u32, 1), handle.owned_page_count);

    // And the handle keeps allocating from it.
    const again = try handle.allocate();
    try testing.expectEqual(page, again.origin_page.?);
    EnvelopePool.free(again);
    handle.abandon();
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_page_count);
}

// -- deterministic transient over-count regression -----------------------------

/// Drives one `free` on a separate thread and parks it INSIDE the
/// push→decrement window via the test-only free instrumentation, so the
/// owner can re-allocate the pushed slot while the page's live count
/// still includes the not-yet-decremented free.
const ParkedFreer = struct {
    envelope_to_free: *Envelope,
    reached_window: std.atomic.Value(bool) = .init(false),
    release_from_window: std.atomic.Value(bool) = .init(false),

    fn instrumentation(instrumentation_context: ?*anyopaque, envelope: *Envelope) void {
        const freer: *ParkedFreer = @ptrCast(@alignCast(instrumentation_context.?));
        if (envelope != freer.envelope_to_free) return;
        freer.reached_window.store(true, .release);
        const deadline = mailbox_module.TestDeadline.init(30 * std.time.ns_per_s);
        while (!freer.release_from_window.load(.acquire)) {
            if (deadline.expired()) @panic("ParkedFreer: never released from the window");
            std.atomic.spinLoopHint();
        }
    }

    fn run(freer: *ParkedFreer) void {
        EnvelopePool.free(freer.envelope_to_free);
    }
};

test "EnvelopePool: owner re-allocation during a free's push→decrement window is legal (transient over-count)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 4 });
    defer pool.deinit();
    var handle = EnvelopePool.Handle.init(&pool);

    // Fill the page completely: live count == capacity, bump exhausted.
    var envelopes: [4]*Envelope = undefined;
    for (&envelopes) |*slot| slot.* = try handle.allocate();
    const page = envelopes[0].origin_page.?;
    try testing.expectEqual(@as(u32, 4), page.liveEnvelopeCount());

    // A "receiver" frees one envelope but is parked between its
    // recycled-slot push and its count decrement.
    var freer = ParkedFreer{ .envelope_to_free = envelopes[2] };
    pool.free_instrumentation = .{
        .between_slot_push_and_count_decrement = ParkedFreer.instrumentation,
        .instrumentation_context = &freer,
    };
    const freer_thread = try std.Thread.spawn(.{}, ParkedFreer.run, .{&freer});
    {
        const deadline = mailbox_module.TestDeadline.init(30 * std.time.ns_per_s);
        while (!freer.reached_window.load(.acquire)) {
            if (deadline.expired()) return error.TestTimeout;
            std.atomic.spinLoopHint();
        }
    }

    // The slot is already on the recycled list but the count still says
    // 4 (== capacity): the owner's re-allocation MUST succeed — the
    // transient over-count to 5 is the documented legal state, not
    // corruption.
    const reallocated = try handle.allocate();
    try testing.expectEqual(envelopes[2], reallocated);
    try testing.expectEqual(@as(u32, 5), page.liveEnvelopeCount());

    // Release the parked free; its decrement lands and the count returns
    // to the true live number.
    freer.release_from_window.store(true, .release);
    freer_thread.join();
    try testing.expectEqual(@as(u32, 4), page.liveEnvelopeCount());

    // Exact accounting from here on: everything frees, the page empties,
    // abandon returns it.
    pool.free_instrumentation = .{};
    EnvelopePool.free(envelopes[0]);
    EnvelopePool.free(envelopes[1]);
    EnvelopePool.free(reallocated);
    EnvelopePool.free(envelopes[3]);
    try testing.expectEqual(@as(u32, 0), page.liveEnvelopeCount());
    handle.abandon();
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_page_count);
    try testing.expectEqual(@as(u32, 0), stats.abandoned_page_count);
}

// -- multi-threaded integration stress ---------------------------------------

/// One producer of the integration stress: allocates envelopes from its
/// own handle, stamps (identity, sequence) into the opaque fragment,
/// pushes into the shared mailbox, and finally ABANDONS its handle with
/// whatever is still in flight — the sender-dies case, every iteration.
const StressProducer = struct {
    pool: *EnvelopePool,
    target_mailbox: *mailbox_module.Mailbox,
    payload_identity: [*]const u8,
    message_count: usize,
    wake_signal_count: usize = 0,
    failed: bool = false,

    fn run(producer: *StressProducer) void {
        var handle = EnvelopePool.Handle.init(producer.pool);
        var sequence: usize = 0;
        while (sequence < producer.message_count) : (sequence += 1) {
            const envelope = handle.allocate() catch {
                producer.failed = true;
                break;
            };
            envelope.fragment = .{
                .payload_pointer = producer.payload_identity,
                .payload_byte_length = sequence,
            };
            if (producer.target_mailbox.push(envelope)) producer.wake_signal_count += 1;
        }
        // Sender dies with in-flight envelopes: abandon, never leak.
        handle.abandon();
    }
};

test "EnvelopePool+Mailbox: multi-threaded stress — per-producer FIFO, no loss, abandon/reclaim, exact accounting" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const producer_count = 4;
    const messages_per_producer = 100_000;
    const total_messages = producer_count * messages_per_producer;

    var pool = EnvelopePool.init(testing.allocator, .{});
    defer pool.deinit();

    var shared_mailbox: mailbox_module.Mailbox = undefined;
    shared_mailbox.init();
    var wake_callback_count = std.atomic.Value(usize).init(0);
    shared_mailbox.wake_callback = countingWakeCallback;
    shared_mailbox.wake_context = &wake_callback_count;

    // Producer identity bank: fragment payload pointers point at these
    // bytes; pointer identity recovers the producer index.
    var payload_bank: [producer_count]u8 = @splat(0);

    var producers: [producer_count]StressProducer = undefined;
    for (&producers, 0..) |*producer, producer_index| {
        producer.* = .{
            .pool = &pool,
            .target_mailbox = &shared_mailbox,
            .payload_identity = @ptrCast(&payload_bank[producer_index]),
            .message_count = messages_per_producer,
        };
    }

    var producer_threads: [producer_count]std.Thread = undefined;
    for (&producer_threads, &producers) |*thread, *producer| {
        thread.* = try std.Thread.spawn(.{}, StressProducer.run, .{producer});
    }

    // The consumer: this thread. Pairwise FIFO — every producer's
    // sequence numbers arrive strictly in order; global order is NOT
    // asserted (none is promised).
    var expected_sequence: [producer_count]usize = @splat(0);
    var received_total: usize = 0;
    const deadline = mailbox_module.TestDeadline.init(120 * std.time.ns_per_s);
    while (received_total < total_messages) {
        switch (shared_mailbox.pop()) {
            .envelope => |envelope| {
                const identity_address = @intFromPtr(envelope.fragment.payload_pointer.?);
                const producer_index = identity_address - @intFromPtr(&payload_bank[0]);
                if (envelope.fragment.payload_byte_length != expected_sequence[producer_index]) {
                    std.debug.print("producer {d}: expected sequence {d}, got {d}\n", .{
                        producer_index,
                        expected_sequence[producer_index],
                        envelope.fragment.payload_byte_length,
                    });
                    return error.TestUnexpectedResult;
                }
                expected_sequence[producer_index] += 1;
                received_total += 1;
                EnvelopePool.free(envelope);
            },
            .empty, .transient_gap => {
                if (deadline.expired()) return error.TestTimeout;
                std.atomic.spinLoopHint();
            },
        }
    }

    for (&producer_threads) |*thread| thread.join();
    for (&producers) |*producer| try testing.expect(!producer.failed);

    // No loss, per-producer completeness.
    for (expected_sequence) |sequence| {
        try testing.expectEqual(@as(usize, messages_per_producer), sequence);
    }

    // Quiescent mailbox: drained, depth zero.
    try testing.expectEqual(mailbox_module.PopOutcome.empty, shared_mailbox.pop());
    try testing.expectEqual(@as(usize, 0), shared_mailbox.depth());

    // Wake-signal exactness at quiescence (started empty, ended empty,
    // ≥1 push): the number of true push returns == the number of wake
    // callbacks == the number of times the consumer closed the queue to
    // empty (see mailbox.zig doc, "Wake signal exactness").
    var wake_signal_total: usize = 0;
    for (&producers) |*producer| wake_signal_total += producer.wake_signal_count;
    try testing.expectEqual(wake_signal_total, wake_callback_count.load(.monotonic));
    try testing.expectEqual(wake_signal_total, shared_mailbox.drain_closure_count);

    // Exact page accounting: every producer abandoned mid-flight, the
    // consumer freed every envelope, so every page was reclaimed or
    // returned — none live, none abandoned, cache within its cap.
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_page_count);
    try testing.expectEqual(@as(u32, 0), stats.abandoned_page_count);
    try testing.expect(stats.cached_page_count <= stats.page_cache_capacity);
    // (pool.deinit + std.testing.allocator assert the byte-exact rest.)
}

fn countingWakeCallback(wake_context: ?*anyopaque) void {
    const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(wake_context.?));
    _ = counter.fetchAdd(1, .monotonic);
}
