//! Dedicated DNS-resolver thread pool for the Zap socket layer (the Decision-C
//! isolation fix in `docs/socket-implementation-plan.md`, P3a variant 1b).
//!
//! ## The DoS this severs
//!
//! `Socket.connect_host` used to offload its WHOLE state machine — the
//! uninterruptible `getaddrinfo` resolve AND the RFC-8305 race — onto the ONE
//! shared 64-thread blocking pool that ALSO serves `recv`/`send`/`accept`.
//! `getaddrinfo` cannot be interrupted on macOS/musl, so N concurrent
//! `connect_host` calls to slow/black-hole hostnames pinned N of the 64 shared
//! threads for the OS resolver timeout (seconds) — and because that pool also
//! serves I/O, a resolve storm STARVED I/O on healthy connections. The caller's
//! `timeout_ms`/`kill_flag` bound only the on-core wait, never the in-flight
//! resolve.
//!
//! ## The root fix (not a workaround): sever resolve from I/O
//!
//! Resolves run on a SEPARATE bounded pool. `getaddrinfo` can then only ever
//! pin a resolver thread — never an I/O thread — so a resolve storm cannot
//! starve I/O. The residual (a resolver thread pinned until the OS returns) is
//! INHERENT and BOUNDED: ≤ the resolver cap, and it self-limits resolver
//! throughput ONLY. `connect_host` becomes two sequential stages: Stage 1 (this
//! pool) resolves while the fiber parks on-core with the caller's absolute
//! deadline (`Scheduler.ProcessContext.resolveWaitDeadline`); Stage 2 races the
//! resolved addresses on the I/O pool exactly as the single-address connect
//! always has.
//!
//! ## Shape (mirrors `blocking_pool.zig`, MINUS the fiber-handoff)
//!
//! A resolver worker does NOT resume a fiber or touch the owning process's
//! heap/manager (unlike a blocking-pool worker). It only:
//!   1. pops a slab slot,
//!   2. runs the injected `resolve` (the `getaddrinfo` call) into the slot,
//!   3. publishes the result (`completed` release-store),
//!   4. wakes the parked fiber via `Scheduler.wakeParked` (the SAME cross-thread
//!      revive handshake a foreign message producer uses — `reviveIfParked`),
//!   5. drops its slab-slot reference.
//! So the resolver worker's only cross-thread touch of a process is the proven
//! `park_control` revive — never non-atomic process state — and the
//! scheduler-local invariant is untouched.
//!
//! ## The bounded slab IS the backpressure
//!
//! A fixed-capacity SLAB of `ResolveRequest` slots is the queue-depth bound:
//! `acquire` with no free slot REJECTS (the caller gets `.timed_out` — bounded
//! backpressure). Combined with the worker-thread cap (in-flight ≤ `max`) and
//! the RFC-8305 address cap (`socket_io.max_addresses`) and the caller's
//! absolute deadline, a resolve storm grows NOTHING unbounded: in-flight ≤ 16,
//! outstanding slots ≤ slab, addresses/resolve ≤ 8.
//!
//! ## Abandon-safety (why the slot is SLAB-owned + refcounted + host-copied)
//!
//! A slot is owned by the SLAB — NOT the fiber's stack (an abandon reuses the
//! frame) and NOT the process heap (a kill frees it at teardown while a worker
//! still holds it → UAF). The host bytes are COPIED into the slot (≤ 255). Each
//! slot carries a refcount of 2 (fiber + worker); the LAST dropper returns it to
//! the free-list. On ABANDON (deadline/kill with the resolve still in flight)
//! the fiber sets `abandoned`, clears the process's `pending_resolve`, and drops
//! its ref; the worker either (i) is already in `getaddrinfo` → finishes,
//! observes `abandoned`, discards the result, and drops its ref (the resolver
//! thread stays pinned until the OS returns — ACCEPTABLE, it is a resolver
//! thread, not I/O), or (ii) has not started → observes `abandoned` BEFORE
//! `getaddrinfo`, never starts, and drops its ref. Either way the slot returns
//! to the free-list, no fd is produced by a resolve, and at most ONE
//! `getaddrinfo` is in flight per abandoned-while-running resolve (bounded by
//! the thread cap).

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const socket_io = @import("socket_io.zig");
const futex = @import("futex.zig");

const ProcessRecord = scheduler_module.ProcessRecord;

/// Maximum host-name length copied into a slot (RFC-1123 / the fork's
/// `HostName.max_len`). The slot owns its own copy so the caller's `String`
/// bytes need not outlive the (possibly abandoned) resolve.
pub const host_max_len: usize = 255;

