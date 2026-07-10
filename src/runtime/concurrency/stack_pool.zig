//! Pooled fixed-reservation fiber stacks for the Zap concurrency kernel.
//!
//! Phase 1 item 1.1 of `docs/concurrency-implementation-plan.md` (job P1-J1),
//! implementing the binding design consequence A.2.1: **pooling is
//! mandatory**. E9 (`docs/concurrency-bench-results.md`) measured a fresh
//! stack (mmap + guard mprotect + first-page fault + munmap) at 1,646 ns
//! against an 8.99 ns spawn on a pooled stack — a 183× penalty that alone
//! consumes the entire sub-µs spawn budget. The spawn hot path therefore
//! never calls mmap: stacks come from this pool's free list, and fresh
//! mapping happens only on pool growth.
//!
//! ## Reservation shape
//!
//! Every stack is one anonymous private mapping laid out as:
//!
//! ```
//!   low addresses                                        high addresses
//!   +------------------+--------------------------------------------+
//!   | guard page       | usable stack bytes (grow downward from top)|
//!   | PROT_NONE        | READ|WRITE, committed lazily on first touch|
//!   +------------------+--------------------------------------------+
//! ```
//!
//! The guard page sits at the LOW end because stacks grow downward: an
//! overflow runs off the low end of the usable range and faults on the
//! guard page instead of silently corrupting an adjacent mapping.
//!
//! ## Lazy commit: fault-commit, not mprotect-on-acquire
//!
//! The usable range is mapped `READ|WRITE` up front and relies on the OS
//! committing anonymous pages on first touch (fault-commit). The rejected
//! alternative — reserving `PROT_NONE` and `mprotect`ing the usable range
//! on acquisition — would put a syscall on the pool-hit path and destroy
//! the E9 9 ns pooled-spawn floor this pool exists to preserve. E9's
//! measurement harness (`spike/concurrency-e9/fiber_switch.zig`) used this
//! exact fault-commit shape, so the recorded floor numbers price it.
//!
//! ## Free-list bounding: live-stack high-watermark
//!
//! The free list mirrors the ARC manager's empty-slab cache policy
//! (`src/memory/arc/manager.zig`, `SizeClass`/`emptyCacheCap`): the cache
//! cap derives from `live_stack_peak`, the most stacks that were ever
//! simultaneously acquired, so cached stacks can only exist strictly below
//! a live level the process already reached while the stacks held real
//! fiber frames — peak reservation is set by live demand, never by
//! caching. The structural invariant `live_stack_count + cached_stack_count
//! <= live_stack_peak` holds at all times because `acquire` reuses a cached
//! stack before it ever maps a fresh one (a fresh mmap only happens while
//! the cache is empty) and a release either moves a stack from live to
//! cached (total unchanged) or unmaps it (total shrinks).
//!
//! The A.4 item 3 stack-RSS-decay question — whether and where committed
//! stack pages `madvise` back to the OS — is DECIDED as of P6-J4 (plan
//! item 6.4), split by call shape:
//!
//!   * **Hibernate (`Process.hibernate`) DOES decommit.** An explicitly
//!     idle process's committed pages below its parked frame are released
//!     via `decommitBelowStackPointer` (Darwin `MADV_FREE_REUSABLE`,
//!     Linux `MADV_DONTNEED` — see `decommitRange` for the exact
//!     semantics) and recommit by fault on wake. The process itself
//!     signals long idleness, so the refault cost is off any hot path.
//!   * **Release-to-cache does NOT decommit.** A cached stack's resident
//!     pages still do not decay — the free list retains whatever pages
//!     the deepest tenant faulted in until `trim`. Rationale: the pool's
//!     design invariant is ZERO syscalls on the acquire/release fast
//!     path (the E9 9 ns pooled-spawn floor above), and spawn/die-storm
//!     workloads — exactly the shape that populates the cache — reuse
//!     the pages immediately, so an unconditional release-madvise would
//!     buy nothing there and cost a syscall plus refaults per cycle.
//!     Idle-cache decay therefore rides hibernate (per-process, demand-
//!     signaled) rather than the pool (global, workload-blind); if a
//!     future workload shows long-idle caches dominating RSS, the
//!     decommit primitive below is the ready-made mechanism to apply at
//!     `release` behind a policy knob, measured with the 1.7 teardown
//!     harness.
//!
//! ## The fiber-stack-lifetime invariant (release-side enforcement)
//!
//! From the G2 triage (`spike/concurrency-e1/triage/README.md`) of the
//! Dispatch backend's fiber-lifetime race: **a finished fiber's stack may
//! not be freed or recycled until the finishing fiber has provably left
//! it.** `release` enforces the local half of that invariant structurally:
//! it panics if the caller's own frame lives inside the stack being
//! released, so the API cannot be used to release the stack one is
//! currently executing on. The scheduling half (release only ever happens
//! on the scheduler's stack, after the finishing fiber's final context
//! switch has returned control) is enforced by `fiber_context.zig`, whose
//! `resumeFiber` post-switch path is the only kernel release site.
//!
//! ## Concurrency
//!
//! A `StackPool` is per-scheduler state (plan A.2.1/A.3): it is owned and
//! accessed by exactly one scheduler thread and performs no atomic
//! operations. Cross-scheduler stack traffic is a Phase 4 policy question.
//!
//! ## Toolchain
//!
//! Pure data-structure/syscall code — no fiber context switches — so this
//! file itself has no special compiler requirement; see `concurrency.zig`
//! for the kernel-wide fork-compiler requirement.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Whether `release` fills the usable range with `poison_byte` before the
/// stack enters the cache (or is unmapped). Debug-only: the memset commits
/// every page of the released stack, which is exactly the diagnostic
/// trade-off wanted in Debug (use-after-release of a cached stack reads
/// poison and fails loudly) and exactly wrong for optimized builds.
pub const poison_on_release = builtin.mode == .Debug;

