//! M:N work-stealing scheduler pool for the Zap concurrency kernel.
//!
//! Phase 4 item 4.1 of `docs/concurrency-implementation-plan.md` (job P4-J1),
//! realizing research.md §6.1's now-standard M:N design (Go GMP / Tokio / zio):
//! one scheduler thread per core, per-core run queues with a LIFO slot for the
//! just-woken task, a global overflow queue for spillover, work stealing when a
//! core's local queue empties, and netpoller-style parking when idle. This
//! module is the ORCHESTRATION over the already-instance-based `Scheduler`
//! (`scheduler.zig`): it multiplies scheduler instances over the shared,
//! already-M:N-safe `PidTable` and `EnvelopePool`, exactly as the Phase-1
//! kernel was built to allow (that kernel has no module-level mutable state).
//!
//! ## The sacred scheduler-local invariant, now genuinely parallel
//!
//! Each process's manager/heap/refcounts are touched by only ONE scheduler
//! thread at a time — the one running its quantum. The ONLY cross-thread atomics
//! in the whole system are the mailbox queue links (`mailbox.zig`), the
//! envelope-pool page ownership (`envelope_pool.zig`), the pid-table slots
//! (`pid_table.zig`), the run-queue/steal machinery + LIFO handshake
//! (`scheduler.zig`), and the wake signals — NEVER a payload refcount. A wake
//! (`park_state` handshake) and a steal (`stealInto`) each carry a
//! happens-before edge that orders one scheduler's quantum for a process
//! strictly before the next scheduler's quantum for that same process, so the
//! non-atomic per-process state a quantum touches is single-threaded by
//! construction. Since P4-R1 added the `__tsan_switch_to_fiber` annotations
//! that let ThreadSanitizer follow the kernel's manual fiber context switches,
//! the P4 TSan harnesses RUN this invariant end-to-end — the marquee
//! `-fsanitize-thread` suite passes with ZERO findings, where before R1 TSan
//! faulted on the switch and could not observe it at all.
//!
//! ## Threading model
//!
//! `run` starts N−1 worker OS threads (cores 1..N−1) and runs core 0's worker
//! loop on the CALLING (driver) thread, so the driver's pre-run spawn of the
//! root process and core 0's quanta share one thread (that handoff needs no
//! lock). Each core's RECORD CACHE stays strictly owner-only — a finished
//! process's record recycles to the OWN cache of whichever core tore it down,
//! never another's. The per-scheduler STACK POOL, by contrast, IS touched
//! cross-thread under work stealing: a process stolen from its origin core
//! exits on another core, whose `resumeFiber` releases the stack back to the
//! ORIGIN pool — which is exactly why the stack pool takes its spinlock when
//! `work_stealing` (`StackPool.thread_safe`), keeping the origin pool's counters
//! exact. Subsequent spawns are in-process (on the running core). When the root
//! process exits
//! (Erlang halt model: the program's lifetime is the root's lifetime) every
//! core is signalled to stop; after the workers join, the driver reaps every
//! straggler single-threaded and the pool is `deinit`-able.
//!
//! ## Worker loop (per core)
//!
//! ```
//!   while not stopping:
//!     service cross-thread events (drain wake stack → runnable; fire timeouts)
//!     ├─ local runnable? (LIFO slot then FIFO) → run one quantum, loop
//!     ├─ global overflow queue non-empty?      → run one quantum, loop
//!     ├─ steal half of a random sibling's FIFO → loop
//!     └─ nothing anywhere: park on the futex (spin-then-sleep), woken by a
//!        mailbox push to one of this core's processes, a sibling's new-work
//!        notification, or the stop signal — never a busy-wait.
//! ```
//!
//! ## Determinism
//!
//! The seeded deterministic mode (`deterministic.zig`) is single-threaded and
//! forbids parking; it drives a standalone `Scheduler`, NOT this pool. The pool
//! never participates in a deterministic run — multi-scheduler seeded sweeps are
//! job P4-J4. A pool of one core is still a legal, fully-functional M:N pool
//! (no worker threads; the driver runs core 0), which is what the concurrency
//! runtime falls back to when the platform cannot spawn threads.

const std = @import("std");
const builtin = @import("builtin");
const scheduler_module = @import("scheduler.zig");
const blocking_pool_module = @import("blocking_pool.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const process_module = @import("process.zig");

const Scheduler = scheduler_module.Scheduler;
const ProcessRecord = scheduler_module.ProcessRecord;
const GlobalRunQueue = scheduler_module.GlobalRunQueue;
const PoolHooks = scheduler_module.PoolHooks;
const BlockingHandoff = scheduler_module.BlockingHandoff;
const BlockingPool = blocking_pool_module.BlockingPool;
const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;

/// Default number of scheduler cores: one per logical CPU, the standard M:N
/// mapping (Go's `GOMAXPROCS` default, BEAM's `+S` default). Clamped to at
/// least one. A caller may override via `Options.scheduler_count`.
pub fn defaultSchedulerCount() usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(cpu_count, 1);
}

