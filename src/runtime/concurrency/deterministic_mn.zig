//! Seeded multi-scheduler (M:N) deterministic simulator for the Zap
//! concurrency kernel.
//!
//! Phase 4 item 4.4 of `docs/concurrency-implementation-plan.md` (job
//! P4-J4), realizing research.md §6.11's gold standard (FoundationDB
//! deterministic simulation / Loom / Shuttle / verona-rt seed sweeps) for
//! GENUINE M:N concurrency: the Phase-1 deterministic mode
//! (`deterministic.zig`) drives ONE `Scheduler` for byte-identical seeded
//! replay; Phase 4 is M:N (`scheduler_pool.zig`), where real parallelism is
//! nondeterministic. This simulator makes M:N bugs reproducible by SIMULATING
//! the N cores on ONE OS thread, with a single seed driving every scheduling
//! decision — same seed ⇒ identical interleaving ⇒ byte-identical trace; a
//! failing seed reproduces exactly (and is printed for replay).
//!
//! ## What it models — the REAL kernel, not an abstraction
//!
//! The simulator drives the SAME `Scheduler` instances a `SchedulerPool`
//! owns (shared `PidTable` + `EnvelopePool` + `GlobalRunQueue`, `work_stealing
//! = true`, the pool `PoolHooks` seam), and composes the SAME pool-facing
//! primitives the production worker loop composes — `drainPendingWakes`,
//! `takeLocalRunnable` (LIFO slot then FIFO), `runNext` (a real fiber
//! quantum), `stealInto`, `fireEarliestReceiveTimeout`. It exercises the real
//! mailboxes, the real cross-thread wake handshake (`park_control`), the real
//! steal machinery, and the real timing wheels. The ONLY thing replaced is the
//! source of nondeterminism: instead of OS-thread races, a seed.
//!
//! ## The seam inventory (all nondeterminism funnels through the seed)
//!
//! Every decision the real M:N pool leaves to OS timing is a pure function of
//! the seed here:
//!
//!  * **which logical core steps next** — a uniform seeded choice among the
//!    cores that can make progress this instant (the driver's core-scheduling
//!    order, standing in for OS-thread scheduling);
//!  * **steal victim choice** — a seeded start offset + scan, standing in for
//!    the production per-worker steal RNG;
//!  * **within-core next-runnable + quantum budget** — each core's seeded
//!    `Decisions` seam (`SeededDecisions`), randomizing the FIFO pick and the
//!    per-quantum preemption budget (moving every safepoint preemption point,
//!    so a producer's send burst can be split and interleaved with sibling
//!    cores' steps at fine grain);
//!  * **timer firing** — a SHARED `VirtualClock`: `receive … after` deadlines
//!    are computed against virtual time (the scheduler's `Clock` seam), and the
//!    driver advances virtual time to the globally-earliest armed deadline and
//!    fires it (discrete-event order) only when no core can otherwise run.
//!
//! Message-delivery and wake ordering are then a pure consequence of the
//! core-step order: a cross-core `send` pushes onto the producing (stepping)
//! core's own wake stack (wake locality, exactly as a real pool worker thread
//! routes it), and the seeded order in which cores are stepped IS the order in
//! which those wakes and mailbox pushes are observed.
//!
//! ## Interleaving granularity (Shuttle/Loom model)
//!
//! The simulator interleaves at the QUANTUM / seam-operation granularity, not
//! per machine instruction — the same choice Loom and Shuttle make. A quantum
//! runs uninterrupted on its core (the cooperative-safepoint unit of
//! preemption); cross-core effects are observed at step boundaries. Because the
//! kernel's cross-thread interactions are DESIGNED to occur only at
//! well-defined atomic seams (mailbox push, the `park_control` wake handshake,
//! the steal splice, a timer fire), exploring every ORDERING of those
//! seam operations — which the seeded core-step order does — covers the
//! meaningful M:N scheduling nondeterminism. The seeded per-quantum budget
//! subdivides a quantum at safepoints, so a producer's sends interleave with
//! sibling steps at fine grain. This does NOT model a data race on shared
//! non-atomic memory INSIDE a quantum (that is what the TSan harnesses —
//! `mn_refcount_stress.zig` — prove instead); it models scheduling and
//! message-ordering nondeterminism, which is where M:N logic bugs live.
//!
//! ## Trace, replay, and the failing-seed contract
//!
//! `MnTraceRecorder` captures every scheduler `TraceEvent` TAGGED WITH THE CORE
//! that produced it, in the exact order the driver stepped the cores — so the
//! recorded `MnTraceEvent` stream IS the M:N interleaving. Two runs are
//! equivalent iff `mnTracesIdentical`. `runScenario` prints the seed on ANY
//! failure before propagating the error (the plan-1.5/4.4 contract), and
//! `runSeedSweep` runs a scenario across a seed range (verona-rt-style), so an
//! interleaving-dependent bug surfaces with a replayable seed.
//!
//! ## Toolchain
//!
//! Drives real fiber switches, so the kernel-wide fork-compiler requirement for
//! optimized builds applies (see `concurrency.zig`).

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const mailbox_module = @import("mailbox.zig");
const process_module = @import("process.zig");
const timing_wheel_module = @import("timing_wheel.zig");
const deterministic_module = @import("deterministic.zig");

const SeededDecisions = deterministic_module.SeededDecisions;
const Scheduler = scheduler_module.Scheduler;
const TraceEvent = scheduler_module.TraceEvent;
const Decisions = scheduler_module.Decisions;
const Clock = scheduler_module.Clock;
const PoolHooks = scheduler_module.PoolHooks;
const GlobalRunQueue = scheduler_module.GlobalRunQueue;
const ProcessContext = scheduler_module.ProcessContext;
const ProcessEntry = scheduler_module.ProcessEntry;
const ProcessRecord = scheduler_module.ProcessRecord;
const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;

