//! Blocking / dirty-scheduler thread pool for the Zap concurrency kernel.
//!
//! Phase 4 item 4.3 of `docs/concurrency-implementation-plan.md` (job P4-J3),
//! realizing research.md §6.1's "Blocking operations and FFI" recommendation:
//! a dedicated OS-thread pool — the dirty-scheduler equivalent — that runs a
//! green process's `Process.blocking` call OFF the M:N core schedulers, so one
//! blocking native call (crypto, a DB driver, `getaddrinfo`) cannot stall a
//! whole core and every green process co-scheduled on it. This is Zap's answer
//! to the same problem BEAM solved with dirty schedulers (OTP 17), Go with
//! syscall handoff, and Tokio with `spawn_blocking`.
//!
//! ## Shape / sizing / the CPU-vs-IO-split decision (deliverable 1)
//!
//! **One unified, growable pool — NOT a BEAM-style dirty-CPU/dirty-IO split.**
//! BEAM runs two dirty pools because it must bound CPU-bound parallelism to the
//! core count (so dirty-CPU work does not oversubscribe the CPUs) while allowing
//! many mostly-sleeping IO threads. For Zap v1 a single grow-on-demand pool
//! captures both without the split's complexity: IO-bound ops sleep and consume
//! no CPU, so growing to serve many concurrent blocking IO ops is free; a CPU-
//! bound op is the caller's responsibility not to over-spawn (documented in the
//! FFI contract). The growth cap bounds total parallelism. A CPU/IO split (and
//! shrink-on-idle) is a measured v2 tuning refinement, not a v1 correctness
//! need — recorded here so the decision is explicit.
//!
//! **Sizing policy.** Eager-start `initial_thread_count` workers at `init`
//! (default 1 — a gate-ON binary already runs N core threads, so one idle
//! blocking worker is negligible, and a live worker guarantees the very first
//! offload has somewhere to run without a lazy-start race). Grow lazily on
//! `submit`: when no worker is idle to take the newly-queued record and the
//! started count is below `max_thread_count`, start one more. Workers persist
//! (no shrink in v1) and PARK on a futex eventcount when the queue drains — no
//! busy-wait. `max_thread_count` (default 64) bounds parallelism; excess
//! concurrent blocks queue FIFO and are served as workers free up (correct
//! backpressure, bounded threads — far below Tokio's 512 default cap).
//!
//! ## The handoff (the P4-J3 scheduler-local-invariant chain of custody)
//!
//! A blocking episode moves a process's ownership core → pool → core, each
//! transfer carrying a happens-before edge so the process's non-atomic state
//! (manager/heap/refcounts/stack) is touched by exactly ONE thread at a time:
//!
//! ```
//!   core: fiber yields .blocking_offload → runQuantum transitions .blocking,
//!         submit(record)  ───────────── RELEASE (state_lock) ─────────────┐
//!                                                                          v
//!   pool: worker pops record ── ACQUIRE (state_lock) ── runBlockingPhase   │
//!         (resumes the fiber; the op runs on THIS thread, into the         │
//!          process's own heap) → reattachFromBlocking(record)              │
//!                              ── RELEASE (reattach_stack) ───────────────┐│
//!                                                                         vv
//!   core: drainReattachStack ── ACQUIRE ── .blocking → .runnable → run
//! ```
//!
//! The pool NEVER touches a process's manager/refcounts concurrently with a
//! core: `submit` is the offloading core's LAST touch of the record, and the
//! re-attach push is the pool worker's LAST touch. This is the invariant the
//! P4-J3 ThreadSanitizer harness (`mn_refcount_stress.zig`) proves by
//! measurement.
//!
//! ## Decoupling
//!
//! The pool is a generic "run submitted `ProcessRecord`s on worker threads"
//! primitive: what a worker DOES with a record is the injectable `execute`
//! hook. The real hook (`scheduler.blockingPoolExecute`) resumes the fiber and
//! re-attaches; unit tests inject a self-contained hook to exercise the queue /
//! park / growth mechanics without real fibers. So this module imports
//! `scheduler.zig` only for the `ProcessRecord` type (and the `blocking_next`
//! intrusive link) — a one-directional dependency, no import cycle (the
//! scheduler references the pool only through the opaque `BlockingHandoff`).

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const futex = @import("futex.zig");

const ProcessRecord = scheduler_module.ProcessRecord;
const BlockingHandoff = scheduler_module.BlockingHandoff;