/// The M:N work-stealing scheduler pool. Pinned after `init` (its cores hold
/// `&pool.hooks`/`&pool.global_queue`, and each core is itself pinned after its
/// first spawn), so construct it in place at its final address.
pub const SchedulerPool = struct {
    /// Backing allocator for the core array, the worker-thread array, and every
    /// core's record cache (records are freed only at `deinit`).
    allocator: std.mem.Allocator,
    /// The shared (M:N-safe) pid table. Not owned.
    pid_table: *PidTable,
    /// The shared (M:N-safe) envelope reservoir. Not owned.
    envelope_pool: *EnvelopePool,
    /// The per-core schedulers, one per core. Heap-allocated so the array is
    /// stable (cores are pinned). Owned.
    cores: []Scheduler,
    /// The global overflow queue (research.md §6.1). Shared by every core.
    global_queue: GlobalRunQueue,
    /// The orchestration seam installed into every core (see `PoolHooks`).
    /// `context` is this pool; pinned for the pool's lifetime.
    hooks: PoolHooks,
    /// The shared blocking / dirty-scheduler pool (P4-J3, `blocking_pool.zig`):
    /// ONE pool serving every core, onto which a `Process.blocking` call
    /// evacuates the calling process's fiber so the core is freed. Owned;
    /// pinned (its worker threads hold `&pool.blocking_pool`).
    blocking_pool: BlockingPool,
    /// The blocking handoff seam installed into every core (the offload path).
    /// Points at `blocking_pool`; pinned for the pool's lifetime. A core's
    /// `Options.blocking_handoff` is `&pool.blocking_handoff` when the blocking
    /// pool is live, else null (inline degradation).
    blocking_handoff: BlockingHandoff,
    /// Worker OS threads for cores 1..N−1 (core 0 runs on the driver thread).
    /// Empty for a single-core pool. Owned.
    worker_threads: []std.Thread,
    /// Pool-wide count of live processes (spawned, not yet torn down). The
    /// authoritative count under M:N — a per-core count would drift because a
    /// stolen process is spawned on one core and torn down on another. Signed
    /// so an intermediate observation is always well-defined; conserved to zero.
    live_count: std.atomic.Value(i64),
    /// Number of workers currently parked (netpoller). Read by `wakeOneIdle` to
    /// skip the wake scan when every core is busy.
    idle_count: std.atomic.Value(usize),
    /// Set to stop every worker loop: the root exited (root mode) or the pool
    /// went quiescent (quiescent mode). Workers observe it each iteration and on
    /// every park wake.
    stopping: std.atomic.Value(bool),
    /// The root process's raw pid bits in root mode (0 ⇒ quiescent mode). When a
    /// process with these bits completes teardown the pool stops (Erlang halt).
    root_target_bits: u64,

    /// Construction options.
    pub const Options = struct {
        /// Number of scheduler cores. Null ⇒ `defaultSchedulerCount()` (one per
        /// CPU). Clamped to at least one.
        scheduler_count: ?usize = null,
        /// Per-core scheduler options (budget, spin/park tuning, stack size,
        /// trace/crash hooks). `work_stealing`, `pool_hooks`, and `global_queue`
        /// are set by the pool and must be left at their defaults here.
        core_options: Scheduler.Options = .{},
    };

    /// Initialize the pool in place over a shared pid table and envelope pool.
    /// Allocates the core array and the worker-thread array; each core's stack
    /// pool and record cache grow lazily. Does NOT start any thread — `run`
    /// does. On failure the pool is left uninitialized and any partial
    /// allocation is released.
    pub fn init(
        pool: *SchedulerPool,
        allocator: std.mem.Allocator,
        pid_table: *PidTable,
        envelope_pool: *EnvelopePool,
        options: Options,
    ) error{OutOfMemory}!void {
        const requested = options.scheduler_count orelse defaultSchedulerCount();
        const core_count = @max(requested, 1);

        const cores = allocator.alloc(Scheduler, core_count) catch return error.OutOfMemory;
        errdefer allocator.free(cores);
        const worker_threads = allocator.alloc(std.Thread, core_count - 1) catch return error.OutOfMemory;
        errdefer allocator.free(worker_threads);

        pool.* = .{
            .allocator = allocator,
            .pid_table = pid_table,
            .envelope_pool = envelope_pool,
            .cores = cores,
            .global_queue = GlobalRunQueue.init(),
            .hooks = .{
                .context = pool,
                .liveCountDelta = liveCountDeltaHook,
                .notifyWork = notifyWorkHook,
                .onProcessExit = onProcessExitHook,
            },
            .blocking_pool = undefined,
            .blocking_handoff = undefined,
            .worker_threads = worker_threads,
            .live_count = .init(0),
            .idle_count = .init(0),
            .stopping = .init(false),
            .root_target_bits = 0,
        };

        // Bring up the shared blocking / dirty-scheduler pool AFTER `pool.*` is
        // set so `&pool.blocking_pool` is its final address (its workers pin it),
        // then build its handoff seam. `Scheduler.blockingPoolExecute` is the
        // real execute hook: a worker resumes the offloaded fiber, runs the
        // blocking op, and re-attaches it. OOM here unwinds the core/worker
        // arrays via the errdefers above.
        try BlockingPool.init(
            &pool.blocking_pool,
            allocator,
            Scheduler.blockingPoolExecute,
            null,
            .{},
        );
        pool.blocking_handoff = pool.blocking_pool.handoff();

        // Build each core AFTER `pool.*` is set so `&pool.hooks`/
        // `&pool.global_queue`/`&pool.blocking_handoff` are their final
        // addresses. The blocking handoff is wired only when the pool is live
        // (has ≥1 worker); if it could not start any, cores leave it null and a
        // `Process.blocking` call degrades to inline (documented).
        var core_options = options.core_options;
        core_options.work_stealing = true;
        core_options.pool_hooks = &pool.hooks;
        core_options.global_queue = &pool.global_queue;
        core_options.blocking_handoff = if (pool.blocking_pool.isLive()) &pool.blocking_handoff else null;
        for (pool.cores) |*core| {
            core.* = Scheduler.init(allocator, pid_table, envelope_pool, core_options);
        }
    }

    /// Tear the pool down: every process must already have been reaped (`run`
    /// leaves the pool quiescent). Frees each core, the core array, and the
    /// worker-thread array.
    pub fn deinit(pool: *SchedulerPool) void {
        std.debug.assert(pool.live_count.load(.acquire) == 0);
        std.debug.assert(pool.global_queue.isEmptyApprox());
        // Stop and join the blocking-pool workers FIRST, so no blocking-pool
        // thread can touch a core (via re-attach) after the cores are freed. By
        // here every blocking episode has quiesced (`drive` quiesces at run end)
        // and every re-attach has been drained (`shutdownAllProcesses`), so this
        // only joins idle, parked workers.
        pool.blocking_pool.deinit();
        for (pool.cores) |*core| core.deinit();
        pool.allocator.free(pool.cores);
        pool.allocator.free(pool.worker_threads);
        pool.* = undefined;
    }

    /// The core the driver spawns the root process onto (core 0). The driver
    /// thread runs core 0's worker loop, so this spawn and core 0's quanta share
    /// one thread — core 0's stack pool and record cache are never raced.
    pub fn primaryCore(pool: *SchedulerPool) *Scheduler {
        return &pool.cores[0];
    }

    /// Number of scheduler cores.
    pub fn coreCount(pool: *const SchedulerPool) usize {
        return pool.cores.len;
    }

    /// Snapshot of the pool-wide live-process count (observability/tests).
    pub fn liveProcessCount(pool: *const SchedulerPool) i64 {
        return pool.live_count.load(.acquire);
    }

    /// Pool-wide statistics: the authoritative live count plus the per-core
    /// counters summed across every core (spawn/exit/kill totals are recorded on
    /// whichever core performed the operation, so the pool total is their sum).
    pub const Statistics = struct {
        live_process_count: i64,
        spawn_total: u64,
        normal_exit_total: u64,
        kill_total: u64,
        quantum_total: u64,
        unexpected_message_total: u64,
        park_count: u64,
        wake_signal_count: u64,
        /// `Process.blocking` evacuations to the blocking pool (P4-J3), summed
        /// across cores (whichever core offloaded counts it).
        blocking_offload_total: u64,
        /// Blocking-pool re-attaches drained back to runnable (P4-J3), summed
        /// across cores (whichever core the process re-attached onto counts it).
        blocking_reattach_total: u64,
    };

    pub fn statistics(pool: *const SchedulerPool) Statistics {
        var totals = Statistics{
            .live_process_count = pool.liveProcessCount(),
            .spawn_total = 0,
            .normal_exit_total = 0,
            .kill_total = 0,
            .quantum_total = 0,
            .unexpected_message_total = 0,
            .park_count = 0,
            .wake_signal_count = 0,
            .blocking_offload_total = 0,
            .blocking_reattach_total = 0,
        };
        for (pool.cores) |*core| {
            const core_stats = core.statistics();
            totals.spawn_total += core_stats.spawn_total;
            totals.normal_exit_total += core_stats.normal_exit_total;
            totals.kill_total += core_stats.kill_total;
            totals.quantum_total += core_stats.quantum_total;
            totals.unexpected_message_total += core_stats.unexpected_message_total;
            totals.park_count += core_stats.park_count;
            totals.wake_signal_count += core_stats.wake_signal_count;
            totals.blocking_offload_total += core_stats.blocking_offload_total;
            totals.blocking_reattach_total += core_stats.blocking_reattach_total;
        }
        return totals;
    }

    /// Snapshot of the shared blocking / dirty-scheduler pool's statistics
    /// (P4-J3): submit/execute/park totals and the worker-population high-water
    /// mark. See `blocking_pool.BlockingPool.Statistics`.
    pub fn blockingPoolStatistics(pool: *SchedulerPool) BlockingPool.Statistics {
        return pool.blocking_pool.statistics();
    }

    // -------------------------------------------------------------------------
    // Running
    // -------------------------------------------------------------------------

    /// Run every core until the process `root` exits, then stop all cores, join
    /// the workers, and reap every straggler (Erlang halt model). The driver
    /// thread runs core 0; `root` may run on any core (stealing) — whichever
    /// core completes its teardown signals the stop. Returns with the pool
    /// quiescent and `deinit`-able.
    pub fn runUntilRootExits(pool: *SchedulerPool, root: Pid) void {
        pool.root_target_bits = root.toBits();
        pool.drive();
    }

    /// Run every core until the pool is quiescent (no live process), then stop,
    /// join, and reap. The multi-core analogue of `Scheduler.runUntilQuiescent`.
    pub fn runUntilQuiescent(pool: *SchedulerPool) void {
        pool.root_target_bits = 0;
        pool.drive();
    }

    fn drive(pool: *SchedulerPool) void {
        pool.stopping.store(false, .release);
        pool.idle_count.store(0, .release);

        // Start worker threads for cores 1..N−1. If a thread fails to spawn the
        // pool degrades to fewer cores (the already-started workers plus the
        // driver still make progress); the failed core simply never runs, and
        // its (empty) queues are reaped at shutdown.
        var started: usize = 0;
        for (pool.worker_threads, 1..) |*thread, core_index| {
            thread.* = std.Thread.spawn(.{}, workerEntry, .{ pool, core_index }) catch {
                break;
            };
            started += 1;
        }

        // Run core 0 on the driver thread.
        pool.workerLoop(0);

        // Core 0's loop returned ⇒ stopping is set (root exit / quiescence).
        // Make it unconditional and wake every parked worker so they exit too.
        pool.stopping.store(true, .release);
        pool.wakeAll();
        for (pool.worker_threads[0..started]) |thread| thread.join();
        // The core workers have joined. QUIESCE the blocking pool before
        // returning: a process that was mid-`Process.blocking` when the run
        // stopped has its op run to completion off-core (native code is never
        // interrupted) and re-attaches onto a — now stopped — core's reattach
        // stack. After this returns no blocking op is in flight, and every
        // re-attached straggler is on a core's reattach stack for
        // `shutdownAllProcesses` to drain and reap (Erlang halt).
        pool.blocking_pool.quiesce();
        // The workers have joined; the pool is single-threaded and STOPPED. In
        // quiescent mode nothing is live (the loop ran until the count hit
        // zero); in root mode the root's children remain as stragglers for
        // `shutdownAllProcesses` (Erlang halt — the ABI reaps them at deinit).
    }

    fn workerEntry(pool: *SchedulerPool, core_index: usize) void {
        pool.workerLoop(core_index);
    }

    /// One core's worker loop (research.md §6.1). Runs on core `core_index`'s
    /// own thread (the driver thread for core 0). Never busy-waits: when no work
    /// exists anywhere it parks on the futex.
    fn workerLoop(pool: *SchedulerPool, core_index: usize) void {
        const core = &pool.cores[core_index];
        core.beginRunThread();
        defer core.endRunThread();

        // Per-worker steal RNG (xorshift), distinct per core so thieves start
        // their victim scan at different offsets rather than all hammering
        // core 0.
        var steal_rng: u64 = (@as(u64, core_index) *% 0x9E3779B97F4A7C15) | 1;

        while (!pool.stopping.load(.acquire)) {
            // Root-mode termination is normally driven by `onProcessExit` when
            // the root's teardown completes, but the driver (core 0) ALSO polls
            // the pid table each iteration so the stop is observed even when the
            // root is ALREADY dead on entry (a second `runUntilRootExits` on a
            // finished root) or if the exit signal were ever missed — mirroring
            // the single-scheduler `runUntilProcessExits` loop-top `isAlive`
            // check. Cheap: one lock-free pid-table probe per iteration, driver
            // only.
            if (core_index == 0 and pool.root_target_bits != 0 and
                !pool.pid_table.isAlive(Pid.fromBits(pool.root_target_bits)))
            {
                pool.stopping.store(true, .release);
                pool.wakeAll();
                break;
            }

            // Convert freshly-woken processes to runnable and fire elapsed
            // `receive … after` deadlines for this core.
            core.serviceLocalEvents();

            // Local work first (LIFO slot then FIFO) — cache locality.
            if (core.takeLocalRunnable()) |record| {
                core.runNext(record);
                continue;
            }

            // Global overflow queue — O(1) shared surplus.
            if (pool.global_queue.pop()) |record| {
                core.runNext(record);
                continue;
            }

            // Steal half of a random sibling's FIFO.
            if (pool.tryStealFor(core, &steal_rng)) continue;

            // Nothing anywhere: park (netpoller). The re-check inside closes the
            // work-appeared-while-deciding race.
            pool.parkWorker(core, &steal_rng);
        }
    }

    /// Attempt to steal work into `thief` from a random sibling. Scans every
    /// other core once, starting at a per-thief random offset, and returns true
    /// as soon as one steal moves work. `Scheduler.stealInto` never holds two
    /// run-queue locks at once (it detaches under the victim lock, then splices
    /// under the thief lock), so no thief-pair can deadlock regardless of scan
    /// order.
    fn tryStealFor(pool: *SchedulerPool, thief: *Scheduler, steal_rng: *u64) bool {
        const n = pool.cores.len;
        if (n <= 1) return false;
        const start = randNext(steal_rng) % n;
        var offset: usize = 0;
        while (offset < n) : (offset += 1) {
            const victim = &pool.cores[(start + offset) % n];
            if (victim == thief) continue;
            if (victim.stealInto(thief) > 0) return true;
        }
        return false;
    }

    /// Park `core` until work appears or the pool stops. Registers the core as
    /// idle, re-checks every work source (its own queue, the global queue, and
    /// one more steal sweep) so it never sleeps while work is available, then
    /// parks on the core's futex (spin-then-sleep — no busy-wait). Woken by a
    /// mailbox push to one of the core's processes (`wake()`), a sibling's
    /// new-work notification (`wakeOneIdle`), or the stop signal (`wakeAll`).
    fn parkWorker(pool: *SchedulerPool, core: *Scheduler, steal_rng: *u64) void {
        _ = pool.idle_count.fetchAdd(1, .seq_cst);
        // Re-check under idle registration: work that appeared between the
        // loop's checks and here must not be slept through. A sibling that
        // enqueued after we registered idle will `wakeOneIdle` us; this closes
        // the earlier window.
        if (pool.stopping.load(.acquire) or
            core.hasLocalWork() or
            core.hasPendingReattach() or
            !pool.global_queue.isEmptyApprox() or
            pool.tryStealFor(core, steal_rng))
        {
            _ = pool.idle_count.fetchSub(1, .seq_cst);
            return;
        }
        core.parkForWork();
        _ = pool.idle_count.fetchSub(1, .seq_cst);
    }

    // -------------------------------------------------------------------------
    // Shutdown
    // -------------------------------------------------------------------------

    /// Reap every straggler, leaving the pool quiescent (`deinit`-able). MUST be
    /// called only after `run` has returned (workers joined — single-threaded).
    /// The runtime-shutdown path after a root-mode run, in which the root's
    /// still-live children are killed (Erlang halt model). A no-op after a
    /// quiescent-mode run (nothing is live). Drains each core's wake stack first
    /// so no stale wake entry references a record about to be recycled, then
    /// tears down every runnable process (per core and in the global queue) and
    /// every waiting process (via the pid table).
    pub fn shutdownAllProcesses(pool: *SchedulerPool) void {
        // Flush every core's cross-thread revive channels single-threaded (the
        // blocking pool is already quiesced by `drive`, so no new re-attach can
        // land): pending message wakes AND pending blocking-pool re-attaches, so
        // no straggler is missed and no stale entry references a record about to
        // recycle. A re-attach converts its process `.blocking → .runnable`, and
        // the reap sweep below tears it down.
        for (pool.cores) |*core| {
            core.drainPendingWakes();
            core.drainPendingReattach();
        }

        // Reap until the pool-wide live count reaches zero. Each pass tears down
        // all currently-runnable and one waiting straggler; a killed process may
        // leave a link/monitor signal (Phase 5) that makes another runnable, so
        // loop until quiescent. `progressed` guards against a logic bug wedging
        // the loop.
        while (pool.live_count.load(.acquire) > 0) {
            var progressed = false;

            for (pool.cores) |*core| {
                while (core.takeLocalRunnable()) |record| {
                    core.teardownAsStraggler(record);
                    progressed = true;
                }
            }
            while (pool.global_queue.pop()) |record| {
                pool.cores[0].teardownAsStraggler(record);
                progressed = true;
            }

            if (pool.findWaitingStraggler()) |record| {
                // A waiting process sits on no run queue; tear it down via its
                // last-running core (its `record.scheduler`), whose stack pool
                // owns the fiber stack.
                record.scheduler.teardownAsStraggler(record);
                progressed = true;
            }

            if (!progressed) break;
        }
        std.debug.assert(pool.live_count.load(.acquire) == 0);
    }

    fn findWaitingStraggler(pool: *SchedulerPool) ?*ProcessRecord {
        var iterator = pool.pid_table.iterateLiveProcesses();
        while (iterator.next()) |live| {
            if (live.pcb.currentState() == .waiting) {
                return @fieldParentPtr("pcb", live.pcb);
            }
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // Wake machinery (netpoller)
    // -------------------------------------------------------------------------

    /// Wake one parked worker so it can steal/run newly-created work. No-op when
    /// no worker is parked (the common busy case pays only an atomic load). The
    /// scan finds a core whose park hint is set and futex-wakes it; a spurious
    /// wake (the core was mid-transition) is harmless — the woken core re-checks
    /// and re-parks. Called from a core's `readyEnqueue` via the pool hook.
    fn wakeOneIdle(pool: *SchedulerPool) void {
        if (pool.idle_count.load(.acquire) == 0) return;
        for (pool.cores) |*core| {
            if (core.isParkedHint()) {
                core.wake();
                return;
            }
        }
    }

    /// Wake every core (stop path): bump each core's wake epoch and futex-wake
    /// it if parked, so a parked worker returns and observes `stopping`.
    fn wakeAll(pool: *SchedulerPool) void {
        for (pool.cores) |*core| core.wake();
    }

    // -------------------------------------------------------------------------
    // Pool hooks (trampolines from `PoolHooks`)
    // -------------------------------------------------------------------------

    fn liveCountDeltaHook(context: ?*anyopaque, delta: i32) void {
        const pool: *SchedulerPool = @ptrCast(@alignCast(context.?));
        const previous = pool.live_count.fetchAdd(@as(i64, delta), .acq_rel);
        // Quiescent-run mode: the pool goes idle exactly when the count reaches
        // zero. In root mode the root's exit (not quiescence) stops the pool.
        if (delta < 0 and previous + @as(i64, delta) == 0 and pool.root_target_bits == 0) {
            pool.stopping.store(true, .release);
            pool.wakeAll();
        }
    }

    fn notifyWorkHook(context: ?*anyopaque) void {
        const pool: *SchedulerPool = @ptrCast(@alignCast(context.?));
        pool.wakeOneIdle();
    }

    fn onProcessExitHook(context: ?*anyopaque, exited_pid_bits: u64) void {
        const pool: *SchedulerPool = @ptrCast(@alignCast(context.?));
        if (pool.root_target_bits != 0 and exited_pid_bits == pool.root_target_bits) {
            pool.stopping.store(true, .release);
            pool.wakeAll();
        }
    }
};

/// xorshift64 step — a cheap, well-distributed victim-selection RNG. Never
/// returns a degenerate all-zeros stream (the seed is forced odd).
fn randNext(state: *u64) usize {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return @intCast(x >> 1);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ProcessContext = scheduler_module.ProcessContext;
const mailbox_module = @import("mailbox.zig");
const ManagerContext = process_module.ManagerContext;
const ManagerVTable = process_module.ManagerVTable;

/// Whether this test run was launched under deliberate CPU oversubscription
/// (P4-R2 finding #2-residual). The validation harness that runs the suite N×
/// concurrently under ≥8× load sets `ZAP_TEST_OVERSUBSCRIBED=1`; when it is set
/// the pool tests SKIP the timing/observability assertions that can legitimately
/// FALSE-NEGATIVE when the OS cannot give every worker thread CPU time — "a
/// steal happened" and "an idle core parked" are EMERGENT properties of real
/// parallelism, not correctness. The CORRECTNESS assertions (every process ran
/// exactly once, leak-exact teardown) are UNCONDITIONAL and run either way, so
/// the suite still proves the scheduler correct under oversubscription; it just
/// does not demand parallelism the host cannot currently deliver. Read via
/// `std.c.getenv`, matching the kernel's existing env knobs (`abi.zig`); this is
/// test-only code, skipped by the portability gate's test-section exclusion.
fn testRunIsOversubscribed() bool {
    const raw = std.c.getenv("ZAP_TEST_OVERSUBSCRIBED") orelse return false;
    return std.mem.sliceTo(raw, 0).len != 0;
}

/// Thread-safe no-allocation test manager for the pool tests: the bodies do not
/// allocate through the manager (they touch only shared atomics), so `allocate`
/// is a no-op and the only per-manager state is an ATOMIC teardown counter —
/// safe to share across cores because teardowns run on whichever core last ran
/// each process. One teardown per spawn is the leak-exactness signal. (The
/// TSan harness uses REAL per-process ARC managers instead; here the mechanics
/// under test are spawn/steal/park/teardown, not the heap.)
const PoolTestManager = struct {
    teardown_count: std.atomic.Value(usize) = .init(0),

    fn managerContext(manager: *PoolTestManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(_: ?*anyopaque, _: usize, _: std.mem.Alignment) ?[*]u8 {
        return null;
    }
    fn deallocateThunk(_: ?*anyopaque, _: [*]u8, _: usize, _: std.mem.Alignment) void {}
    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *PoolTestManager = @ptrCast(@alignCast(manager_state.?));
        _ = manager.teardown_count.fetchAdd(1, .monotonic);
    }
    fn heapByteCountThunk(_: ?*anyopaque) usize {
        return 0;
    }
};

const WorkStealState = struct {
    run_count: std.atomic.Value(usize) = .init(0),
    manager: *PoolTestManager,
};

fn incrementAndExitBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *WorkStealState = @ptrCast(@alignCast(argument.?));
    _ = state.run_count.fetchAdd(1, .monotonic);
}

test "SchedulerPool: work stealing runs every process exactly once with no loss, no duplication, and leak-exact teardown" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 2048 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};
    var state = WorkStealState{ .manager = &manager };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    // Saturate core 0: every process is admitted to core 0's FIFO before any
    // worker runs, so the other cores can only make progress by STEALING.
    // Fewer under ThreadSanitizer (its fiber-trace machinery faults on the
    // switch volume; the stealing coverage holds at 64 just as well as 500).
    const child_count: usize = if (@import("builtin").sanitize_thread) 64 else 500;
    var spawned: usize = 0;
    for (0..child_count) |_| {
        _ = pool.primaryCore().spawn(.{
            .entry = incrementAndExitBody,
            .argument = &state,
            .manager = manager.managerContext(),
            .model = .refcounted,
        }) catch break;
        spawned += 1;
    }
    // A non-trivial workload was admitted. The exact-count invariant below is
    // asserted against the number ACTUALLY spawned, not `child_count`: under
    // memory pressure (the finding-#2 oversubscription harness) a stack-mmap can
    // fail and the `catch break` admits fewer — the scheduler-correctness claim
    // is "every process that WAS admitted ran and tore down exactly once", not
    // "the host had memory for all 500".
    try testing.expect(spawned > 0);

    pool.runUntilQuiescent();

    // Exactly once: every SPAWNED process ran its body and exited.
    try testing.expectEqual(spawned, state.run_count.load(.monotonic));
    // Leak-exact: one teardown per spawn; every pid released; every page back.
    try testing.expectEqual(spawned, manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().abandoned_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());

    // The saturated core's work was genuinely STOLEN: cores other than core 0
    // executed quanta. (Hundreds of processes cannot all drain on core 0 before
    // three sibling workers, spinning and stealing, claim a share.) This is an
    // EMERGENT parallelism property, not a correctness one — the exact-once and
    // leak-exact assertions above already prove correctness whether the work was
    // stolen or drained on core 0 — so it is skipped under deliberate CPU
    // oversubscription, where the OS may not schedule the siblings before core 0
    // drains the queue (a false negative, not a stealing regression).
    if (pool.coreCount() >= 2 and !testRunIsOversubscribed()) {
        var stolen_quanta: u64 = 0;
        for (pool.cores[1..]) |*core| stolen_quanta += core.statistics().quantum_total;
        try testing.expect(stolen_quanta > 0);
    }
}