/// Default eager-started resolver worker (one live worker guarantees the very
/// first resolve has somewhere to run without a lazy-start race — the same
/// policy as `blocking_pool.zig`).
pub const default_initial_thread_count: usize = 1;

/// Default resolver worker cap. Deliberately FAR below the 64 I/O threads:
/// resolves are the scarce, uninterruptible resource, so the cap bounds how
/// many `getaddrinfo` calls can ever be pinned at once. 16 is enough for real
/// hostname-connect concurrency while keeping a resolve storm from ever
/// growing the resolver footprint unbounded.
pub const default_max_thread_count: usize = 16;

/// Default slab capacity — the queue-depth bound. ~400 B/slot × 1024 ≈ 400 KB,
/// a fixed one-time cost. A submit with no free slot rejects, so this is the
/// hard ceiling on outstanding resolves (in-flight + queued + result-not-yet-
/// consumed).
pub const default_slab_capacity: usize = 1024;

/// Default bound on one worker futex park (defense-in-depth re-check period;
/// the eventcount protocol needs no timeout for correctness).
pub const default_park_timeout_nanoseconds: u64 = 100 * std.time.ns_per_ms;

/// One resolve request — a SLAB slot. Pinned for the pool's lifetime (the slab
/// array is stable), reused across resolves. A slot is in exactly one of three
/// states, all threaded through the single `link` field: FREE (on the
/// free-list), QUEUED (in the submit FIFO), or IN-FLIGHT/PARKED (owned by a
/// worker + a parked fiber, `link == null`).
pub const ResolveRequest = struct {
    /// Free-list / submit-FIFO intrusive link (never both at once), or null
    /// while a worker holds it. Slab-owner (`state_lock`) only.
    link: ?*ResolveRequest,
    /// The COPIED host bytes (`host_buffer[0..host_len]`), owned by the slot so
    /// an abandon does not dangle into the caller's freed `String`.
    host_buffer: [host_max_len]u8,
    host_len: usize,
    /// The connect port, folded into every resolved address by Stage 1.
    port: u16,
    /// The parked fiber's record — the target of the completion revive
    /// (`Scheduler.wakeParked`). Filled on-core before submit; the record is
    /// pinned for the process's whole life (never freed before scheduler
    /// deinit), so it is safe to touch from a resolver thread's revive even if
    /// the process tore down meanwhile (the epoch-packed handshake no-ops).
    waiter_record: *ProcessRecord,
    /// Reference count (fiber + worker = 2 at submit). The LAST dropper returns
    /// the slot to the free-list.
    refcount: std.atomic.Value(u8),
    /// Set by the fiber when it gives up on this resolve (deadline/kill): the
    /// worker observes it (before AND after `getaddrinfo`) and discards.
    abandoned: std.atomic.Value(bool),
    /// Set by the worker (release) after it writes `result` — the completion
    /// flag the parked fiber checks on wake (acquire).
    completed: std.atomic.Value(bool),
    /// The resolved address batch (worker writes it BEFORE `completed`; fiber
    /// reads it AFTER an acquire-load of `completed == true`).
    result: socket_io.ResolvedAddresses,
};

/// What a worker runs on a popped slot: the resolve (`getaddrinfo`) into
/// `slot.result`, reading `slot.host_buffer[0..slot.host_len]` and `slot.port`.
/// Injected at `init` so production wires the real `socket_io.resolveHost` and
/// tests wire a deterministic stub (no network). Runs on the worker's own OS
/// thread; must NOT touch the scheduler or any process state.
pub const ResolveFn = *const fn (resolve_context: ?*anyopaque, slot: *ResolveRequest) void;

/// The production resolve hook: the real Stage-1 `getaddrinfo`. This is the ONE
/// call that may pin its (resolver) thread until the OS returns.
pub fn realResolve(resolve_context: ?*anyopaque, slot: *ResolveRequest) void {
    _ = resolve_context;
    socket_io.resolveHost(slot.host_buffer[0..slot.host_len], slot.port, &slot.result);
}