/// The shared VIRTUAL clock the simulator installs on every core through the
/// scheduler's `Clock` seam. It defines ONE timeline for all cores (so
/// cross-core `receive … after` ordering is deterministic): `receive … after`
/// arms its deadline as `now + timeout`, and the driver advances `now` — only
/// ever forward, only ever to the globally-earliest armed deadline — when it
/// fires a timer. Between fires, `now` is constant, so a freshly-armed timer's
/// deadline is always in the future (discrete-event time model). Starts at one
/// base tick so the first deadline is never zero. PINNED (cores hold `.clock`
/// views pointing at it).
pub const VirtualClock = struct {
    /// Current virtual time in monotonic nanoseconds.
    now_nanoseconds: u64,

    /// Create a virtual clock at the base tick (tick 1).
    pub fn init() VirtualClock {
        return .{ .now_nanoseconds = timing_wheel_module.base_tick_nanoseconds };
    }

    /// The `Clock` seam view to install into `Scheduler.Options`. The returned
    /// value points at `virtual_clock`, which must stay pinned.
    pub fn clock(virtual_clock: *VirtualClock) Clock {
        return .{ .clock_context = virtual_clock, .readNanoseconds = readThunk };
    }

    /// Advance virtual time to `target_nanoseconds`. Only ever forward — the
    /// driver advances to the globally-earliest armed deadline (or an exact tie
    /// with the current instant), never backward.
    pub fn advanceTo(virtual_clock: *VirtualClock, target_nanoseconds: u64) void {
        std.debug.assert(target_nanoseconds >= virtual_clock.now_nanoseconds);
        virtual_clock.now_nanoseconds = target_nanoseconds;
    }

    fn readThunk(clock_context: ?*anyopaque) u64 {
        const virtual_clock: *VirtualClock = @ptrCast(@alignCast(clock_context.?));
        return virtual_clock.now_nanoseconds;
    }
};

/// One scheduler event tagged with the core that produced it — the M:N
/// interleaving trace element. Deliberately a plain, comparison-friendly value:
/// two runs are equivalent iff their `MnTraceEvent` sequences are element-wise
/// equal (`mnTracesIdentical`).
pub const MnTraceEvent = struct {
    /// Which logical core the event happened on (0-based).
    core_index: u16,
    /// What happened.
    kind: TraceEvent.Kind,
    /// The raw pid bits of the process it happened to (`Pid.toBits`).
    pid_bits: u64,
};

/// Append-only recorder for the combined, core-tagged trace of a
/// multi-scheduler run. Each core is given its own `CoreTraceTap` as its
/// scheduler `trace_context`, so an event carries its core index without any
/// mutable driver state; the driver steps one core at a time, so appends land
/// in exact interleaving order. Panics on OOM — the trace hook cannot return
/// errors and a truncated trace would silently break replay comparison, so the
/// recorder fails loudly (test-harness posture, mirroring `deterministic.zig`).
pub const MnTraceRecorder = struct {
    /// Allocator backing the event log.
    allocator: std.mem.Allocator,
    /// The recorded events, oldest first.
    events: std.ArrayList(MnTraceEvent),

    /// Create an empty recorder.
    pub fn init(allocator: std.mem.Allocator) MnTraceRecorder {
        return .{ .allocator = allocator, .events = .empty };
    }

    /// Free the event log.
    pub fn deinit(recorder: *MnTraceRecorder) void {
        recorder.events.deinit(recorder.allocator);
        recorder.* = undefined;
    }

    /// The recorded event sequence (borrowed; valid until the next record or
    /// deinit).
    pub fn recorded(recorder: *const MnTraceRecorder) []const MnTraceEvent {
        return recorder.events.items;
    }

    fn append(recorder: *MnTraceRecorder, event: MnTraceEvent) void {
        recorder.events.append(recorder.allocator, event) catch
            @panic("MnTraceRecorder: out of memory recording a trace event");
    }
};

/// One core's trace tap: the scheduler `trace_context` a core is given, so its
/// events are recorded with THAT core's index. Pinned for the run (the core
/// holds `&tap`).
pub const CoreTraceTap = struct {
    /// The shared combined recorder.
    recorder: *MnTraceRecorder,
    /// This core's index.
    core_index: u16,

    /// The `TraceHook` thunk to install into a core's `Scheduler.Options`
    /// (`trace_context` = the tap).
    pub fn hookThunk(trace_context: ?*anyopaque, event: TraceEvent) void {
        const tap: *CoreTraceTap = @ptrCast(@alignCast(trace_context.?));
        tap.recorder.append(.{
            .core_index = tap.core_index,
            .kind = event.kind,
            .pid_bits = event.pid_bits,
        });
    }
};

/// Whether two core-tagged traces are byte-identical (same events, same cores,
/// same pids, same order) — the equality the same-seed reproducibility contract
/// is stated in.
pub fn mnTracesIdentical(first: []const MnTraceEvent, second: []const MnTraceEvent) bool {
    if (first.len != second.len) return false;
    for (first, second) |first_event, second_event| {
        if (!std.meta.eql(first_event, second_event)) return false;
    }
    return true;
}