const LifoOrderState = struct {
    order: [2]u8 = @splat(0),
    cursor: usize = 0,
    responder_pid_bits: u64 = 0,

    fn record(state: *LifoOrderState, identity: u8) void {
        state.order[state.cursor] = identity;
        state.cursor += 1;
    }
};

fn lifoResponderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *LifoOrderState = @ptrCast(@alignCast(argument.?));
    // Park on the empty mailbox; the sender wakes us into the LIFO slot.
    const envelope = context.receive();
    envelope_pool_module.free(envelope);
    state.record('R');
}

fn lifoFillerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *LifoOrderState = @ptrCast(@alignCast(argument.?));
    state.record('F');
}

fn lifoSenderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *LifoOrderState = @ptrCast(@alignCast(argument.?));
    const responder = Pid.fromBits(state.responder_pid_bits);
    _ = context.send(responder, .{}) catch {};
}

test "SchedulerPool: the LIFO slot runs a just-woken process ahead of older FIFO work (message-passing locality)" {
    // A single-core pool is single-threaded and deterministic, isolating the
    // LIFO-slot ordering from thread timing. The just-woken responder must run
    // BEFORE the filler that was already queued in the FIFO — the ping-pong
    // partner runs immediately (research.md §6.1). Under a plain FIFO revive the
    // filler would run first.
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};
    var state = LifoOrderState{};

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 1 });
    defer pool.deinit();

    // Spawn order R, S, F. Core 0 runs R (which parks on receive), then S (which
    // wakes R into the LIFO slot). F is still queued in the FIFO behind S. When
    // S exits, the core takes the LIFO slot (R) before the FIFO (F).
    const responder = try pool.primaryCore().spawn(.{
        .entry = lifoResponderBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    state.responder_pid_bits = responder.toBits();
    _ = try pool.primaryCore().spawn(.{
        .entry = lifoSenderBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    _ = try pool.primaryCore().spawn(.{
        .entry = lifoFillerBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 2), state.cursor);
    try testing.expectEqual(@as(u8, 'R'), state.order[0]);
    try testing.expectEqual(@as(u8, 'F'), state.order[1]);
    try testing.expectEqual(@as(usize, 3), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
}

const ParkWakeState = struct {
    manager: *PoolTestManager,
    received: std.atomic.Value(usize) = .init(0),
    rounds: usize,
    responder_pid_bits: std.atomic.Value(u64) = .init(0),
};

fn parkWakeResponderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *ParkWakeState = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        const envelope = context.receive();
        envelope_pool_module.free(envelope);
        _ = state.received.fetchAdd(1, .monotonic);
    }
}

fn parkWakeSenderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *ParkWakeState = @ptrCast(@alignCast(argument.?));
    const responder = Pid.fromBits(state.responder_pid_bits.load(.acquire));
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        // Yield a few times so the responder (likely on another core) drains
        // its mailbox and PARKS before the next message — exercising a genuine
        // cross-thread futex wake, not a message found already waiting.
        var yield_count: usize = 0;
        while (yield_count < 8) : (yield_count += 1) context.yieldNow();
        _ = context.send(responder, .{}) catch {};
    }
}