/// What a worker does with one popped record: run its blocking phase and
/// re-attach it (the real hook is `scheduler.blockingPoolExecute`; tests inject
/// a self-contained one). Runs on the worker's own OS thread and stack.
pub const ExecuteFn = *const fn (execute_context: ?*anyopaque, record: *ProcessRecord) void;

/// Default eager-started worker count (see the module doc's sizing policy).
pub const default_initial_thread_count: usize = 1;

/// Default upper bound on grown worker threads (bounds blocking parallelism;
/// excess concurrent blocks queue FIFO). Well below Tokio's 512 default.
pub const default_max_thread_count: usize = 64;

/// Default bound on one worker futex park (defense-in-depth re-check period; the
/// eventcount protocol needs no timeout for correctness).
pub const default_park_timeout_nanoseconds: u64 = 100 * std.time.ns_per_ms;

/// The blocking / dirty-scheduler pool. Pinned after `init` (its worker threads
/// hold `pool` back-pointers), so construct it in place at its final address.
pub const BlockingPool = struct {
    /// Backing allocator for the worker-thread array. Owned.
    allocator: std.mem.Allocator,
    /// What a worker does with a popped record (module doc). Set at `init`.
    execute: ExecuteFn,
    /// Opaque context forwarded to every `execute` call.
    execute_context: ?*anyopaque,
    /// Worker OS threads. Capacity `max_thread_count`; `[0..started_thread_count)`
    /// are slots. Optional so a growth `submit` can RESERVE a slot (null) under
    /// the lock, drop the lock to run `std.Thread.spawn` (mmap+clone) OFF the
    /// lock (DEFER #6), then publish the handle — a slot whose spawn failed, or a
    /// reservation not yet published, reads null and is skipped at join. Owned.
    threads: []?std.Thread,

    /// Guards the submit queue and the worker-population counters. A
    /// `std.atomic.Mutex` spinlock by kernel convention (no libc-coupled
    /// `std.Thread.Mutex`); every critical section is O(1) queue-pointer surgery,
    /// except the rare growth spawn (bounded to `max_thread_count` times over the
    /// pool's whole life — submit is not a hot path).
    state_lock: std.atomic.Mutex,
    /// Intrusive FIFO of submitted records (linked via `ProcessRecord.blocking_next`).
    /// Oldest.
    queue_head: ?*ProcessRecord,
    /// Newest.
    queue_tail: ?*ProcessRecord,
    /// Queue length (records submitted, not yet popped by a worker).
    queue_len: usize,
    /// Worker threads started (`≤ max_thread_count`). Written only by `init` and
    /// `submit`-growth (never by a worker); read under `state_lock`.
    started_thread_count: usize,
    /// Workers currently running an `execute` (a blocking phase in flight). Part
    /// of the demand metric (`queue_len + inflight_count`) `submit` grows on.
    inflight_count: usize,

    /// Eventcount workers park on: `submit` bumps it (and futex-wakes one) after
    /// enqueuing; `deinit` bumps it (and wakes all) after setting `stopping`. A
    /// worker reads it under `state_lock` after seeing the queue empty, so a
    /// submit that races the park is never lost.
    work_epoch: std.atomic.Value(u32),
    /// Eventcount a `quiesce` waiter parks on: a worker bumps it (and wakes)
    /// when it finishes the LAST in-flight item with an empty queue.
    idle_epoch: std.atomic.Value(u32),
    /// Set by `deinit`: workers observe it (via the `work_epoch` wake) and exit.
    stopping: std.atomic.Value(bool),

    /// Max worker threads (grow ceiling).
    max_thread_count: usize,
    /// Bound on one worker futex park.
    park_timeout_nanoseconds: u64,

    // -- counters (thread-safe observability) --------------------------------
    /// Records submitted (offloads accepted).
    submit_total: std.atomic.Value(u64),
    /// Blocking phases executed to completion.
    execute_total: std.atomic.Value(u64),
    /// Worker futex parks entered (proves no busy-wait when idle).
    park_total: std.atomic.Value(u64),
    /// High-watermark of `started_thread_count` (read under `state_lock`).
    peak_thread_count: usize,

    /// Construction options.
    pub const Options = struct {
        /// Workers eager-started at `init` (module doc). Clamped to
        /// `[0, max_thread_count]`; 0 means fully lazy (then `isLive()` is false
        /// until a growth spawn succeeds — the offload seam checks it).
        initial_thread_count: usize = default_initial_thread_count,
        /// Grow ceiling.
        max_thread_count: usize = default_max_thread_count,
        /// Bound on one worker futex park.
        park_timeout_nanoseconds: u64 = default_park_timeout_nanoseconds,
    };

    /// Initialize the pool in place and eager-start `initial_thread_count`
    /// workers (which park immediately — there is no work yet). On a worker
    /// spawn failure the eager start stops early; the pool is still valid but
    /// may be `!isLive()` (see `isLive`). Allocates only the worker-thread
    /// array.
    pub fn init(
        pool: *BlockingPool,
        allocator: std.mem.Allocator,
        execute: ExecuteFn,
        execute_context: ?*anyopaque,
        options: Options,
    ) error{OutOfMemory}!void {
        const max = @max(options.max_thread_count, 1);
        const initial = @min(options.initial_thread_count, max);
        const threads = allocator.alloc(?std.Thread, max) catch return error.OutOfMemory;
        @memset(threads, null);

        pool.* = .{
            .allocator = allocator,
            .execute = execute,
            .execute_context = execute_context,
            .threads = threads,
            .state_lock = .unlocked,
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
            .execute_total = .init(0),
            .park_total = .init(0),
            .peak_thread_count = 0,
        };

        // Eager-start the initial workers. They immediately park (empty queue).
        // `started_thread_count` is written only here and by `submit`-growth,
        // never by a worker, and `init` is not concurrent with `submit`, so no
        // lock is needed for these writes.
        var started: usize = 0;
        while (started < initial) : (started += 1) {
            pool.threads[started] = std.Thread.spawn(.{}, workerEntry, .{pool}) catch break;
        }
        pool.started_thread_count = started;
        pool.peak_thread_count = started;
    }

    /// Whether the pool has at least one worker — the offload seam
    /// (`SchedulerPool`) wires the `BlockingHandoff` only when the pool is live,
    /// so a pool that could not start any worker degrades to inline blocking
    /// rather than stranding an offloaded record with no thread to run it.
    pub fn isLive(pool: *BlockingPool) bool {
        pool.lockState();
        defer pool.unlockState();
        return pool.started_thread_count > 0;
    }

    /// The opaque handoff seam the scheduler classifies `.blocking_offload`
    /// through (`scheduler.BlockingHandoff`), pointing at THIS pool. Store the
    /// returned value at a stable address and hand `&it` to `Scheduler.Options`.
    pub fn handoff(pool: *BlockingPool) BlockingHandoff {
        return .{ .context = pool, .submit = submitTrampoline };
    }

    fn submitTrampoline(context: ?*anyopaque, record: *ProcessRecord) void {
        const pool: *BlockingPool = @ptrCast(@alignCast(context.?));
        pool.submit(record);
    }

    /// Spin-acquire the state spinlock. The fork's `std.atomic.Mutex` exposes
    /// only `tryLock`/`unlock` (a lock-free single-owner word), so a blocking
    /// acquire is a `tryLock` spin — exactly as the scheduler's `lockRunQueue`
    /// does. Critical sections are O(1) queue-pointer surgery (plus the rare,
    /// bounded growth spawn), so contention is brief.
    inline fn lockState(pool: *BlockingPool) void {
        while (!pool.state_lock.tryLock()) std.atomic.spinLoopHint();
    }

    inline fn unlockState(pool: *BlockingPool) void {
        pool.state_lock.unlock();
    }

    /// Accept an offloaded record (its fiber suspended at its `.blocking_offload`
    /// point) onto the pool: enqueue it FIFO, grow a worker if none is idle to
    /// take it and there is room, and wake a parked worker. The enqueue under
    /// `state_lock` is the RELEASE edge of the core → pool handoff (the module
    /// doc's chain of custody). Called on the offloading core's thread.
    pub fn submit(pool: *BlockingPool, record: *ProcessRecord) void {
        record.blocking_next = null;
        pool.lockState();
        // Enqueue FIFO.
        if (pool.queue_tail) |tail| {
            tail.blocking_next = record;
        } else {
            pool.queue_head = record;
        }
        pool.queue_tail = record;
        pool.queue_len += 1;
        _ = pool.submit_total.fetchAdd(1, .monotonic);
        // Grow when DEMAND (queued + in-flight ops) exceeds the worker count and
        // there is room below the cap. Demand — not "is any worker idle?" — is
        // the race-free trigger: a worker that a prior submit woke but that has
        // not yet dequeued is momentarily neither idle nor in-flight, so an
        // idle-count test would leave a second concurrent block un-served
        // (serialized behind that one woken worker). `queue_len + inflight_count
        // > started_thread_count` grows exactly when the existing workers cannot
        // cover the outstanding blocks, giving true dirty-scheduler parallelism.
        //
        // RESERVE the slot here but SPAWN below, OFF the lock (DEFER #6):
        // `std.Thread.spawn` does mmap+clone, and holding `state_lock` (a
        // spinlock) across that syscall would stall every concurrent submit and
        // every worker's post-drain re-check on the spin for the whole spawn.
        // Bumping `started_thread_count` at reservation (not at publish) makes a
        // concurrent submit see the slot as provisioned so it does not
        // double-grow for the same demand; the slot reads null until the handle
        // is published. Growth is rare (bounded to `max_thread_count` over the
        // pool's life; workers persist), so the extra lock round-trip is cheap.
        const reserved_index: ?usize = blk: {
            if (pool.queue_len + pool.inflight_count > pool.started_thread_count and
                pool.started_thread_count < pool.max_thread_count)
            {
                const index = pool.started_thread_count;
                pool.threads[index] = null; // reserved; published below or rolled back
                pool.started_thread_count += 1;
                if (pool.started_thread_count > pool.peak_thread_count) {
                    pool.peak_thread_count = pool.started_thread_count;
                }
                break :blk index;
            }
            break :blk null;
        };
        pool.unlockState();

        // Spawn OFF the lock, then re-lock only to publish the handle. A spawn
        // failure is non-fatal — the record is served by an existing worker (the
        // pool is live ⇒ ≥1 worker exists) — but the reservation must be released
        // so it does not permanently lower the grow ceiling: reclaim it when ours
        // is still the last slot; otherwise a concurrent grow already took a later
        // slot, so leave this one null (join skips it) rather than open a hole.
        if (reserved_index) |index| {
            const spawned: ?std.Thread = std.Thread.spawn(.{}, workerEntry, .{pool}) catch null;
            pool.lockState();
            if (spawned) |thread| {
                pool.threads[index] = thread;
            } else {
                if (index == pool.started_thread_count - 1) {
                    pool.started_thread_count -= 1;
                }
                pool.threads[index] = null;
            }
            pool.unlockState();
        }
        // Wake a parked worker (eventcount): bump the epoch a parked worker read
        // under the lock, then futex-wake one. A worker that read the epoch and
        // is about to wait sees the bump and re-checks instead of sleeping — no
        // lost wakeup across the submit/park race.
        _ = pool.work_epoch.fetchAdd(1, .seq_cst);
        futex.wakeOne(&pool.work_epoch);
    }

    /// Block the CALLING thread until the pool has no queued and no in-flight
    /// work — every accepted blocking op has finished and re-attached. Called by
    /// the `SchedulerPool` after its core workers stop, so no blocking episode is
    /// still executing on a pool thread when stragglers are reaped. A no-op when
    /// the pool is already idle. Must not be called concurrently with `submit`
    /// (the caller has stopped every offloading core).
    pub fn quiesce(pool: *BlockingPool) void {
        while (true) {
            pool.lockState();
            const done = pool.queue_len == 0 and pool.inflight_count == 0;
            // Read the eventcount UNDER the lock so a worker that finishes the
            // last item between here and the wait bumps it and we re-check.
            const observed = pool.idle_epoch.load(.seq_cst);
            pool.unlockState();
            if (done) return;
            futex.waitBounded(&pool.idle_epoch, observed, pool.park_timeout_nanoseconds);
        }
    }

    /// Stop and join every worker, then free the thread array. Quiesces first
    /// (any in-flight blocking op runs to completion — native code is never
    /// interrupted). Must be called after every offloading core has stopped
    /// (single-threaded w.r.t. `submit`). After it returns the pool is
    /// `undefined`.
    pub fn deinit(pool: *BlockingPool) void {
        pool.quiesce();
        pool.stopping.store(true, .release);
        pool.wakeAllWorkers();
        pool.lockState();
        const live = pool.started_thread_count;
        pool.unlockState();
        // Skip null slots: a reservation whose spawn failed (DEFER #6) leaves a
        // null in `[0..started_thread_count)`. `deinit` runs after every core has
        // stopped, so no reservation is still in flight here.
        for (pool.threads[0..live]) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }
        pool.allocator.free(pool.threads);
        pool.* = undefined;
    }

    /// Statistics snapshot (thread-safe reads; `peak_thread_count` under lock).
    pub const Statistics = struct {
        submit_total: u64,
        execute_total: u64,
        park_total: u64,
        started_thread_count: usize,
        peak_thread_count: usize,
        queue_len: usize,
        inflight_count: usize,
    };

    pub fn statistics(pool: *BlockingPool) Statistics {
        pool.lockState();
        defer pool.unlockState();
        return .{
            .submit_total = pool.submit_total.load(.monotonic),
            .execute_total = pool.execute_total.load(.monotonic),
            .park_total = pool.park_total.load(.monotonic),
            .started_thread_count = pool.started_thread_count,
            .peak_thread_count = pool.peak_thread_count,
            .queue_len = pool.queue_len,
            .inflight_count = pool.inflight_count,
        };
    }

    // -------------------------------------------------------------------------
    // Worker
    // -------------------------------------------------------------------------

    fn workerEntry(pool: *BlockingPool) void {
        pool.workerLoop();
    }

    fn workerLoop(pool: *BlockingPool) void {
        while (true) {
            pool.lockState();
            if (pool.dequeueLocked()) |record| {
                pool.inflight_count += 1;
                pool.unlockState();

                // Run the blocking phase + re-attach (the injected hook). Runs
                // OFF the lock — this is the whole point: the (possibly long)
                // blocking op does not hold any pool lock.
                pool.execute(pool.execute_context, record);
                _ = pool.execute_total.fetchAdd(1, .monotonic);

                pool.lockState();
                pool.inflight_count -= 1;
                const now_quiescent = pool.queue_len == 0 and pool.inflight_count == 0;
                pool.unlockState();
                if (now_quiescent) pool.signalQuiescent();
                continue;
            }
            // Queue empty.
            if (pool.stopping.load(.acquire)) {
                pool.unlockState();
                return;
            }
            // Park on the eventcount: read the epoch UNDER the lock (after
            // seeing empty), then unlock and wait. A submit/stop that bumps the
            // epoch after this read makes the wait return at once — no lost
            // wakeup across the empty-check/park race.
            const observed = pool.work_epoch.load(.seq_cst);
            pool.unlockState();
            _ = pool.park_total.fetchAdd(1, .monotonic);
            futex.waitBounded(&pool.work_epoch, observed, pool.park_timeout_nanoseconds);
        }
    }

    /// Pop the oldest queued record, or null. Caller holds `state_lock`.
    fn dequeueLocked(pool: *BlockingPool) ?*ProcessRecord {
        const record = pool.queue_head orelse return null;
        pool.queue_head = record.blocking_next;
        if (pool.queue_tail == record) pool.queue_tail = null;
        record.blocking_next = null;
        pool.queue_len -= 1;
        return record;
    }

    /// Signal a `quiesce` waiter that the pool went idle (empty queue, no
    /// in-flight work): bump the idle eventcount and futex-wake the waiter.
    fn signalQuiescent(pool: *BlockingPool) void {
        _ = pool.idle_epoch.fetchAdd(1, .seq_cst);
        futex.wakeOne(&pool.idle_epoch);
    }

    /// Wake every parked worker (stop path): bump the work eventcount, then
    /// futex-wake one per started worker so each returns and observes `stopping`.
    fn wakeAllWorkers(pool: *BlockingPool) void {
        _ = pool.work_epoch.fetchAdd(1, .seq_cst);
        pool.lockState();
        const live = pool.started_thread_count;
        pool.unlockState();
        var woken: usize = 0;
        while (woken < live) : (woken += 1) futex.wakeOne(&pool.work_epoch);
    }
};