/// A scenario body: spawns processes (and may stash context for post-run
/// verification). Runs BEFORE the simulator drives; the spawned processes run
/// when `MnSimulator.runToQuiescence` is called.
pub const ScenarioFunction = *const fn (simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void;

/// Errors surfaced by `MnSimulator.verifyExactAccounting`.
pub const AccountingError = error{
    /// Processes remained live after the run.
    LiveProcessesRemain,
    /// Envelope pages remained in service (leak).
    EnvelopePagesLeaked,
    /// Envelope pages remained abandoned (reclaim never happened).
    EnvelopePagesAbandoned,
    /// Some process's manager was not torn down exactly once.
    ManagerTeardownMismatch,
};

/// Arena-backed per-process manager for simulator scenarios: `teardown` is the
/// wholesale free-on-exit shape (plan 1.4), counted so exactly-once teardown is
/// verifiable. A plain (non-atomic) counter is correct here — the simulator is
/// single-threaded by construction, which is the entire point.
const SimProcessManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    fn managerContext(manager: *SimProcessManager) process_module.ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *SimProcessManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *SimProcessManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *SimProcessManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        // Capture the child allocator BEFORE deinit (reading through the arena
        // after `deinit` is use-after-deinit), then leave a deinit-safe empty
        // arena so a double teardown is caught by the count, not a crash.
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *SimProcessManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

/// The seeded multi-scheduler simulator: N real `Scheduler` cores over a shared
/// pid table, envelope pool, and global overflow queue — wired exactly as a
/// `SchedulerPool` wires them (work stealing, the pool hooks, the LIFO wake
/// slot) — driven single-threaded by ONE seed. Heap-allocated (`create`)
/// because the cores and every seam hold internal pointers (the pool hooks, the
/// per-core seeded decisions, the virtual clock, the per-core trace taps).
pub const MnSimulator = struct {
    /// Allocator backing every simulator structure.
    allocator: std.mem.Allocator,
    /// The seed this run uses (printed on failure).
    seed: u64,
    /// The master generator for driver-level decisions: which core steps next,
    /// steal victim choice, and which tied timer fires first. A pure function of
    /// the seed.
    master_prng: std.Random.DefaultPrng,
    /// The shared virtual clock (pinned; every core's `.clock` points at it).
    virtual_clock: VirtualClock,
    /// The combined core-tagged trace recorder (pinned).
    trace_recorder: MnTraceRecorder,
    /// Per-core trace taps (pinned; each core's `trace_context` points at its
    /// tap). Owned.
    core_taps: []CoreTraceTap,
    /// Per-core seeded decision sources (pinned; each core's `Decisions` points
    /// at its entry). Owned.
    core_decisions: []SeededDecisions,
    /// The shared (M:N-safe) pid table. BORROWED (not owned) so the simulator
    /// can serve as the ABI's seeded backend over the runtime's own shared
    /// structures, exactly as `SchedulerPool` borrows them.
    pid_table: *PidTable,
    /// The shared (M:N-safe) envelope reservoir. BORROWED (see `pid_table`).
    envelope_pool: *EnvelopePool,
    /// The shared global overflow queue.
    global_queue: GlobalRunQueue,
    /// The pool-orchestration seam installed into every core (`context` = this
    /// simulator; pinned).
    hooks: PoolHooks,
    /// The N cores (real schedulers). Owned; pinned.
    cores: []Scheduler,
    /// One arena manager per spawned process (torn down by process teardown;
    /// freed by `destroy`).
    process_managers: std.ArrayList(*SimProcessManager),
    /// Scratch index buffer (core-count sized) reused for the steppable set and
    /// the tied-timer set. Owned.
    index_scratch: []usize,
    /// Live-process count, tracked single-threaded through the `liveCountDelta`
    /// hook (a plain int is correct — the simulator never runs two cores at
    /// once). Conserved to zero at quiescence.
    live_count: i64,
    /// Root process pid bits in root-exit mode (0 ⇒ quiescent mode).
    root_target_bits: u64,

    /// Construction options.
    pub const Options = struct {
        /// Number of logical cores to simulate (≥ 1). Default 2 — the smallest
        /// genuinely-M:N configuration.
        core_count: usize = 2,
        /// Pid-table capacity (= max concurrent processes).
        pid_capacity: u32 = 256,
        /// Configured preemption budget (the seeded seam randomizes each quantum
        /// in `[1, this]` unless disabled).
        preemption_budget: u32 = 16,
        /// Randomize per-quantum budgets (moves every safepoint preemption point
        /// so producer bursts interleave with sibling steps at fine grain).
        randomize_quantum_budget: bool = true,
        /// Usable bytes per fiber stack.
        stack_usable_size: usize = 64 * 1024,
        /// Envelope slots per pool page (small default so scenarios exercise
        /// page growth/abandon/reclaim).
        envelopes_per_page: u32 = 8,
        /// FIFO length past which a core spills half its backlog to the global
        /// queue (small default so scenarios exercise the overflow path).
        spill_threshold: usize = 8,
        /// The kernel signal runtime (P5-J1) shared across the simulated cores,
        /// or null (signal-free scenarios). The ABI's seeded backend passes the
        /// runtime's shared instance so seeded signal runs work.
        signal_runtime: ?*@import("signal.zig").SignalRuntime = null,
    };

    /// Build a seeded M:N simulator for `seed` over a BORROWED pid table and
    /// envelope pool (mirroring `SchedulerPool.init`), so it can be the ABI's
    /// seeded backend over the runtime's shared structures. Tests use
    /// `runScenario`, which owns a fresh pid table + envelope pool per run.
    pub fn create(
        allocator: std.mem.Allocator,
        pid_table: *PidTable,
        envelope_pool: *EnvelopePool,
        seed: u64,
        options: Options,
    ) !*MnSimulator {
        std.debug.assert(options.core_count >= 1);
        const simulator = try allocator.create(MnSimulator);
        errdefer allocator.destroy(simulator);

        simulator.allocator = allocator;
        simulator.seed = seed;
        simulator.master_prng = std.Random.DefaultPrng.init(seed);
        simulator.virtual_clock = VirtualClock.init();
        simulator.trace_recorder = MnTraceRecorder.init(allocator);
        errdefer simulator.trace_recorder.deinit();
        simulator.process_managers = .empty;
        simulator.live_count = 0;
        simulator.root_target_bits = 0;

        simulator.core_taps = try allocator.alloc(CoreTraceTap, options.core_count);
        errdefer allocator.free(simulator.core_taps);
        simulator.core_decisions = try allocator.alloc(SeededDecisions, options.core_count);
        errdefer allocator.free(simulator.core_decisions);
        simulator.index_scratch = try allocator.alloc(usize, options.core_count);
        errdefer allocator.free(simulator.index_scratch);
        simulator.cores = try allocator.alloc(Scheduler, options.core_count);
        errdefer allocator.free(simulator.cores);

        simulator.pid_table = pid_table;
        simulator.envelope_pool = envelope_pool;
        simulator.global_queue = GlobalRunQueue.init();
        simulator.hooks = .{
            .context = simulator,
            .liveCountDelta = liveCountDeltaHook,
            .notifyWork = notifyWorkHook,
            .onProcessExit = onProcessExitHook,
        };

        // Wire each core exactly as a `SchedulerPool` would — work stealing on,
        // the pool hooks and global queue installed — but for a SEEDED,
        // never-parking, single-threaded run: `forbid_parking`, a per-core
        // seeded `Decisions`, the shared virtual clock, and a per-core trace
        // tap. Each core's decision source is derived from the master seed so
        // the whole run stays a pure function of `seed`.
        for (0..options.core_count) |core_index| {
            simulator.core_taps[core_index] = .{
                .recorder = &simulator.trace_recorder,
                .core_index = @intCast(core_index),
            };
            simulator.core_decisions[core_index] = SeededDecisions.init(
                seed +% (@as(u64, core_index) *% 0x9E3779B97F4A7C15),
                options.randomize_quantum_budget,
            );
            simulator.cores[core_index] = Scheduler.init(allocator, simulator.pid_table, simulator.envelope_pool, .{
                .preemption_budget = options.preemption_budget,
                .idle_strategy = .forbid_parking,
                .work_stealing = true,
                .pool_hooks = &simulator.hooks,
                .global_queue = &simulator.global_queue,
                .spill_threshold = options.spill_threshold,
                .decisions = simulator.core_decisions[core_index].decisions(),
                .clock = simulator.virtual_clock.clock(),
                .trace_hook = CoreTraceTap.hookThunk,
                .trace_context = &simulator.core_taps[core_index],
                .stack_usable_size = options.stack_usable_size,
                .signal_runtime = options.signal_runtime,
            });
        }
        return simulator;
    }

    /// Tear the simulator down. Any processes a failed/deadlocked scenario left
    /// behind are reaped first (`shutdownStragglers`), so destroy is safe on
    /// every path and manager teardown stays exactly-once.
    pub fn destroy(simulator: *MnSimulator) void {
        simulator.shutdownStragglers();
        for (simulator.cores) |*core| core.deinit();
        // The pid table and envelope pool are BORROWED — the owner (the test
        // harness, or the ABI runtime) frees them.
        for (simulator.process_managers.items) |manager| {
            std.debug.assert(manager.teardown_count == 1);
            simulator.allocator.destroy(manager);
        }
        simulator.process_managers.deinit(simulator.allocator);
        simulator.trace_recorder.deinit();
        simulator.allocator.free(simulator.cores);
        simulator.allocator.free(simulator.index_scratch);
        simulator.allocator.free(simulator.core_decisions);
        simulator.allocator.free(simulator.core_taps);
        const allocator = simulator.allocator;
        allocator.destroy(simulator);
    }

    /// Number of simulated cores.
    pub fn coreCount(simulator: *const MnSimulator) usize {
        return simulator.cores.len;
    }

    /// The core an EXTERNAL (driver-thread) spawn admits to — core 0, the
    /// analogue of `SchedulerPool.primaryCore`. An in-process spawn routes to the
    /// running core instead (via `Scheduler.currentThreadScheduler`, which the
    /// driver publishes per step). The ABI's seeded backend calls this.
    pub fn primaryCore(simulator: *MnSimulator) *Scheduler {
        return &simulator.cores[0];
    }

    /// Spawn a process onto the primary core (core 0) with a fresh arena-backed
    /// manager — the scenario-setup entry point (work stealing then distributes
    /// it across cores). In-process spawns from a running body route to the
    /// running core instead (via the scheduler's current-thread routing).
    pub fn spawnProcess(simulator: *MnSimulator, entry: ProcessEntry, argument: ?*anyopaque) !Pid {
        try simulator.process_managers.ensureUnusedCapacity(simulator.allocator, 1);
        const manager = try simulator.allocator.create(SimProcessManager);
        errdefer simulator.allocator.destroy(manager);
        manager.* = .{ .arena = std.heap.ArenaAllocator.init(simulator.allocator) };
        const pid = try simulator.cores[0].spawn(.{
            .entry = entry,
            .argument = argument,
            .manager = manager.managerContext(),
        });
        simulator.process_managers.appendAssumeCapacity(manager);
        return pid;
    }

    /// The recorded core-tagged trace so far (borrowed).
    pub fn trace(simulator: *const MnSimulator) []const MnTraceEvent {
        return simulator.trace_recorder.recorded();
    }

    /// Drive the simulation until every process has exited (quiescence).
    /// `error.AllProcessesWaiting` is the deterministic-idle outcome: the
    /// scenario deadlocked (no core can run, no timer is armed).
    pub fn runToQuiescence(simulator: *MnSimulator) scheduler_module.RunError!void {
        return simulator.drive(.quiescent);
    }

    /// Drive the simulation until process `root` exits (Erlang halt model), then
    /// reap any stragglers. The multi-scheduler analogue of
    /// `Scheduler.runUntilProcessExits`; the ABI seeded backend drives this.
    pub fn runUntilRootExits(simulator: *MnSimulator, root: Pid) scheduler_module.RunError!void {
        simulator.root_target_bits = root.toBits();
        defer simulator.root_target_bits = 0;
        return simulator.drive(.{ .until_root = root });
    }

    const RunMode = union(enum) {
        quiescent,
        until_root: Pid,
    };

    /// The discrete-event driver: at each iteration, seeded-pick a core that can
    /// make progress and step it once; when no core can run, advance virtual
    /// time to the earliest armed `receive … after` timer and fire it; if there
    /// is neither runnable work nor an armed timer while processes remain, the
    /// scenario is deadlocked (`error.AllProcessesWaiting`).
    fn drive(simulator: *MnSimulator, mode: RunMode) scheduler_module.RunError!void {
        while (true) {
            switch (mode) {
                .quiescent => if (simulator.live_count == 0) return,
                .until_root => |root| if (!simulator.pid_table.isAlive(root)) return,
            }
            // Nothing live ⇒ done regardless of mode (in root mode the root and
            // all its children are gone).
            if (simulator.live_count == 0) return;

            const steppable = simulator.collectSteppable();
            if (steppable.len > 0) {
                const pick = simulator.master_prng.random().uintLessThan(usize, steppable.len);
                simulator.stepCore(steppable[pick]);
                continue;
            }

            // No core can run: every live process is waiting. Fire the
            // globally-earliest armed timer (virtual time), or declare deadlock.
            if (simulator.fireEarliestDueTimer()) continue;
            return error.AllProcessesWaiting;
        }
    }

    /// Collect the indices of cores that can make progress this instant into the
    /// scratch buffer and return the used slice. A core is steppable when it can
    /// service or run on its own (a pending wake it alone can drain, a pending
    /// blocking re-attach, local LIFO/FIFO work, or a non-empty global queue) OR
    /// it can steal a sibling's FIFO work.
    fn collectSteppable(simulator: *MnSimulator) []usize {
        var used: usize = 0;
        for (0..simulator.cores.len) |core_index| {
            if (simulator.canProgress(core_index)) {
                simulator.index_scratch[used] = core_index;
                used += 1;
            }
        }
        return simulator.index_scratch[0..used];
    }

    fn canProgress(simulator: *MnSimulator, core_index: usize) bool {
        const core = &simulator.cores[core_index];
        // Only this core can drain its own wake stack / re-attach stack, so a
        // pending one there must keep it steppable (else the driver would
        // wrongly declare deadlock while a wake is pending).
        if (core.hasPendingWake()) return true;
        if (core.hasPendingReattach()) return true;
        if (core.hasLocalWork()) return true;
        if (!simulator.global_queue.isEmptyApprox()) return true;
        // Steal availability: some OTHER core has FIFO work to take.
        for (simulator.cores, 0..) |*victim, victim_index| {
            if (victim_index == core_index) continue;
            if (victim.hasStealableWork()) return true;
        }
        return false;
    }

    /// Step one core once, mirroring the production worker-loop body but as a
    /// single discrete action driven on this one thread. Publishes the core as
    /// the current-thread scheduler for the step so the mailbox wake seam routes
    /// producer-side wakes to it (wake locality) and in-process spawns / current
    /// process resolution land on it — exactly as a real pool worker thread
    /// behaves.
    fn stepCore(simulator: *MnSimulator, core_index: usize) void {
        const core = &simulator.cores[core_index];
        const previous = Scheduler.swapCurrentThreadScheduler(core);
        defer _ = Scheduler.swapCurrentThreadScheduler(previous);

        // Service this core's cross-thread events. Deliberately NOT
        // `serviceLocalEvents` (which advances timers off the wall clock): the
        // simulator advances virtual time and fires timers ONLY through
        // `fireEarliestDueTimer`, keeping timer firing a crisp discrete event.
        core.drainPendingWakes();
        core.drainPendingReattach();

        // Local work first (LIFO slot then FIFO) — cache locality.
        if (core.takeLocalRunnable()) |record| {
            core.runNext(record);
            return;
        }
        // Global overflow queue.
        if (simulator.global_queue.pop()) |record| {
            core.runNext(record);
            return;
        }
        // Steal half of a seeded-chosen sibling's FIFO and run it immediately
        // (the production loop steals then re-loops to take-local on the same
        // core; coupling them here is faithful and avoids a work-bounce).
        if (simulator.trySeededStealFor(core_index)) {
            if (core.takeLocalRunnable()) |record| {
                core.runNext(record);
                return;
            }
        }
        // No quantum ran this step. Single-threaded, this happens only when the
        // core's sole `canProgress` justification was a pending wake/re-attach
        // that `drainPendingWakes`/`drainPendingReattach` already resolved above
        // without leaving runnable work (e.g. a wake for a since-torn-down
        // record) — a benign no-op the driver's next iteration re-evaluates.
    }

    /// Steal into `thief_index` from a seeded-chosen sibling: a seeded start
    /// offset then a full scan, taking from the first sibling with stealable
    /// FIFO work (mirrors the production `SchedulerPool.tryStealFor`, with the
    /// steal RNG replaced by the master seed).
    fn trySeededStealFor(simulator: *MnSimulator, thief_index: usize) bool {
        const n = simulator.cores.len;
        if (n <= 1) return false;
        const start = simulator.master_prng.random().uintLessThan(usize, n);
        var offset: usize = 0;
        while (offset < n) : (offset += 1) {
            const victim_index = (start + offset) % n;
            if (victim_index == thief_index) continue;
            const victim = &simulator.cores[victim_index];
            if (victim.stealInto(&simulator.cores[thief_index]) > 0) return true;
        }
        return false;
    }

    /// Advance virtual time to the globally-earliest armed `receive … after`
    /// deadline and fire one due core's timer (seeded among exact ties). Returns
    /// false when no timer is armed anywhere (a genuine deadlock). Fires ONE due
    /// core per call so the driver interleaves the woken process's cascade with
    /// any tied timer (discrete-event order; ties broken by the seed).
    fn fireEarliestDueTimer(simulator: *MnSimulator) bool {
        var earliest: ?u64 = null;
        for (simulator.cores) |*core| {
            if (core.earliestReceiveDeadlineNanoseconds()) |deadline| {
                if (earliest == null or deadline < earliest.?) earliest = deadline;
            }
        }
        const due = earliest orelse return false;
        simulator.virtual_clock.advanceTo(due);

        // Collect the cores whose earliest deadline is exactly `due` and fire a
        // seeded one.
        var tied: usize = 0;
        for (simulator.cores, 0..) |*core, core_index| {
            if (core.earliestReceiveDeadlineNanoseconds()) |deadline| {
                if (deadline == due) {
                    simulator.index_scratch[tied] = core_index;
                    tied += 1;
                }
            }
        }
        std.debug.assert(tied > 0);
        const pick = simulator.master_prng.random().uintLessThan(usize, tied);
        const fire_core = &simulator.cores[simulator.index_scratch[pick]];
        const previous = Scheduler.swapCurrentThreadScheduler(fire_core);
        defer _ = Scheduler.swapCurrentThreadScheduler(previous);
        const fired = fire_core.fireEarliestReceiveTimeout();
        std.debug.assert(fired);
        return true;
    }

    /// Reap every straggler left after a root-exit run (or a failed/deadlocked
    /// scenario), leaving the simulator quiescent (`destroy`-able). Drains each
    /// core's wake/re-attach stacks first (single-threaded — no producer races),
    /// then tears down every runnable process (per core and in the global queue)
    /// and every waiting process (via the pid table) until the live count is
    /// zero — the single-threaded analogue of `SchedulerPool.shutdownAllProcesses`.
    fn shutdownStragglers(simulator: *MnSimulator) void {
        for (simulator.cores) |*core| {
            core.drainPendingWakes();
            core.drainPendingReattach();
        }
        while (simulator.live_count > 0) {
            var progressed = false;
            for (simulator.cores) |*core| {
                while (core.takeLocalRunnable()) |record| {
                    core.teardownAsStraggler(record);
                    progressed = true;
                }
            }
            while (simulator.global_queue.pop()) |record| {
                simulator.cores[0].teardownAsStraggler(record);
                progressed = true;
            }
            if (simulator.findWaitingStraggler()) |record| {
                record.scheduler.teardownAsStraggler(record);
                progressed = true;
            }
            if (!progressed) break;
        }
        std.debug.assert(simulator.live_count == 0);
    }

    fn findWaitingStraggler(simulator: *MnSimulator) ?*ProcessRecord {
        var iterator = simulator.pid_table.iterateLiveProcesses();
        while (iterator.next()) |live| {
            if (live.pcb.currentState() == .waiting) {
                return @fieldParentPtr("pcb", live.pcb);
            }
        }
        return null;
    }

    /// Assert the post-run exact-accounting invariant (plan 1.4): no live
    /// processes, no live or abandoned envelope pages, and every spawned
    /// process's manager torn down exactly once. Fiber stacks live in per-core
    /// pools; a leaked stack surfaces as a live process (never torn down), which
    /// the live-process check already catches.
    pub fn verifyExactAccounting(simulator: *MnSimulator) AccountingError!void {
        if (simulator.live_count != 0) return error.LiveProcessesRemain;
        if (simulator.pid_table.statistics().live_process_count != 0) return error.LiveProcessesRemain;
        const envelope_statistics = simulator.envelope_pool.statistics();
        if (envelope_statistics.live_page_count != 0) return error.EnvelopePagesLeaked;
        if (envelope_statistics.abandoned_page_count != 0) return error.EnvelopePagesAbandoned;
        for (simulator.process_managers.items) |manager| {
            if (manager.teardown_count != 1) return error.ManagerTeardownMismatch;
        }
    }

    // -- pool hooks (single-threaded trampolines) ------------------------------

    fn liveCountDeltaHook(context: ?*anyopaque, delta: i32) void {
        const simulator: *MnSimulator = @ptrCast(@alignCast(context.?));
        simulator.live_count += @as(i64, delta);
    }

    fn notifyWorkHook(context: ?*anyopaque) void {
        // No-op: the discrete-event driver re-scans the steppable set every
        // iteration, so there is no parked worker to wake.
        _ = context;
    }

    fn onProcessExitHook(context: ?*anyopaque, exited_pid_bits: u64) void {
        // Root-exit termination is polled by the driver via the pid table
        // (`until_root`), so this hook needs no state; kept for the `PoolHooks`
        // contract (a standalone `Scheduler` requires the full seam).
        _ = context;
        _ = exited_pid_bits;
    }
};

/// Options for `runScenario`/`runSeedSweep`.
pub const ScenarioOptions = struct {
    /// Simulator construction options.
    simulator: MnSimulator.Options = .{},
    /// Optional post-run verification (runs after quiescence and the
    /// exact-accounting check; its error fails the scenario and prints the
    /// seed).
    verify_after_run: ?ScenarioFunction = null,
    /// Test-only seam: suppress the failing-seed replay print for a scenario
    /// DELIBERATELY driven to a known failure (a negative self-test asserts on
    /// the returned error), keeping `test-kernel` stderr clean. Left false for
    /// every genuine run so the plan-4.4 failing-seed contract still fires.
    /// Mirrors `deterministic.ScenarioOptions.suppress_failure_seed_print`.
    suppress_failure_seed_print: bool = false,
};

/// Run `scenario` under `seed` to quiescence, verify exact accounting (and the
/// optional scenario verifier), and return the owned core-tagged trace (caller
/// frees with `allocator.free`).
///
/// THE FAILING-SEED CONTRACT (plan 1.5/4.4): on ANY failure this prints the
/// seed to stderr before propagating the error, so the exact M:N interleaving
/// is replayable by passing the printed seed back in.
pub fn runScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    scenario: ScenarioFunction,
    scenario_context: ?*anyopaque,
    options: ScenarioOptions,
) ![]MnTraceEvent {
    errdefer if (!options.suppress_failure_seed_print) std.debug.print(
        "\n[deterministic-mn] scenario FAILED under seed {d} (0x{x}) — rerun with this seed for an exact M:N replay\n",
        .{ seed, seed },
    );
    // Own the shared structures locally; the simulator borrows them. Teardown
    // order (defers run in reverse): simulator first (reaps stragglers through
    // the pid table + envelope pool), then the envelope pool, then the pid table.
    var pid_table = try PidTable.init(allocator, .{ .capacity = options.simulator.pid_capacity });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(allocator, .{ .envelopes_per_page = options.simulator.envelopes_per_page });
    defer envelope_pool.deinit();
    var simulator = try MnSimulator.create(allocator, &pid_table, &envelope_pool, seed, options.simulator);
    defer simulator.destroy();

    try scenario(simulator, scenario_context);
    try simulator.runToQuiescence();
    try simulator.verifyExactAccounting();
    if (options.verify_after_run) |verify| try verify(simulator, scenario_context);

    return allocator.dupe(MnTraceEvent, simulator.trace());
}