/// The dedicated DNS-resolver pool. Pinned after `init` (worker threads hold
/// `pool` back-pointers); construct it in place at its final address.
pub const ResolverPool = struct {
    /// Backing allocator for the worker-thread array AND the slab. Owned.
    allocator: std.mem.Allocator,
    /// What a worker does with a popped slot (the resolve). Set at `init`.
    resolve: ResolveFn,
    /// Opaque context forwarded to every `resolve` call.
    resolve_context: ?*anyopaque,
    /// Worker OS threads. Capacity `max_thread_count`; slots `[0..started)`.
    /// Optional so a growth `submit` can RESERVE a slot (null) under the lock,
    /// spawn OFF the lock, then publish — mirroring `blocking_pool.zig`. Owned.
    threads: []?std.Thread,

    /// The fixed-capacity slab — the queue-depth bound. Pinned; never resized.
    slab: []ResolveRequest,

    /// Guards the free-list, the submit queue, and the worker-population
    /// counters. A `std.atomic.Mutex` spinlock (kernel convention); every
    /// critical section is O(1) pointer surgery except the rare growth spawn.
    state_lock: std.atomic.Mutex,
    /// Free-list head (slots available for `acquire`).
    free_head: ?*ResolveRequest,
    /// Free slots remaining (== slab capacity when fully idle).
    free_count: usize,
    /// Submit FIFO of filled slots awaiting a worker. Oldest.
    queue_head: ?*ResolveRequest,
    /// Newest.
    queue_tail: ?*ResolveRequest,
    /// Queued (submitted, not yet popped) slots.
    queue_len: usize,
    /// Worker threads started (`≤ max_thread_count`). Written by `init` and
    /// `submit`-growth only; read under `state_lock`.
    started_thread_count: usize,
    /// Workers currently running a resolve. Part of the demand metric.
    inflight_count: usize,

    /// Eventcount workers park on (a submit / stop bumps it, then futex-wakes).
    work_epoch: std.atomic.Value(u32),
    /// Eventcount a `quiesce` waiter parks on (a worker bumps it when it
    /// finishes the LAST in-flight resolve with an empty queue).
    idle_epoch: std.atomic.Value(u32),
    /// Set by `deinit`: workers observe it (via the `work_epoch` wake) and exit.
    stopping: std.atomic.Value(bool),

    /// Max worker threads (grow ceiling).
    max_thread_count: usize,
    /// Bound on one worker futex park.
    park_timeout_nanoseconds: u64,

    // -- counters (thread-safe observability) --------------------------------
    /// Resolves accepted (slots submitted).
    submit_total: std.atomic.Value(u64),
    /// Resolves rejected (`acquire` found no free slot — bounded backpressure).
    reject_total: std.atomic.Value(u64),
    /// Resolves executed to completion (excludes abandoned-before-start).
    execute_total: std.atomic.Value(u64),
    /// Worker futex parks entered (proves no busy-wait when idle).
    park_total: std.atomic.Value(u64),
    /// High-watermark of `started_thread_count` (read under `state_lock`).
    peak_thread_count: usize,
    /// High-watermark of concurrently-outstanding slots (`slab_capacity -
    /// free_count`) — the storm-saturation observability the DoS test reads.
    peak_outstanding: usize,

    /// Construction options (mirrors `blocking_pool.BlockingPool.Options`, plus
    /// the slab cap). `SchedulerPool.Options.resolver_pool_options` forwards it.
    pub const Options = struct {
        /// Workers eager-started at `init`. Clamped to `[0, max_thread_count]`.
        initial_thread_count: usize = default_initial_thread_count,
        /// Grow ceiling (the resolver footprint bound).
        max_thread_count: usize = default_max_thread_count,
        /// Slab capacity (the queue-depth bound). Clamped to at least 1.
        slab_capacity: usize = default_slab_capacity,
        /// Bound on one worker futex park.
        park_timeout_nanoseconds: u64 = default_park_timeout_nanoseconds,
    };

    /// Initialize the pool in place: allocate the worker array and the slab,
    /// thread every slot onto the free-list, and eager-start
    /// `initial_thread_count` workers (which park immediately — no work yet).
    /// A worker spawn failure stops the eager start early; the pool is still
    /// valid but may be `!isLive()`.
    pub fn init(
        pool: *ResolverPool,
        allocator: std.mem.Allocator,
        resolve: ResolveFn,
        resolve_context: ?*anyopaque,
        options: Options,
    ) error{OutOfMemory}!void {
        const max = @max(options.max_thread_count, 1);
        const initial = @min(options.initial_thread_count, max);
        const capacity = @max(options.slab_capacity, 1);

        const threads = allocator.alloc(?std.Thread, max) catch return error.OutOfMemory;
        errdefer allocator.free(threads);
        @memset(threads, null);

        const slab = allocator.alloc(ResolveRequest, capacity) catch return error.OutOfMemory;

        pool.* = .{
            .allocator = allocator,
            .resolve = resolve,
            .resolve_context = resolve_context,
            .threads = threads,
            .slab = slab,
            .state_lock = .unlocked,
            .free_head = null,
            .free_count = capacity,
            .queue_head = null,
            .queue_tail = null,
            .queue_len = 0,
            .started_thread_count = 0,
            .inflight_count = 0,
            .work_epoch = .init(0),
            .idle_epoch = .init(0),
            .stopping = .init(false),
            .max_thread_count = max,
            .park_timeout_nanoseconds = options.park_timeout_nanoseconds,
            .submit_total = .init(0),
            .reject_total = .init(0),
            .execute_total = .init(0),
            .park_total = .init(0),
            .peak_thread_count = 0,
            .peak_outstanding = 0,
        };

        // Thread every slab slot onto the free-list (reverse, so `[0]` ends up
        // at the head — immaterial, just deterministic).
        var index: usize = capacity;
        while (index > 0) {
            index -= 1;
            const slot = &pool.slab[index];
            slot.link = pool.free_head;
            pool.free_head = slot;
        }

        var started: usize = 0;
        while (started < initial) : (started += 1) {
            pool.threads[started] = std.Thread.spawn(.{}, workerEntry, .{pool}) catch break;
        }
        pool.started_thread_count = started;
        pool.peak_thread_count = started;
    }

    /// Whether the pool has at least one worker (the offload seam wires it only
    /// when live, so a pool that could not start any worker degrades to the
    /// inline single-offload `connect_host` path).
    pub fn isLive(pool: *ResolverPool) bool {
        pool.lockState();
        defer pool.unlockState();
        return pool.started_thread_count > 0;
    }

    inline fn lockState(pool: *ResolverPool) void {
        while (!pool.state_lock.tryLock()) std.atomic.spinLoopHint();
    }

    inline fn unlockState(pool: *ResolverPool) void {
        pool.state_lock.unlock();
    }

    /// Acquire a free slab slot, or null when the slab is exhausted (the
    /// bounded-backpressure REJECT — the caller returns `.timed_out`). The
    /// caller fills the slot (`host`/`port`/`waiter_record`), then `submit`s it.
    /// Refcount, flags, and result are (re)initialized here so the caller only
    /// sets the inputs.
    pub fn acquire(pool: *ResolverPool) ?*ResolveRequest {
        pool.lockState();
        const slot = pool.free_head orelse {
            pool.unlockState();
            _ = pool.reject_total.fetchAdd(1, .monotonic);
            return null;
        };
        pool.free_head = slot.link;
        pool.free_count -= 1;
        const outstanding = pool.slab.len - pool.free_count;
        if (outstanding > pool.peak_outstanding) pool.peak_outstanding = outstanding;
        pool.unlockState();

        slot.link = null;
        slot.host_len = 0;
        slot.port = 0;
        slot.refcount = .init(2);
        slot.abandoned = .init(false);
        slot.completed = .init(false);
        return slot;
    }

    /// Copy `host` (truncated to `host_max_len`; the caller has already
    /// validated ≤ 255) into the slot and record the connect `port`.
    pub fn fillHost(slot: *ResolveRequest, host: []const u8, port: u16) void {
        const len = @min(host.len, host_max_len);
        @memcpy(slot.host_buffer[0..len], host[0..len]);
        slot.host_len = len;
        slot.port = port;
    }

    /// Submit a filled slot: enqueue FIFO, grow a worker if demand exceeds the
    /// worker count and there is room, and wake a parked worker. The offloading
    /// core's LAST touch of the slot as a queue member (a worker owns it next).
    /// A plain job enqueue — NOT a fiber evacuation; the fiber keeps its PCB and
    /// parks on-core.
    pub fn submit(pool: *ResolverPool, slot: *ResolveRequest) void {
        slot.link = null;
        pool.lockState();
        if (pool.queue_tail) |tail| {
            tail.link = slot;
        } else {
            pool.queue_head = slot;
        }
        pool.queue_tail = slot;
        pool.queue_len += 1;
        _ = pool.submit_total.fetchAdd(1, .monotonic);

        // Grow on DEMAND (queued + in-flight > workers) when there is room —
        // the same race-free trigger `blocking_pool.zig` uses. Reserve the slot
        // under the lock, spawn OFF it.
        const reserved_index: ?usize = blk: {
            if (pool.queue_len + pool.inflight_count > pool.started_thread_count and
                pool.started_thread_count < pool.max_thread_count)
            {
                const worker_index = pool.started_thread_count;
                pool.threads[worker_index] = null;
                pool.started_thread_count += 1;
                if (pool.started_thread_count > pool.peak_thread_count) {
                    pool.peak_thread_count = pool.started_thread_count;
                }
                break :blk worker_index;
            }
            break :blk null;
        };
        pool.unlockState();

        if (reserved_index) |worker_index| {
            const spawned: ?std.Thread = std.Thread.spawn(.{}, workerEntry, .{pool}) catch null;
            pool.lockState();
            if (spawned) |thread| {
                pool.threads[worker_index] = thread;
            } else {
                if (worker_index == pool.started_thread_count - 1) {
                    pool.started_thread_count -= 1;
                }
                pool.threads[worker_index] = null;
            }
            pool.unlockState();
        }
        _ = pool.work_epoch.fetchAdd(1, .seq_cst);
        futex.wakeOne(&pool.work_epoch);
    }

    /// Drop one reference to a slot; the LAST dropper (refcount → 0) returns it
    /// to the free-list. Called by the worker after its resolve (or its
    /// abandoned-discard) AND by the fiber after it consumes the result (or
    /// abandons). `.acq_rel` so the last dropper's free-list push is ordered
    /// after every prior touch of the slot.
    fn dropRef(pool: *ResolverPool, slot: *ResolveRequest) void {
        if (slot.refcount.fetchSub(1, .acq_rel) != 1) return;
        pool.lockState();
        slot.link = pool.free_head;
        pool.free_head = slot;
        pool.free_count += 1;
        pool.unlockState();
    }

    /// The fiber's completion drop: it has consumed `slot.result`, so release
    /// its reference (the worker's ref is dropped independently). NOT an abandon
    /// — the resolve succeeded.
    pub fn releaseCompleted(pool: *ResolverPool, slot: *ResolveRequest) void {
        pool.dropRef(slot);
    }

    /// ABANDON a slot the fiber gave up on (deadline elapsed or the process is
    /// being killed): publish `abandoned` (release — the worker's acquire-load
    /// sees it), then drop the fiber's reference. The worker discards its result
    /// and drops its own ref; the last dropper frees the slot. No fd is ever
    /// produced by a resolve, so an abandon leaks nothing.
    pub fn abandon(pool: *ResolverPool, slot: *ResolveRequest) void {
        slot.abandoned.store(true, .release);
        pool.dropRef(slot);
    }

    /// Block the CALLING thread until no queued and no in-flight resolve remains.
    /// Called by `SchedulerPool` teardown after the cores stop, so no resolver
    /// worker is still running (or about to revive a core) when cores are freed.
    /// Must not race `submit` (every process has been reaped by then).
    pub fn quiesce(pool: *ResolverPool) void {
        while (true) {
            pool.lockState();
            const done = pool.queue_len == 0 and pool.inflight_count == 0;
            const observed = pool.idle_epoch.load(.seq_cst);
            pool.unlockState();
            if (done) return;
            futex.waitBounded(&pool.idle_epoch, observed, pool.park_timeout_nanoseconds);
        }
    }

    /// Stop and join every worker, then free the slab and the thread array.
    /// Quiesces first (an in-flight `getaddrinfo` runs to completion — native
    /// code is never interrupted). MUST be called AFTER every offloading core
    /// has stopped and every process has been reaped (so every fiber ref was
    /// abandoned/consumed): asserts the slab is fully returned (leak-exactness,
    /// the resolver analogue of the socket domain's zero-open-sockets assert).
    pub fn deinit(pool: *ResolverPool) void {
        pool.quiesce();
        pool.stopping.store(true, .release);
        pool.wakeAllWorkers();
        pool.lockState();
        const live = pool.started_thread_count;
        pool.unlockState();
        for (pool.threads[0..live]) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }
        // Every acquired slot is back on the free-list: an outstanding slot here
        // is a leaked resolve (a fiber ref never dropped) — surface it.
        std.debug.assert(pool.free_count == pool.slab.len);
        pool.allocator.free(pool.slab);
        pool.allocator.free(pool.threads);
        pool.* = undefined;
    }

    /// Statistics snapshot (thread-safe reads; population fields under lock).
    pub const Statistics = struct {
        submit_total: u64,
        reject_total: u64,
        execute_total: u64,
        park_total: u64,
        started_thread_count: usize,
        peak_thread_count: usize,
        queue_len: usize,
        inflight_count: usize,
        free_count: usize,
        slab_capacity: usize,
        peak_outstanding: usize,
    };

    pub fn statistics(pool: *ResolverPool) Statistics {
        pool.lockState();
        defer pool.unlockState();
        return .{
            .submit_total = pool.submit_total.load(.monotonic),
            .reject_total = pool.reject_total.load(.monotonic),
            .execute_total = pool.execute_total.load(.monotonic),
            .park_total = pool.park_total.load(.monotonic),
            .started_thread_count = pool.started_thread_count,
            .peak_thread_count = pool.peak_thread_count,
            .queue_len = pool.queue_len,
            .inflight_count = pool.inflight_count,
            .free_count = pool.free_count,
            .slab_capacity = pool.slab.len,
            .peak_outstanding = pool.peak_outstanding,
        };
    }

    // -------------------------------------------------------------------------
    // Worker
    // -------------------------------------------------------------------------

    fn workerEntry(pool: *ResolverPool) void {
        pool.workerLoop();
    }

    fn workerLoop(pool: *ResolverPool) void {
        while (true) {
            pool.lockState();
            if (pool.dequeueLocked()) |slot| {
                pool.inflight_count += 1;
                pool.unlockState();

                pool.runResolve(slot);

                pool.lockState();
                pool.inflight_count -= 1;
                const now_quiescent = pool.queue_len == 0 and pool.inflight_count == 0;
                pool.unlockState();
                if (now_quiescent) pool.signalQuiescent();
                continue;
            }
            if (pool.stopping.load(.acquire)) {
                pool.unlockState();
                return;
            }
            const observed = pool.work_epoch.load(.seq_cst);
            pool.unlockState();
            _ = pool.park_total.fetchAdd(1, .monotonic);
            futex.waitBounded(&pool.work_epoch, observed, pool.park_timeout_nanoseconds);
        }
    }

    /// Run one popped slot's resolve + completion revive (OFF the lock — the
    /// whole point: `getaddrinfo` never holds a pool lock). Honors abandon
    /// before AND after the resolve, so an abandoned-before-start resolve never
    /// calls `getaddrinfo`, and an abandoned-mid-resolve one discards without a
    /// spurious revive. Always drops the worker's ref.
    fn runResolve(pool: *ResolverPool, slot: *ResolveRequest) void {
        // (i) Abandoned before we started: never call `getaddrinfo`.
        if (slot.abandoned.load(.acquire)) {
            pool.dropRef(slot);
            return;
        }
        pool.resolve(pool.resolve_context, slot);
        _ = pool.execute_total.fetchAdd(1, .monotonic);
        // (ii) Abandoned while we were in `getaddrinfo`: discard, no revive
        // (the fiber has moved on; the handshake would no-op anyway, but skip
        // the needless cross-thread poke).
        if (slot.abandoned.load(.acquire)) {
            pool.dropRef(slot);
            return;
        }
        // Publish the result, THEN revive the parked fiber (the release-store of
        // `completed` happens-before the fiber's acquire-load, and the revive
        // handshake linearizes against the fiber's park commit — no lost wake,
        // no double revive; the same protocol a foreign message producer uses).
        slot.completed.store(true, .release);
        scheduler_module.Scheduler.wakeParked(slot.waiter_record);
        pool.dropRef(slot);
    }

    /// Pop the oldest queued slot, or null. Caller holds `state_lock`.
    fn dequeueLocked(pool: *ResolverPool) ?*ResolveRequest {
        const slot = pool.queue_head orelse return null;
        pool.queue_head = slot.link;
        if (pool.queue_tail == slot) pool.queue_tail = null;
        slot.link = null;
        pool.queue_len -= 1;
        return slot;
    }

    fn signalQuiescent(pool: *ResolverPool) void {
        _ = pool.idle_epoch.fetchAdd(1, .seq_cst);
        futex.wakeOne(&pool.idle_epoch);
    }

    fn wakeAllWorkers(pool: *ResolverPool) void {
        _ = pool.work_epoch.fetchAdd(1, .seq_cst);
        pool.lockState();
        const live = pool.started_thread_count;
        pool.unlockState();
        var woken: usize = 0;
        while (woken < live) : (woken += 1) futex.wakeOne(&pool.work_epoch);
    }
};