// ---------------------------------------------------------------------------
// Tests — pool mechanics with an injected self-contained execute hook (no real
// fibers; the end-to-end fiber-evacuation path is proven in `scheduler_pool.zig`
// and `mn_refcount_stress.zig`). The queue only touches `record.blocking_next`,
// so bare (otherwise-`undefined`) `ProcessRecord`s suffice as work items.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test execute hook: bumps a shared atomic counter. No fiber, no re-attach —
/// this exercises the pool's queue / wake / growth / quiesce machinery alone.
const CountingExecute = struct {
    executed: std.atomic.Value(u64) = .init(0),
    /// Optional busy-block per execute (nanoseconds), to force concurrency and
    /// thus growth. Spins on the monotonic clock (no scheduler dependency).
    busy_nanoseconds: u64 = 0,

    fn run(context: ?*anyopaque, record: *ProcessRecord) void {
        _ = record;
        const self: *CountingExecute = @ptrCast(@alignCast(context.?));
        if (self.busy_nanoseconds > 0) {
            const deadline = nowNanoseconds() + self.busy_nanoseconds;
            while (nowNanoseconds() < deadline) std.atomic.spinLoopHint();
        }
        _ = self.executed.fetchAdd(1, .monotonic);
    }
};

fn nowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Allocate `count` bare work-item records (only `blocking_next` is touched).
fn allocRecords(count: usize) ![]ProcessRecord {
    const records = try testing.allocator.alloc(ProcessRecord, count);
    for (records) |*record| record.blocking_next = null;
    return records;
}