/// Run `scenario` under `seed_count` consecutive seeds starting at `first_seed`
/// (verona-rt-style seed sweep, plan decision 11 / item 4.4). Any failing seed
/// is printed by `runScenario` before the error propagates.
pub fn runSeedSweep(
    allocator: std.mem.Allocator,
    first_seed: u64,
    seed_count: u64,
    scenario: ScenarioFunction,
    scenario_context: ?*anyopaque,
    options: ScenarioOptions,
) !void {
    var seed_offset: u64 = 0;
    while (seed_offset < seed_count) : (seed_offset += 1) {
        const trace = try runScenario(allocator, first_seed + seed_offset, scenario, scenario_context, options);
        allocator.free(trace);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// -- fan-in scenario: producers (stolen across cores) send to one consumer ------

const fan_in_producer_count = 4;
const fan_in_messages_per_producer = 6;

const FanInProducerState = struct {
    consumer_pid: Pid = Pid.invalid,
    producer_index: usize = 0,
};

const FanInScenarioState = struct {
    producers: [fan_in_producer_count]FanInProducerState = @splat(.{}),
    consumer_pid: Pid = Pid.invalid,
    received_total: usize = 0,
    per_producer_received: [fan_in_producer_count]usize = @splat(0),
    pairwise_fifo_violation: bool = false,
    /// Set true by the buggy invariant variant (see the race test): the
    /// consumer additionally asserts total arrival order is "all of producer 0,
    /// then all of producer 1, …", an assumption only a single-core FIFO run
    /// upholds. M:N interleaving breaks it.
    assert_global_producer_order: bool = false,
    global_order_violation: bool = false,
    last_seen_producer: usize = 0,
};

fn fanInProducerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const producer: *FanInProducerState = @ptrCast(@alignCast(argument.?));
    var sequence: usize = 0;
    while (sequence < fan_in_messages_per_producer) : (sequence += 1) {
        const stamp = (producer.producer_index << 16) | sequence;
        const outcome = context.send(producer.consumer_pid, .{ .payload_byte_length = stamp }) catch
            @panic("fan-in producer: envelope allocation failed");
        std.debug.assert(outcome == .delivered);
        // Safepoint between sends: seeded budgets can preempt mid-burst so a
        // sibling core's producer interleaves.
        context.yieldCheck();
    }
}

fn fanInConsumerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *FanInScenarioState = @ptrCast(@alignCast(argument.?));
    const expected_total = fan_in_producer_count * fan_in_messages_per_producer;
    while (state.received_total < expected_total) {
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        const producer_index = stamp >> 16;
        const sequence = stamp & 0xFFFF;
        // Pairwise FIFO (a real guarantee): each producer's messages arrive in
        // send order.
        if (sequence != state.per_producer_received[producer_index]) state.pairwise_fifo_violation = true;
        state.per_producer_received[producer_index] += 1;
        // The buggy global-order assumption (only the race variant sets this).
        if (state.assert_global_producer_order) {
            if (producer_index < state.last_seen_producer) state.global_order_violation = true;
            state.last_seen_producer = producer_index;
        }
        state.received_total += 1;
    }
}