test "SchedulerPool: an idle core parks and a cross-thread send wakes it (netpoller, no busy-wait)" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};
    var state = ParkWakeState{ .manager = &manager, .rounds = 64 };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    const responder = try pool.primaryCore().spawn(.{
        .entry = parkWakeResponderBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    state.responder_pid_bits.store(responder.toBits(), .release);
    _ = try pool.primaryCore().spawn(.{
        .entry = parkWakeSenderBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    // Every message was delivered across the park/wake handshake — no lost wake,
    // and the run terminated (a busy-wait or a lost wake would hang).
    try testing.expectEqual(state.rounds, state.received.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);

    // Cores genuinely PARKED on the futex while idle (not busy-waiting): with a
    // parked responder and a periodically-yielding sender, the surplus cores run
    // out of work and sleep. (Multi-core only — one core always has the sender.)
    //
    // This is a TIMING property, not a correctness one, so it is not asserted
    // under ThreadSanitizer: TSan's ~20× uniform slowdown collapses the idle
    // windows the netpoller parks in — the surplus cores stay in their bounded
    // pre-park spin for the whole (logically-shortened) run and never commit to a
    // futex sleep, so the park COUNT is unobservable. The park/WAKE CORRECTNESS
    // this test exists for is fully asserted above and DOES run under TSan: all 64
    // messages crossed a park/wake handshake (a lost wake would hang the run), and
    // teardown/leak accounting is exact. For the same reason it is skipped under
    // deliberate CPU oversubscription (finding #2-residual): when four worker
    // threads timeshare too few cores, a surplus core may never reach a genuine
    // futex sleep within the (contention-stretched) run, so a zero park count is
    // a false negative rather than a busy-wait regression.
    if (pool.coreCount() >= 2 and !@import("builtin").sanitize_thread and !testRunIsOversubscribed()) {
        var total_parks: u64 = 0;
        for (pool.cores) |*core| total_parks += core.statistics().park_count;
        try testing.expect(total_parks > 0);
    }
}

const StormState = struct {
    manager: *PoolTestManager,
    total_ran: std.atomic.Value(usize) = .init(0),
    children_per_parent: usize,
    /// Children actually admitted (a child spawn can fail under memory pressure
    /// — the finding-#2 oversubscription harness — so the leak-exact assertion
    /// counts real admissions, not the nominal `children_per_parent`).
    children_spawned: std.atomic.Value(usize) = .init(0),
};

fn stormChildBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *StormState = @ptrCast(@alignCast(argument.?));
    _ = state.total_ran.fetchAdd(1, .monotonic);
}

fn stormParentBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *StormState = @ptrCast(@alignCast(argument.?));
    _ = state.total_ran.fetchAdd(1, .monotonic);
    var child: usize = 0;
    while (child < state.children_per_parent) : (child += 1) {
        // A child spawn can legitimately fail under memory pressure; count only
        // the ones actually admitted so the exact-count invariant is "every
        // ADMITTED process ran and tore down once", not "every spawn succeeded".
        if (context.spawn(.{
            .entry = stormChildBody,
            .argument = state,
            .manager = state.manager.managerContext(),
            .model = .refcounted,
        })) |_| {
            _ = state.children_spawned.fetchAdd(1, .monotonic);
        } else |_| {}
    }
}

test "SchedulerPool: a spawn/die storm across cores tears down leak-exact under real parallelism" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 4096 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    // Several waves of a parent-spawns-children cascade. Each wave spawns
    // `parent_count` parents that each spawn `children_per_parent` children; the
    // whole tree runs and exits on cores chosen by stealing. Leak-exact after
    // every wave: exactly one teardown per process, zero pids, zero pages.
    // Fewer waves/parents under ThreadSanitizer (fiber-trace volume ceiling);
    // the cascade teardown coverage is identical, just smaller.
    const tsan = @import("builtin").sanitize_thread;
    const waves: usize = if (tsan) 2 else 8;
    const parent_count: usize = if (tsan) 8 else 32;
    const children_per_parent: usize = 8;

    // Cumulative expected process count across every wave, summed from the
    // ACTUAL admissions per wave (parents are `try`-spawned so all `parent_count`
    // land; children are best-effort under memory pressure). This is the
    // leak-exact ground truth: one teardown per admitted process.
    var admitted_total: usize = 0;
    var wave: usize = 0;
    while (wave < waves) : (wave += 1) {
        var state = StormState{ .manager = &manager, .children_per_parent = children_per_parent };
        for (0..parent_count) |_| {
            _ = try pool.primaryCore().spawn(.{
                .entry = stormParentBody,
                .argument = &state,
                .manager = manager.managerContext(),
                .model = .refcounted,
            });
        }
        pool.runUntilQuiescent();

        // Every admitted process (all parents + the children they managed to
        // spawn) ran its body exactly once.
        const wave_admitted = parent_count + state.children_spawned.load(.monotonic);
        try testing.expectEqual(wave_admitted, state.total_ran.load(.monotonic));
        admitted_total += wave_admitted;
        try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
        try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
        try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().abandoned_page_count);
        try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
    }

    // Cumulative leak-exactness: one teardown per admitted process across every
    // wave (no loss, no duplication) — independent of any per-wave child-spawn
    // shortfall under memory pressure.
    try testing.expectEqual(admitted_total, manager.teardown_count.load(.monotonic));
}