// ---------------------------------------------------------------------------
// Tests — pool mechanics with an injected resolve hook (no real fibers, no real
// DNS). A slot's `waiter_record` is never dereferenced by these tests' hooks
// (they set no revive target that matters — the revive path against a real
// parked fiber is covered end-to-end in the scheduler + abi tests), so a bare
// (otherwise-`undefined`) `ProcessRecord` behind a stable pointer suffices as a
// placeholder. The revive IS exercised against a REAL parked process in
// `scheduler.zig`'s `.waiting_for_resolve_deadline` tests and abi's connect_host
// tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A counting resolve hook: writes a canned single-address result and bumps a
/// shared atomic. An optional busy-sleep forces concurrency (storm behavior).
const CountingResolve = struct {
    resolved: std.atomic.Value(u64) = .init(0),
    /// Optional per-resolve busy-block (ns) — spins on the monotonic clock (no
    /// scheduler dependency), simulating a slow `getaddrinfo`.
    busy_nanoseconds: u64 = 0,
    /// Bumped on entry, decremented on exit — the live-in-`getaddrinfo` gauge
    /// the storm test reads to see the pool saturate.
    in_resolve: std.atomic.Value(i64) = .init(0),
    peak_in_resolve: std.atomic.Value(i64) = .init(0),

    fn run(resolve_context: ?*anyopaque, slot: *ResolveRequest) void {
        const self: *CountingResolve = @ptrCast(@alignCast(resolve_context.?));
        const now_in = self.in_resolve.fetchAdd(1, .acq_rel) + 1;
        var peak = self.peak_in_resolve.load(.acquire);
        while (now_in > peak) {
            peak = self.peak_in_resolve.cmpxchgWeak(peak, now_in, .acq_rel, .acquire) orelse break;
        }
        if (self.busy_nanoseconds > 0) {
            const deadline = nowNanoseconds() + self.busy_nanoseconds;
            while (nowNanoseconds() < deadline) std.atomic.spinLoopHint();
        }
        // A canned result (single loopback address). Slot address type is the
        // real `net.IpAddress`; a zeroed ip4 with a marker port is enough.
        slot.result.count = 1;
        slot.result.reason = .ok;
        slot.result.addresses[0] = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = slot.port } };
        _ = self.resolved.fetchAdd(1, .monotonic);
        _ = self.in_resolve.fetchSub(1, .acq_rel);
    }
};