fn fanInScenario(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    const state: *FanInScenarioState = @ptrCast(@alignCast(scenario_context.?));
    state.consumer_pid = try simulator.spawnProcess(fanInConsumerEntry, state);
    for (&state.producers, 0..) |*producer, producer_index| {
        producer.* = .{ .consumer_pid = state.consumer_pid, .producer_index = producer_index };
        _ = try simulator.spawnProcess(fanInProducerEntry, producer);
    }
}

fn fanInVerify(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    _ = simulator;
    const state: *FanInScenarioState = @ptrCast(@alignCast(scenario_context.?));
    if (state.pairwise_fifo_violation) return error.PairwiseFifoViolated;
    if (state.received_total != fan_in_producer_count * fan_in_messages_per_producer) return error.MessagesLost;
    for (state.per_producer_received) |received| {
        if (received != fan_in_messages_per_producer) return error.MessagesLost;
    }
    if (state.assert_global_producer_order and state.global_order_violation) return error.GlobalProducerOrderViolated;
}

fn traceUsesMultipleCores(trace: []const MnTraceEvent) bool {
    if (trace.len == 0) return false;
    const first_core = trace[0].core_index;
    for (trace) |event| {
        if (event.core_index != first_core) return true;
    }
    return false;
}

fn traceWakeCount(trace: []const MnTraceEvent) usize {
    var count: usize = 0;
    for (trace) |event| {
        if (event.kind == .wake) count += 1;
    }
    return count;
}