const TimeoutState = struct {
    manager: *PoolTestManager,
    timeout_nanoseconds: u64,
    timed_out_count: std.atomic.Value(usize) = .init(0),
};

fn timeoutWaiterBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *TimeoutState = @ptrCast(@alignCast(argument.?));
    // Park as a timed waiter with no sender: the deadline fires. The firing
    // core reads the pid for the trace, then the timed-out process becomes
    // runnable and STEALABLE — a sibling can run and tear it down concurrently
    // (the P4-J1 race that read the pid after enqueue). Exercised across N cores.
    const outcome = context.receiveWaitTimeout(state.timeout_nanoseconds);
    if (outcome == .timed_out) _ = state.timed_out_count.fetchAdd(1, .monotonic);
}

test "SchedulerPool: receive-after timed waiters fire and tear down race-free across cores" {
    // Runs under ThreadSanitizer: firing a timeout RESUMES the waiter's fiber,
    // and the `fiber_context.zig` `__tsan_switch_to_fiber` annotations now let
    // TSan follow that resume (and the subsequent fire-then-steal-then-teardown
    // migration) across the manual context switch instead of faulting on it.

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 1024 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};
    var state = TimeoutState{ .manager = &manager, .timeout_nanoseconds = std.time.ns_per_ms };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{});
    defer pool.deinit();

    // Many timed waiters, each parked on some core and fired by this core's
    // timing wheel — then run and torn down on any core (the fire-then-steal-
    // then-teardown path this test guards).
    const waiter_count: usize = 128;
    for (0..waiter_count) |_| {
        _ = try pool.primaryCore().spawn(.{
            .entry = timeoutWaiterBody,
            .argument = &state,
            .manager = manager.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    try testing.expectEqual(waiter_count, state.timed_out_count.load(.monotonic));
    try testing.expectEqual(waiter_count, manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}

// -- cross-scheduler message-vs-timer race (P4-J2) ---------------------------

const CancelRaceState = struct {
    manager: *PoolTestManager,
    rounds: usize,
    timeout_nanoseconds: u64,
    receiver_pid_bits: std.atomic.Value(u64) = .init(0),
    message_won: std.atomic.Value(usize) = .init(0),
    timed_out: std.atomic.Value(usize) = .init(0),
};

/// A receiver that arms a `receive … after` timer each round and (with a
/// generous deadline) expects a cross-core message to beat it every time —
/// exercising the cross-scheduler timer-CANCEL path: the timer armed on this
/// receiver's core is invalidated by a message wake delivered from the sender's
/// (likely different) core.
fn cancelRaceReceiverBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *CancelRaceState = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        const outcome = context.receiveWaitTimeout(state.timeout_nanoseconds);
        if (outcome == .message_available) {
            const envelope = context.receive();
            envelope_pool_module.free(envelope);
            _ = state.message_won.fetchAdd(1, .monotonic);
        } else {
            _ = state.timed_out.fetchAdd(1, .monotonic);
            break; // a spurious timeout under a generous deadline — stop
        }
    }
}

fn cancelRaceSenderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *CancelRaceState = @ptrCast(@alignCast(argument.?));
    const receiver = Pid.fromBits(state.receiver_pid_bits.load(.acquire));
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        // Yield so the receiver (likely on another core) parks — arming its
        // timer — before this cross-core send wakes it and cancels the timer.
        var yield_count: usize = 0;
        while (yield_count < 8) : (yield_count += 1) context.yieldNow();
        _ = context.send(receiver, .{}) catch {};
    }
}