fn nowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// A stable placeholder record for a slot's `waiter_record` (never revived in
/// these mechanics tests — see the module-test note).
var placeholder_record: ProcessRecord = undefined;

fn fillAndSubmit(pool: *ResolverPool, slot: *ResolveRequest) void {
    ResolverPool.fillHost(slot, "example.test", 80);
    slot.waiter_record = &placeholder_record;
    pool.submit(slot);
}

test "ResolverPool: every submitted slot is resolved once and returns to the free-list" {
    var counter = CountingResolve{};
    var pool: ResolverPool = undefined;
    try ResolverPool.init(&pool, testing.allocator, CountingResolve.run, &counter, .{ .slab_capacity = 256 });
    defer pool.deinit();

    // Submit N slots; a worker resolves each and drops the WORKER ref. We drop
    // the FIBER ref here (standing in for a fiber that consumed the result),
    // after observing completion — so every slot returns to the free-list.
    const n: usize = 200;
    var acquired: [200]*ResolveRequest = undefined;
    for (0..n) |i| {
        const slot = pool.acquire() orelse return error.SlabExhausted;
        acquired[i] = slot;
        fillAndSubmit(&pool, slot);
    }
    // Wait for every resolve to complete, then drop each fiber ref.
    for (0..n) |i| {
        const slot = acquired[i];
        while (!slot.completed.load(.acquire)) std.atomic.spinLoopHint();
        try testing.expectEqual(@as(usize, 1), slot.result.count);
        pool.releaseCompleted(slot);
    }
    pool.quiesce();
    // Spin until every worker ref has also drained back (dropRef races quiesce).
    var settle: u64 = 0;
    while (pool.statistics().free_count != 256 and settle < 5_000_000) : (settle += 1) {
        std.atomic.spinLoopHint();
    }
    const stats = pool.statistics();
    try testing.expectEqual(@as(u64, n), counter.resolved.load(.monotonic));
    try testing.expectEqual(@as(u64, n), stats.submit_total);
    try testing.expectEqual(@as(u64, n), stats.execute_total);
    try testing.expectEqual(@as(usize, 256), stats.free_count); // fully returned
    try testing.expectEqual(@as(u64, 0), stats.reject_total);
}