/// Fill byte for released stacks in Debug builds. Distinct from common
/// sentinel values (0x00, 0xFF) and from `undefined`'s 0xAA-adjacent
/// patterns is not required — 0xAA is used deliberately so a poisoned
/// pointer/length read from a stale stack is glaringly non-canonical.
pub const poison_byte: u8 = 0xAA;

/// Number of leading and trailing usable bytes sampled by the debug
/// poison-integrity check on cache-hit acquisition.
const poison_sample_length: usize = 64;

/// Default usable stack size (excluding the guard page): 256 KiB, matching
/// the E9 measurement geometry (`spike/concurrency-e9/fiber_switch.zig`
/// `fiber_stack_size`) so the recorded floor numbers stay comparable.
pub const default_usable_size: usize = 256 * 1024;

/// Cache cap = clamp(live_stack_peak / CACHE_PEAK_DIVISOR,
///                   CACHE_RETAIN_FLOOR, CACHE_RETAIN_CEILING).
///
/// * `CACHE_PEAK_DIVISOR = 2` — retain at most half the demonstrated peak,
///   mirroring `EMPTY_CACHE_PEAK_DIVISOR` in `src/memory/arc/manager.zig`.
/// * `CACHE_RETAIN_FLOOR = 2` — small working sets whose peak/2 rounds to
///   0–1 still avoid mmap/munmap thrash when oscillating around one stack.
/// * `CACHE_RETAIN_CEILING = 256` — bounds worst-case idle retention to
///   256 × (usable + guard) reservations (~68 MiB of address space at the
///   256 KiB default; resident bytes stay bounded by pages actually
///   touched). Deliberately more conservative than the ARC slab ceiling
///   (1024 × 64 KiB) because stacks are 4× larger than slabs; revisited by
///   Phase 1.7 per plan Appendix A.4 item 3.
const CACHE_PEAK_DIVISOR: u32 = 2;
const CACHE_RETAIN_FLOOR: u32 = 2;
const CACHE_RETAIN_CEILING: u32 = 256;

/// Errors surfaced by `StackPool.acquire` when the pool must grow.
pub const AcquireError = error{
    /// The anonymous reservation mmap failed (address space or commit
    /// charge exhaustion).
    StackReservationFailed,
    /// The reservation succeeded but the guard page could not be
    /// protected; the mapping is unmapped before this is returned, so no
    /// unguarded stack ever escapes the pool.
    GuardProtectionFailed,
};

/// One pooled stack: a single mapping with a PROT_NONE guard region at the
/// low end and the usable stack bytes above it. Plain value type — the
/// pool retains no reference to acquired stacks; ownership travels with
/// the value until `release` hands it back.
pub const Stack = struct {
    /// The whole reservation, including the guard region at the low end.
    mapping: []align(std.heap.page_size_min) u8,
    /// Byte length of the PROT_NONE guard region at the low end of
    /// `mapping` (one OS page).
    guard_length: usize,

    /// The writable stack bytes (everything above the guard region).
    pub fn usable(stack: Stack) []u8 {
        return stack.mapping[stack.guard_length..];
    }

    /// The PROT_NONE guard region at the low end of the reservation.
    /// Touching these bytes faults by design.
    pub fn guard(stack: Stack) []u8 {
        return stack.mapping[0..stack.guard_length];
    }

    /// One past the highest usable address — the initial stack top a fiber
    /// grows downward from.
    pub fn top(stack: Stack) usize {
        return @intFromPtr(stack.mapping.ptr) + stack.mapping.len;
    }
};

/// Release the committed pages of `stack` STRICTLY BELOW `stack_pointer`
/// back to the OS — the `Process.hibernate` stack shrink (plan item 6.4,
/// P6-J4; the A.4 item 3 decision recorded in the module doc). The released
/// range is dead stack (a downward-growing stack never holds live data below
/// its SP), and the pages recommit by fault on the next deep call — the
/// pool's lazy-commit design working in reverse.
///
/// The caller must guarantee NO execution can be on `stack` for the duration
/// of the call (the kernel's one call site runs on the scheduler's stack
/// against a `.suspended` fiber it still exclusively owns —
/// `scheduler.zig`'s `.hibernating` dispatch, strictly before the park is
/// published to potential revivers).
///
/// One whole page below the page containing `stack_pointer` is preserved in
/// addition to the SP page itself: the tier-1 ABIs' 128-byte red zone lives
/// below SP (AAPCS64 / SysV x86-64), and the cushion also covers any spill
/// slots the saved frame's resume path touches before pushing a new frame.
/// Returns the byte length released (0 when the range is empty, when
/// `stack_pointer` lies outside the usable range — a contract violation
/// answered conservatively — or when the platform has no decommit
/// primitive).
pub fn decommitBelowStackPointer(stack: Stack, stack_pointer: usize) usize {
    const usable_bytes = stack.usable();
    const usable_start = @intFromPtr(usable_bytes.ptr);
    const usable_end = usable_start + usable_bytes.len;
    if (stack_pointer < usable_start or stack_pointer > usable_end) return 0;
    const page = std.heap.pageSize();
    const sp_page_floor = std.mem.alignBackward(usize, stack_pointer, page);
    if (sp_page_floor < usable_start + page) return 0;
    const keep_boundary = sp_page_floor - page;
    if (keep_boundary <= usable_start) return 0;
    const length = keep_boundary - usable_start;
    decommitRange(usable_start, length);
    return length;
}