test "BlockingPool: every submitted record is executed exactly once, then quiesces and joins clean" {
    var counter = CountingExecute{};
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, CountingExecute.run, &counter, .{});
    defer pool.deinit();

    const records = try allocRecords(200);
    defer testing.allocator.free(records);

    for (records) |*record| pool.submit(record);
    pool.quiesce();

    try testing.expectEqual(@as(u64, 200), counter.executed.load(.monotonic));
    const stats = pool.statistics();
    try testing.expectEqual(@as(u64, 200), stats.submit_total);
    try testing.expectEqual(@as(u64, 200), stats.execute_total);
    try testing.expectEqual(@as(usize, 0), stats.queue_len);
    try testing.expectEqual(@as(usize, 0), stats.inflight_count);
    // The pool started at least the eager worker and never exceeded the cap.
    try testing.expect(stats.started_thread_count >= 1);
    try testing.expect(stats.started_thread_count <= default_max_thread_count);
}

test "BlockingPool: concurrent blocking work grows the pool beyond its initial worker (dirty-scheduler parallelism)" {
    // Each op busy-blocks ~1 ms, so a burst of submissions with only one idle
    // worker forces the pool to GROW additional workers to make progress in
    // parallel — the dirty-scheduler-equivalent behaviour.
    var counter = CountingExecute{ .busy_nanoseconds = std.time.ns_per_ms };
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, CountingExecute.run, &counter, .{
        .initial_thread_count = 1,
        .max_thread_count = 8,
    });
    defer pool.deinit();

    const records = try allocRecords(32);
    defer testing.allocator.free(records);

    for (records) |*record| pool.submit(record);
    pool.quiesce();

    try testing.expectEqual(@as(u64, 32), counter.executed.load(.monotonic));
    // With one initial worker and 1 ms ops, the pool must have grown to keep up.
    const stats = pool.statistics();
    try testing.expect(stats.peak_thread_count > 1);
    try testing.expect(stats.peak_thread_count <= 8);
}