test "ResolverPool: the slab bounds outstanding resolves — acquire past capacity REJECTS" {
    var counter = CountingResolve{ .busy_nanoseconds = 50 * std.time.ns_per_ms };
    var pool: ResolverPool = undefined;
    // Tiny slab, one worker: hold every slot outstanding, then the next acquire
    // must reject (bounded backpressure — no growth of any kind).
    try ResolverPool.init(&pool, testing.allocator, CountingResolve.run, &counter, .{
        .slab_capacity = 4,
        .initial_thread_count = 1,
        .max_thread_count = 2,
    });
    defer pool.deinit();

    var held: [4]*ResolveRequest = undefined;
    for (0..4) |i| {
        held[i] = pool.acquire() orelse return error.SlabExhausted;
        fillAndSubmit(&pool, held[i]);
    }
    // Slab exhausted → the 5th acquire rejects (returns null), no growth.
    try testing.expectEqual(@as(?*ResolveRequest, null), pool.acquire());
    try testing.expect(pool.statistics().reject_total >= 1);

    // Drain: consume each result, dropping the fiber ref, so the slab returns.
    for (0..4) |i| {
        while (!held[i].completed.load(.acquire)) std.atomic.spinLoopHint();
        pool.releaseCompleted(held[i]);
    }
    pool.quiesce();
    var settle: u64 = 0;
    while (pool.statistics().free_count != 4 and settle < 5_000_000) : (settle += 1) {
        std.atomic.spinLoopHint();
    }
    try testing.expectEqual(@as(usize, 4), pool.statistics().free_count);
}