/// Per-OS decommit of a page-aligned anonymous-mapping range (both `address`
/// and `length` are page multiples by construction in
/// `decommitBelowStackPointer`: the usable range starts one page above the
/// page-aligned mapping base and the keep boundary is page-floored).
///
/// * **Darwin — `MADV_FREE_REUSABLE`, falling back to `MADV_FREE`.** Plain
///   `MADV_FREE` on xnu only marks pages clean-and-reclaimable: physical
///   pages leave the task lazily under memory pressure, so RSS and
///   `phys_footprint` do not visibly drop — useless for an observable
///   hibernate. `MADV_FREE_REUSABLE` (Darwin-specific; the primitive
///   WebKit's bmalloc and jemalloc's Darwin `pages_purge` use for exactly
///   this decommit-without-unmap purpose) additionally marks the range
///   "reusable", removing the pages from the task's `phys_footprint` ledger
///   IMMEDIATELY and making them reclaimable at any time. Data correctness
///   on re-touch does not require the paired `MADV_FREE_REUSE`: a write
///   fault re-dirties the page and xnu's fault path takes it back out of
///   the reusable set (the `FREE_REUSE` pairing exists for exact footprint
///   RE-accounting, which a fault-recommitted dead-stack page can
///   harmlessly under-report — jemalloc ships the same asymmetry). The
///   fallback covers kernels/ranges where `FREE_REUSABLE` returns an error
///   (it is stricter about range shape than `MADV_FREE`).
/// * **Linux — `MADV_DONTNEED`** (direct syscall, no libc dependency):
///   immediate decommit semantics for private anonymous mappings — RSS
///   drops at once and the next touch faults in a fresh zero page.
///   Deliberately not Linux `MADV_FREE`, whose RSS effect is deferred to
///   memory pressure and thus unobservable/undeterministic for tests.
/// * **Other targets — no-op** (returning the stack to the OS wholesale at
///   `munmap` remains the only decay). Windows would use
///   `VirtualFree(MEM_DECOMMIT)` over a `MEM_RESERVE`d region and wasm has
///   no virtual-memory decommit; both are follow-ons recorded at plan item
///   6.4's deferral list.
fn decommitRange(address: usize, length: usize) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const range_pointer: *align(std.heap.page_size_min) anyopaque = @ptrFromInt(address);
            if (std.c.madvise(range_pointer, length, std.c.MADV.FREE_REUSABLE) != 0) {
                _ = std.c.madvise(range_pointer, length, std.c.MADV.FREE);
            }
        },
        .linux => {
            _ = std.os.linux.madvise(@ptrFromInt(address), length, std.os.linux.MADV.DONTNEED);
        },
        else => {},
    }
}

/// Intrusive free-list node stored in the first bytes of a cached stack's
/// usable range (the lowest, coldest usable page — the bytes a fiber only
/// reaches at maximum stack depth). Using the stack's own memory keeps the
/// pool allocation-free; the node clobbers the first `@sizeOf(FreeNode)`
/// bytes of the Debug poison fill, which the poison-integrity sample
/// accounts for.
const FreeNode = struct {
    next: ?*FreeNode,
};

/// Pool statistics snapshot for tests and the Phase 1.6 observability
/// skeleton.
pub const Statistics = struct {
    /// Stacks currently acquired and not yet released.
    live_stack_count: u32,
    /// High-watermark of `live_stack_count`.
    live_stack_peak: u32,
    /// Stacks currently cached on the free list.
    cached_stack_count: u32,
    /// Current cache cap derived from the high-watermark.
    cache_capacity: u32,
};