test "BlockingPool: quiesce waits for an in-flight op to complete" {
    var counter = CountingExecute{ .busy_nanoseconds = 5 * std.time.ns_per_ms };
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, CountingExecute.run, &counter, .{});
    defer pool.deinit();

    var record: ProcessRecord = undefined;
    record.blocking_next = null;
    pool.submit(&record);
    // quiesce must not return until the (5 ms) op has finished executing.
    pool.quiesce();
    try testing.expectEqual(@as(u64, 1), counter.executed.load(.monotonic));
}

test "BlockingPool: idle workers PARK on the futex (no busy-wait) and a later submit wakes one" {
    var counter = CountingExecute{};
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, CountingExecute.run, &counter, .{
        .initial_thread_count = 2,
    });
    defer pool.deinit();

    // Give the eager workers a moment to reach their park. Then a submit must
    // wake one to run the work — proving the wake path across a genuine park.
    var settle: u64 = 0;
    while (pool.statistics().park_total < 2 and settle < 1_000_000) : (settle += 1) {
        std.atomic.spinLoopHint();
    }
    try testing.expect(pool.statistics().park_total >= 1);

    var record: ProcessRecord = undefined;
    record.blocking_next = null;
    pool.submit(&record);
    pool.quiesce();
    try testing.expectEqual(@as(u64, 1), counter.executed.load(.monotonic));
}

test "BlockingPool: a lazily-started pool (zero initial workers) grows on first submit and stays live" {
    var counter = CountingExecute{};
    var pool: BlockingPool = undefined;
    try BlockingPool.init(&pool, testing.allocator, CountingExecute.run, &counter, .{
        .initial_thread_count = 0,
        .max_thread_count = 4,
    });
    defer pool.deinit();

    // No eager worker: not live until the first submit grows one.
    try testing.expectEqual(false, pool.isLive());

    const records = try allocRecords(16);
    defer testing.allocator.free(records);
    for (records) |*record| pool.submit(record);
    pool.quiesce();

    try testing.expectEqual(@as(u64, 16), counter.executed.load(.monotonic));
    try testing.expectEqual(true, pool.isLive());
}