test "DeterministicMn: same seed twice yields byte-identical M:N interleaving (fan-in, work-stealing, cross-core sends)" {
    var first_state = FanInScenarioState{};
    const first_trace = try runScenario(testing.allocator, 0x5EED_4A11, fanInScenario, &first_state, .{
        .simulator = .{ .core_count = 3 },
        .verify_after_run = fanInVerify,
    });
    defer testing.allocator.free(first_trace);

    var second_state = FanInScenarioState{};
    const second_trace = try runScenario(testing.allocator, 0x5EED_4A11, fanInScenario, &second_state, .{
        .simulator = .{ .core_count = 3 },
        .verify_after_run = fanInVerify,
    });
    defer testing.allocator.free(second_trace);

    // The core reproducibility contract: same seed ⇒ byte-identical core-tagged
    // interleaving.
    try testing.expect(mnTracesIdentical(first_trace, second_trace));

    // And the trace is a GENUINE M:N interleaving: events on more than one core,
    // real cross-core wake traffic, and the full spawn/exit vocabulary.
    try testing.expect(traceUsesMultipleCores(first_trace));
    try testing.expect(traceWakeCount(first_trace) > 0);
    var spawn_count: usize = 0;
    var exit_count: usize = 0;
    for (first_trace) |event| {
        switch (event.kind) {
            .spawn => spawn_count += 1,
            .exit => exit_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1 + fan_in_producer_count), spawn_count);
    try testing.expectEqual(@as(usize, 1 + fan_in_producer_count), exit_count);
}