/// Per-scheduler pool of fixed-reservation, guard-paged, lazy-commit fiber
/// stacks with a high-watermark-bounded free list. See the module doc for
/// the full policy rationale.
pub const StackPool = struct {
    /// Construction options.
    pub const Options = struct {
        /// Requested usable stack bytes (excluding the guard page);
        /// rounded up to a whole number of OS pages. Must be non-zero.
        usable_size: usize = default_usable_size,
        /// Guard `acquire`/`release`/`trim` with a spinlock (P4-J1). Required
        /// when a stack may be RELEASED on a different scheduler thread than the
        /// one that acquired it: under M:N work stealing a process is spawned on
        /// its origin core (acquire) but, if stolen, exits on another core,
        /// whose `resumeFiber` releases the stack back to this origin pool
        /// (`KernelFiber.origin_stack_pool`) — a cross-thread free list mutation.
        /// The lock makes both ends serialize on the ORIGIN pool, keeping its
        /// counters exact. Default false — a standalone (single-scheduler,
        /// deterministic) pool is owner-only and pays nothing, preserving the E9
        /// pooled-spawn floor byte-for-byte.
        thread_safe: bool = false,
    };

    /// Usable bytes per stack (page-multiple, fixed for the pool's
    /// lifetime — every cached stack is geometry-compatible with every
    /// acquisition).
    usable_length: usize,
    /// Guard bytes per stack (one OS page).
    guard_length: usize,
    /// LIFO free list of cached stacks (LIFO keeps the most recently
    /// touched — most likely still resident — stack on top).
    free_list_head: ?*FreeNode,
    /// Length of `free_list_head`'s list.
    cached_stack_count: u32,
    /// Stacks currently acquired and not yet released.
    live_stack_count: u32,
    /// High-watermark of `live_stack_count`; the cache cap derives from it.
    live_stack_peak: u32,
    /// Whether `acquire`/`release`/`trim` take `lock` (see `Options.thread_safe`).
    thread_safe: bool,
    /// Spinlock guarding the free list and counters when `thread_safe`
    /// (`std.atomic.Mutex`, kernel convention). Untouched otherwise.
    lock: std.atomic.Mutex,

    /// Create an empty pool. Performs no syscalls; the first `acquire`
    /// maps the first stack.
    pub fn init(options: Options) StackPool {
        std.debug.assert(options.usable_size > 0);
        const page_length = std.heap.pageSize();
        return .{
            .usable_length = std.mem.alignForward(usize, options.usable_size, page_length),
            .guard_length = page_length,
            .free_list_head = null,
            .cached_stack_count = 0,
            .live_stack_count = 0,
            .live_stack_peak = 0,
            .thread_safe = options.thread_safe,
            .lock = .unlocked,
        };
    }

    /// Acquire `lock` when `thread_safe` (a no-op for an owner-only pool).
    inline fn lockPool(pool: *StackPool) void {
        if (pool.thread_safe) {
            while (!pool.lock.tryLock()) std.atomic.spinLoopHint();
        }
    }

    inline fn unlockPool(pool: *StackPool) void {
        if (pool.thread_safe) pool.lock.unlock();
    }

    /// Tear the pool down: every acquired stack must already have been
    /// released (asserted), and all cached stacks are unmapped.
    pub fn deinit(pool: *StackPool) void {
        std.debug.assert(pool.live_stack_count == 0);
        pool.trim();
        pool.* = undefined;
    }

    /// Hand out a stack: pool hit pops the free list (no syscalls — the
    /// E9 9 ns pooled-spawn floor path); pool miss maps a fresh
    /// reservation and protects its guard page (the E9-measured 1,646 ns
    /// growth path).
    pub fn acquire(pool: *StackPool) AcquireError!Stack {
        pool.lockPool();
        defer pool.unlockPool();
        if (pool.free_list_head) |cached_node| {
            pool.free_list_head = cached_node.next;
            pool.cached_stack_count -= 1;
            const stack = pool.stackFromFreeNode(cached_node);
            if (poison_on_release) verifyPoisonIntegrity(stack);
            pool.noteStackEnteredService();
            return stack;
        }

        const mapping = posix.mmap(
            null,
            pool.reservationLength(),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.StackReservationFailed;
        if (std.c.mprotect(@ptrCast(mapping.ptr), pool.guard_length, .{}) != 0) {
            posix.munmap(mapping);
            return error.GuardProtectionFailed;
        }
        pool.noteStackEnteredService();
        return .{ .mapping = mapping, .guard_length = pool.guard_length };
    }

    /// Return a stack to the pool: poisons the usable range in Debug
    /// builds, then either caches the stack (free list below the
    /// high-watermark-derived cap) or unmaps it.
    ///
    /// Enforces the fiber-stack-lifetime invariant locally: panics if the
    /// caller's frame lives inside the stack being released (releasing the
    /// stack one is currently executing on is exactly the Dispatch-backend
    /// bug the G2 triage documented). This check is active in ALL build
    /// modes — it is two integer compares on a path that runs once per
    /// process exit.
    pub fn release(pool: *StackPool, stack: Stack) void {
        // Geometry must match: stacks are not transferable between pools
        // with different reservation shapes.
        std.debug.assert(stack.guard_length == pool.guard_length);
        std.debug.assert(stack.mapping.len == pool.reservationLength());

        // Serialize the free-list/counter mutation with a possibly-concurrent
        // `acquire` on the ORIGIN pool: under M:N a stolen process's stack is
        // released here on its runner's thread while its origin core may be
        // spawning (P4-J1). No-op for an owner-only pool.
        pool.lockPool();
        defer pool.unlockPool();

        // Fiber-stack-lifetime invariant, local half (module doc): the
        // caller must have LEFT this stack. Active in all build modes.
        const releasing_frame_address = @frameAddress();
        const stack_start = @intFromPtr(stack.mapping.ptr);
        const stack_end = stack_start + stack.mapping.len;
        if (releasing_frame_address >= stack_start and releasing_frame_address < stack_end) {
            @branchHint(.cold);
            @panic("StackPool.release called from a frame on the stack being released " ++
                "(fiber-stack-lifetime invariant violation)");
        }

        if (poison_on_release) {
            pool.assertNotAlreadyCached(stack);
            @memset(stack.usable(), poison_byte);
        }

        std.debug.assert(pool.live_stack_count > 0);
        pool.live_stack_count -= 1;

        if (pool.cached_stack_count < pool.cacheCapacity()) {
            const node: *FreeNode = @ptrCast(@alignCast(stack.usable().ptr));
            node.* = .{ .next = pool.free_list_head };
            pool.free_list_head = node;
            pool.cached_stack_count += 1;
        } else {
            posix.munmap(stack.mapping);
        }
        std.debug.assert(pool.live_stack_count + pool.cached_stack_count <= pool.live_stack_peak);
    }

    /// Unmap every cached stack, returning the address space to the OS.
    /// Live stacks are unaffected. The high-watermark is deliberately NOT
    /// reset: demonstrated peak demand remains the cache bound.
    pub fn trim(pool: *StackPool) void {
        pool.lockPool();
        defer pool.unlockPool();
        while (pool.free_list_head) |cached_node| {
            pool.free_list_head = cached_node.next;
            pool.cached_stack_count -= 1;
            posix.munmap(pool.stackFromFreeNode(cached_node).mapping);
        }
        std.debug.assert(pool.cached_stack_count == 0);
    }

    /// Snapshot the pool counters (tests + Phase 1.6 observability).
    pub fn statistics(pool: *const StackPool) Statistics {
        return .{
            .live_stack_count = pool.live_stack_count,
            .live_stack_peak = pool.live_stack_peak,
            .cached_stack_count = pool.cached_stack_count,
            .cache_capacity = pool.cacheCapacity(),
        };
    }

    /// Maximum number of stacks the free list may hold, derived from the
    /// live-stack high-watermark (see the constant block above).
    fn cacheCapacity(pool: *const StackPool) u32 {
        const peak_fraction = pool.live_stack_peak / CACHE_PEAK_DIVISOR;
        return @min(@max(peak_fraction, CACHE_RETAIN_FLOOR), CACHE_RETAIN_CEILING);
    }

    /// Total reservation bytes per stack (guard + usable).
    fn reservationLength(pool: *const StackPool) usize {
        return pool.guard_length + pool.usable_length;
    }

    /// Record that a stack entered service (fresh mmap or cache reuse):
    /// bump the live count and advance the high-watermark. Mirrors
    /// `noteSlabEnteredService` in `src/memory/arc/manager.zig`.
    fn noteStackEnteredService(pool: *StackPool) void {
        pool.live_stack_count += 1;
        if (pool.live_stack_count > pool.live_stack_peak) {
            pool.live_stack_peak = pool.live_stack_count;
        }
    }

    /// Reconstruct the `Stack` value from its intrusive free-list node
    /// (which sits at the base of the usable range, one guard-length above
    /// the mapping start).
    fn stackFromFreeNode(pool: *const StackPool, node: *FreeNode) Stack {
        const mapping_start = @intFromPtr(node) - pool.guard_length;
        const mapping_pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(mapping_start);
        return .{
            .mapping = mapping_pointer[0..pool.reservationLength()],
            .guard_length = pool.guard_length,
        };
    }

    /// Debug: leading/trailing poison samples of a cache-hit stack must be
    /// intact — a mismatch means someone wrote to a stack after releasing
    /// it (use-after-release). The first `@sizeOf(FreeNode)` bytes are the
    /// intrusive node and are exempt.
    fn verifyPoisonIntegrity(stack: Stack) void {
        const usable_bytes = stack.usable();
        const sample_start = @sizeOf(FreeNode);
        const leading_end = @min(sample_start + poison_sample_length, usable_bytes.len);
        for (usable_bytes[sample_start..leading_end]) |byte| {
            if (byte != poison_byte) {
                @panic("StackPool: cached stack was written after release (use-after-release)");
            }
        }
        const trailing_start = usable_bytes.len -| poison_sample_length;
        for (usable_bytes[@max(trailing_start, leading_end)..]) |byte| {
            if (byte != poison_byte) {
                @panic("StackPool: cached stack was written after release (use-after-release)");
            }
        }
    }

    /// Debug: walk the free list and assert `stack` is not already on it
    /// (double-release detection; the list is bounded by the cache cap, so
    /// the walk is short).
    fn assertNotAlreadyCached(pool: *const StackPool, stack: Stack) void {
        const stack_node_address = @intFromPtr(stack.usable().ptr);
        var cursor = pool.free_list_head;
        while (cursor) |cached_node| : (cursor = cached_node.next) {
            if (@intFromPtr(cached_node) == stack_node_address) {
                @panic("StackPool: stack released twice");
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "StackPool: acquire returns a guard-paged stack with the configured usable size" {
    var pool = StackPool.init(.{});
    defer pool.deinit();

    const stack = try pool.acquire();
    defer pool.release(stack);

    const page_length = std.heap.pageSize();
    try testing.expectEqual(page_length, stack.guard_length);
    try testing.expectEqual(default_usable_size, stack.usable().len);
    try testing.expectEqual(default_usable_size + page_length, stack.mapping.len);
    try testing.expectEqual(@intFromPtr(stack.mapping.ptr) + stack.mapping.len, stack.top());

    // The usable range is writable and readable end to end (touch the
    // first and last usable bytes; the first touch also proves fault-
    // commit works).
    const usable_bytes = stack.usable();
    usable_bytes[0] = 0x11;
    usable_bytes[usable_bytes.len - 1] = 0x22;
    try testing.expectEqual(@as(u8, 0x11), usable_bytes[0]);
    try testing.expectEqual(@as(u8, 0x22), usable_bytes[usable_bytes.len - 1]);

    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 1), stats.live_stack_count);
    try testing.expectEqual(@as(u32, 1), stats.live_stack_peak);
    try testing.expectEqual(@as(u32, 0), stats.cached_stack_count);
}

test "StackPool: usable size is rounded up to a whole page" {
    var pool = StackPool.init(.{ .usable_size = 1 });
    defer pool.deinit();

    const page_length = std.heap.pageSize();
    try testing.expectEqual(page_length, pool.usable_length);

    const stack = try pool.acquire();
    defer pool.release(stack);
    try testing.expectEqual(page_length, stack.usable().len);
}

test "StackPool: release caches the stack and acquire reuses it LIFO" {
    var pool = StackPool.init(.{});
    defer pool.deinit();

    const first = try pool.acquire();
    const first_base = first.mapping.ptr;
    pool.release(first);

    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
        try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
        try testing.expectEqual(@as(u32, 1), stats.live_stack_peak);
    }

    // Pool hit: the exact same reservation comes back (LIFO top).
    const second = try pool.acquire();
    try testing.expectEqual(first_base, second.mapping.ptr);
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 1), stats.live_stack_count);
        try testing.expectEqual(@as(u32, 0), stats.cached_stack_count);
        // Reuse does not raise the peak.
        try testing.expectEqual(@as(u32, 1), stats.live_stack_peak);
    }
    pool.release(second);
}