test "SchedulerPool: a cross-core message cancels an armed after-timer every round (no spurious timeout)" {
    // Runs under ThreadSanitizer: each round a cross-core message wake RESUMES
    // the receiver's fiber, which the `fiber_context.zig` fiber annotations now
    // let TSan track across the manual context switch. The cross-scheduler
    // timer-CANCEL path is thus exercised under TSan, not merely inferred.

    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};
    // A GENEROUS deadline (10 s) the test never approaches: the cross-core
    // message must win — and thus cancel the timer — on every round.
    var state = CancelRaceState{
        .manager = &manager,
        .rounds = 64,
        .timeout_nanoseconds = 10 * std.time.ns_per_s,
    };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    const receiver = try pool.primaryCore().spawn(.{
        .entry = cancelRaceReceiverBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    state.receiver_pid_bits.store(receiver.toBits(), .release);
    _ = try pool.primaryCore().spawn(.{
        .entry = cancelRaceSenderBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    pool.runUntilQuiescent();

    // Every round: the message beat the deadline and cancelled the timer — no
    // spurious after-fires, no lost wake (a lost wake would hang the run).
    try testing.expectEqual(state.rounds, state.message_won.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), state.timed_out.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
}

const TimerRaceState = struct {
    manager: *PoolTestManager,
    timeout_nanoseconds: u64,
    message_won: std.atomic.Value(usize) = .init(0),
    timed_out: std.atomic.Value(usize) = .init(0),
    consumed_envelopes: std.atomic.Value(usize) = .init(0),
};

/// One receiver in the tight race: arms a SHORT after-timer, and a sender on
/// another core sends a single message timed to race the deadline. Either
/// outcome is legal — the invariant is exactly ONE outcome and no
/// double-delivery.
fn timerRaceReceiverBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *TimerRaceState = @ptrCast(@alignCast(argument.?));
    const outcome = context.receiveWaitTimeout(state.timeout_nanoseconds);
    if (outcome == .message_available) {
        const envelope = context.receive();
        envelope_pool_module.free(envelope);
        _ = state.consumed_envelopes.fetchAdd(1, .monotonic);
        _ = state.message_won.fetchAdd(1, .monotonic);
    } else {
        _ = state.timed_out.fetchAdd(1, .monotonic);
    }
}

const TimerRacePair = struct {
    state: *TimerRaceState,
    receiver_pid_bits: std.atomic.Value(u64) = .init(0),
};

fn timerRacePairSenderBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const pair: *TimerRacePair = @ptrCast(@alignCast(argument.?));
    const receiver = Pid.fromBits(pair.receiver_pid_bits.load(.acquire));
    // A few yields so the receiver parks and arms its (short) timer, then send —
    // the send and the deadline genuinely race across cores.
    var yield_count: usize = 0;
    while (yield_count < 4) : (yield_count += 1) context.yieldNow();
    _ = context.send(receiver, .{}) catch {};
}

test "SchedulerPool: message-vs-after-timer race across cores yields exactly one outcome, no double-delivery" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 2048 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = PoolTestManager{};

    // A SHORT deadline tuned near the cross-core send latency so both outcomes
    // (message wins / timer fires) genuinely occur — the subtle M:N race. The
    // invariant asserted holds regardless of who wins each pair. Runs under
    // ThreadSanitizer: the race is decided by a fiber RESUME on either outcome
    // (a message wake or a timeout fire), which the `fiber_context.zig` fiber
    // annotations now let TSan follow across the manual context switch. The
    // arbitration itself is a single seq_cst CAS on the packed `park_control`,
    // so TSan validates exactly-one-outcome / no-double-delivery directly here.

    const pair_count: usize = 256;
    var state = TimerRaceState{ .manager = &manager, .timeout_nanoseconds = 200 * std.time.ns_per_us };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, testing.allocator, &pid_table, &envelope_pool, .{ .scheduler_count = 4 });
    defer pool.deinit();

    const pairs = try testing.allocator.alloc(TimerRacePair, pair_count);
    defer testing.allocator.free(pairs);

    for (pairs) |*pair| {
        pair.* = .{ .state = &state };
        const receiver = try pool.primaryCore().spawn(.{
            .entry = timerRaceReceiverBody,
            .argument = &state,
            .manager = manager.managerContext(),
            .model = .refcounted,
        });
        pair.receiver_pid_bits.store(receiver.toBits(), .release);
        _ = try pool.primaryCore().spawn(.{
            .entry = timerRacePairSenderBody,
            .argument = pair,
            .manager = manager.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    // Exactly one outcome per receiver — no lost wake, no double-fire.
    try testing.expectEqual(pair_count, state.message_won.load(.monotonic) + state.timed_out.load(.monotonic));
    // No double-delivery: a "message won" consumed exactly one envelope, and a
    // "timed out" consumed none (a message that raced in late is reclaimed at
    // teardown, never double-counted).
    try testing.expectEqual(state.message_won.load(.monotonic), state.consumed_envelopes.load(.monotonic));
    // Leak-exact: every process (2 per pair) torn down, every envelope reclaimed.
    try testing.expectEqual(pair_count * 2, manager.teardown_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
}