test "DeterministicMn: different seeds explore divergent interleavings" {
    const seed_count = 16;
    var traces: [seed_count][]MnTraceEvent = undefined;
    var collected: usize = 0;
    defer for (traces[0..collected]) |trace| testing.allocator.free(trace);

    for (0..seed_count) |seed_index| {
        var state = FanInScenarioState{};
        traces[seed_index] = try runScenario(
            testing.allocator,
            0x1000 + @as(u64, seed_index),
            fanInScenario,
            &state,
            .{ .simulator = .{ .core_count = 3 }, .verify_after_run = fanInVerify },
        );
        collected += 1;
    }

    var found_divergence = false;
    for (traces[1..]) |trace| {
        if (!mnTracesIdentical(traces[0], trace)) found_divergence = true;
    }
    try testing.expect(found_divergence);
}

// -- concurrent send + steal + timer sweep --------------------------------------

const timer_sweep_producer_count = 3;
const timer_sweep_messages_per_producer = 4;

const TimerSweepState = struct {
    producers: [timer_sweep_producer_count]FanInProducerState = @splat(.{}),
    consumer_pid: Pid = Pid.invalid,
    received_total: usize = 0,
    per_producer_received: [timer_sweep_producer_count]usize = @splat(0),
    pairwise_fifo_violation: bool = false,
    timed_waiter_timed_out: bool = false,
};

/// A producer for the timer sweep: sends exactly `timer_sweep_messages_per_producer`
/// tagged messages to the consumer, with a safepoint between sends so seeded
/// budgets interleave it with sibling cores' producers.
fn timerSweepProducerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const producer: *FanInProducerState = @ptrCast(@alignCast(argument.?));
    var sequence: usize = 0;
    while (sequence < timer_sweep_messages_per_producer) : (sequence += 1) {
        const stamp = (producer.producer_index << 16) | sequence;
        const outcome = context.send(producer.consumer_pid, .{ .payload_byte_length = stamp }) catch
            @panic("timer-sweep producer: envelope allocation failed");
        std.debug.assert(outcome == .delivered);
        context.yieldCheck();
    }
}

/// A consumer that arms a `receive … after` timer each round (a GENEROUS
/// deadline it never approaches): every round a cross-core message must beat the
/// timer, exercising the cross-scheduler timer-cancel path under seeded
/// interleaving. Firing of the timer would be a lost-message bug.
fn timerSweepConsumerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *TimerSweepState = @ptrCast(@alignCast(argument.?));
    const expected_total = timer_sweep_producer_count * timer_sweep_messages_per_producer;
    while (state.received_total < expected_total) {
        const outcome = context.receiveWaitTimeout(10 * std.time.ns_per_s);
        if (outcome == .timed_out) {
            state.pairwise_fifo_violation = true; // a spurious timeout under a generous deadline
            return;
        }
        const envelope = context.receive();
        const stamp = envelope.fragment.payload_byte_length;
        envelope_pool_module.free(envelope);
        const producer_index = stamp >> 16;
        const sequence = stamp & 0xFFFF;
        if (sequence != state.per_producer_received[producer_index]) state.pairwise_fifo_violation = true;
        state.per_producer_received[producer_index] += 1;
        state.received_total += 1;
    }
}

/// A standalone timed waiter that no one ever sends to: its `receive … after`
/// timer MUST fire (via the simulator's virtual clock) — proving the seeded
/// virtual-time timer path delivers under M:N.
fn timerSweepTimedWaiterEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *TimerSweepState = @ptrCast(@alignCast(argument.?));
    const outcome = context.receiveWaitTimeout(50 * std.time.ns_per_ms);
    if (outcome == .timed_out) state.timed_waiter_timed_out = true;
}

fn timerSweepScenario(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    const state: *TimerSweepState = @ptrCast(@alignCast(scenario_context.?));
    // Reset per run: `runSeedSweep` reuses one state across seeds (mirrors
    // `deterministic.sweepScenario`).
    state.* = .{};
    state.consumer_pid = try simulator.spawnProcess(timerSweepConsumerEntry, state);
    _ = try simulator.spawnProcess(timerSweepTimedWaiterEntry, state);
    for (&state.producers, 0..) |*producer, producer_index| {
        producer.* = .{ .consumer_pid = state.consumer_pid, .producer_index = producer_index };
        _ = try simulator.spawnProcess(timerSweepProducerEntry, producer);
    }
}

fn timerSweepVerify(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    _ = simulator;
    const state: *TimerSweepState = @ptrCast(@alignCast(scenario_context.?));
    if (state.pairwise_fifo_violation) return error.PairwiseFifoOrSpuriousTimeout;
    if (state.received_total != timer_sweep_producer_count * timer_sweep_messages_per_producer) return error.MessagesLost;
    // The standalone waiter's virtual-time timer must have fired.
    if (!state.timed_waiter_timed_out) return error.TimedWaiterNeverFired;
}

test "DeterministicMn: 64-seed sweep of concurrent send + steal + timer holds every invariant" {
    var state = TimerSweepState{};
    try runSeedSweep(testing.allocator, 0xBA5E_713E, 64, timerSweepScenario, &state, .{
        .simulator = .{ .core_count = 3 },
        .verify_after_run = timerSweepVerify,
    });
}