test "StackPool: cache is bounded by the live-stack high-watermark and trim unmaps" {
    var pool = StackPool.init(.{ .usable_size = 16 * 1024 });
    defer pool.deinit();

    // Drive the live peak to 6 simultaneously-acquired stacks.
    var stacks: [6]Stack = undefined;
    for (&stacks) |*slot| slot.* = try pool.acquire();
    try testing.expectEqual(@as(u32, 6), pool.statistics().live_stack_peak);

    // Release all six: cap = clamp(6/2, 2, 256) = 3, so exactly three are
    // cached and the other three unmap immediately.
    for (stacks) |stack| pool.release(stack);
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
        try testing.expectEqual(@as(u32, 3), stats.cache_capacity);
        try testing.expectEqual(@as(u32, 3), stats.cached_stack_count);
        // The watermark survives the releases.
        try testing.expectEqual(@as(u32, 6), stats.live_stack_peak);
    }

    // trim returns every cached reservation to the OS.
    pool.trim();
    {
        const stats = pool.statistics();
        try testing.expectEqual(@as(u32, 0), stats.cached_stack_count);
        try testing.expectEqual(@as(u32, 6), stats.live_stack_peak);
    }
}

test "StackPool: small peaks retain up to the cache floor" {
    var pool = StackPool.init(.{ .usable_size = 16 * 1024 });
    defer pool.deinit();

    // Peak of 1: cap = clamp(0, 2, 256) = 2 — the floor still absorbs
    // oscillation around a single stack.
    const only = try pool.acquire();
    pool.release(only);
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 2), stats.cache_capacity);
    try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
}