test "ResolverPool: a storm saturates resolver threads but nothing grows unbounded" {
    var counter = CountingResolve{ .busy_nanoseconds = 2 * std.time.ns_per_ms };
    var pool: ResolverPool = undefined;
    try ResolverPool.init(&pool, testing.allocator, CountingResolve.run, &counter, .{
        .slab_capacity = 128,
        .initial_thread_count = 1,
        .max_thread_count = 4, // the storm can pin AT MOST 4 resolver threads
    });
    defer pool.deinit();

    const n: usize = 64;
    var acquired: [64]*ResolveRequest = undefined;
    for (0..n) |i| {
        acquired[i] = pool.acquire() orelse return error.SlabExhausted;
        fillAndSubmit(&pool, acquired[i]);
    }
    for (0..n) |i| {
        while (!acquired[i].completed.load(.acquire)) std.atomic.spinLoopHint();
        pool.releaseCompleted(acquired[i]);
    }
    pool.quiesce();
    const stats = pool.statistics();
    // In-flight NEVER exceeded the 4-thread cap, even under a 64-deep storm.
    try testing.expect(counter.peak_in_resolve.load(.acquire) <= 4);
    try testing.expect(stats.peak_thread_count <= 4);
    try testing.expectEqual(@as(u64, n), counter.resolved.load(.monotonic));
}