// -- injected race: an M:N interleaving reproduced by its seed --------------------

/// The buggy variant of the fan-in scenario: the consumer additionally asserts a
/// GLOBAL producer arrival order ("all of producer 0 before any of producer 1,
/// …"), a WRONG assumption that only a single-core FIFO run upholds. Under M:N,
/// producers run on different cores (work stealing) and their sends interleave,
/// so some seeds violate it — a genuine M:N ordering bug the simulator both
/// FINDS (a sweep surfaces a failing seed) and REPRODUCES (that seed fails
/// identically every time). The pairwise-FIFO invariant, a REAL guarantee, holds
/// under every seed regardless — proving the simulator does not false-positive.
fn buggyFanInScenario(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    const state: *FanInScenarioState = @ptrCast(@alignCast(scenario_context.?));
    state.assert_global_producer_order = true;
    return fanInScenario(simulator, scenario_context);
}

/// Sweep seeds until the buggy global-order invariant is violated; returns the
/// first violating seed, or null if none in the range.
fn findRaceReproducingSeed(first_seed: u64, seed_count: u64) !?u64 {
    var seed_offset: u64 = 0;
    while (seed_offset < seed_count) : (seed_offset += 1) {
        const seed = first_seed + seed_offset;
        var state = FanInScenarioState{};
        const result = runScenario(testing.allocator, seed, buggyFanInScenario, &state, .{
            .simulator = .{ .core_count = 3 },
            .verify_after_run = fanInVerify,
            .suppress_failure_seed_print = true, // sweeping-to-find: the banner is noise here
        });
        if (result) |trace| {
            testing.allocator.free(trace);
        } else |err| {
            try testing.expectEqual(error.GlobalProducerOrderViolated, err);
            return seed;
        }
    }
    return null;
}

test "DeterministicMn: a known M:N ordering race is FOUND by a seed sweep and REPRODUCED by that seed" {
    // 1. A sweep FINDS an interleaving that violates the buggy global-order
    //    assumption — proving the simulator explores M:N interleavings.
    const violating_seed = (try findRaceReproducingSeed(0xF00D_0000, 400)) orelse
        return error.NoRaceFoundInSweep;

    // 2. That exact seed REPRODUCES the violation — every time. Determinism is
    //    the whole point: three runs of the same seed fail identically.
    for (0..3) |_| {
        var state = FanInScenarioState{};
        try testing.expectError(error.GlobalProducerOrderViolated, runScenario(
            testing.allocator,
            violating_seed,
            buggyFanInScenario,
            &state,
            .{ .simulator = .{ .core_count = 3 }, .verify_after_run = fanInVerify, .suppress_failure_seed_print = true },
        ));
    }

    // 3. The REAL invariant (pairwise FIFO) holds under the same seed — the bug
    //    is the wrong ORDERING ASSUMPTION, not a kernel defect. The simulator
    //    does not false-positive on correct code.
    var honest_state = FanInScenarioState{};
    const honest_trace = try runScenario(testing.allocator, violating_seed, fanInScenario, &honest_state, .{
        .simulator = .{ .core_count = 3 },
        .verify_after_run = fanInVerify,
    });
    defer testing.allocator.free(honest_trace);
    try testing.expect(!honest_state.pairwise_fifo_violation);
}

// -- deterministic deadlock + failing-seed propagation ---------------------------

fn deadlockedWaiterEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("nobody ever sends to the deadlocked waiter");
}

fn deadlockScenario(simulator: *MnSimulator, scenario_context: ?*anyopaque) anyerror!void {
    _ = scenario_context;
    _ = try simulator.spawnProcess(deadlockedWaiterEntry, null);
}

test "DeterministicMn: idle with a waiting process (no timer) surfaces AllProcessesWaiting" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var simulator = try MnSimulator.create(testing.allocator, &pid_table, &envelope_pool, 99, .{ .core_count = 2 });
    defer simulator.destroy();

    try deadlockScenario(simulator, null);
    try testing.expectError(error.AllProcessesWaiting, simulator.runToQuiescence());
    // destroy() reaps the deadlocked waiter and every pool balances.
}

test "DeterministicMn: a failing scenario propagates its error through runScenario" {
    var state: usize = 0;
    _ = &state;
    try testing.expectError(
        error.AllProcessesWaiting,
        runScenario(testing.allocator, 7, deadlockScenario, null, .{
            .simulator = .{ .core_count = 2 },
            .suppress_failure_seed_print = true,
        }),
    );
}

test "DeterministicMn: mnTracesIdentical distinguishes core, kind, and pid" {
    const base = [_]MnTraceEvent{
        .{ .core_index = 0, .kind = .spawn, .pid_bits = 1 },
        .{ .core_index = 1, .kind = .schedule, .pid_bits = 1 },
        .{ .core_index = 0, .kind = .exit, .pid_bits = 1 },
    };
    const same = base;
    const different_core = [_]MnTraceEvent{
        .{ .core_index = 0, .kind = .spawn, .pid_bits = 1 },
        .{ .core_index = 0, .kind = .schedule, .pid_bits = 1 }, // core differs
        .{ .core_index = 0, .kind = .exit, .pid_bits = 1 },
    };
    const different_kind = [_]MnTraceEvent{
        .{ .core_index = 0, .kind = .spawn, .pid_bits = 1 },
        .{ .core_index = 1, .kind = .yield, .pid_bits = 1 },
        .{ .core_index = 0, .kind = .exit, .pid_bits = 1 },
    };

    try testing.expect(mnTracesIdentical(&base, &same));
    try testing.expect(!mnTracesIdentical(&base, &different_core));
    try testing.expect(!mnTracesIdentical(&base, &different_kind));
    try testing.expect(!mnTracesIdentical(&base, base[0..2]));
}

test "DeterministicMn: single-core configuration is a legal degenerate simulation" {
    // A one-core simulator is still a valid seeded run (no stealing; the driver
    // steps the sole core) — the fallback shape, and a determinism check that
    // the core-count knob does not break replay.
    var first_state = FanInScenarioState{};
    const first_trace = try runScenario(testing.allocator, 0xC0FFEE, fanInScenario, &first_state, .{
        .simulator = .{ .core_count = 1 },
        .verify_after_run = fanInVerify,
    });
    defer testing.allocator.free(first_trace);

    var second_state = FanInScenarioState{};
    const second_trace = try runScenario(testing.allocator, 0xC0FFEE, fanInScenario, &second_state, .{
        .simulator = .{ .core_count = 1 },
        .verify_after_run = fanInVerify,
    });
    defer testing.allocator.free(second_trace);

    try testing.expect(mnTracesIdentical(first_trace, second_trace));
    // One core: every event is on core 0.
    try testing.expect(!traceUsesMultipleCores(first_trace));
}