test "StackPool: live + cached never exceeds the live peak across acquire/release cycles" {
    var pool = StackPool.init(.{ .usable_size = 16 * 1024 });
    defer pool.deinit();

    var held: [8]?Stack = @splat(null);
    // Deterministic acquire/release pattern exercising growth, reuse, and
    // cache eviction; the structural invariant must hold at every step.
    const script = [_]struct { slot: usize, acquire: bool }{
        .{ .slot = 0, .acquire = true },  .{ .slot = 1, .acquire = true },
        .{ .slot = 2, .acquire = true },  .{ .slot = 0, .acquire = false },
        .{ .slot = 3, .acquire = true },  .{ .slot = 4, .acquire = true },
        .{ .slot = 1, .acquire = false }, .{ .slot = 2, .acquire = false },
        .{ .slot = 5, .acquire = true },  .{ .slot = 6, .acquire = true },
        .{ .slot = 7, .acquire = true },  .{ .slot = 3, .acquire = false },
        .{ .slot = 4, .acquire = false }, .{ .slot = 5, .acquire = false },
        .{ .slot = 6, .acquire = false }, .{ .slot = 7, .acquire = false },
    };
    for (script) |step| {
        if (step.acquire) {
            try testing.expect(held[step.slot] == null);
            held[step.slot] = try pool.acquire();
        } else {
            pool.release(held[step.slot].?);
            held[step.slot] = null;
        }
        const stats = pool.statistics();
        try testing.expect(stats.live_stack_count + stats.cached_stack_count <= stats.live_stack_peak);
    }
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_stack_count);
}