test "ResolverPool: an abandoned-before-start slot never resolves and returns to the free-list" {
    var counter = CountingResolve{};
    var pool: ResolverPool = undefined;
    // Zero workers so a submitted slot sits QUEUED; abandon it before any worker
    // exists, then start draining by growing — the worker must see `abandoned`
    // and skip `getaddrinfo` entirely.
    try ResolverPool.init(&pool, testing.allocator, CountingResolve.run, &counter, .{
        .slab_capacity = 8,
        .initial_thread_count = 0,
        .max_thread_count = 1,
    });
    defer pool.deinit();

    const slot = pool.acquire() orelse return error.SlabExhausted;
    ResolverPool.fillHost(slot, "abandon.test", 80);
    slot.waiter_record = &placeholder_record;
    // Abandon BEFORE submit wakes/grows a worker: the fiber's ref drops now (via
    // the real `abandon` path — publish `abandoned`, drop the fiber ref); the
    // worker (grown by submit) then sees `abandoned` and never calls the resolve.
    pool.abandon(slot); // fiber ref (refcount 2 → 1)
    pool.submit(slot); // grows a worker, which discards + drops the worker ref → free

    pool.quiesce();
    var settle: u64 = 0;
    while (pool.statistics().free_count != 8 and settle < 5_000_000) : (settle += 1) {
        std.atomic.spinLoopHint();
    }
    const stats = pool.statistics();
    try testing.expectEqual(@as(u64, 0), counter.resolved.load(.monotonic)); // never resolved
    try testing.expectEqual(@as(u64, 0), stats.execute_total);
    try testing.expectEqual(@as(usize, 8), stats.free_count); // slot reclaimed
}