test "StackPool: guard page is PROT_NONE and the usable range is read+write" {
    var pool = StackPool.init(.{});
    defer pool.deinit();

    const stack = try pool.acquire();
    defer pool.release(stack);

    // Verified by READING the region's protection from the OS (not by
    // faulting): mach_vm_region on Darwin, /proc/self/maps on Linux.
    const guard_protection = readRegionProtection(@intFromPtr(stack.mapping.ptr)) orelse
        return error.SkipZigTest;
    try testing.expect(!guard_protection.readable);
    try testing.expect(!guard_protection.writable);

    // The queries below skip like the first one: on a platform where the
    // guard query answered, these normally answer too, but a null (e.g.
    // a transient procfs read failure) must skip rather than panic.
    const usable_low = readRegionProtection(@intFromPtr(stack.usable().ptr)) orelse
        return error.SkipZigTest;
    try testing.expect(usable_low.readable);
    try testing.expect(usable_low.writable);

    const usable_high = readRegionProtection(stack.top() - 16) orelse
        return error.SkipZigTest;
    try testing.expect(usable_high.readable);
    try testing.expect(usable_high.writable);
}

test "StackPool: poison-on-release fills the usable range in debug builds" {
    if (!poison_on_release) return error.SkipZigTest;

    var pool = StackPool.init(.{ .usable_size = 32 * 1024 });
    defer pool.deinit();

    const stack = try pool.acquire();
    const usable_bytes = stack.usable();
    // Dirty the stack the way a fiber would.
    @memset(usable_bytes, 0x5A);
    pool.release(stack);
    // peak == 1 → cap == floor (2) → the stack is cached, so its memory is
    // still mapped and inspectable.
    try testing.expectEqual(@as(u32, 1), pool.statistics().cached_stack_count);

    // Everything except the intrusive free-list node at the base of the
    // usable range must now read poison.
    const node_length = @sizeOf(FreeNode);
    for (usable_bytes[node_length..], node_length..) |byte, index| {
        if (byte != poison_byte) {
            std.debug.print("unpoisoned byte at usable offset {d}\n", .{index});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// Test support: read a region's protection from the OS (never by faulting).
// ---------------------------------------------------------------------------

const RegionProtection = struct {
    readable: bool,
    writable: bool,
};

/// Query the protection of the mapping containing `address`, where the OS
/// exposes it (Darwin: `mach_vm_region`; Linux: `/proc/self/maps`).
/// Returns null on platforms without a supported query so callers can skip.
fn readRegionProtection(address: usize) ?RegionProtection {
    if (comptime builtin.os.tag.isDarwin()) return readMachRegionProtection(address);
    if (comptime builtin.os.tag == .linux) return readLinuxRegionProtection(address);
    return null;
}

fn readMachRegionProtection(address: usize) ?RegionProtection {
    var region_address: std.c.mach_vm_address_t = address;
    var region_size: std.c.mach_vm_size_t = 0;
    var region_info: std.c.vm_region_basic_info_64 = undefined;
    var info_count: std.c.mach_msg_type_number_t = std.c.VM.REGION.BASIC_INFO_COUNT;
    var object_name: std.c.mach_port_t = 0;
    const kern_result = std.c.mach_vm_region(
        std.c.mach_task_self(),
        &region_address,
        &region_size,
        std.c.VM.REGION.BASIC_INFO_64,
        @ptrCast(&region_info),
        &info_count,
        &object_name,
    );
    if (kern_result != 0) return null;
    // mach_vm_region rounds forward to the next region when `address` sits
    // in a hole; only accept an answer that actually contains the address.
    if (address < region_address or address >= region_address + region_size) return null;
    return .{
        .readable = region_info.protection.READ,
        .writable = region_info.protection.WRITE,
    };
}

fn readLinuxRegionProtection(address: usize) ?RegionProtection {
    // procfs reports a zero file size, so read through raw syscalls rather
    // than size-driven helpers. A fixed buffer suffices for test
    // processes; if the map table ever exceeds it, callers skip (null).
    const linux = std.os.linux;
    const open_result = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.E.init(open_result) != .SUCCESS) return null;
    const maps_fd: linux.fd_t = @intCast(open_result);
    defer _ = linux.close(maps_fd);
    var maps_buffer: [1 << 22]u8 = undefined;
    var maps_length: usize = 0;
    while (maps_length < maps_buffer.len) {
        const read_result = linux.read(maps_fd, maps_buffer[maps_length..].ptr, maps_buffer.len - maps_length);
        if (linux.E.init(read_result) != .SUCCESS) return null;
        if (read_result == 0) break;
        maps_length += read_result;
    } else return null; // table larger than the buffer — cannot answer reliably
    var lines = std.mem.splitScalar(u8, maps_buffer[0..maps_length], '\n');
    while (lines.next()) |line| {
        // "<start>-<end> <perms> ..." with hex addresses.
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const space = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse continue;
        const start = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(usize, line[dash + 1 .. space], 16) catch continue;
        if (address < start or address >= end) continue;
        const perms = line[space + 1 ..];
        if (perms.len < 2) return null;
        return .{ .readable = perms[0] == 'r', .writable = perms[1] == 'w' };
    }
    return null;
}

// ---------------------------------------------------------------------------
// P6-J4 — `decommitBelowStackPointer` (the hibernate stack shrink)
// ---------------------------------------------------------------------------

test "decommitBelowStackPointer: geometry — keep boundary, empty ranges, out-of-range SP" {
    var pool = StackPool.init(.{});
    defer pool.deinit();
    const stack = try pool.acquire();
    defer pool.release(stack);

    const page_length = std.heap.pageSize();
    const usable_bytes = stack.usable();
    const usable_start = @intFromPtr(usable_bytes.ptr);

    // An SP outside the usable range is a contract violation answered with 0.
    try testing.expectEqual(@as(usize, 0), decommitBelowStackPointer(stack, usable_start - 1));
    try testing.expectEqual(@as(usize, 0), decommitBelowStackPointer(stack, stack.top() + 1));

    // An SP within the two lowest usable pages leaves nothing to release
    // (the SP page and one cushion page below it are always preserved).
    try testing.expectEqual(@as(usize, 0), decommitBelowStackPointer(stack, usable_start));
    try testing.expectEqual(@as(usize, 0), decommitBelowStackPointer(stack, usable_start + 2 * page_length - 1));

    // An SP at the very top (page-aligned: its page floor is itself, so only
    // the one cushion page below it is preserved) releases everything except
    // that cushion page.
    const released = decommitBelowStackPointer(stack, stack.top());
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expectEqual(usable_bytes.len - 1 * page_length, released);
    }
}

test "decommitBelowStackPointer: bytes at and above the keep boundary survive; released range recommits by fault" {
    var pool = StackPool.init(.{});
    defer pool.deinit();
    const stack = try pool.acquire();
    defer pool.release(stack);

    const page_length = std.heap.pageSize();
    const usable_bytes = stack.usable();
    const usable_start = @intFromPtr(usable_bytes.ptr);

    // Commit the whole usable range with a position-derived pattern.
    for (usable_bytes, 0..) |*byte, index| byte.* = @truncate(index);

    // A mid-stack SP: everything below (sp_page - 1 page) is released.
    const synthetic_sp = usable_start + usable_bytes.len / 2;
    const sp_page_floor = std.mem.alignBackward(usize, synthetic_sp, page_length);
    const keep_boundary = sp_page_floor - page_length;
    const released = decommitBelowStackPointer(stack, synthetic_sp);
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expectEqual(keep_boundary - usable_start, released);
    }

    // Everything from the keep boundary up must be byte-identical — the
    // preserved cushion page, the SP page, and all live frames above.
    var offset = keep_boundary - usable_start;
    while (offset < usable_bytes.len) : (offset += 1) {
        try testing.expectEqual(@as(u8, @truncate(offset)), usable_bytes[offset]);
    }

    // The released range recommits by fault: writes land and read back —
    // the wake-after-hibernate path in miniature. (Its PRIOR contents are
    // legitimately gone or stale — either is allowed; only re-use must work.)
    var probe_offset: usize = 0;
    while (probe_offset < keep_boundary - usable_start) : (probe_offset += page_length) {
        usable_bytes[probe_offset] = 0x5C;
        try testing.expectEqual(@as(u8, 0x5C), usable_bytes[probe_offset]);
    }
}

/// Current `phys_footprint` of this task (Darwin) — the ledger the hibernate
/// shrink must visibly reduce (`MADV_FREE_REUSABLE` removes reusable pages
/// from it immediately, unlike `MADV_FREE`'s lazy reclaim). 0 elsewhere.
fn testCurrentPhysFootprint() usize {
    if (builtin.os.tag != .macos) return 0;
    var info: std.c.task_vm_info_data_t = undefined;
    var count: std.c.mach_msg_type_number_t = std.c.TASK.VM.INFO_COUNT;
    const kr = std.c.task_info(
        std.c.mach_task_self(),
        std.c.TASK.VM.INFO,
        @ptrCast(&info),
        &count,
    );
    if (kr != 0) return 0;
    return @intCast(info.phys_footprint);
}

test "decommitBelowStackPointer: the released pages leave the task's physical footprint (Darwin)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // A deliberately large stack so the measured delta dwarfs allocator /
    // runtime footprint noise during the test.
    const touched_length: usize = 32 * 1024 * 1024;
    var pool = StackPool.init(.{ .usable_size = touched_length });
    defer pool.deinit();
    const stack = try pool.acquire();
    defer pool.release(stack);

    const usable_bytes = stack.usable();
    // Commit every page.
    var offset: usize = 0;
    while (offset < usable_bytes.len) : (offset += std.heap.pageSize()) {
        usable_bytes[offset] = 0xA5;
    }
    const footprint_committed = testCurrentPhysFootprint();

    // Hibernate-shape shrink: SP parked near the top, everything below
    // released.
    const released = decommitBelowStackPointer(stack, stack.top());
    try testing.expect(released >= touched_length - 1 * std.heap.pageSize());
    const footprint_shrunk = testCurrentPhysFootprint();

    // The footprint must drop by at least half the released range (generous
    // slack for unrelated allocations racing the two samples; the real delta
    // is ~the full 32 MiB).
    try testing.expect(footprint_committed > footprint_shrunk);
    try testing.expect(footprint_committed - footprint_shrunk >= released / 2);
}
