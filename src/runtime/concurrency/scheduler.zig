//! Run-queue scheduler core for the Zap concurrency kernel.
//!
//! Phase 1 item 1.4 of `docs/concurrency-implementation-plan.md` (job
//! P1-J4), plus the 1.4/1.5 idle park/wake sub-item pulled forward by
//! Appendix A.3. This module owns spawn, the run loop, preemption-budget
//! mechanics, the flag-only watchdog seam, exit/kill teardown, and idle
//! parking — the orchestration layer over the landed kernel structures
//! (`fiber_context.zig`, `stack_pool.zig`, `pid_table.zig`,
//! `mailbox.zig`, `envelope_pool.zig`, `process.zig`).
//!
//! ## Instance-based by design (Phase 4 multiplication)
//!
//! There is NO module-level mutable state anywhere in this file. A
//! `Scheduler` is a value: Phase 1 constructs exactly one; Phase 4
//! constructs one per core over a SHARED `PidTable` and `EnvelopePool`
//! (which are already M:N-safe) while each scheduler keeps its OWN stack
//! pool, ready queue, record cache, and park word (plan §6.1 of
//! research.md: per-core run queues + work stealing multiply this
//! instance, they do not refactor it).
//!
//! ## The run loop
//!
//! ```
//!   runUntilQuiescent:
//!     loop {
//!       drain the cross-thread wake stack (waiting → runnable)
//!       pick a runnable process        (Decisions seam; production = FIFO)
//!       ├─ pending kill? → teardown (killed) and loop
//!       ├─ found: run one quantum (switch in → run until yield/wait/exit
//!       │         → switch out), classify the yield, loop
//!       └─ none: zero live processes → return (quiescent)
//!               live processes exist → idle (spin ~1–2 µs, then park on
//!               the futex word) or, when parking is forbidden
//!               (deterministic mode), return error.AllProcessesWaiting
//!     }
//! ```
//!
//! ### Ready queue: intrusive FIFO, and the Phase 4 upgrade path
//!
//! The ready queue is an intrusive singly-linked FIFO through
//! `ProcessRecord.ready_next` (head+tail, O(1) enqueue, O(1) FIFO
//! dequeue). Which queued process runs next is NOT the queue's decision —
//! it is the `Decisions` seam's (deterministic mode picks by seeded PRNG,
//! which costs an O(index) unlink walk that production never pays;
//! production FIFO always picks index 0). Phase 4 (plan §5 items
//! 4.1/A.2) upgrades this to per-scheduler queues with a LIFO slot for
//! message-driven wakeup locality plus a global overflow queue and work
//! stealing; the `Decisions` seam and the quantum machinery are unchanged
//! by that upgrade — only the pick/enqueue implementation multiplies.
//!
//! ### The per-quantum current-process discipline (plan A.2.4/A.3, E10)
//!
//! `current_process` is written exactly once at quantum entry and cleared
//! at quantum exit; every kernel entry point that runs on behalf of a
//! process receives the process as a PARAMETER (`ProcessContext`), never
//! by re-resolving scheduler state — E10 measured per-site Darwin TLV
//! reads at +13.8% on the pure-alloc shape, so re-resolution per call
//! site is banned by design. In Phase 1 the scheduler-instance field IS
//! the mechanism (kernel code is all parameter-threaded). Phase 2 exposes
//! the pointer to compiled Zap code by either (a) a TLS slot written once
//! here at quantum entry and read once per compiled-function entry, or
//! (b) parameter-threading through the compiled ABI — plan Appendix A.4
//! open question 1 decides between them with measured numbers; the
//! quantum-entry write below is the seam either choice hooks into.
//!
//! ## Preemption budget + flag-only watchdog (plan decision 6, item 2.5)
//!
//! Every quantum starts with a budget in reductions (`Decisions` may vary
//! it; production uses the configured default). `ProcessContext.yieldCheck`
//! — the Phase 1 kernel-test safepoint — decrements the budget and yields
//! when it reaches zero, when the watchdog flag is set, or when a kill is
//! pending. The watchdog is FLAG-ONLY: any thread may set it
//! (`requestWatchdogPreemption`), the running process observes it at its
//! next safepoint and yields, and the scheduler clears it at the end of that
//! quantum (one-shot consume). The timer thread that sets it periodically is
//! Phase 4; tests exercise the seam by setting the flag directly. Flag-only
//! is what keeps the watchdog wasm-portable (no signals; Go #36365).
//!
//! ### Compiler-emitted safepoints (P2-J6, plan item 2.5)
//!
//! From Phase 2 on, COMPILED Zap code reaches this machinery through
//! `abi.zap_proc_safepoint_slow` → `ProcessContext.reductionSafepoint`, the
//! shared slow path of a three-layer cooperative-safepoint design the ZIR
//! builder emits (all comptime-gated on `runtime_concurrency`: OFF ⇒ zero
//! emission ⇒ the CLBG binaries are byte-for-byte unchanged):
//!
//!   * **Layer 2, loopified loops** — a loop-local `u32` reduction counter
//!     (LLVM promotes it to a register: a `subs`/`cbz` per iteration, no
//!     per-iteration memory) seeded from `zap_proc_reductions_budget` and
//!     polled at the loop's back-edge. Emitted for EVERY loopified loop, not
//!     just statically alloc-free ones: Zap's `list_cons`/map growth
//!     allocate through an amortized (doubling) `bufferAlloc`, so relying on
//!     the layer-1 alloc piggyback for allocating loops would leave a
//!     conses-each-iteration loop polled only O(log n) times — far too
//!     rarely to bound preemption.
//!   * **Layer 2, musttail loops** — a TCO-safe self-recursive function
//!     reuses its frame (no promotable loop-local slot), so its back-edge
//!     poll (`Kernel.procReductionTick`) rides the shared GLOBAL reduction
//!     counter `zap_proc_reductions_remaining`.
//!   * **Layer 1, alloc piggyback** — `procReductionTick` again, one
//!     reduction per manager cell/buffer allocation (`allocAny`/`bufferAlloc`),
//!     the safepoint for allocation bursts outside a tail loop.
//!
//! The scheduler publishes both counters at quantum entry (`runQuantum`) —
//! the per-quantum current-process discipline (A.2.4) extended to the
//! emitted safepoints. `reductionSafepoint` yields only when preemption can
//! matter (kill / watchdog / a co-runnable peer), so a sole runnable process
//! (a CLBG hot loop with concurrency compiled on) stays switch-free.
//!
//! ### Advertised preemption-latency bound
//!
//! Because every Zap loop is a tail-recursive function (loopified or
//! musttail) and BOTH forms are now polled, preemption latency is bounded by
//! **one reduction budget's worth of iterations of the slowest polled loop**
//! (plus one watchdog tick, whichever is larger): a co-runnable peer or a set
//! watchdog flag is observed at the next budget boundary. The residual
//! un-polled code is straight-line sequences and NON-tail-recursive call
//! chains, each bounded by its own finite instruction count / stack depth —
//! the honest analogue of Go's documented "un-splittable leaf kernel" case,
//! but narrower here since Zap has no unbounded non-tail loop form. The
//! separate E7 hazard (a fiber blocking INSIDE a manager call — a GC pause,
//! a lazy-commit fault) is out of scope for the poll and handled by the
//! Phase-4 dirty-scheduler handoff.
//!
//! ## Spawn (plan 1.4 + A.3: the E1-measured hot path)
//!
//! Spawn is pool-only after warmup — the steady-state path performs NO
//! syscalls and NO backing-allocator calls: record from the record cache
//! (pool hit), stack from the stack pool (pool hit — the E9 8.99 ns
//! pooled-spawn floor), pid slot from the lock-free free list, envelope
//! handle init (allocation-free), and a ready-queue append. Fresh mmap /
//! allocator traffic happens only on pool growth (first spawns).
//!
//! ### Lazy-start decision (Appendix A lazy-admission note) — DECIDED
//!
//! Spawn acquires the pooled stack EAGERLY and defers everything else:
//! no byte of the stack is touched at spawn (the entry frame is written
//! by `fiber_context.resumeFiber` on the FIRST schedule — that half of
//! lazy-start is structural in the landed fiber module), and the fiber
//! runs no code until its first quantum. Full stack-deferral (acquire at
//! first schedule) was considered and REJECTED: a pool-hit acquire is
//! ~9 ns (E9) so the spawn-path saving is negligible, while deferral
//! moves `error.StackReservationFailed` from spawn — where the caller
//! handles it synchronously, the BEAM-aligned contract — to first
//! dispatch, where no caller exists and the kernel would have to convert
//! a resource failure into an asynchronous crash of an already-visible
//! pid. Spawn stays the single synchronous failure point.
//!
//! ## Exit and crash teardown (plan Phase 1 item 1.4 "spawn/exit/
//! teardown" — the wholesale-free guarantee)
//!
//! Normal exit (entry function returns) and kill run ONE teardown path:
//!
//! 1. transition to `.exiting`;
//! 2. unregister the pid — the generation bump dead-letters every
//!    outstanding copy INSTANTLY, before any resource is torn down (the
//!    order `process.zig` documents: no lookup may resolve to a process
//!    whose heap is being torn down);
//! 3. drain the cross-thread wake stack — after unregister no new wake
//!    entry can reference this record (a wake rides a mailbox push, which
//!    rides a successful lookup), and draining flushes any entry pushed
//!    before unregister, so a recycled record can never be reached
//!    through the wake stack;
//! 4. run the drop-list destructors, LIFO (newest-first, the `defer`
//!    ordering; `process.registerDropResource`);
//! 5. drain the mailbox and free every envelope to its ORIGIN page
//!    (`envelope_pool.free`) — foreign senders' envelopes go back to
//!    their pages, reclaiming abandoned ones (dead-lettering of the
//!    payload contents is a Phase 2 concern; Phase 1 fragments are
//!    opaque);
//! 6. abandon the process's envelope-pool handle — own pages with
//!    still-in-flight envelopes flip to `.abandoned` and are reclaimed by
//!    whichever receiver frees their last envelope (J3 semantics);
//! 7. release the stack via the invariant path: a finished fiber's stack
//!    was already released by `resumeFiber`'s post-switch path; a killed
//!    `.ready`/`.suspended` fiber goes through
//!    `fiber_context.reclaimWithoutResume` (the fiber has provably left
//!    the stack — see that function's doc);
//! 8. wholesale-free the process heap (`manager.teardown()` — plan Phase
//!    1 item 1.4: bulk arena/slab free, never per-object);
//! 9. recycle the record.
//!
//! Leak accounting balances EXACTLY after every teardown: stack pool,
//! envelope pool, pid table, and record cache all return to their
//! pre-spawn counts (asserted by the tests below and by the pools' own
//! `deinit` asserts).
//!
//! **Crash teardown:** a kill is the same teardown from a non-cooperative
//! point — a `.waiting` process is torn down immediately without ever
//! being resumed (its suspended stack is reclaimed unwound-free; owned
//! resources ride the drop-list, not stack unwinding), and a `.runnable`/
//! `.running` process is marked and torn down at its next scheduling
//! point/safepoint (`kill` is untrappable — there is no user-level hook).
//! Phase 1 SIMULATES crashes via this explicit kill API; wiring
//! trap/panic entry into the same path is Phase 2+ (plan 2.x), and
//! `io.cancel()`-based cancellation of in-flight I/O joins the drop-list
//! run when the `std.Io` vtable lands (plan §3; re-scoped out of Phase 1
//! item 1.4 — see that item's annotation in
//! `docs/concurrency-implementation-plan.md`, which cites this doc back).
//!
//! ## Idle parking (E9 / plan A.2.2–A.2.3, Appendix A.3)
//!
//! When no process is runnable but live processes exist, the scheduler
//! spins `spin_iterations_before_park` iterations (default sized to the
//! E9 crossover: a parked wake costs ~900 ns end-to-end ≈ one park, so
//! spin 1–2 µs before paying it) checking the wake stack, then parks on a
//! 32-bit futex word (`wake_epoch`) using an eventcount protocol:
//!
//! * `wake()` (any thread): bump `wake_epoch`, then futex-wake ONLY if
//!   the parked hint is set — an un-parked scheduler costs producers zero
//!   syscalls.
//! * park: load epoch → re-check work → publish the parked hint → futex
//!   wait while `wake_epoch` still equals the loaded value. The futex's
//!   own value check makes the hint a pure syscall-elision optimization:
//!   a wake that lands between the epoch load and the wait entry changes
//!   the word and the wait returns immediately — no lost-wake window.
//!   The wait is additionally time-bounded (`park_timeout_nanoseconds`)
//!   as defense-in-depth; the loop re-checks work on every return.
//!
//! ### Darwin futex mapping (verified against the fork, E9-measured)
//!
//! The fork has NO `std.Thread.Futex`; its futex surface lives inside
//! `Io/Threaded.zig` as `__ulock_wait2`/`__ulock_wait`/`__ulock_wake`
//! (verified 2026-07). Per the Appendix A.2.2 decision this module uses
//! Apple's PUBLIC futex API `os_sync_wait_on_address_with_timeout` /
//! `os_sync_wake_by_address_any` when the target's minimum macOS version
//! is ≥ 14.4 (the API's availability floor), and otherwise falls back to
//! `__ulock_wait2` (macOS ≥ 11) / `__ulock_wait`, gated at comptime on
//! `builtin.os.version_range` exactly as the fork's `Io.Threaded` gates
//! its ulock selection. E9 measured the parked-wake cost at ~917 ns
//! median for the os_sync path with all four Darwin mechanisms within
//! ~20% (792–958 ns), so the fallback costs nothing measurable; the
//! kqueue `EVFILT_USER` path is reserved for the Phase 4 I/O poller
//! thread per A.2.2. Linux parks on `futex(2)` `WAIT`/`WAKE` (private);
//! other OSes are Phase 4/7 ports and fail loudly at comptime.
//!
//! ### Cross-thread wake sources (Phase 1)
//!
//! 1. **Mailbox push to a waiting process**: spawn installs this
//!    module's wake callback into the process's mailbox seam
//!    (`mailbox.zig`, "Wake-signal exactness"); the empty→nonempty push —
//!    from ANY thread — marks the record's wake-pending flag, pushes the
//!    record onto the scheduler's lock-free wake stack (Treiber push;
//!    the scheduler consumes with a pop-all swap, so there is no ABA),
//!    and calls `wake()`.
//! 2. **External spawn**: `spawn` itself is scheduler-thread-only in
//!    Phase 1 (it mutates the thread-local stack pool and ready queue),
//!    so a remote spawner cannot exist yet; the public, thread-safe
//!    `wake()` is the seam Phase 4's cross-scheduler admission
//!    (spawn-injection + work stealing) will ride, and spawn calls it
//!    unconditionally so the wake edge is exercised from day one.
//!
//! A wake targeting a process that is not `.waiting` degrades to a no-op
//! (the message is already observable to its next receive); a wake
//! processed after a spurious flag reset degrades to a spurious
//! runnable→receive→wait cycle. Both are benign and deterministic-mode
//! safe. The one genuinely unhandled shape — a foreign thread's send
//! racing the TARGET's teardown after it already passed `lookup` — is
//! the documented Phase 4 PCB-lifetime caveat (`pid_table.zig`,
//! `mailbox.zig`) and is out of the single-scheduler Phase 1 contract;
//! the record cache softens even that (records are never returned to the
//! backing allocator until `deinit`, so such a racing push can never
//! touch unmapped memory).
//!
//! ## Deterministic mode (plan 1.5)
//!
//! ALL scheduler nondeterminism is funneled through the `Decisions` seam:
//! which runnable process runs next, and the quantum budget (varying the
//! budget moves every preemption point). Production mode is FIFO with the
//! configured budget (`Decisions.production_fifo`). `deterministic.zig`
//! provides the seeded implementation, the trace recorder (the
//! `TraceHook` seam below), and the replay harness; deterministic runs
//! forbid parking (`IdleStrategy.forbid_parking`) — a deterministic
//! scheduler that would park is a deadlocked scenario and surfaces as
//! `error.AllProcessesWaiting`, never as a real futex sleep.
//!
//! ## Toolchain
//!
//! This module resumes fibers, so the kernel-wide fork-compiler
//! requirement for optimized builds applies (see `concurrency.zig`).

const std = @import("std");
const builtin = @import("builtin");
const fiber_context = @import("fiber_context.zig");
const stack_pool_module = @import("stack_pool.zig");
const pid_table_module = @import("pid_table.zig");
const mailbox_module = @import("mailbox.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const process_module = @import("process.zig");
const crash_report_module = @import("crash_report.zig");
const timing_wheel_module = @import("timing_wheel.zig");
const signal_module = @import("signal.zig");
const registry_module = @import("registry.zig");
const blob_module = @import("blob.zig");

const Pid = pid_table_module.Pid;
const PidTable = pid_table_module.PidTable;
const ReclamationModel = pid_table_module.ReclamationModel;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const StackPool = stack_pool_module.StackPool;
const ProcessControlBlock = process_module.ProcessControlBlock;
const ManagerContext = process_module.ManagerContext;

/// A process body: runs on the process's fiber stack, receives the
/// per-quantum kernel capability (`ProcessContext` — the parameter-
/// threaded current process, plan A.2.4) and the opaque spawn argument.
/// Returning normally exits the process.
pub const ProcessEntry = *const fn (context: *ProcessContext, argument: ?*anyopaque) void;

/// Why a teardown ran; selects the trace event kind and the exit
/// counters. Phase 2 extends this with crash/trap reasons.
pub const ExitReason = enum {
    /// The entry function returned.
    normal,
    /// The process was killed (`Scheduler.kill` / shutdown) — the Phase 1
    /// simulation of crash teardown from a non-cooperative point.
    killed,
};

/// One scheduler event for the trace seam (plan 1.5 trace recording).
/// Deliberately a plain, comparison-friendly value: two runs are
/// equivalent iff their event sequences are element-wise equal.
pub const TraceEvent = struct {
    /// What happened.
    kind: Kind,
    /// The raw pid bits of the process it happened to (`Pid.toBits`).
    pid_bits: u64,

    /// Event kinds emitted by the scheduler.
    pub const Kind = enum(u8) {
        /// A process was created and admitted to the ready queue.
        spawn,
        /// A quantum started (the process was switched in).
        schedule,
        /// A quantum ended with the process still runnable (voluntary
        /// yield, budget exhaustion, watchdog, or transient mailbox gap).
        yield,
        /// A quantum ended with the process suspended on an empty mailbox.
        wait,
        /// A waiting process was made runnable by a wake signal.
        wake,
        /// A process was evacuated to the blocking / dirty-scheduler pool by a
        /// `Process.blocking` call (P4-J3); its core is freed.
        block,
        /// A process re-attached from the blocking pool (its blocking op
        /// finished off-core) and became runnable again (P4-J3).
        unblock,
        /// A process exited normally (teardown complete).
        exit,
        /// A process was killed (teardown complete).
        kill,
    };
};

/// Trace seam callback: invoked synchronously on the scheduler thread for
/// every `TraceEvent`, in program order. Must not call back into the
/// scheduler. Production default: none (zero cost); `deterministic.zig`
/// installs its recorder here, and the Phase 1.6 observability skeleton
/// grows from the same seam.
pub const TraceHook = *const fn (trace_context: ?*anyopaque, event: TraceEvent) void;

/// The seam that owns ALL scheduler nondeterminism (plan 1.5, research.md
/// §6.11: FoundationDB-style — every decision a run makes must be a
/// function of the seed). Production mode is `production_fifo`;
/// `deterministic.zig` provides the seeded implementation.
pub const Decisions = struct {
    /// Opaque state for the implementation (the seeded PRNG, in
    /// deterministic mode).
    decision_context: ?*anyopaque,
    /// Dispatch table; see `VTable`.
    vtable: *const VTable,

    /// The decision points. Every scheduling choice with more than one
    /// legal answer routes through here — adding a nondeterministic
    /// mechanism to the scheduler REQUIRES adding its decision to this
    /// table (that is the seam's contract).
    pub const VTable = struct {
        /// Choose which of the `ready_count` (> 0) queued runnable
        /// processes runs next; returns its queue index (0 = oldest).
        /// Production: always 0 (FIFO).
        chooseNextReadyIndex: *const fn (decision_context: ?*anyopaque, ready_count: usize) usize,
        /// Choose the preemption budget for the quantum about to start,
        /// given the configured default. Production: the default,
        /// unchanged. Deterministic mode randomizes in `[1, default]`,
        /// which moves every budget-driven preemption point.
        chooseQuantumBudget: *const fn (decision_context: ?*anyopaque, configured_budget: u32) u32,
    };

    /// Production policy: strict FIFO, configured budget. Stateless.
    pub const production_fifo: Decisions = .{
        .decision_context = null,
        .vtable = &production_fifo_vtable,
    };

    const production_fifo_vtable = VTable{
        .chooseNextReadyIndex = productionChooseNextReadyIndex,
        .chooseQuantumBudget = productionChooseQuantumBudget,
    };

    fn productionChooseNextReadyIndex(decision_context: ?*anyopaque, ready_count: usize) usize {
        _ = decision_context;
        _ = ready_count;
        return 0;
    }

    fn productionChooseQuantumBudget(decision_context: ?*anyopaque, configured_budget: u32) u32 {
        _ = decision_context;
        return configured_budget;
    }
};

/// The monotonic-time seam (plan 4.4, research.md §6.11): the scheduler
/// reads "now" for `receive … after` deadline arithmetic and timing-wheel
/// advancement ONLY through this seam, so a seeded run can substitute a
/// VIRTUAL clock and make timer firing a pure function of the seed. This is
/// the "timers" half of the seam inventory the module doc anticipated
/// (`deterministic.zig` header): production reads the real monotonic clock;
/// the multi-scheduler seeded simulator (`deterministic_mn.zig`) installs a
/// shared virtual clock the discrete-event driver advances only when it fires
/// the earliest armed timer. PINNED once handed to a scheduler.
pub const Clock = struct {
    /// Opaque state for the implementation (the virtual clock, in seeded mode).
    clock_context: ?*anyopaque,
    /// Read the current monotonic time in nanoseconds.
    readNanoseconds: *const fn (clock_context: ?*anyopaque) u64,

    /// Production policy: the real libc-free monotonic clock. Stateless.
    pub const wall: Clock = .{
        .clock_context = null,
        .readNanoseconds = wallReadNanoseconds,
    };

    /// Read "now" in monotonic nanoseconds through the seam.
    pub inline fn read(clock: Clock) u64 {
        return clock.readNanoseconds(clock.clock_context);
    }

    fn wallReadNanoseconds(clock_context: ?*anyopaque) u64 {
        _ = clock_context;
        return monotonicNowNanoseconds();
    }
};

/// What the scheduler does when no process is runnable but live processes
/// exist.
pub const IdleStrategy = enum {
    /// Spin briefly, then park on the futex word until woken (production).
    futex_park,
    /// Never park: surface `error.AllProcessesWaiting` instead
    /// (deterministic mode — a single-threaded seeded run that would park
    /// is a deadlocked scenario, plan 1.5).
    forbid_parking,
};

/// Why a `Scheduler.kill` request resolved the way it did.
pub const KillOutcome = enum {
    /// The target was `.waiting`; it was torn down immediately, without
    /// ever being resumed (the non-cooperative teardown point).
    killed,
    /// The target was `.runnable` or `.running`; the kill is pending and
    /// takes effect at the target's next scheduling point or safepoint.
    kill_pending,
    /// The pid did not resolve (already dead, stale, or forged) — the
    /// lookup dead-lettered it.
    not_found,
};

/// Outcome of a kernel-level send.
pub const SendOutcome = enum {
    /// The envelope was pushed to the target's mailbox (and the wake seam
    /// fired if the mailbox was empty).
    delivered,
    /// The target pid did not resolve; nothing was sent (Erlang
    /// semantics: send to a dead process is not an error). The pid
    /// table's dead-letter hook observed the miss.
    dead_lettered,
};

/// Errors surfaced by `Scheduler.spawn`.
pub const SpawnError = error{OutOfMemory} ||
    stack_pool_module.AcquireError ||
    PidTable.AcquireError;

/// Errors surfaced by `Scheduler.runUntilQuiescent`.
pub const RunError = error{
    /// Parking is forbidden (deterministic mode) and every live process
    /// is waiting with no wake pending — the scenario is deadlocked.
    AllProcessesWaiting,
};

/// Why a process's quantum ended, written by the process side
/// (`ProcessContext`) immediately before its yield switch and classified
/// by the scheduler after the switch returns.
const YieldReason = enum(u8) {
    /// Still runnable: voluntary yield, budget exhaustion, watchdog
    /// preemption, or a transient mailbox-publication gap retry. The
    /// scheduler re-enqueues the process.
    reenqueue,
    /// Suspended on an empty mailbox; made runnable again only by a wake
    /// signal (or a kill).
    waiting_for_message,
    /// Suspended on an empty mailbox with a timeout (`receive … after`):
    /// made runnable by a wake signal, a kill, OR the scheduler observing
    /// `wake_deadline_nanoseconds` elapse (which sets `receive_timed_out`).
    waiting_for_message_deadline,
    /// Evacuating to the blocking / dirty-scheduler pool (P4-J3): a
    /// `Process.blocking` call yielded to hand its fiber to a blocking-pool
    /// OS thread. The scheduler does NOT re-enqueue it (it goes to `.blocking`)
    /// — it submits the record to the blocking pool and frees this core.
    blocking_offload,
    /// A `Process.blocking` op finished on the pool thread (P4-J3): the fiber
    /// yielded on the POOL thread to hand control back so the pool thread can
    /// re-attach the process onto a core. Observed only by the blocking-pool
    /// worker's `runBlockingPhase`, never by a core's `runQuantum`.
    blocking_complete,
};

/// The cross-thread wake handshake state of a process (P4-J1). Under M:N a
/// producer on any thread may deliver a message to a process that a
/// (different) scheduler thread is simultaneously deciding to suspend; this
/// atomic is the arbiter that makes exactly ONE party revive the process — no
/// lost wake, no double enqueue — the role Go's `casgstatus` and Tokio's
/// task-notify state play.
///
/// The whole handshake linearizes on THIS ONE variable via seq_cst
/// read-modify-writes, so it needs no standalone memory fence (the Zig fork's
/// std has none): two seq_cst RMWs on one location are totally ordered, and the
/// message-arrival signal is carried by `park_state` itself (the mailbox
/// empty→nonempty wake seam swaps in `.notified`) rather than by a second
/// variable the park would have to re-read behind a StoreLoad barrier.
///
/// Protocol (`scheduler.zig`, "Cross-thread wake handshake"):
///   * a running process is `.running`;
///   * the mailbox wake seam (any producer thread, on empty→nonempty) does
///     `swap(.notified)`: if it displaced `.parked` the process was suspended
///     and this producer owns the revival (push to a scheduler's wake stack);
///     if it displaced `.running`/`.notified` the process is active and will
///     observe the message itself — no push;
///   * the scheduler suspending the process does `cmpxchg(.running → .parked)`
///     (`commitPark`): success ⇒ genuinely parked, a later wake revives it;
///     failure ⇒ it read `.notified` (a message landed in the park window) ⇒
///     the scheduler self-revives immediately.
/// Exactly one of {producer push, scheduler self-revive} fires per episode
/// because the two RMWs are totally ordered on this variable.
pub const ParkState = enum(u2) {
    /// Running or runnable — not suspended. A wake seam displacing this is a
    /// no-op (the process observes the message itself).
    running = 0,
    /// Suspended on an empty mailbox — a wake must revive it. A wake seam
    /// displacing this means the displacing producer owns the revival.
    parked = 1,
    /// A message arrived in the park window (the wake seam swapped this in over
    /// `.running`): the process's own park attempt sees it and self-revives
    /// instead of suspending, so the wake is never lost.
    notified = 2,
};

/// The `park_control` word packs the `ParkState` (low 2 bits) with the process's
/// **park epoch** (high 62 bits) into one seq_cst atomic. The epoch is bumped
/// every time a `receive … after` park episode ends — on ANY core (a
/// cross-scheduler message wake, a kill, or a timeout fire). Packing them
/// together is what makes the timing wheel's cross-scheduler timeout-fire
/// race-free (P4-J2): a stale timer in core A's wheel can only fire its process
/// with a single `cmpxchg(pack(epoch, .parked) → pack(epoch+1, .running))`,
/// which atomically proves the process is STILL parked for exactly THAT episode.
/// A process revived cross-core and re-parked (a new episode, epoch+1) cannot be
/// grabbed by the stale timer — the CAS's expected value no longer matches — so
/// the after-branch never fires prematurely and the wheel entry is discarded
/// lazily when its bucket expires. The epoch is monotonic for a record's whole
/// life (it survives recycle, so a stale timer can never alias a reused record's
/// new episode). One seq_cst variable still linearizes the entire handshake.
const park_epoch_shift: u6 = 2;

/// Pack an epoch and state into a `park_control` word.
inline fn packParkControl(epoch: u64, state: ParkState) u64 {
    return (epoch << park_epoch_shift) | @intFromEnum(state);
}

/// The epoch carried by a `park_control` word.
inline fn parkControlEpoch(control: u64) u64 {
    return control >> park_epoch_shift;
}

/// The `ParkState` carried by a `park_control` word.
inline fn parkControlState(control: u64) ParkState {
    return @enumFromInt(@as(u2, @truncate(control)));
}

/// Scheduler-side bookkeeping for one process: the PCB plus the fields
/// that are the scheduler's business rather than the process's (queue
/// links, the sender-side envelope handle, kill/wake flags).
///
/// KERNEL-INTERNAL: exposed only because the compilation unit is; nothing
/// outside this file constructs or fields one. Records are pinned from
/// spawn (the PCB pins itself via its embedded mailbox stub, and the pid
/// table and wake stack hold pointers) and are recycled through the
/// scheduler's record cache — never returned to the backing allocator
/// before `Scheduler.deinit` (see the module doc's wake-race note).
pub const ProcessRecord = struct {
    /// The embedded process control block (`process.zig`). The pid table
    /// stores `&record.pcb`; `@fieldParentPtr` recovers the record.
    pcb: ProcessControlBlock,
    /// The owning scheduler (needed by the wake callback, which receives
    /// only the record).
    scheduler: *Scheduler,
    /// The process body and its opaque argument.
    entry_function: ProcessEntry,
    entry_argument: ?*anyopaque,
    /// The process's sender side of the shared envelope pool: envelopes
    /// this process sends are carved from pages owned by this handle;
    /// teardown abandons it (J3 semantics). Deliberately a record field,
    /// not a PCB field — whether handles bind per-process or
    /// per-scheduler-thread is a Phase 4 decision (`envelope_pool.zig`,
    /// "Multi-producer posture"), and the record is the scheduler-owned
    /// place that can move either way without touching the PCB layout.
    envelope_handle: EnvelopePool.Handle,
    /// Intrusive link: ready-queue FIFO while `.runnable`, record-cache
    /// free list while recycled. Scheduler-thread only.
    ready_next: ?*ProcessRecord,
    /// Why the last quantum ended (see `YieldReason`). Written on the
    /// fiber, read by the scheduler after the switch — same thread.
    yield_reason: YieldReason,
    /// Absolute monotonic-nanosecond deadline for a
    /// `.waiting_for_message_deadline` suspension (`receive … after`). The
    /// hand-off field from `receiveWaitTimeout` (which computes it) to
    /// `runQuantum` (which arms the timing-wheel entry). Scheduler-thread only.
    wake_deadline_nanoseconds: u64,
    /// Set by the timing wheel's fire callback when it wakes this waiter because
    /// its deadline elapsed (rather than a message arriving); read and cleared by
    /// `receiveWaitTimeout` on resume. Written by the owning wheel's scheduler
    /// thread, read by the owning fiber after revival (queue-ordered).
    receive_timed_out: bool,
    /// The live timing-wheel entry for the current `receive … after` episode, or
    /// null. Written by the parking core at insert; consulted only on the SAME
    /// core (the owner) for O(1) eager cancellation when a message beats the
    /// deadline locally. Validated against `timer_epoch` so a freed node is never
    /// dereferenced. Scheduler-thread (owner) only.
    timer_entry: ?*timing_wheel_module.Entry,
    /// Which scheduler's wheel holds `timer_entry`. A reviver/killer compares it
    /// to itself to decide whether it may eagerly cancel (same core) or must let
    /// the owner reap the entry lazily (cross core). Written at insert, read after
    /// a seq_cst `park_control` acquire (which orders it).
    timer_wheel_owner: ?*Scheduler,
    /// The park epoch captured when `timer_entry` was armed (a plain copy of the
    /// entry's epoch). Compared against the live `park_control` epoch to tell
    /// whether the entry still belongs to the current episode — i.e. whether it
    /// is live and safe to dereference — without touching the (possibly freed)
    /// node. Scheduler-thread (owner) only.
    timer_epoch: u64,
    /// Kill/exit requested: the process must die at its next scheduling point
    /// or safepoint. Set by same-core `kill` and by cross-core exit-signal
    /// delivery (`killWithReason`, P5-J1), observed at scheduling points,
    /// safepoints, and the receive loop. ATOMIC because under M:N an exit
    /// signal from a process on another core dooms this one: the killer stores
    /// `true` (release) then wakes the target (`reviveIfParked`), and the
    /// target's core loads it (acquire) at its next observation point. The
    /// paired reason lives in the PCB's `signal_state.pending_exit` (set under
    /// that lock before this store); a plain same-core `kill`/self-exit leaves
    /// `pending_exit` null and teardown defaults the reason to `killed`.
    pending_kill: std.atomic.Value(bool),
    /// Cache of the most recently `awaitSignal`-consumed exit/`DOWN` signal —
    /// the raw J1 test/observation surface (`abi.zig`'s `zap_proc_last_signal_*`).
    /// Owner-only (written and read by this process on its own core, in one
    /// `awaitSignal` → read sequence). `last_signal_kind` is `.none` until the
    /// first signal is consumed.
    last_signal: signal_module.SignalPayload,
    /// Kind of the cached `last_signal` (`.none` before the first consumed).
    last_signal_kind: signal_module.SignalKind,
    /// The correlated user REPLY stashed by a `.reply_ready`
    /// `awaitCorrelated`, held for the immediately-following typed decode
    /// (`takeCorrelatedStash` — the two-call `zap_proc_receive_correlated`
    /// → `zap_proc_take_correlated` ABI protocol, P5-J4). Owner-only.
    /// Per-PROCESS (never thread-local): a safepoint yield between the two
    /// ABI calls may interleave another process on this OS thread, and its
    /// own correlated receive must not clobber this one's stash. Freed at
    /// teardown if the process dies between the two calls.
    pending_correlated_envelope: ?*mailbox_module.Envelope,
    /// The cross-thread wake handshake state (P4-J1; see `ParkState`). A
    /// spawned process is `.running`; the scheduler suspending it publishes
    /// `.parked`; the unique `.parked → .running` CAS winner (a producer that
    /// delivered a message, or the suspending scheduler's own re-check) owns the
    /// revival and pushes the record onto a scheduler's wake stack exactly once.
    /// Replaces the Phase-1 `wake_pending` coalescing flag: the CAS both
    /// coalesces (one winner) and arbitrates the park/signal race, which a plain
    /// flag could not do across two scheduler threads. Packs the park EPOCH
    /// alongside the state (see `packParkControl`) so the wheel's cross-scheduler
    /// timeout-fire is race-free.
    park_control: std.atomic.Value(u64),
    /// Cross-thread send grace period (P4 PCB-lifetime — `pid_table.zig`
    /// "Deferred to Phase 4", `mailbox.zig` "Teardown protocol"): the number of
    /// producers currently inside `send`'s pin→push→unpin bracket for THIS
    /// process (`beginSend` … `endSend`). Teardown's `closeAndQuiesce` waits for
    /// it to reach zero before the mailbox is drained, so no producer's push can
    /// land in an already-drained mailbox (the message-vs-timer envelope-page
    /// leak). PRESERVED across recycle — like `park_control`'s epoch, and for the
    /// same reason: a stale cross-core sender holding a borrowed PCB pointer may
    /// still touch it after the record recycles, so a destructive per-spawn reset
    /// could underflow it. Every `beginSend` is balanced by an `endSend`, so it
    /// is provably zero at recycle (that very wait guarantees it) and a recycled
    /// record inherits zero; initialized once at record allocation.
    in_flight_send_count: std.atomic.Value(u32),
    /// Set true by `closeAndQuiesce` at teardown to reject producers that have
    /// not yet pinned; reset false at each `spawn` (a fresh incarnation accepts
    /// sends). Paired with `in_flight_send_count` in a seq_cst StoreLoad — the
    /// same Dekker shape as the park/wake handshake — so a producer that observes
    /// the mailbox open is always waited for by teardown. The per-spawn reset is
    /// ordered before the incarnation is registered, so a legitimate sender
    /// (which looks the pid up only AFTER registration) never observes a stale
    /// `true`.
    send_closed: std.atomic.Value(bool),
    /// Intrusive Treiber link in the target scheduler's wake stack. Written by
    /// the revival CAS winner before the head CAS publishes it.
    wake_next: ?*ProcessRecord,
    /// Intrusive link for the blocking / dirty-scheduler pool (P4-J3), serving
    /// two NON-overlapping roles across a blocking episode: (a) the FIFO link in
    /// the `BlockingPool`'s submit queue from offload until a worker pops it,
    /// then (b) the Treiber link in the offloading core's `reattach_stack_head`
    /// from the op's completion until the core drains it. A record is never in
    /// both structures at once, so one link suffices. Untouched (and null)
    /// except during a blocking episode.
    blocking_next: ?*ProcessRecord,
    /// The `ProcessContext` living on this process's fiber stack, or
    /// null before the first quantum (the context is built by
    /// `processFiberEntry` at first schedule). This is the plan-A.2.4
    /// ambient-lookup seam the module doc's current-process discipline
    /// reserves for compiled Zap code: kernel code keeps receiving the
    /// context as a parameter, while `Scheduler.currentProcessContext`
    /// (backing the `zap_proc_current` intrinsic) reads this field for
    /// the process the scheduler is currently running. The pointer
    /// targets `processFiberEntry`'s frame, which outlives every quantum
    /// of the process — it dies only with the fiber stack at teardown,
    /// after which the record is recycled and `spawn` resets the field.
    active_context: ?*ProcessContext,

    /// Producer side of the cross-thread send grace period: announce an
    /// in-flight send to this process and return whether it may proceed. Returns
    /// false if the process is tearing down (its mailbox is closed) — the caller
    /// must dead-letter WITHOUT pushing. Balanced by `endSend` on the true path.
    ///
    /// The seq_cst increment and the `send_closed` observation form a StoreLoad
    /// with `closeAndQuiesce` (the Dekker shape of the park/wake handshake): if
    /// this observes the mailbox OPEN, then in the single seq_cst total order its
    /// increment precedes teardown's `in_flight_send_count` read, so teardown is
    /// guaranteed to wait for this send's `endSend`. Conversely if teardown's
    /// close precedes this observation, this reports closed and never pushes.
    fn beginSend(record: *ProcessRecord) bool {
        _ = record.in_flight_send_count.fetchAdd(1, .seq_cst);
        if (record.send_closed.load(.seq_cst)) {
            _ = record.in_flight_send_count.fetchSub(1, .seq_cst);
            return false;
        }
        return true;
    }

    /// Producer side: retire an in-flight send announced by `beginSend`.
    fn endSend(record: *ProcessRecord) void {
        _ = record.in_flight_send_count.fetchSub(1, .seq_cst);
    }

    /// Consumer side (teardown): close the mailbox to producers that have not yet
    /// pinned, then wait for every already-pinned producer to finish its push, so
    /// the following `drainMailboxForTeardown` reclaims every enqueued envelope.
    /// The wait is bounded by the longest in-flight push (a wait-free XCHG+store),
    /// the same spin discipline the teardown drain already uses. Scheduler-thread
    /// only (the tearing-down core).
    fn closeAndQuiesce(record: *ProcessRecord) void {
        record.send_closed.store(true, .seq_cst);
        while (record.in_flight_send_count.load(.seq_cst) != 0) std.atomic.spinLoopHint();
    }
};

/// The per-quantum kernel capability handed to a process body: the
/// parameter-threaded current process (plan A.2.4 — kernel code receives
/// the process, it never re-resolves it). Lives on the process's own
/// fiber stack for exactly one spawn's lifetime; every method is
/// scheduler-thread-by-construction (process bodies run on the scheduler
/// thread).
pub const ProcessContext = struct {
    /// The scheduler driving this process.
    scheduler: *Scheduler,
    /// This process's record.
    record: *ProcessRecord,
    /// The fiber yield capability.
    execution: *fiber_context.FiberExecution,

    /// This process's pid.
    pub fn selfPid(context: *const ProcessContext) Pid {
        return context.record.pcb.pid;
    }

    /// Register an external resource for destruction at process exit
    /// (LIFO; see `process.ProcessControlBlock.registerDropResource`).
    pub fn registerDropResource(context: *ProcessContext, node: *process_module.DropListNode) void {
        context.record.pcb.registerDropResource(node);
    }

    /// This process's blob-ownership ledger (P6-J2 — owner-only, like
    /// every PCB field; the blob intrinsics append/verify/remove through
    /// it and teardown drains it).
    pub fn blobLedger(context: *ProcessContext) *blob_module.BlobLedger {
        return &context.record.pcb.blob_ledger;
    }

    /// The shared blob domain this scheduler runs over, or null when the
    /// runtime was built without one (standalone schedulers).
    pub fn blobDomain(context: *ProcessContext) ?*blob_module.BlobDomain {
        return context.scheduler.options.blob_domain;
    }

    /// Voluntarily end this quantum; the process is re-enqueued runnable.
    pub fn yieldNow(context: *ProcessContext) void {
        context.record.yield_reason = .reenqueue;
        context.execution.yield();
    }

    /// The preemption safepoint (plan decision 6 / item 2.5): decrement
    /// the quantum budget and yield if it reached zero, if the watchdog
    /// flag is set, or if a kill is pending. Compiler-inserted safepoints
    /// call this from Phase 2 on; Phase 1 kernel tests call it
    /// explicitly. When a kill is pending the yield never returns — the
    /// scheduler tears the process down instead of resuming it.
    pub fn yieldCheck(context: *ProcessContext) void {
        const record = context.record;
        const pcb = &record.pcb;
        if (pcb.preemption_budget > 0) pcb.preemption_budget -= 1;
        const watchdog_requested =
            record.scheduler.watchdog_preempt_flag.load(.monotonic);
        if (pcb.preemption_budget == 0 or watchdog_requested or record.pending_kill.load(.acquire)) {
            record.yield_reason = .reenqueue;
            context.execution.yield();
        }
    }

    /// The slow path of the compiler-emitted preemption safepoints (plan
    /// item 2.5, P2-J6) — the three-layer cooperative-safepoint design's
    /// shared yield point. It is entered when a layer-2 loop-local
    /// reduction counter (the bare back-edge poll the ZIR builder emits
    /// into alloc-free loops) or the layer-1 alloc-piggyback counter
    /// reaches zero, i.e. a full quantum's worth of reductions has elapsed.
    ///
    /// Unlike `yieldCheck` (which the Phase 1 kernel tests drive directly
    /// and which always yields on budget exhaustion), this yields ONLY when
    /// preemption can matter — a kill is pending (untrappable — the yield
    /// never returns, the scheduler tears the process down), the flag-only
    /// watchdog asked (layer 3), or another process is runnable
    /// (`ready_count > 0`; the running process is dequeued, so any positive
    /// count is a co-runnable peer). A sole runnable process with no
    /// watchdog/kill request returns WITHOUT a fiber switch, so a CLBG hot
    /// loop compiled with concurrency on (the E2 gate) re-arms its counter
    /// and keeps running rather than burning two switches per quantum.
    ///
    /// The layer-1 running counter is refreshed by the C-ABI entry
    /// (`abi.zap_proc_safepoint_slow` → `refreshReductionCounter`) before
    /// this runs; the layer-2 loop-local counter is reseeded by the emitted
    /// code from `zap_proc_reductions_budget` after this returns.
    pub fn reductionSafepoint(context: *ProcessContext) void {
        const record = context.record;
        const scheduler = record.scheduler;
        const watchdog_requested =
            scheduler.watchdog_preempt_flag.load(.monotonic);
        if (record.pending_kill.load(.acquire) or watchdog_requested or scheduler.ready_count > 0) {
            record.yield_reason = .reenqueue;
            context.execution.yield();
        }
    }

    /// Blocking receive: return the oldest deliverable envelope, waiting
    /// (suspending this process) while the mailbox is empty. The caller
    /// owns the returned envelope and must free it via
    /// `envelope_pool.free` once done (Phase 2's receive lowering adopts
    /// the payload before freeing). A transient publication gap (a
    /// producer mid-push; `mailbox.zig`) re-enqueues the process runnable
    /// and retries next quantum rather than burning this quantum spinning
    /// on a preempted producer's behalf. If the process is killed while
    /// waiting, the suspension never returns.
    pub fn receive(context: *ProcessContext) *mailbox_module.Envelope {
        const record = context.record;
        while (true) {
            if (record.pending_kill.load(.acquire)) {
                // Die at this safepoint rather than consuming more input.
                record.yield_reason = .reenqueue;
                context.execution.yield();
                continue;
            }
            switch (record.pcb.mailbox.pop()) {
                .envelope => |envelope| return envelope,
                .empty => {
                    record.yield_reason = .waiting_for_message;
                    context.execution.yield();
                },
                .transient_gap => {
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                },
            }
        }
    }

    /// Blocking receive of the oldest USER message (P5-R1): like `receive`,
    /// but signal envelopes (trapped exits / `DOWN`s) are SKIPPED and stay
    /// queued, in order, for `await_signal` — the steady-state typed receive
    /// must never decode a `SignalPayload` as the message type (Erlang: an
    /// unmatched trapped exit sits in the mailbox until a wait that matches
    /// it). The head-is-a-user-message common case extracts the head exactly
    /// as `pop` delivers it. If the process is killed while waiting, the
    /// suspension never returns.
    pub fn receiveUser(context: *ProcessContext) *mailbox_module.Envelope {
        switch (context.receiveCorrelated(0, .user_any, null)) {
            .matched => |envelope| return envelope,
            .timed_out => unreachable, // no deadline was armed
        }
    }

    /// Blocking receive with a timeout — the `receive … after` mechanism
    /// (plan item 2.3, P2-J3). Parks (non-consuming) until a USER message
    /// is queued or `timeout_nanoseconds` elapses, returning which
    /// happened WITHOUT consuming the message (a following `receive`
    /// takes it). Signal envelopes (trapped exits / `DOWN`s) are NOT user
    /// messages (P5-R1): they never satisfy the wait — they stay queued
    /// for `await_signal` while the wait probes past them — so a `receive
    /// … after` whose mailbox holds only signals still times out instead
    /// of parking forever behind a message the receive would then skip.
    /// `timeout_nanoseconds == 0` probes once without parking (`after 0`).
    /// A message that races the deadline wins. If the process is killed
    /// while waiting, the suspension never returns.
    pub fn receiveWaitTimeout(context: *ProcessContext, timeout_nanoseconds: u64) ReceiveWaitOutcome {
        const record = context.record;
        const mailbox = &record.pcb.mailbox;

        // `after 0`: probe once without parking. A bounded spin resolves a
        // producer mid-publish (a materializing message the probe must see).
        if (timeout_nanoseconds == 0) {
            var gap_spins: u32 = 0;
            var resume_after: ?*mailbox_module.Envelope = null;
            while (true) {
                if (record.pending_kill.load(.acquire)) {
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                    continue;
                }
                switch (mailbox.scanForMatch(0, .user_any, resume_after)) {
                    .found => return .message_available,
                    .exhausted => return .timed_out,
                    .publish_pending => |last_examined| {
                        gap_spins += 1;
                        if (gap_spins >= poll_transient_gap_spin_limit) return .timed_out;
                        resume_after = last_examined;
                        std.atomic.spinLoopHint();
                    },
                }
            }
        }

        const deadline_nanoseconds = context.scheduler.options.clock.read() +| timeout_nanoseconds;
        var resume_after: ?*mailbox_module.Envelope = null;
        while (true) {
            if (record.pending_kill.load(.acquire)) {
                record.yield_reason = .reenqueue;
                context.execution.yield();
                continue;
            }
            switch (mailbox.scanForMatch(0, .user_any, resume_after)) {
                .found => return .message_available,
                .publish_pending => |last_examined| {
                    // A producer is mid-publish — a message is arriving.
                    // Retry next quantum rather than parking on it.
                    resume_after = last_examined;
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                },
                .exhausted => |last_examined| {
                    if (context.scheduler.options.clock.read() >= deadline_nanoseconds) return .timed_out;
                    // Park with the deadline AND the any-push wake armed
                    // (the mailbox may be nonempty — signals we probed
                    // past — so the empty→nonempty wake alone would miss
                    // a new push; the correlated receive's protocol
                    // covers exactly this parked-on-nonempty shape).
                    if (!mailbox.armCorrelatedWake(last_examined)) {
                        // A message landed after the probe — re-probe the
                        // new arrivals instead of parking.
                        resume_after = last_examined;
                        continue;
                    }
                    record.receive_timed_out = false;
                    record.wake_deadline_nanoseconds = deadline_nanoseconds;
                    record.yield_reason = .waiting_for_message_deadline;
                    context.execution.yield();
                    mailbox.disarmCorrelatedWake();
                    resume_after = last_examined;
                    if (record.receive_timed_out) {
                        record.receive_timed_out = false;
                        // A message that raced the timeout wins: one final
                        // probe of the arrivals before conceding.
                        switch (mailbox.scanForMatch(0, .user_any, resume_after)) {
                            .found => return .message_available,
                            else => return .timed_out,
                        }
                    }
                    // Push wake or spurious resume: loop re-probes the new
                    // arrivals and re-checks the deadline.
                },
            }
        }
    }

    // -- The correlated receive (P5-J4 — `mailbox.zig`, "The correlated
    // -- receive + receive-mark"). INTERNAL to the `call`/`Task.await`
    // -- machinery (decision 7): never surface syntax, and the steady-state
    // -- exhaustive `receive` above is untouched.

    /// Capture the receive-mark at the current mailbox position. MUST run
    /// BEFORE the correlation ref is minted (`Mailbox.prepareReceiveMark`).
    pub fn prepareReceiveMark(context: *ProcessContext) void {
        context.record.pcb.mailbox.prepareReceiveMark();
    }

    /// Bind the prepared mark to its freshly-minted `ref`.
    pub fn bindReceiveMark(context: *ProcessContext, ref: u64) void {
        context.record.pcb.mailbox.bindReceiveMark(ref);
    }

    /// Block until a message correlated with `ref` arrives (a stamped user
    /// reply, or the monitor `DOWN` carrying `ref`) or the timeout elapses;
    /// `timeout_nanoseconds == null` waits indefinitely (the internal
    /// demonitor-flush wait for a DOWN that is provably in flight). The
    /// match is EXTRACTED and owned by the caller; skipped messages remain
    /// queued in order for the steady-state receive. Scanning starts at the
    /// receive-mark when it is armed for `ref` (O(1) past any older
    /// backlog), else at the head (sound, unskipped). Parks between scans
    /// with the mailbox's any-push wake armed, so a reply pushed into a
    /// nonempty mailbox still wakes this process. If the process is killed
    /// while waiting, the suspension never returns.
    pub fn receiveCorrelated(
        context: *ProcessContext,
        ref: u64,
        match_kind: mailbox_module.CorrelatedMatchKind,
        timeout_nanoseconds: ?u64,
    ) CorrelatedWaitOutcome {
        const record = context.record;
        const mailbox = &record.pcb.mailbox;
        const deadline_nanoseconds: ?u64 = if (timeout_nanoseconds) |timeout|
            context.scheduler.options.clock.read() +| timeout
        else
            null;
        var resume_after: ?*mailbox_module.Envelope = null;
        while (true) {
            if (record.pending_kill.load(.acquire)) {
                record.yield_reason = .reenqueue;
                context.execution.yield();
                continue;
            }
            switch (mailbox.takeCorrelated(ref, match_kind, resume_after)) {
                .matched => |envelope| return .{ .matched = envelope },
                .publish_pending => |last_examined| {
                    // A producer is mid-publish: input is arriving. Retry
                    // next quantum (pop's transient-gap discipline) from
                    // where the scan stopped.
                    resume_after = last_examined;
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                },
                .extraction_pending => {
                    // The match is found but its extraction lost a
                    // close-CAS to a mid-publish producer; it remains
                    // queued — rescan from the top (the deterministic
                    // match is found again, with the link landed).
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                },
                .exhausted => |last_examined| {
                    if (deadline_nanoseconds) |deadline| {
                        if (context.scheduler.options.clock.read() >= deadline) return .timed_out;
                    }
                    // Arm the any-push wake against the exact tail the scan
                    // saw; failure means a message landed after the scan —
                    // rescan instead of parking (no lost wake).
                    if (!mailbox.armCorrelatedWake(last_examined)) {
                        resume_after = last_examined;
                        continue;
                    }
                    if (deadline_nanoseconds) |deadline| {
                        record.receive_timed_out = false;
                        record.wake_deadline_nanoseconds = deadline;
                        record.yield_reason = .waiting_for_message_deadline;
                    } else {
                        record.yield_reason = .waiting_for_message;
                    }
                    context.execution.yield();
                    mailbox.disarmCorrelatedWake();
                    resume_after = last_examined;
                    if (deadline_nanoseconds != null and record.receive_timed_out) {
                        record.receive_timed_out = false;
                        // A message that raced the deadline wins: one final
                        // scan before conceding the timeout.
                        switch (mailbox.takeCorrelated(ref, match_kind, resume_after)) {
                            .matched => |envelope| return .{ .matched = envelope },
                            else => return .timed_out,
                        }
                    }
                },
            }
        }
    }

    /// The `call`/`Task.await` wait (the ABI surface behind
    /// `zap_proc_receive_correlated`): block for the message correlated
    /// with `ref`, then classify it. A user REPLY is stashed on the record
    /// for the immediately-following typed decode
    /// (`takeCorrelatedStash` ← `zap_proc_take_correlated`); the monitor
    /// `DOWN` is consumed here — its fields cached exactly like
    /// `awaitSignal` (read via `lastSignal*`/`lastSignalReason`), its
    /// payload and envelope freed.
    pub fn awaitCorrelated(
        context: *ProcessContext,
        ref: u64,
        timeout_nanoseconds: ?u64,
    ) AwaitCorrelatedOutcome {
        switch (context.receiveCorrelated(ref, .user_or_down, timeout_nanoseconds)) {
            .timed_out => return .timed_out,
            .matched => |envelope| {
                if (envelope.fragment.signal_kind == .down) {
                    const payload: *const signal_module.SignalPayload =
                        @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
                    context.record.last_signal = payload.*;
                    context.record.last_signal_kind = .down;
                    context.scheduler.freeSignalEnvelope(envelope);
                    return .down_consumed;
                }
                std.debug.assert(context.record.pending_correlated_envelope == null);
                context.record.pending_correlated_envelope = envelope;
                return .reply_ready;
            },
        }
    }

    /// Take the reply envelope stashed by the last `.reply_ready`
    /// `awaitCorrelated`. Aborts on a protocol violation (no stash) —
    /// the internal call/await machinery always pairs the two.
    pub fn takeCorrelatedStash(context: *ProcessContext) *mailbox_module.Envelope {
        const envelope = context.record.pending_correlated_envelope orelse
            @panic("takeCorrelatedStash: no correlated reply is pending (kernel protocol violation)");
        context.record.pending_correlated_envelope = null;
        return envelope;
    }

    /// The reason term of the most recently cached signal (`awaitSignal`
    /// or a `.down_consumed` `awaitCorrelated`).
    pub fn lastSignalReason(context: *const ProcessContext) u64 {
        return context.record.last_signal.reason_term;
    }

    /// `demonitor(ref)` + FLUSH (Elixir `Process.demonitor(ref, [:flush])`
    /// semantics): drop the monitor AND guarantee no `DOWN` for `ref` is
    /// ever observed by this process afterwards. See
    /// `Scheduler.signalDemonitorFlush`.
    pub fn demonitorFlush(context: *ProcessContext, ref: u64) bool {
        return context.scheduler.signalDemonitorFlush(context, ref);
    }

    /// Cumulative correlated-scan visit count for THIS process's mailbox —
    /// the R8 O(1)-from-mark telemetry (`mailbox.zig`).
    pub fn correlatedScanVisits(context: *const ProcessContext) u64 {
        return context.record.pcb.mailbox.correlatedScanVisits();
    }

    /// Send one envelope to `target`: allocate from THIS process's
    /// envelope handle (the sender-owns-pages discipline), stamp
    /// `fragment` into it, and push it onto the target's mailbox — the
    /// wake seam fires automatically on an empty→nonempty transition. A
    /// dead/stale pid dead-letters (drops) instead of erroring, matching
    /// Erlang send semantics; the outcome is returned for observability.
    pub fn send(
        context: *ProcessContext,
        target: Pid,
        fragment: mailbox_module.Fragment,
    ) error{OutOfMemory}!SendOutcome {
        const target_pcb = context.scheduler.pid_table.lookup(target) orelse
            return .dead_lettered;
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        // Cross-thread send grace period (P4 PCB-lifetime — `pid_table.zig`
        // "Deferred to Phase 4", `mailbox.zig` "Teardown protocol"). `lookup`
        // borrowed a PCB pointer; between here and the push the target can
        // time-out/exit and tear down on another core, draining and recycling its
        // mailbox. Two hazards, both closed here:
        //   * a push landing AFTER the target's teardown drain orphans its
        //     envelope (and the sender's abandoned page) — a leak. `beginSend`
        //     pins the target so its `closeAndQuiesce` waits for THIS push before
        //     draining; a mailbox already closed rejects the send (dead-letter).
        //   * a record recycled AND reused for a new process in the lookup→pin
        //     window would mis-deliver. The pin holds the pinned incarnation
        //     stable; `isAlive` then re-confirms the pid is still the same live
        //     generation (generations are monotone and never reissued), so a
        //     reused record fails the check and the send dead-letters.
        // Nothing is allocated until both checks pass, so a dead-letter leaks
        // nothing.
        if (!target_record.beginSend()) return .dead_lettered;
        defer target_record.endSend();
        if (!context.scheduler.pid_table.isAlive(target)) return .dead_lettered;
        const envelope = try context.record.envelope_handle.allocate();
        envelope.fragment = fragment;
        _ = target_pcb.mailbox.push(envelope);
        return .delivered;
    }

    /// Spawn a child process (scheduler-thread-safe by construction:
    /// process bodies run on the scheduler thread).
    pub fn spawn(context: *ProcessContext, options: Scheduler.SpawnOptions) SpawnError!Pid {
        return context.scheduler.spawn(options);
    }

    /// Kill another process (or this one; a self-kill takes effect at the
    /// next safepoint). See `Scheduler.kill`.
    pub fn kill(context: *ProcessContext, target: Pid) KillOutcome {
        return context.scheduler.kill(target);
    }

    // -- Kernel signal primitives (P5-J1, `signal.zig`) -----------------------

    /// `link(target)`: establish a bidirectional link (idempotent). See
    /// `Scheduler.signalLink`.
    pub fn link(context: *ProcessContext, target: Pid) bool {
        return context.scheduler.signalLink(context.record, target);
    }

    /// `unlink(target)`: break a bidirectional link (idempotent).
    pub fn unlink(context: *ProcessContext, target: Pid) bool {
        return context.scheduler.signalUnlink(context.record, target);
    }

    /// `monitor(target) -> Ref`: install a stackable, unidirectional monitor.
    pub fn monitor(context: *ProcessContext, target: Pid) signal_module.Ref {
        return context.scheduler.signalMonitor(context.record, target);
    }

    /// `demonitor(ref)`: drop a monitor this process holds.
    pub fn demonitor(context: *ProcessContext, ref: signal_module.Ref) bool {
        return context.scheduler.signalDemonitor(context.record, ref);
    }

    /// `exit(target, reason)`: send a trappable exit signal (the Zap surface
    /// classifies the reason atom into `normal`/`abnormal`).
    pub fn exitSignal(
        context: *ProcessContext,
        target: Pid,
        category: signal_module.ReasonCategory,
        reason_term: u64,
    ) SendOutcome {
        return context.scheduler.signalExit(context.record, target, category, reason_term);
    }

    /// `exit(target, kill)`: the untrappable kill (target dies `killed`).
    pub fn killUntrappable(context: *ProcessContext, target: Pid) SendOutcome {
        return context.scheduler.signalKill(context.record, target);
    }

    /// Set this process's `trap_exit` flag, returning the previous value.
    pub fn setTrapExit(context: *ProcessContext, value: bool) bool {
        return context.record.pcb.signal_state.setTrapExit(value);
    }

    /// Self-terminate with an explicit reason (`Process.exit()` = `normal`;
    /// `Process.exit(reason)` = the given category/term). Records the reason,
    /// arms `pending_kill`, and yields; the scheduler observes the kill when the
    /// quantum ends and tears the process down (the yield never returns for a
    /// killed process — the caller follows with `unreachable`). Overrides any
    /// signal-recorded reason (a self-exit is definitive).
    pub fn exitSelf(context: *ProcessContext, category: signal_module.ReasonCategory, reason_term: u64) void {
        context.record.pcb.signal_state.setPendingExit(.{ .category = category, .term = reason_term }, true);
        context.record.pending_kill.store(true, .release);
        context.yieldNow();
    }

    /// Whether this process traps exits.
    pub fn trapsExits(context: *const ProcessContext) bool {
        return context.record.pcb.signal_state.trapsExits();
    }

    /// Blocking receive of the next signal message (user messages skipped,
    /// left queued); caches it and returns the reason term (`lastSignal*`
    /// read the other fields). See `Scheduler.awaitSignal`.
    pub fn awaitSignal(context: *ProcessContext) u64 {
        return context.scheduler.awaitSignal(context);
    }

    /// `awaitSignal` bounded by a deadline: the consumed signal's reason term,
    /// or null when `timeout_nanoseconds` elapsed with no signal. See
    /// `Scheduler.awaitSignalTimeout`.
    pub fn awaitSignalTimeout(context: *ProcessContext, timeout_nanoseconds: u64) ?u64 {
        return context.scheduler.awaitSignalTimeout(context, timeout_nanoseconds);
    }

    /// The `from` pid bits of the most recently `awaitSignal`-consumed signal.
    pub fn lastSignalFrom(context: *const ProcessContext) u64 {
        return context.record.last_signal.from_bits;
    }

    /// The monitor ref of the most recently consumed signal (`down` only).
    pub fn lastSignalRef(context: *const ProcessContext) signal_module.Ref {
        return context.record.last_signal.ref;
    }

    /// The kind of the most recently consumed signal (as its enum tag: 1=exit,
    /// 2=down; 0=none if none consumed yet).
    pub fn lastSignalKind(context: *const ProcessContext) u8 {
        return @intFromEnum(context.record.last_signal_kind);
    }

    /// The current MONOTONIC time in nanoseconds, read through the scheduler's
    /// `Clock` seam — the SAME clock that drives `receive … after` deadlines
    /// (`receiveWaitTimeout`) and the timing wheel. In production this is the
    /// libc-free monotonic clock; under the seeded deterministic scheduler it is
    /// the shared virtual clock, so a caller that measures elapsed intervals
    /// (e.g. a supervisor's restart-intensity window, `lib/supervisor.zap`) is
    /// reproducible under a seed exactly like every other timed decision. It is a
    /// pure read — no allocation, no yield.
    pub fn monotonicNanos(context: *const ProcessContext) u64 {
        return context.scheduler.options.clock.read();
    }

    // -- Local process registry (P5-J2, `registry.zig`) -----------------------

    /// `register(name)`: register the CALLING process under `name` (an atom id).
    /// Returns false if the name is taken by a live process or this process
    /// already holds a name (Erlang one-name-per-process). See
    /// `Scheduler.registryRegister`.
    pub fn registerName(context: *ProcessContext, name: u64) bool {
        return context.scheduler.registryRegister(context.record, name);
    }

    /// `unregister(name)`: release `name` if this process holds it (idempotent).
    /// See `Scheduler.registryUnregister`.
    pub fn unregisterName(context: *ProcessContext, name: u64) bool {
        return context.scheduler.registryUnregister(context.record, name);
    }

    /// `whereis(name) -> pid bits`: resolve `name` to the raw pid bits of its
    /// LIVE registrant, or `0` (the invalid pid) when unregistered or resolving
    /// to a dead pid. See `Scheduler.registryWhereis`.
    pub fn whereisName(context: *const ProcessContext, name: u64) u64 {
        return context.scheduler.registryWhereis(name);
    }

    /// Run `operation` on the blocking / dirty-scheduler pool (P4-J3,
    /// research.md §6.1) — the `Process.blocking` intrinsic. Moves THIS
    /// process's fiber onto a dedicated blocking-pool OS thread for the
    /// duration of the (blocking or long-running) native call, so its core
    /// scheduler is FREED to run its other processes / be stolen from. This is
    /// Zap's answer to a blocking FFI call: an un-annotated blocking call stalls
    /// a core scheduler exactly as an over-long NIF stalls a BEAM scheduler;
    /// wrapping it in `Process.blocking` evacuates it instead (BEAM dirty
    /// schedulers / Go's syscall handoff / Tokio's `spawn_blocking`).
    ///
    /// Mechanism (the fiber-evacuation / detach–reattach handoff):
    ///   * (A) on the core, request evacuation (`.blocking_offload`) and yield —
    ///     the core submits this record to the blocking pool and moves on;
    ///   * (B) a blocking-pool thread resumes this fiber and runs `operation`
    ///     ON ITS OWN STACK, off-core;
    ///   * (C) request re-attach (`.blocking_complete`) and yield — the pool
    ///     thread makes this process runnable again on a core;
    ///   * (D) a core resumes this fiber and this call returns `operation`'s
    ///     result.
    /// Across the whole episode the process's manager/heap/refcounts are touched
    /// by exactly ONE thread at a time — the pool thread while blocking, then a
    /// core — ordered by the two handoff edges (the scheduler-local invariant,
    /// TSan-proven in `mn_refcount_stress.zig`).
    ///
    /// Contract: `operation` is a LEAF (see `BlockingOperation`) — it must not
    /// re-enter the scheduler (no `send`/`spawn`/`receive`/`kill`/`exit`), since
    /// it runs off-core; it may allocate into this process's own heap. A kill
    /// requested while blocking is deferred (native code is never interrupted —
    /// BEAM dirty-NIF semantics) and takes effect at re-attach.
    ///
    /// Degradation: on a STANDALONE scheduler with no blocking pool wired
    /// (`options.blocking_handoff == null`) the operation runs INLINE on this
    /// scheduler thread — correct, but it stalls this scheduler for the call's
    /// duration (the documented single-core fallback). The gate-ON runtime
    /// always wires a `SchedulerPool`, so it always evacuates.
    pub fn blocking(
        context: *ProcessContext,
        operation: BlockingOperation,
        operation_argument: ?*anyopaque,
    ) ?*anyopaque {
        // Standalone-scheduler degradation: no pool → run inline (see doc).
        if (context.scheduler.options.blocking_handoff == null) {
            return operation(operation_argument);
        }
        const record = context.record;
        // (A) On the CORE: request evacuation. The yield switches back to this
        // core's `runQuantum`, which submits the record to the blocking pool and
        // frees the core. This `yield()` RETURNS on a blocking-pool thread.
        record.yield_reason = .blocking_offload;
        context.execution.yield();
        // (B) On a BLOCKING-POOL thread: run the operation off-core, on this
        // fiber's own stack and into this process's own heap.
        const result = operation(operation_argument);
        // (C) Hand control back to the pool thread to re-attach onto a core.
        // This `yield()` RETURNS on a core scheduler thread.
        record.yield_reason = .blocking_complete;
        context.execution.yield();
        // (D) Back on a CORE: `result` lives on this fiber's stack, preserved
        // across both migrations, so it is returned directly.
        return result;
    }

    /// Route a mailbox message that matched no `receive` arm to the
    /// dead-letter path (plan item 2.3 unexpected-message posture): record
    /// non-silent telemetry (`unexpected_message_total`) and terminate THIS
    /// process through the kill path — never the scheduler. The keep-alive
    /// dead-letter sink is Phase 5 (plan item 5.3). Never returns.
    pub fn deadLetterUnexpected(context: *ProcessContext) noreturn {
        context.scheduler.unexpected_message_total += 1;
        _ = context.kill(context.selfPid());
        context.yieldNow();
        unreachable;
    }
};

/// Default spin iterations before parking: sized to the E9 crossover
/// (spin ~1–2 µs — a few hundred `spinLoopHint`s on M4 — before paying
/// the ~900 ns parked-wake cost; plan A.2.3).
pub const default_spin_iterations_before_park: u32 = 512;

/// Default local-FIFO length past which a work-stealing core spills half its
/// backlog to the global overflow queue (P4-J1). Sized so a core keeps a
/// healthy local batch (locality) while surfacing surplus for idle cores to
/// grab in O(1); a starting point, not a tuned contract.
pub const default_spill_threshold: usize = 64;

/// The runnext-fairness poll interval (P4-R2 finding #3; Go's runtime
/// `schedtick % 61` analogue). Under work stealing, a hot mutual-wake pair
/// refills the owner-only `runnext` LIFO slot every quantum, so a plain
/// "runnext first, always" pick would let that pair monopolize the core and
/// STARVE any process stranded in the local FIFO or the global overflow queue
/// — stealing only rescues such work while an idle core still exists, so with
/// EVERY core hot the stranded process never runs. Every `runnext_fairness_
/// interval`-th pick therefore BYPASSES `runnext` and serves the global queue
/// then the local FIFO first (`dequeueNextRunnable`), guaranteeing bounded
/// progress for stranded work. 61 is chosen exactly as Go chose it: PRIME (so
/// the poll cannot phase-lock with a power-of-two or otherwise periodic wake
/// cadence and systematically miss/hit the same slot), large enough that the
/// LIFO-locality fast path is preserved on 60 of every 61 picks (the poll's
/// amortized cost is negligible and the ping-pong-locality benchmark floor is
/// unmoved), yet small enough to bound a stranded process's scheduling delay to
/// ≤ 61 quanta.
pub const runnext_fairness_interval: u64 = 61;

/// Default bound on one futex park (defense-in-depth re-check period; the
/// eventcount protocol needs no timeout for correctness — see the module
/// doc's parking section).
pub const default_park_timeout_nanoseconds: u64 = 100 * std.time.ns_per_ms;

/// The outcome of `ProcessContext.receiveWaitTimeout` — whether the wait
/// ended with a deliverable message or the timeout elapsed.
pub const ReceiveWaitOutcome = enum {
    /// A message is at the mailbox head; a following `receive` pops it.
    message_available,
    /// The `after` duration elapsed with no message.
    timed_out,
};

/// The outcome of `ProcessContext.receiveCorrelated` (P5-J4).
pub const CorrelatedWaitOutcome = union(enum) {
    /// The correlated envelope, EXTRACTED from the mailbox (caller owns
    /// it). Skipped messages remain queued, in order.
    matched: *mailbox_module.Envelope,
    /// The timeout elapsed with no correlated message.
    timed_out,
};

/// The outcome of `ProcessContext.awaitCorrelated` — the classified
/// `call`/`Task.await` wait. Tag values are the C-ABI contract of
/// `zap_proc_receive_correlated` (`abi.zig`).
pub const AwaitCorrelatedOutcome = enum(i32) {
    /// A correlated user REPLY arrived; it is stashed on the record for
    /// the immediately-following `takeCorrelatedStash` typed decode.
    reply_ready = 0,
    /// The monitor `DOWN` carrying the ref arrived instead (the callee
    /// died before replying); consumed and cached like `awaitSignal` —
    /// read the fields via `lastSignalFrom`/`lastSignalReason`.
    down_consumed = 1,
    /// The timeout elapsed.
    timed_out = 2,
};

/// Bound on the in-`receiveWaitTimeout` spin that resolves a producer
/// mid-publish during an `after 0` poll. A gap window is two producer
/// instructions (`mailbox.zig`); a bound this large only fails to resolve
/// when a FOREIGN thread's send stalls mid-push, in which case the poll
/// correctly reports the mailbox empty at that instant.
const poll_transient_gap_spin_limit: u32 = 4096;

/// Libc-free monotonic nanoseconds for `receive … after` deadlines. The
/// kernel object is compiled `link_libc = false` on targets that do not
/// require libc (`abi.zig` module doc), so this cannot use `std.c`; it
/// mirrors how the futex parking layer reaches the OS directly. Darwin:
/// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` from libSystem (always linked,
/// exactly like the `os_sync_*` futex calls). Linux: the raw
/// `clock_gettime` syscall (no libc). Other OSes are Phase 4/7 ports —
/// the same posture as the futex layer.
fn monotonicNowNanoseconds() u64 {
    switch (comptime builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
            // CLOCK_UPTIME_RAW (8) — monotonic, does not count time asleep,
            // and is the clock the os_sync timeout API measures against.
            return clock_gettime_nsec_np(clock_uptime_raw);
        },
        .linux => {
            const linux = std.os.linux;
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &now);
            return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
        },
        else => @compileError(
            "receive/after monotonic clock is not implemented for this OS (Phase 4/7 ports)",
        ),
    }
}

/// `CLOCK_UPTIME_RAW` from `<time.h>` (Darwin).
const clock_uptime_raw: u32 = 8;
extern "c" fn clock_gettime_nsec_np(clock_id: u32) u64;

/// The scheduler driving the CURRENT OS thread, or null on a non-scheduler
/// thread (P4-J1). A `SchedulerPool` worker (and a standalone scheduler's run
/// loop) publishes itself here for the lifetime of its run loop — ONCE per
/// thread, never per quantum, since an OS thread only ever drives one
/// `Scheduler`. The cross-thread wake handshake reads it to route a revived
/// process onto the PRODUCER's core (message-passing locality, research.md
/// §6.1's LIFO slot); a foreign producer (null — a test thread, a future I/O
/// poller or blocking-pool thread) falls back to the process's last-running
/// scheduler. Read only on the cold wake path — never the alloc hot path — so
/// the Darwin TLV cost (E10) is irrelevant here.
threadlocal var current_scheduler: ?*Scheduler = null;

/// The pool-wide overflow run queue (P4-J1, research.md §6.1's global queue).
/// An intrusive FIFO of `.runnable` records guarded by a spinlock, shared by
/// every core. Two roles: a core with a large local backlog SPILLS half here so
/// idle cores can grab work in O(1) without hunting for a victim, and any core
/// pulls from here before it steals. Defined here (not in `scheduler_pool.zig`)
/// so a `Scheduler` can spill into it with no import cycle. Records carry the
/// same `ready_next` intrusive link the per-core FIFO uses; a record is on
/// exactly one queue at a time.
pub const GlobalRunQueue = struct {
    lock: std.atomic.Mutex,
    head: ?*ProcessRecord,
    tail: ?*ProcessRecord,
    /// Queue length. Guarded by `lock`; also load-able unlocked as an
    /// approximate emptiness hint for the worker loop's fast path.
    count: std.atomic.Value(usize),

    pub fn init() GlobalRunQueue {
        return .{ .lock = .unlocked, .head = null, .tail = null, .count = .init(0) };
    }

    /// Approximate emptiness (unlocked) — the worker loop's fast pre-check.
    pub fn isEmptyApprox(queue: *const GlobalRunQueue) bool {
        return queue.count.load(.monotonic) == 0;
    }

    fn acquire(queue: *GlobalRunQueue) void {
        while (!queue.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Append a chain of `moved` records (linked by `ready_next`, `chain_tail`
    /// terminating) to the queue tail. Used by a core spilling surplus work.
    fn pushChainLocked(queue: *GlobalRunQueue, chain_head: *ProcessRecord, chain_tail: *ProcessRecord, moved: usize) void {
        chain_tail.ready_next = null;
        if (queue.tail) |tail| {
            tail.ready_next = chain_head;
        } else {
            queue.head = chain_head;
        }
        queue.tail = chain_tail;
        _ = queue.count.fetchAdd(moved, .monotonic);
    }

    /// Pop the oldest record, or null when empty. O(1).
    pub fn pop(queue: *GlobalRunQueue) ?*ProcessRecord {
        queue.acquire();
        defer queue.lock.unlock();
        const record = queue.head orelse return null;
        queue.head = record.ready_next;
        if (queue.tail == record) queue.tail = null;
        record.ready_next = null;
        _ = queue.count.fetchSub(1, .monotonic);
        return record;
    }
};

/// The seam a `SchedulerPool` (`scheduler_pool.zig`) installs into each of its
/// cores so a `Scheduler` stays decoupled from the pool while being correct
/// under work-stealing migration (P4-J1). A standalone scheduler leaves it null
/// and keeps its Phase-1 per-scheduler bookkeeping byte-for-byte.
///
/// Why the live count must leave the scheduler under M:N: a process is spawned
/// on its origin core (which would `+1`) but, if stolen, torn down on another
/// core (which would `-1`), so a per-scheduler counter drifts and can underflow.
/// The pool owns ONE authoritative live-process count; `liveCountDelta` routes
/// both ends to it. (The record cache stays per-scheduler and race-free: a
/// record is always recycled to the tearing-down core's OWN cache, and freed
/// once at `deinit` through the pool's shared allocator.)
pub const PoolHooks = struct {
    /// Opaque pool context passed back to every hook.
    context: ?*anyopaque,
    /// Adjust the pool-wide live-process count (+1 at spawn, -1 at teardown).
    liveCountDelta: *const fn (context: ?*anyopaque, delta: i32) void,
    /// A runnable process was admitted to this core's FIFO — the pool wakes one
    /// idle (parked) worker so it can steal and run the surplus (netpoller
    /// wakeup; research.md §6.1). At most one wake per admission.
    notifyWork: *const fn (context: ?*anyopaque) void,
    /// A process completed teardown (its raw pid bits) — the pool checks whether
    /// it was the root process and, if so, signals every core to stop (Erlang
    /// halt model: the program's lifetime is the root's lifetime).
    onProcessExit: *const fn (context: ?*anyopaque, exited_pid_bits: u64) void,
};

/// The blocking / dirty-scheduler handoff seam (P4-J3, research.md §6.1
/// "Blocking operations and FFI"): the seam a `SchedulerPool` installs into
/// each core so a `Scheduler` classifying a `.blocking_offload` yield can hand
/// the calling process off to the shared blocking-pool OS-thread pool WITHOUT
/// importing the pool's concrete type (mirroring `PoolHooks`, and keeping the
/// scheduler↔blocking-pool dependency one-directional).
///
/// `submit(context, record)` transfers the record — whose fiber is suspended at
/// its `Process.blocking` offload point — to the blocking pool. The transfer is
/// a release edge (the pool's submit-queue lock): the offloading core's writes
/// to the record (its `.blocking` state, its heap) happen-before the pool
/// worker that pops and resumes the fiber. After `submit` returns, the core
/// MUST NOT touch the record again this episode — the pool owns it until it
/// re-attaches (`reattachFromBlocking`). This is the first half of the P4-J3
/// scheduler-local-invariant handoff (core → pool); the re-attach is the second
/// half (pool → core).
pub const BlockingHandoff = struct {
    /// Opaque pool context passed back to `submit` (the `*BlockingPool`).
    context: ?*anyopaque,
    /// Evacuate `record` to the blocking pool. Called by the offloading core's
    /// `runQuantum` as the LAST act of the `.blocking_offload` classification.
    submit: *const fn (context: ?*anyopaque, record: *ProcessRecord) void,
};

/// A blocking operation run through `Process.blocking` (P4-J3): a leaf native
/// call — expected to block or run long — given an opaque argument and
/// returning an opaque result. It executes on a blocking-pool thread, on the
/// calling process's own fiber stack. The C-ABI shape (`callconv(.c)`) so
/// compiled Zap reaches it through `zap_proc_blocking` unchanged. Contract: the
/// operation must RETURN normally (it must not exit the process, spawn, send,
/// receive, or otherwise re-enter the scheduler — it runs off-core where those
/// would violate the scheduler-local invariant); it may allocate into the
/// process's own heap (its manager context is published on the pool thread).
pub const BlockingOperation = *const fn (operation_argument: ?*anyopaque) callconv(.c) ?*anyopaque;

/// The M:N run-queue scheduler (plan 1.4/1.5 + Phase 4.1; instance-based — see
/// the module doc). A single `Scheduler` is NOT thread-safe as a whole:
/// exactly one thread runs its `runQuantum`/`spawn`/`dequeue` loop. Its
/// documented cross-thread surface is `wake()`, `requestWatchdogPreemption()`,
/// `parkCount()`, the mailbox-push wake seam, and — under `work_stealing` —
/// `stealInto()` (another core splicing half this FIFO under `run_queue_lock`).
/// Phase 4 multiplies this instance over the shared, already-M:N-safe pid table
/// and envelope pool: a `SchedulerPool` owns N of these, one per core. The
/// value is PINNED from the first `spawn` on (records hold back-pointers).
pub const Scheduler = struct {
    /// Allocator for process records (records recycle through the record
    /// cache and return here only at `deinit`).
    backing_allocator: std.mem.Allocator,
    /// The (shareable, M:N-safe) pid table. Not owned.
    pid_table: *PidTable,
    /// The (shareable, M:N-safe) envelope page reservoir. Not owned.
    envelope_pool: *EnvelopePool,
    /// This scheduler's OWN stack pool (per-scheduler by design, plan
    /// A.2.1/A.3). Owned.
    stack_pool: StackPool,
    /// Configuration (see `Options`).
    options: Options,
    /// Pool-orchestration seam, mirrored from `options.pool_hooks` for hot-path
    /// access (null for a standalone scheduler). See `PoolHooks`.
    pool_hooks: ?*const PoolHooks,
    /// Shared overflow queue, mirrored from `options.global_queue` (null
    /// standalone). See `GlobalRunQueue`.
    global_queue: ?*GlobalRunQueue,
    /// Saved scheduler-side cpu state while a process fiber runs.
    fiber_scheduler_context: fiber_context.SchedulerContext,
    /// THE per-quantum current process (plan A.2.4/E10): written once at
    /// quantum entry, cleared at quantum exit, null between quanta.
    /// Kernel code never reads it on hot paths — it receives the process
    /// as a parameter; this field is the seam Phase 2's compiled-code
    /// exposure hooks into (module doc).
    current_process: ?*ProcessControlBlock,

    /// This scheduler's per-core hierarchical timing wheel (P4-J2): the O(1)
    /// `receive … after` timer store, replacing the Phase-2 O(n)-per-core
    /// deadline scan. Scheduler-thread only — the SACRED per-scheduler invariant
    /// (`timing_wheel.zig` module doc). Empty for any program that never uses
    /// `after`, so `advanceReceiveTimers` and the deadline-bounded idle park are
    /// entirely skipped — the zero-`after` fast path.
    receive_timer_wheel: timing_wheel_module.TimingWheel,

    // -- run queue (owner + work-stealing thieves) ---------------------------
    /// Whether this scheduler participates in M:N work stealing (P4-J1). When
    /// false (the default, single-scheduler and deterministic modes) the run
    /// queue is a plain owner-only intrusive FIFO exactly as in Phase 1: the
    /// LIFO slot and the run-queue lock are unused and every wake routes to the
    /// FIFO tail. When true (a `SchedulerPool` core) the just-woken task lands
    /// in `runnext` for message-passing locality, thieves steal from the FIFO
    /// under `run_queue_lock`, and spillover reaches the pool's global queue.
    work_stealing: bool,
    /// The just-woken-task LIFO slot (P4-J1, research.md §6.1): a wake enqueues
    /// the revived process here so the waking core runs it NEXT — the ping-pong
    /// partner runs immediately on the producer's core (message-passing
    /// locality). OWNER-ONLY: filled by this scheduler's own `reviveEnqueue`
    /// (from `drainWakeStack` or the park re-check, both on this thread) and
    /// consumed first at `dequeueNextRunnable`; thieves never touch it, so the
    /// LIFO-locality guarantee holds (the partner is never stolen away). Null
    /// and unused when `work_stealing` is false. Consumed first on 60 of every
    /// 61 picks; the 61st pick BYPASSES it for fairness (see `schedule_tick` /
    /// `runnext_fairness_interval`), so a hot mutual-wake pair cannot starve the
    /// FIFO / global queue.
    runnext: ?*ProcessRecord,
    /// Per-core quantum counter driving the runnext-fairness poll (P4-R2
    /// finding #3). `dequeueNextRunnable` bumps it once per pick under work
    /// stealing; every `runnext_fairness_interval`-th pick bypasses `runnext`
    /// to serve the global queue / local FIFO first. Wraps harmlessly (`+%`);
    /// only its residue modulo the interval matters. Owner-thread only; unused
    /// (and never bumped) when `work_stealing` is false.
    schedule_tick: u64,
    /// Intrusive FIFO of `.runnable` processes: oldest. Guarded by
    /// `run_queue_lock` when `work_stealing` (thieves read the head); owner-only
    /// otherwise.
    ready_head: ?*ProcessRecord,
    /// Newest.
    ready_tail: ?*ProcessRecord,
    /// Queue length. Guarded by `run_queue_lock` when `work_stealing`.
    ready_count: usize,
    /// Guards `ready_head`/`ready_tail`/`ready_count` so a work-stealing thief
    /// on another core can splice half this FIFO onto its own (P4-J1). A
    /// `std.atomic.Mutex` spinlock by kernel convention (no libc-coupled
    /// `std.Thread.Mutex`; every critical section is O(1) queue-pointer
    /// surgery). Uncontended — thus ~free — for the owner in single-scheduler
    /// mode and on the hot path (thieves only lock when their own queue empties).
    run_queue_lock: std.atomic.Mutex,

    // -- record cache (scheduler-thread only) --------------------------------
    /// Free list of recycled records (linked via `ready_next`). Records
    /// return to the backing allocator only at `deinit`; the cache is
    /// self-bounded by the live-record peak (a record enters it only when
    /// a live process ends).
    free_records: ?*ProcessRecord,
    /// Length of `free_records`.
    cached_record_count: u32,
    /// Records currently live (spawned, not yet torn down).
    live_record_count: u32,
    /// High-watermark of `live_record_count`.
    live_record_peak: u32,

    // -- cross-thread wake machinery -----------------------------------------
    /// Lock-free Treiber stack of records with pending wake signals: any
    /// thread pushes (mailbox wake seam), only the scheduler pops (pop-all
    /// swap — no ABA).
    wake_stack_head: std.atomic.Value(?*ProcessRecord),
    /// Lock-free Treiber stack of records RE-ATTACHING from the blocking /
    /// dirty-scheduler pool (P4-J3): a blocking-pool worker pushes a record here
    /// after its `Process.blocking` op finishes off-core, and this scheduler
    /// (the record's offloading core) drains it in `serviceLocalEvents` /
    /// `drainReattachStack`, transitioning it `.blocking → .runnable`. Distinct
    /// from `wake_stack_head` because a blocking re-attach carries none of the
    /// message-park handshake's `park_control`/epoch/timer semantics — it is a
    /// plain "this suspended process is runnable again" edge — so keeping it on
    /// its own stack leaves the delicate park/epoch logic in `drainWakeStack`
    /// untouched. Links through `ProcessRecord.blocking_next`. Woken via the
    /// SAME `wake()` eventcount, so a re-attach that races a park is never lost
    /// (the pre-park re-checks read this stack too).
    reattach_stack_head: std.atomic.Value(?*ProcessRecord),
    /// The futex word (eventcount epoch) idle parking waits on.
    wake_epoch: std.atomic.Value(u32),
    /// Syscall-elision hint: true while the scheduler is (about to be)
    /// parked in the futex wait. See the module doc's parking protocol.
    parked_hint: std.atomic.Value(bool),
    /// The flag-only watchdog seam (plan decision 6): any thread sets it;
    /// the running process yields at its next `yieldCheck`; the scheduler
    /// clears it at the end of that quantum (one-shot consume).
    watchdog_preempt_flag: std.atomic.Value(bool),

    // -- counters -------------------------------------------------------------
    /// Times the scheduler entered a futex park (thread-safe read via
    /// `parkCount`).
    park_count: std.atomic.Value(u64),
    /// `wake()` invocations (thread-safe read via `wakeSignalCount`).
    wake_signal_count: std.atomic.Value(u64),
    /// Successful spawns (scheduler-thread only).
    spawn_total: u64,
    /// Normal exits (scheduler-thread only).
    normal_exit_total: u64,
    /// Kill teardowns (scheduler-thread only).
    kill_total: u64,
    /// Quanta executed (process switch-ins; scheduler-thread only —
    /// plan item 1.6 "quanta executed").
    quantum_total: u64,
    /// Mailbox messages that matched no `receive` arm and were routed to
    /// the dead-letter path (`receive`'s unexpected-message posture, plan
    /// item 2.3). Non-silent telemetry (scheduler-thread only).
    unexpected_message_total: u64,
    /// `Process.blocking` calls this core evacuated to the blocking pool
    /// (P4-J3; scheduler-thread only — the offloading core counts it).
    blocking_offload_total: u64,
    /// Blocking-pool re-attaches this core drained back to runnable (P4-J3;
    /// scheduler-thread only — the re-attach-target core counts it).
    blocking_reattach_total: u64,

    /// Construction options.
    pub const Options = struct {
        /// Preemption budget granted per quantum, in reductions
        /// (`ProcessContext.yieldCheck` decrements). The `Decisions` seam
        /// may substitute a per-quantum value (deterministic mode does).
        preemption_budget: u32 = process_module.default_preemption_budget,
        /// Spin iterations before parking when idle (E9 crossover; see
        /// `default_spin_iterations_before_park`).
        spin_iterations_before_park: u32 = default_spin_iterations_before_park,
        /// Upper bound on one futex park before re-checking for work.
        park_timeout_nanoseconds: u64 = default_park_timeout_nanoseconds,
        /// Idle behavior (production parks; deterministic mode forbids).
        idle_strategy: IdleStrategy = .futex_park,
        /// Enroll this scheduler in M:N work stealing (P4-J1): use the LIFO
        /// slot for wake locality and let thieves steal from its FIFO. Default
        /// false — a standalone scheduler (Phase-1 single-scheduler kernel
        /// tests, the deterministic harness) behaves byte-identically to Phase
        /// 1. A `SchedulerPool` sets this true for every core it owns.
        work_stealing: bool = false,
        /// The pool-orchestration seam (see `PoolHooks`). Null for a standalone
        /// scheduler; set by a `SchedulerPool` to route the live-process count,
        /// idle-worker wakeups, and root-exit detection to the pool.
        pool_hooks: ?*const PoolHooks = null,
        /// The shared overflow queue (see `GlobalRunQueue`). Null for a
        /// standalone scheduler; set by a `SchedulerPool`. A core whose local
        /// FIFO grows past `spill_threshold` spills half here for idle cores.
        global_queue: ?*GlobalRunQueue = null,
        /// Local-FIFO length past which `readyEnqueue` spills half the backlog
        /// to `global_queue` (only when both are set). Zero disables spilling.
        spill_threshold: usize = default_spill_threshold,
        /// The blocking / dirty-scheduler handoff seam (P4-J3; see
        /// `BlockingHandoff`). Null for a standalone scheduler, in which case a
        /// `Process.blocking` call runs the blocking op INLINE on this scheduler
        /// thread (the documented single-core degradation — it stalls this
        /// scheduler exactly as an un-annotated blocking FFI call would). Set by
        /// a `SchedulerPool` to a handoff that evacuates the calling process's
        /// fiber onto the shared blocking-pool OS-thread pool so the core is
        /// freed to run its other processes.
        blocking_handoff: ?*const BlockingHandoff = null,
        /// The nondeterminism seam (see `Decisions`).
        decisions: Decisions = .production_fifo,
        /// Trace seam (see `TraceHook`); null = zero-cost no trace.
        trace_hook: ?TraceHook = null,
        /// Opaque context for `trace_hook`.
        trace_context: ?*anyopaque = null,
        /// Crash-report seam (plan 1.6; `crash_report.zig`): invoked
        /// synchronously on the scheduler thread at the START of every
        /// teardown — before the pid is unregistered or any resource is
        /// torn down — with a borrowed report. Null = one branch per
        /// teardown, nothing captured.
        crash_report_hook: ?crash_report_module.ReportHook = null,
        /// Opaque context for `crash_report_hook`.
        crash_report_context: ?*anyopaque = null,
        /// Usable bytes per fiber stack (forwarded to this scheduler's
        /// stack pool).
        stack_usable_size: usize = stack_pool_module.default_usable_size,
        /// The monotonic-time seam (see `Clock`). Production reads the real
        /// clock; the seeded multi-scheduler simulator installs a virtual
        /// clock so `receive … after` firing is a pure function of the seed.
        clock: Clock = .wall,
        /// The kernel signal runtime (P5-J1, `signal.zig`): the shared node
        /// pool, reason-atom registry, and payload seam that links/monitors/
        /// exit signals stand on. A `SchedulerPool` creates ONE and shares it
        /// across every core (like the pid table and envelope pool); a
        /// standalone scheduler with no signal usage leaves it null (its
        /// processes have empty signal sets, so teardown propagation is a
        /// no-op). Signal intrinsics require it.
        signal_runtime: ?*signal_module.SignalRuntime = null,
        /// The local process registry (P5-J2, `registry.zig`): the shared
        /// name→pid table `Process.register`/`whereis`/`unregister` and
        /// send-by-name stand on. A `SchedulerPool` creates ONE and shares it
        /// across every core (like the pid table and signal runtime); a
        /// standalone scheduler with no registry usage leaves it null (its
        /// processes register no names, so teardown name-release is a no-op).
        /// The registry validates pid liveness through this scheduler's
        /// `pid_table` (`registryLiveness`), giving registration and lookup
        /// their generation validation.
        registry: ?*registry_module.ProcessRegistry = null,
        /// The `Zap.Blob` allocation domain (P6-J2, `blob.zig`): the one
        /// sanctioned atomically-refcounted share tier. Shared across every
        /// core exactly like the pid table and signal runtime; teardown
        /// drains each process's blob ledger into it (`releaseAllOwned`) so
        /// a dying process releases every blob reference it holds. Null for
        /// a standalone scheduler with no blob usage (its processes' ledgers
        /// are empty, asserted at teardown).
        blob_domain: ?*blob_module.BlobDomain = null,
    };

    /// Per-spawn options.
    pub const SpawnOptions = struct {
        /// The process body.
        entry: ProcessEntry,
        /// Opaque argument forwarded to `entry`.
        argument: ?*anyopaque = null,
        /// The process's memory-manager binding (Phase 1: the test
        /// vtable; the real manager ABI replaces it later in Phase 1 —
        /// see `process.zig`, "Manager binding").
        manager: ManagerContext,
        /// Reclamation model stamped into the pid (plan §2.4; Phase 1's
        /// manifest model is `.refcounted`).
        model: ReclamationModel = .refcounted,
        /// `spawn_link` (P5-J2): the PARENT record to atomically bidirectional-
        /// link this child to BEFORE it is admitted to a run queue. Establishing
        /// the link before the child can run is what makes `spawn_link` atomic —
        /// a child that exits immediately still propagates its exit to the parent
        /// (Erlang `spawn_link`). Null for a plain spawn. Requires the signal
        /// runtime.
        link_parent: ?*ProcessRecord = null,
        /// `spawn_monitor` (P5-J2): the PARENT record to atomically install a
        /// monitor FROM, on this child, before admission; the minted reference is
        /// written to `monitor_ref_out`. Null for a plain spawn. Requires the
        /// signal runtime.
        monitor_parent: ?*ProcessRecord = null,
        /// Out-param receiving the monitor reference minted for `monitor_parent`.
        monitor_ref_out: ?*signal_module.Ref = null,
    };

    /// Scheduler-thread-only statistics snapshot (Phase 1.6 skeleton).
    /// For the thread-safe subset see `parkCount`/`wakeSignalCount`.
    pub const Statistics = struct {
        /// Processes currently live (spawned, not torn down).
        live_process_count: u32,
        /// High-watermark of live processes.
        live_process_peak: u32,
        /// Current ready-queue depth.
        ready_queue_depth: usize,
        /// Recycled records currently cached.
        cached_record_count: u32,
        /// Successful spawns.
        spawn_total: u64,
        /// Normal exits.
        normal_exit_total: u64,
        /// Kill teardowns.
        kill_total: u64,
        /// Quanta executed (process switch-ins).
        quantum_total: u64,
        /// Mailbox messages routed to the dead-letter path for matching no
        /// `receive` arm (the unexpected-message posture).
        unexpected_message_total: u64,
        /// Futex parks entered.
        park_count: u64,
        /// `wake()` invocations.
        wake_signal_count: u64,
        /// `Process.blocking` evacuations to the blocking pool (P4-J3).
        blocking_offload_total: u64,
        /// Blocking-pool re-attaches drained back to runnable (P4-J3).
        blocking_reattach_total: u64,
    };

    /// Create a scheduler over a shared pid table and envelope reservoir.
    /// Performs no allocation (the record cache and stack pool grow on
    /// first use). The returned value may be moved until the first
    /// `spawn`, after which it is pinned (records hold back-pointers).
    pub fn init(
        backing_allocator: std.mem.Allocator,
        table: *PidTable,
        message_pool: *EnvelopePool,
        options: Options,
    ) Scheduler {
        return .{
            .backing_allocator = backing_allocator,
            .pid_table = table,
            .envelope_pool = message_pool,
            .stack_pool = StackPool.init(.{
                .usable_size = options.stack_usable_size,
                // Under work stealing a stolen process exits on another core,
                // which releases its stack back to THIS origin pool cross-thread.
                .thread_safe = options.work_stealing,
            }),
            .options = options,
            .pool_hooks = options.pool_hooks,
            .global_queue = options.global_queue,
            .fiber_scheduler_context = .{},
            .current_process = null,
            .receive_timer_wheel = timing_wheel_module.TimingWheel.init(backing_allocator),
            .work_stealing = options.work_stealing,
            .runnext = null,
            .schedule_tick = 0,
            .ready_head = null,
            .ready_tail = null,
            .ready_count = 0,
            .run_queue_lock = .unlocked,
            .free_records = null,
            .cached_record_count = 0,
            .live_record_count = 0,
            .live_record_peak = 0,
            .wake_stack_head = .init(null),
            .reattach_stack_head = .init(null),
            .wake_epoch = .init(0),
            .parked_hint = .init(false),
            .watchdog_preempt_flag = .init(false),
            .park_count = .init(0),
            .wake_signal_count = .init(0),
            .spawn_total = 0,
            .normal_exit_total = 0,
            .kill_total = 0,
            .quantum_total = 0,
            .unexpected_message_total = 0,
            .blocking_offload_total = 0,
            .blocking_reattach_total = 0,
        };
    }

    /// Tear the scheduler down. Every process must already have exited or
    /// been killed (`shutdownAllProcesses` handles stragglers) — asserted.
    /// Frees the record cache and the stack pool.
    pub fn deinit(scheduler: *Scheduler) void {
        std.debug.assert(scheduler.live_record_count == 0);
        std.debug.assert(scheduler.ready_count == 0);
        std.debug.assert(scheduler.runnext == null);
        std.debug.assert(scheduler.wake_stack_head.load(.acquire) == null);
        std.debug.assert(scheduler.reattach_stack_head.load(.acquire) == null);
        while (scheduler.free_records) |record| {
            scheduler.free_records = record.ready_next;
            scheduler.backing_allocator.destroy(record);
        }
        scheduler.cached_record_count = 0;
        // Free the timing wheel's node pool. Any entries still linked (a
        // cross-scheduler message beat a not-yet-expired deadline, so the entry
        // was invalidated by epoch but left for lazy reap) are freed here with
        // the pool's arena — never leaked (`timing_wheel.zig` deinit doc).
        scheduler.receive_timer_wheel.deinit();
        scheduler.stack_pool.deinit();
        scheduler.* = undefined;
    }

    // -------------------------------------------------------------------------
    // Spawn (plan 1.4 hot path — see the module doc's spawn section)
    // -------------------------------------------------------------------------

    /// Create a process and admit it to the ready queue. Scheduler-thread
    /// only (module doc, "Cross-thread wake sources"). Pool-only after
    /// warmup: record cache hit + stack pool hit + lock-free pid slot +
    /// allocation-free handle init + queue append — no syscalls, no
    /// backing-allocator calls. All failures are synchronous and leave
    /// the scheduler exactly as before the call (the lazy-start
    /// decision's rationale, module doc).
    pub fn spawn(scheduler: *Scheduler, options: SpawnOptions) SpawnError!Pid {
        const record = try scheduler.acquireRecord();
        errdefer scheduler.recycleRecord(record);

        const kernel_fiber = try fiber_context.init(
            &scheduler.stack_pool,
            processFiberEntry,
            record,
        );
        // The fiber is `.ready`: moving it into the PCB below is legal,
        // and reclaimWithoutResume is its error-path release.
        record.scheduler = scheduler;
        record.entry_function = options.entry;
        record.entry_argument = options.argument;
        record.ready_next = null;
        record.yield_reason = .reenqueue;
        // Reset the kill flag for this incarnation (a recycled record inherits
        // the previous incarnation's `true`, set when it was torn down).
        record.pending_kill.store(false, .monotonic);
        record.last_signal = .{};
        record.last_signal_kind = .none;
        record.pending_correlated_envelope = null;
        // Preserve the record's park epoch across recycle (it is monotonic for
        // the record's whole life so a stale timer can never alias a reused
        // record's new episode); only reset the state bits to `.running`.
        record.park_control = .init(packParkControl(parkControlEpoch(record.park_control.raw), .running));
        // Open this incarnation to sends (teardown left it closed). Ordered
        // before `register` below, so a legitimate sender — which looks the pid
        // up only after registration — never observes a stale `true`. The
        // companion `in_flight_send_count` is deliberately NOT reset (it is
        // preserved across recycle like the park epoch — see its field doc — and
        // is provably zero here because teardown's `closeAndQuiesce` waited it to
        // zero before this record could recycle).
        record.send_closed.store(false, .seq_cst);
        record.wake_next = null;
        record.blocking_next = null;
        record.active_context = null;
        record.wake_deadline_nanoseconds = 0;
        record.receive_timed_out = false;
        record.timer_entry = null;
        record.timer_wheel_owner = null;
        record.timer_epoch = 0;
        ProcessControlBlock.init(&record.pcb, kernel_fiber, options.manager);
        errdefer fiber_context.reclaimWithoutResume(&record.pcb.fiber);

        // spawn_link / spawn_monitor (P5-J2): pre-allocate the relationship nodes
        // BEFORE the pid is minted, so the post-register insertion below — which
        // must complete before the child is admitted and can exit — is
        // infallible. An OOM here fails the spawn cleanly (before any pid) via the
        // errdefers above. The signal runtime backs the node pool.
        var spawn_link_child_node: ?*signal_module.SignalNode = null;
        var spawn_link_parent_node: ?*signal_module.SignalNode = null;
        var spawn_monitor_target_node: ?*signal_module.SignalNode = null;
        var spawn_monitor_holder_node: ?*signal_module.SignalNode = null;
        errdefer if (scheduler.signalRuntimePtr()) |sr| {
            if (spawn_link_child_node) |node| sr.node_pool.free(node);
            if (spawn_link_parent_node) |node| sr.node_pool.free(node);
            if (spawn_monitor_target_node) |node| sr.node_pool.free(node);
            if (spawn_monitor_holder_node) |node| sr.node_pool.free(node);
        };
        if (options.link_parent != null) {
            const sr = scheduler.signalRuntimePtr().?;
            spawn_link_child_node = try sr.node_pool.allocate();
            spawn_link_parent_node = try sr.node_pool.allocate();
        }
        if (options.monitor_parent != null) {
            const sr = scheduler.signalRuntimePtr().?;
            spawn_monitor_target_node = try sr.node_pool.allocate();
            spawn_monitor_holder_node = try sr.node_pool.allocate();
        }

        const pid = try record.pcb.register(scheduler.pid_table, options.model);
        record.envelope_handle = EnvelopePool.Handle.init(scheduler.envelope_pool);
        record.pcb.mailbox.wake_callback = mailboxWakeCallback;
        record.pcb.mailbox.wake_context = record;

        record.pcb.transitionTo(.runnable);
        // spawn_link / spawn_monitor (P5-J2): establish the relationship NOW —
        // the child is registered (has a pid) but NOT yet admitted, so it cannot
        // run or exit until `readyEnqueue` below. Inserting the pre-allocated
        // nodes here is the atomicity guarantee: a `spawn_link` child that exits
        // immediately still finds the link in its set at teardown and propagates
        // its exit to the parent (Erlang `spawn_link` atomicity). Infallible — the
        // nodes were reserved above.
        if (options.link_parent) |parent| {
            record.pcb.signal_state.insertLinkNode(spawn_link_child_node.?, parent.pcb.pid.toBits());
            parent.pcb.signal_state.insertLinkNode(spawn_link_parent_node.?, pid.toBits());
            spawn_link_child_node = null;
            spawn_link_parent_node = null;
        }
        if (options.monitor_parent) |parent| {
            const ref = scheduler.signalRuntimePtr().?.mintRef();
            record.pcb.signal_state.insertMonitoredByNode(spawn_monitor_target_node.?, ref, parent.pcb.pid.toBits());
            parent.pcb.signal_state.insertMonitorNode(spawn_monitor_holder_node.?, ref, pid.toBits());
            spawn_monitor_target_node = null;
            spawn_monitor_holder_node = null;
            if (options.monitor_ref_out) |out| out.* = ref;
        }
        // Live count FIRST — BEFORE `readyEnqueue` makes the record stealable
        // (P4-R2). Under work stealing `readyEnqueue` publishes the record to
        // the FIFO, where a thief can steal, run, AND tear it down —
        // decrementing the live count — before THIS spawn's increment lands. If
        // the increment came second, that stolen `-1` could bring the pool's
        // live count to a spurious transient 0 while the parent is still live,
        // tripping premature quiescence (`SchedulerPool` stops the instant the
        // count hits 0) and LOSING the just-spawned process. Counting before
        // publishing keeps the count ≥ the true live count at every instant.
        // The pool count is authoritative under M:N (a stolen process is torn
        // down on a different core, so a per-scheduler count would drift); a
        // standalone scheduler keeps its own per-scheduler count (no stealing,
        // so ordering is moot there — kept uniform for simplicity).
        if (scheduler.pool_hooks) |hooks| {
            hooks.liveCountDelta(hooks.context, 1);
        } else {
            scheduler.live_record_count += 1;
            if (scheduler.live_record_count > scheduler.live_record_peak) {
                scheduler.live_record_peak = scheduler.live_record_count;
            }
        }
        scheduler.readyEnqueue(record);
        scheduler.spawn_total += 1;
        scheduler.emitTrace(.spawn, pid);
        // Exercise the admission wake edge from day one (no-op syscall-
        // wise while un-parked; Phase 4's cross-scheduler admission rides
        // exactly this seam).
        scheduler.wake();
        return pid;
    }

    // -------------------------------------------------------------------------
    // Kill (plan 1.4 crash-teardown simulation)
    // -------------------------------------------------------------------------

    /// Kill `target` (untrappable). A `.waiting` process is torn down
    /// immediately — the non-cooperative point: its suspended fiber is
    /// never resumed and its stack is reclaimed via the invariant path. A
    /// `.runnable`/`.running` process is marked and torn down at its next
    /// scheduling point/safepoint (a self-kill therefore takes effect at
    /// the caller's next `yieldCheck`/`receive`). Scheduler-thread only.
    pub fn kill(scheduler: *Scheduler, target: Pid) KillOutcome {
        const target_pcb = scheduler.pid_table.lookup(target) orelse return .not_found;
        const record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        switch (target_pcb.currentState()) {
            .waiting => {
                scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                return .killed;
            },
            .runnable, .running, .blocking => {
                // `.blocking` (P4-J3): the process's fiber is executing native
                // code on a blocking-pool thread and CANNOT be torn down here —
                // its stack is live off-core. Like `.running`, the kill is
                // recorded and takes effect at the process's next scheduling
                // point: the blocking op finishes (native code is never
                // interrupted — BEAM's dirty-NIF semantics), the process
                // re-attaches, and `runNext` observes `pending_kill` and tears
                // it down before its next quantum.
                record.pending_kill.store(true, .release);
                return .kill_pending;
            },
            // `.embryo` is only observable inside `spawn` on this same
            // thread, and `.exiting` processes are unregistered before
            // teardown begins — neither can resolve through `lookup`.
            .embryo, .exiting => unreachable,
        }
    }

    /// Tear down EVERY remaining process (killed): runnable ones via the
    /// ready queue, waiting ones via the pid table. The runtime-shutdown
    /// path, and how a deterministic harness cleans up a deadlocked
    /// scenario. Scheduler-thread only; afterwards the scheduler is
    /// quiescent and `deinit`-able.
    pub fn shutdownAllProcesses(scheduler: *Scheduler) void {
        while (true) {
            scheduler.drainWakeStack();
            // Deliberately BYPASSES the Decisions seam (fixed FIFO order,
            // never `chooseNextReadyIndex`): shutdown is a fixed
            // deterministic policy that runs after a scenario's compared
            // trace ends, so exempting it keeps the seam's inventory to
            // decisions that can diverge replayed runs.
            if (scheduler.dequeueReadyAt(0)) |record| {
                scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                continue;
            }
            const waiting_record = find_waiting: {
                var iterator = scheduler.pid_table.iterateLiveProcesses();
                while (iterator.next()) |live| {
                    if (live.pcb.currentState() == .waiting) {
                        const record: *ProcessRecord = @fieldParentPtr("pcb", live.pcb);
                        break :find_waiting record;
                    }
                }
                break :find_waiting null;
            } orelse break;
            scheduler.teardownProcess(waiting_record, scheduler.exitStatusForPending(waiting_record));
        }
        // Every live process is either runnable (queued) or waiting, so
        // the two sweeps above are exhaustive.
        std.debug.assert(scheduler.live_record_count == 0);
    }

    // -------------------------------------------------------------------------
    // `receive … after` timeout firing — the per-scheduler timing wheel (P4-J2,
    // `timing_wheel.zig`). Replaces the Phase-2 O(n)-per-core deadline scan with
    // O(1) insert/cancel and an occupancy-accelerated clock advance.
    // -------------------------------------------------------------------------

    /// Deliver an expired `receive … after` timer: the wheel's fire callback,
    /// run on the owning wheel's scheduler thread when a bucket expires. It
    /// atomically confirms — with one `cmpxchg` on the packed `park_control` —
    /// that `record` is STILL parked for exactly the episode this timer was armed
    /// for (`epoch`), transitions it to `.running` (bumping the epoch so the
    /// episode ends), marks `receive_timed_out`, and makes it runnable. The CAS
    /// failing means the timer is stale — a message beat the deadline, the
    /// process was killed, revived cross-core, or the record recycled — so the
    /// entry is discarded with no timeout delivered (the "harmlessly fires into
    /// an already-satisfied receive" path). Because the epoch is packed INTO the
    /// CAS's expected value, a process that was revived cross-core and re-parked
    /// (a new episode) can never be grabbed by this stale timer.
    fn fireReceiveTimeout(scheduler: *Scheduler, context: *anyopaque, epoch: u64) timing_wheel_module.FireOutcome {
        const record: *ProcessRecord = @ptrCast(@alignCast(context));
        const pcb = &record.pcb;
        // One CAS validates {still parked} AND {still episode `epoch`} and ends
        // the episode. On failure the timer lost the race — discard it.
        if (record.park_control.cmpxchgStrong(
            packParkControl(epoch, .parked),
            packParkControl(epoch + 1, .running),
            .seq_cst,
            .seq_cst,
        )) |_| {
            // Deliberately do NOT null `record.timer_entry` here. The CAS failed
            // because this episode already ended — a message revived the process,
            // or it was killed/recycled/re-parked — so it may now be RUNNING (and
            // arming a NEW timer, writing `timer_entry`) on another core. Writing
            // its per-process `timer_entry` from this (the old owner's) wheel
            // would be a cross-core write to state that core owns — a data race
            // violating the sacred scheduler-local invariant, and it could clobber
            // the freshly-armed entry. The stale pointer is safe left dangling:
            // every reader (`tryEagerCancelReceiveTimer`, `cancelProcessTimer`)
            // gates on `timer_wheel_owner`/`timer_epoch` first, which no longer
            // match this discarded episode, so the freed node is never touched.
            return .discarded;
        }
        // Won the revival. Read `pcb.pid` for the trace BEFORE `readyEnqueue`
        // makes the process stealable (P4-J1): once on the FIFO a sibling core
        // can steal, run, and tear it down — writing `pcb.pid` — concurrently.
        const timed_out_pid = pcb.pid;
        record.receive_timed_out = true;
        record.timer_entry = null; // the node is being freed by the wheel
        pcb.transitionTo(.runnable);
        scheduler.emitTrace(.wake, timed_out_pid);
        scheduler.readyEnqueue(record);
        return .fired;
    }

    /// Arm a `receive … after` timer for `record` on THIS scheduler's wheel at
    /// its `wake_deadline_nanoseconds`, tagged with the current park-episode
    /// epoch, and record the entry / wheel owner / epoch on the record for O(1)
    /// same-core cancellation. Returns false only if the wheel node could not be
    /// allocated (system OOM) — the caller then re-runs the process rather than
    /// parking it timerless. Scheduler-thread only.
    fn armReceiveTimer(scheduler: *Scheduler, record: *ProcessRecord) bool {
        const epoch = parkControlEpoch(record.park_control.load(.seq_cst));
        const entry = scheduler.receive_timer_wheel.insert(
            record,
            epoch,
            record.wake_deadline_nanoseconds,
            scheduler.options.clock.read(),
        ) catch {
            record.timer_entry = null;
            record.timer_wheel_owner = null;
            return false;
        };
        record.timer_entry = entry;
        record.timer_wheel_owner = scheduler;
        record.timer_epoch = epoch;
        return true;
    }

    /// Advance this scheduler's timing wheel to now and fire every elapsed
    /// `receive … after` timer. A no-op when the wheel is empty — the
    /// zero-`after` fast path. Scheduler-thread only; runs at the top of every
    /// run-loop / worker iteration (the deadline analogue of `drainWakeStack`).
    fn advanceReceiveTimers(scheduler: *Scheduler) void {
        if (scheduler.receive_timer_wheel.isEmpty()) return;
        scheduler.receive_timer_wheel.advance(
            scheduler.options.clock.read(),
            *Scheduler,
            scheduler,
            fireReceiveTimeout,
        );
    }

    /// Deterministic-mode (`.forbid_parking`) timeout firing: with no wall clock
    /// to sleep on, when nothing else can run, advance the wheel's virtual clock
    /// straight to the earliest armed timer and fire it. Returns whether the
    /// wheel held any timer. This gives `receive … after` deterministic semantics
    /// under the seeded scheduler (a timeout fires precisely when the system
    /// would otherwise deadlock). Also the per-core fire primitive the
    /// multi-scheduler seeded simulator (`deterministic_mn.zig`) drives once it
    /// has advanced the SHARED virtual clock to this core's due deadline.
    /// Scheduler-thread only.
    pub fn fireEarliestReceiveTimeout(scheduler: *Scheduler) bool {
        return scheduler.receive_timer_wheel.advanceToEarliestAndFire(
            *Scheduler,
            scheduler,
            fireReceiveTimeout,
        );
    }

    /// The exact absolute deadline (monotonic ns) of this core's earliest armed
    /// `receive … after` timer, or null when none is armed. The seeded
    /// multi-scheduler simulator takes the minimum across cores to advance the
    /// shared virtual clock to the globally-next timer event (discrete-event
    /// time order), then fires the due core(s). Scheduler-thread only.
    pub fn earliestReceiveDeadlineNanoseconds(scheduler: *const Scheduler) ?u64 {
        return scheduler.receive_timer_wheel.earliestEntryDeadlineNanoseconds();
    }

    // -------------------------------------------------------------------------
    // Run loop (module doc)
    // -------------------------------------------------------------------------

    /// Run until every process has exited (quiescence). Parks when idle
    /// under `.futex_park`; surfaces `error.AllProcessesWaiting` under
    /// `.forbid_parking` (deterministic mode). Scheduler-thread only.
    pub fn runUntilQuiescent(scheduler: *Scheduler) RunError!void {
        // Publish this thread's scheduler for the wake handshake's locality
        // routing (a send from a process body running below resolves THIS core
        // as the producer's core). Restored on exit so the driver thread's
        // out-of-loop sends take the foreign path. Set once per run, not per
        // quantum — an OS thread only ever drives one scheduler.
        const previous_scheduler = current_scheduler;
        current_scheduler = scheduler;
        defer current_scheduler = previous_scheduler;
        while (true) {
            scheduler.drainWakeStack();
            scheduler.drainReattachStack();
            scheduler.advanceReceiveTimers();
            if (scheduler.dequeueNextRunnable()) |record| {
                if (record.pending_kill.load(.acquire)) {
                    // Killed while queued: torn down without ever running
                    // (legal `runnable → exiting`).
                    scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                    continue;
                }
                scheduler.runQuantum(record);
                continue;
            }
            if (scheduler.live_record_count == 0) return;
            switch (scheduler.options.idle_strategy) {
                // Park bounded by the earliest `receive … after` deadline
                // (parkUntilWakeSignal reads it) so a timeout fires on time.
                .futex_park => scheduler.parkUntilWakeSignal(),
                .forbid_parking => {
                    // Deterministic run: fire the earliest `receive … after`
                    // waiter (virtual time) before declaring deadlock.
                    if (scheduler.fireEarliestReceiveTimeout()) continue;
                    // Single-threaded deterministic run: no producer can
                    // race this re-check, so an empty wake stack here is
                    // a genuine scenario deadlock.
                    if (scheduler.wake_stack_head.load(.acquire) == null) {
                        return error.AllProcessesWaiting;
                    }
                },
            }
        }
    }

    /// Run until `target` has exited (its pid no longer resolves), then
    /// return — other processes may still be live. This is the "join"
    /// shape the P2-J2 root-process bootstrap drives: the generated main
    /// spawns user main as the root process and runs the scheduler until
    /// exactly that process finishes; stragglers are torn down by the
    /// runtime's atexit `shutdownAllProcesses` (Erlang halt semantics —
    /// the program's lifetime is the root process's lifetime). Parks when
    /// idle under `.futex_park`; surfaces `error.AllProcessesWaiting`
    /// under `.forbid_parking` when the target cannot make progress
    /// (deterministic-mode deadlock). Scheduler-thread only.
    pub fn runUntilProcessExits(scheduler: *Scheduler, target: Pid) RunError!void {
        // See `runUntilQuiescent`: publish this thread's scheduler for wake
        // locality routing for the lifetime of the loop.
        const previous_scheduler = current_scheduler;
        current_scheduler = scheduler;
        defer current_scheduler = previous_scheduler;
        while (true) {
            // Silent probe — the target's death is this loop's expected
            // terminal condition, not a dead-lettered message (the
            // logging `lookup` would emit a spurious dead-letter for
            // every join of an exited process).
            if (!scheduler.pid_table.isAlive(target)) return;
            scheduler.drainWakeStack();
            scheduler.drainReattachStack();
            scheduler.advanceReceiveTimers();
            if (scheduler.dequeueNextRunnable()) |record| {
                if (record.pending_kill.load(.acquire)) {
                    // Killed while queued: torn down without ever running
                    // (legal `runnable → exiting`).
                    scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                    continue;
                }
                scheduler.runQuantum(record);
                continue;
            }
            switch (scheduler.options.idle_strategy) {
                // Park bounded by the earliest `receive … after` deadline
                // (parkUntilWakeSignal reads it) so a timeout fires on time.
                .futex_park => scheduler.parkUntilWakeSignal(),
                .forbid_parking => {
                    // Deterministic run: fire the earliest `receive … after`
                    // waiter (virtual time) before declaring deadlock.
                    if (scheduler.fireEarliestReceiveTimeout()) continue;
                    // Single-threaded deterministic run: no producer can
                    // race this re-check, so an empty wake stack here is
                    // a genuine scenario deadlock.
                    if (scheduler.wake_stack_head.load(.acquire) == null) {
                        return error.AllProcessesWaiting;
                    }
                },
            }
        }
    }

    // -------------------------------------------------------------------------
    // Pool-facing API (P4-J1) — `scheduler_pool.zig` drives these on this core's
    // own thread. A standalone scheduler uses `runUntilQuiescent`/
    // `runUntilProcessExits` instead; these compose the same primitives so a
    // pool worker can interleave local work with the global queue and stealing.
    // -------------------------------------------------------------------------

    /// Publish this scheduler as the current thread's scheduler for the lifetime
    /// of its worker loop (wake-locality routing; see `current_scheduler`).
    /// Called once when a pool worker thread enters, paired with `endRunThread`.
    pub fn beginRunThread(scheduler: *Scheduler) void {
        current_scheduler = scheduler;
    }

    /// Clear the current-thread scheduler on worker exit.
    pub fn endRunThread(scheduler: *Scheduler) void {
        std.debug.assert(current_scheduler == scheduler);
        current_scheduler = null;
    }

    /// The scheduler driving the calling thread, or null on a non-scheduler
    /// thread (P4-J1). The gate-ON ABI uses it to route an in-process spawn to
    /// the RUNNING core (locality; stealing rebalances) and to resolve the
    /// current process on the calling core for `zap_proc_current`. Null on the
    /// driver thread before/after the run loop.
    pub fn currentThreadScheduler() ?*Scheduler {
        return current_scheduler;
    }

    /// Set the current-thread scheduler and return the prior value — the
    /// save/restore seam for a driver that multiplexes several schedulers on ONE
    /// thread (the seeded multi-scheduler simulator, `deterministic_mn.zig`). It
    /// swaps in the core it is about to step so the mailbox wake seam routes a
    /// producer-side wake to that core (wake locality, exactly as a real pool
    /// worker thread would) and `currentProcessContext`/`zap_proc_current`
    /// resolve on it, then restores the prior value when the run ends. Production
    /// pool workers use `beginRunThread`/`endRunThread` (one core per thread for
    /// the whole loop) instead. Thread-local; caller-owned.
    pub fn swapCurrentThreadScheduler(scheduler: ?*Scheduler) ?*Scheduler {
        const previous = current_scheduler;
        current_scheduler = scheduler;
        return previous;
    }

    /// Service this core's cross-thread events once: convert freshly-woken
    /// processes to runnable (drain the wake stack) and fire any elapsed
    /// `receive … after` deadlines. Run at the top of every worker iteration.
    pub fn serviceLocalEvents(scheduler: *Scheduler) void {
        scheduler.drainWakeStack();
        scheduler.drainReattachStack();
        scheduler.advanceReceiveTimers();
    }

    /// Take the next runnable process from this core (LIFO slot then FIFO), or
    /// null when this core has no local work. Owner-thread only.
    pub fn takeLocalRunnable(scheduler: *Scheduler) ?*ProcessRecord {
        return scheduler.dequeueNextRunnable();
    }

    /// Run one quantum for `record` on this core (or tear it down if a kill is
    /// pending) — the per-record body of the run loop. `record` may have been
    /// dequeued from this core, pulled from the global queue, or just stolen;
    /// `runQuantum` claims ownership for the quantum (migration). Owner-thread.
    pub fn runNext(scheduler: *Scheduler, record: *ProcessRecord) void {
        if (record.pending_kill.load(.acquire)) {
            scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
            return;
        }
        scheduler.runQuantum(record);
    }

    /// Park this core until woken (spin-then-futex; the netpoller idle path).
    /// The pool calls this only after local, global, and steal sources are all
    /// empty; a cross-thread wake (`wake()`, driven by a mailbox push, a new
    /// spawn's `notifyWork`, or the pool's stop signal) returns it to the loop.
    pub fn parkForWork(scheduler: *Scheduler) void {
        scheduler.parkUntilWakeSignal();
    }

    /// Whether this core is (about to be) parked on its futex — the pool's
    /// `wakeOneIdle` reads it to pick a parked worker to wake. Thread-safe
    /// (a plain atomic load of the parking hint); a stale read is benign (a
    /// spurious `wake()` on an un-parked core is a no-op).
    pub fn isParkedHint(scheduler: *const Scheduler) bool {
        return scheduler.parked_hint.load(.acquire);
    }

    /// Whether this core currently holds any local runnable work (LIFO slot or
    /// FIFO). Approximate under concurrency (a thief may empty the FIFO); the
    /// worker loop's park path re-checks authoritatively. Owner-biased read.
    pub fn hasLocalWork(scheduler: *Scheduler) bool {
        if (scheduler.runnext != null) return true;
        scheduler.lockRunQueue();
        defer scheduler.unlockRunQueue();
        return scheduler.ready_count != 0;
    }

    /// Whether a blocking-pool re-attach is pending for this core (P4-J3) — a
    /// blocking op finished off-core and pushed its process onto this core's
    /// `reattach_stack`. The pool's `parkWorker` re-checks it so a re-attach that
    /// lands just before a park is not slept through.
    pub fn hasPendingReattach(scheduler: *Scheduler) bool {
        return scheduler.reattach_stack_head.load(.acquire) != null;
    }

    /// Whether a cross-thread message wake is pending on this core's wake stack
    /// but not yet drained to runnable. The seeded multi-scheduler simulator
    /// (`deterministic_mn.zig`) reads this — WITHOUT draining — to decide a core
    /// is steppable: only the owning core can drain its own wake stack, so a
    /// pending wake that no other core can service must keep the owner steppable
    /// (else the discrete-event driver would wrongly declare deadlock). A stale
    /// read is impossible in the single-threaded simulator (the only reader).
    pub fn hasPendingWake(scheduler: *const Scheduler) bool {
        return scheduler.wake_stack_head.load(.acquire) != null;
    }

    /// Whether this core's FIFO holds work a sibling could STEAL (the LIFO slot
    /// is owner-only and never stealable, so it is excluded). The seeded
    /// multi-scheduler simulator reads it to decide whether an otherwise-idle
    /// core is steppable via a steal. Owner-biased approximate read under
    /// concurrency; EXACT in the single-threaded simulator (its only caller).
    pub fn hasStealableWork(scheduler: *Scheduler) bool {
        scheduler.lockRunQueue();
        defer scheduler.unlockRunQueue();
        return scheduler.ready_count != 0;
    }

    /// Drain this core's cross-thread wake stack without running anything — the
    /// pool's shutdown flushes every core's stack (single-threaded) so no stale
    /// entry references a record about to be recycled.
    pub fn drainPendingWakes(scheduler: *Scheduler) void {
        scheduler.drainWakeStack();
    }

    /// Tear down `record` as a shutdown straggler (killed teardown). The caller
    /// (pool shutdown, single-threaded) has already removed it from every run
    /// queue, or it is a `.waiting` process that sits on none.
    pub fn teardownAsStraggler(scheduler: *Scheduler, record: *ProcessRecord) void {
        scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
    }

    /// The `ProcessContext` of the process the scheduler is currently
    /// running a quantum for, or null between quanta (including on the
    /// driver thread outside `runQuantum`). The ambient-lookup companion
    /// to the kernel's parameter-threaded current-process discipline
    /// (module doc): kernel code never calls this — it exists for the
    /// `zap_proc_current` intrinsic, which compiled Zap code reaches
    /// through the runtime's process wrappers. Scheduler-thread only.
    pub fn currentProcessContext(scheduler: *Scheduler) ?*ProcessContext {
        const pcb = scheduler.current_process orelse return null;
        const record: *ProcessRecord = @fieldParentPtr("pcb", pcb);
        // The first quantum enters `processFiberEntry` before any code
        // that could observe the scheduler runs, so a current process
        // always has its context published.
        return record.active_context;
    }

    // -------------------------------------------------------------------------
    // Cross-thread wake surface
    // -------------------------------------------------------------------------

    /// Wake the scheduler if it is (or is about to be) parked. Thread-
    /// safe, wait-free, and syscall-free while the scheduler is running
    /// (module doc, parking protocol). Producers normally reach this
    /// through the mailbox wake seam; it is public as the Phase 4
    /// admission seam.
    pub fn wake(scheduler: *Scheduler) void {
        _ = scheduler.wake_signal_count.fetchAdd(1, .monotonic);
        _ = scheduler.wake_epoch.fetchAdd(1, .seq_cst);
        if (scheduler.parked_hint.load(.seq_cst)) {
            parking_futex.wakeOne(&scheduler.wake_epoch);
        }
    }

    /// Set the flag-only watchdog (plan decision 6): the currently
    /// running process yields at its next `yieldCheck`; the scheduler
    /// clears the flag when that quantum ends (one-shot). Thread-safe —
    /// this is the seam Phase 4's watchdog timer thread drives; Phase 1
    /// tests set it directly.
    pub fn requestWatchdogPreemption(scheduler: *Scheduler) void {
        scheduler.watchdog_preempt_flag.store(true, .monotonic);
    }

    /// Thread-safe read of the park counter (test/observability surface
    /// for the cross-thread park/wake tests).
    pub fn parkCount(scheduler: *const Scheduler) u64 {
        return scheduler.park_count.load(.monotonic);
    }

    /// Thread-safe read of the wake-signal counter.
    pub fn wakeSignalCount(scheduler: *const Scheduler) u64 {
        return scheduler.wake_signal_count.load(.monotonic);
    }

    /// Scheduler-thread-only statistics snapshot.
    pub fn statistics(scheduler: *const Scheduler) Statistics {
        return .{
            .live_process_count = scheduler.live_record_count,
            .live_process_peak = scheduler.live_record_peak,
            .ready_queue_depth = scheduler.ready_count,
            .cached_record_count = scheduler.cached_record_count,
            .spawn_total = scheduler.spawn_total,
            .normal_exit_total = scheduler.normal_exit_total,
            .kill_total = scheduler.kill_total,
            .quantum_total = scheduler.quantum_total,
            .unexpected_message_total = scheduler.unexpected_message_total,
            .park_count = scheduler.park_count.load(.monotonic),
            .wake_signal_count = scheduler.wake_signal_count.load(.monotonic),
            .blocking_offload_total = scheduler.blocking_offload_total,
            .blocking_reattach_total = scheduler.blocking_reattach_total,
        };
    }

    /// This scheduler's stack-pool counters (exact-accounting assertions).
    pub fn stackPoolStatistics(scheduler: *const Scheduler) stack_pool_module.Statistics {
        return scheduler.stack_pool.statistics();
    }

    // -------------------------------------------------------------------------
    // Quantum
    // -------------------------------------------------------------------------

    /// Run one quantum: budget per the Decisions seam, current-process
    /// write (A.2.4), switch in, classify the outcome, clear the watchdog.
    fn runQuantum(scheduler: *Scheduler, record: *ProcessRecord) void {
        const pcb = &record.pcb;
        // Claim ownership for this quantum (P4-J1 migration): a process may run
        // on a different core than last time (work stealing moved it). The
        // record's `scheduler` pointer — read by `yieldCheck`/
        // `reductionSafepoint` for the watchdog/co-runnable check, by the wake
        // handshake's foreign-producer fallback, and by the process's own
        // `send`/`spawn`/`kill` through the context — must be THIS core while it
        // runs here. Refresh the on-stack `ProcessContext` too (it caches the
        // scheduler; null before the first quantum, when `processFiberEntry`
        // reads the freshly-set `record.scheduler` instead).
        record.scheduler = scheduler;
        if (record.active_context) |context| context.scheduler = scheduler;
        pcb.transitionTo(.running);
        pcb.preemption_budget = scheduler.options.decisions.vtable.chooseQuantumBudget(
            scheduler.options.decisions.decision_context,
            scheduler.options.preemption_budget,
        );
        // P2-J6: publish this quantum's budget to the compiled-code
        // safepoint counters (plan A.2.4's per-quantum discipline extended
        // to the ZIR-emitted safepoints). `_budget` seeds the layer-2
        // loop-local reduction counter the ZIR builder emits at alloc-free
        // loop back-edges; `_remaining` is the layer-1 alloc-piggyback
        // running counter the runtime's allocation path decrements. Kept in
        // lockstep with `pcb.preemption_budget` so the seeded deterministic
        // mode's budget variation moves every compiled-code preemption
        // point exactly as it moves the kernel `yieldCheck` path.
        process_module.zap_proc_reductions_budget = pcb.preemption_budget;
        process_module.zap_proc_reductions_remaining = pcb.preemption_budget;
        scheduler.emitTrace(.schedule, pcb.pid);
        scheduler.quantum_total += 1;
        scheduler.current_process = pcb;
        // Publish this process's PRIVATE manager context (plan item 3.1 /
        // A.4 OQ1, P3-J1) so the runtime's allocation hot path routes every
        // cell this quantum allocates — and every message it adopts through
        // the deep-copy walker — into this process's own heap. Save/restore
        // the prior value so between-quantum and out-of-quantum allocations
        // (startup/atexit) keep resolving the runtime's bootstrap context
        // (seeded by `concurrencyStartupForEntry`).
        const previous_arc_context = process_module.zap_proc_active_arc_context;
        process_module.zap_proc_active_arc_context = pcb.manager.manager_state;
        const outcome = fiber_context.resumeFiber(&scheduler.fiber_scheduler_context, &pcb.fiber);
        process_module.zap_proc_active_arc_context = previous_arc_context;
        scheduler.current_process = null;
        // One watchdog request preempts (at most) one quantum: the
        // quantum just ended, so the request — whether it caused the end
        // or the process yielded first — is consumed.
        scheduler.watchdog_preempt_flag.store(false, .monotonic);

        switch (outcome) {
            .finished => {
                // A process that finished its entry exits `normal` — UNLESS a
                // signal doomed it first (a self `exit_signal`/kill whose
                // `pending_kill` the finishing fiber never hit a safepoint to
                // observe): honor the pending reason so a self-signalled abnormal
                // exit still propagates abnormally (P5-J1).
                if (record.pending_kill.load(.acquire)) {
                    scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                } else {
                    scheduler.teardownProcess(record, scheduler.normalStatus());
                }
            },
            .yielded => {
                if (record.pending_kill.load(.acquire)) {
                    // Killed at a safepoint (or while it happened to
                    // yield): `running → exiting`.
                    scheduler.teardownProcess(record, scheduler.exitStatusForPending(record));
                    return;
                }
                switch (record.yield_reason) {
                    .reenqueue => {
                        scheduler.emitTrace(.yield, pcb.pid);
                        pcb.transitionTo(.runnable);
                        scheduler.readyEnqueue(record);
                    },
                    .waiting_for_message => {
                        scheduler.emitTrace(.wait, pcb.pid);
                        pcb.transitionTo(.waiting);
                        // Commit the park under the cross-thread handshake: a
                        // message that raced the final empty-check is caught by
                        // the seq_cst re-check here and revives the process
                        // immediately; otherwise it stays parked until a wake
                        // (module doc, "Cross-thread wake handshake"). No
                        // lost-wake window across scheduler threads.
                        _ = scheduler.commitPark(record);
                    },
                    .waiting_for_message_deadline => {
                        // Arm the timing-wheel entry on THIS core's wheel BEFORE
                        // committing the park, so the entry's writes
                        // (`timer_entry`/`timer_wheel_owner`/`timer_epoch`) are
                        // published by `commitPark`'s `.parked` release edge — a
                        // cross-core reviver that later acquires `.parked` then
                        // sees a coherent owner and correctly declines to touch
                        // the entry (leaving it for lazy reap).
                        if (scheduler.armReceiveTimer(record)) {
                            scheduler.emitTrace(.wait, pcb.pid);
                            pcb.transitionTo(.waiting);
                            if (scheduler.commitPark(record)) {
                                // Genuinely parked; the wheel entry fires or is
                                // cancelled by a later message/kill.
                            } else {
                                // A message beat the park (`commitPark`
                                // self-revived the process): cancel the just-armed
                                // entry eagerly — same core, O(1) — since no
                                // cross-core actor ever saw a `.parked` publish
                                // for it, then end this aborted episode.
                                scheduler.tryEagerCancelReceiveTimer(record, record.timer_epoch);
                                const control = record.park_control.load(.seq_cst);
                                record.park_control.store(
                                    packParkControl(parkControlEpoch(control) + 1, .running),
                                    .seq_cst,
                                );
                            }
                        } else {
                            // The wheel node could not be allocated (system OOM).
                            // Do not park timerless (that would drop the `after`
                            // deadline); re-run the process so `receiveWaitTimeout`
                            // re-checks its deadline against the monotonic clock
                            // and re-attempts the park — graceful degradation
                            // under memory exhaustion, no `after` semantics lost.
                            pcb.transitionTo(.runnable);
                            scheduler.readyEnqueue(record);
                        }
                    },
                    .blocking_offload => {
                        // `Process.blocking` (P4-J3): evacuate this process to
                        // the blocking / dirty-scheduler pool and free this core.
                        // `blocking_handoff` is guaranteed non-null here —
                        // `ProcessContext.blocking` only emits `.blocking_offload`
                        // when a pool is wired (else it runs inline and never
                        // yields). `submit` is the release edge that transfers
                        // ownership of the record to the pool; it MUST be the last
                        // touch of `record` on this core this episode.
                        scheduler.emitTrace(.block, pcb.pid);
                        scheduler.blocking_offload_total += 1;
                        pcb.transitionTo(.blocking);
                        const handoff = scheduler.options.blocking_handoff.?;
                        handoff.submit(handoff.context, record);
                    },
                    // A core never observes `.blocking_complete`: that yield
                    // happens on a blocking-pool thread and is consumed by
                    // `runBlockingPhase`, which switches back to the pool
                    // thread's own scheduler context, not a core's.
                    .blocking_complete => unreachable,
                }
            },
        }
    }

    // -------------------------------------------------------------------------
    // Blocking / dirty-scheduler pool integration (P4-J3, `blocking_pool.zig`)
    // -------------------------------------------------------------------------

    /// Run one process's `Process.blocking` operation to completion on the
    /// CALLING (blocking-pool) thread, then return so the caller can re-attach
    /// it (P4-J3). Entered by a `BlockingPool` worker after it pops `record`
    /// from the submit queue (the acquire edge that pairs with the offloading
    /// core's `submit` release — so this thread sees the record's `.blocking`
    /// state and heap coherently). Resumes the fiber, which was suspended at
    /// its `.blocking_offload` point; the fiber runs the blocking op on its own
    /// stack and yields `.blocking_complete`. Publishes the process's manager
    /// context and a saturated reduction budget on THIS thread first, so the
    /// op's allocations route into the process's own heap and its
    /// compiler-emitted safepoints never yield (an off-core fiber has no core to
    /// yield to — it runs the dirty op to completion, BEAM dirty-scheduler
    /// semantics). Not re-entrant: the pool thread runs exactly one blocking
    /// phase at a time on its own `SchedulerContext`.
    pub fn runBlockingPhase(record: *ProcessRecord, pool_context: *fiber_context.SchedulerContext) void {
        const pcb = &record.pcb;
        // Publish this process's private manager context on the pool thread so
        // the op's allocations route into its own heap (mirrors `runQuantum`'s
        // publish; threadlocals are per-thread, so this never disturbs a core).
        const previous_arc_context = process_module.zap_proc_active_arc_context;
        process_module.zap_proc_active_arc_context = pcb.manager.manager_state;
        // Saturate the reduction counters so the op's compiler-emitted
        // safepoints (`reductionSafepoint`) never reach zero and thus never
        // yield: the dirty op is meant to run to completion off-core.
        const previous_budget = process_module.zap_proc_reductions_budget;
        const previous_remaining = process_module.zap_proc_reductions_remaining;
        process_module.zap_proc_reductions_budget = std.math.maxInt(u32);
        process_module.zap_proc_reductions_remaining = std.math.maxInt(u32);

        const outcome = fiber_context.resumeFiber(pool_context, &pcb.fiber);

        process_module.zap_proc_active_arc_context = previous_arc_context;
        process_module.zap_proc_reductions_budget = previous_budget;
        process_module.zap_proc_reductions_remaining = previous_remaining;

        // The op returns via a second `.blocking_complete` yield — never a fiber
        // finish (the intrinsic yields again before the entry can return) and
        // never any other reason. A violation means the blocking-op contract was
        // broken (it exited the process or re-entered the scheduler off-core).
        std.debug.assert(outcome == .yielded);
        std.debug.assert(record.yield_reason == .blocking_complete);
    }

    /// Re-attach a process whose blocking op has finished onto a core (P4-J3),
    /// the pool → core half of the handoff. Called by a `BlockingPool` worker on
    /// its own thread AFTER `runBlockingPhase` returns. Pushes the record onto
    /// its offloading core's `reattach_stack` (a release edge — the pool thread's
    /// off-core touches of the process heap happen-before the core's next
    /// quantum) and wakes that core. The core drains it in `serviceLocalEvents`
    /// (`drainReattachStack`), transitioning `.blocking → .runnable`. Re-attach
    /// targets the OFFLOADING core (`record.scheduler`) for locality; stealing
    /// rebalances, and shutdown drains any core's reattach stack single-threaded.
    pub fn reattachFromBlocking(record: *ProcessRecord) void {
        record.scheduler.pushReattach(record);
    }

    /// The real blocking-pool `execute` hook (`blocking_pool.ExecuteFn`): run one
    /// record's blocking phase and re-attach it. A `BlockingPool` worker calls
    /// this per popped record on its own thread. Each call uses a FRESH
    /// `SchedulerContext` on the worker's own stack — the resumed fiber yields
    /// back to THIS thread's context, so a worker may run any process's blocking
    /// phase (they never share a context). `execute_context` is unused (the
    /// record carries everything the phase needs).
    pub fn blockingPoolExecute(execute_context: ?*anyopaque, record: *ProcessRecord) void {
        _ = execute_context;
        var pool_context: fiber_context.SchedulerContext = .{};
        runBlockingPhase(record, &pool_context);
        reattachFromBlocking(record);
    }

    /// Push a re-attaching record onto this scheduler's reattach stack
    /// (lock-free Treiber) and wake it. Only the blocking-pool worker that ran
    /// the record's blocking phase calls this (exactly once per episode), so a
    /// record is on at most one reattach stack at a time. The `wake()` reuses the
    /// idle-park eventcount, so a re-attach that races the core's park is never
    /// lost (the pre-park re-checks read `reattach_stack_head` too).
    fn pushReattach(target: *Scheduler, record: *ProcessRecord) void {
        var observed_head = target.reattach_stack_head.load(.monotonic);
        while (true) {
            record.blocking_next = observed_head;
            observed_head = target.reattach_stack_head.cmpxchgWeak(
                observed_head,
                record,
                .release,
                .monotonic,
            ) orelse break;
        }
        target.wake();
    }

    /// Drain every pending blocking-pool re-attach: pop-all (swap — no ABA),
    /// restore push order, and make each re-attached process runnable
    /// (`.blocking → .runnable`, enqueued via the LIFO slot for locality under
    /// work stealing). Run at the top of every worker iteration
    /// (`serviceLocalEvents`) and in the standalone run loops. Runs on this
    /// scheduler's own thread. Cheap no-op when the stack is empty (the common
    /// case — a program that never blocks pays one relaxed load per iteration).
    fn drainReattachStack(scheduler: *Scheduler) void {
        var popped: ?*ProcessRecord = scheduler.reattach_stack_head.swap(null, .acquire) orelse return;
        // The Treiber stack yields newest-first; reverse to arrival order.
        var oldest_first: ?*ProcessRecord = null;
        while (popped) |record| {
            popped = record.blocking_next;
            record.blocking_next = oldest_first;
            oldest_first = record;
        }
        while (oldest_first) |record| {
            oldest_first = record.blocking_next;
            record.blocking_next = null;
            const pcb = &record.pcb;
            // The unique pool-worker re-attacher pushed this record; this core is
            // its sole reviver. A `.blocking` record becomes runnable; any other
            // state is impossible (only a `.blocking` record is ever pushed here).
            std.debug.assert(pcb.currentState() == .blocking);
            pcb.transitionTo(.runnable);
            scheduler.blocking_reattach_total += 1;
            scheduler.reviveEnqueue(record);
            scheduler.emitTrace(.unblock, pcb.pid);
        }
    }

    /// Drain this core's pending re-attaches without running anything — the
    /// pool's shutdown flushes every core's reattach stack (single-threaded, all
    /// blocking-pool workers already quiesced) so no in-flight blocking episode
    /// is lost and every re-attached straggler is reaped. Companion to
    /// `drainPendingWakes`.
    pub fn drainPendingReattach(scheduler: *Scheduler) void {
        scheduler.drainReattachStack();
    }

    /// The parking side of the cross-thread wake handshake (P4-J1). The caller
    /// has already transitioned `record` to `.waiting` (its mailbox was empty
    /// when `receive` decided to suspend). This attempts `cmpxchg(.running →
    /// .parked)` on the single seq_cst handshake variable:
    ///   * success — genuinely parked; returns true. A later wake seam
    ///     `swap(.notified)` will displace `.parked`, and THAT producer pushes
    ///     the record to a wake stack to revive it.
    ///   * failure — the CAS read `.notified`: a producer delivered a message in
    ///     the window between `receive` seeing the mailbox empty and this park
    ///     (the wake seam swapped `.notified` in over `.running`). The scheduler
    ///     resets `.running`, revives the process locally (the LIFO slot under
    ///     `work_stealing`), and returns false.
    /// The producer's `swap` and this `cmpxchg` are seq_cst RMWs on the SAME
    /// variable and thus totally ordered, so no message and no wake is ever lost
    /// — and no standalone memory fence is required. Runs on this scheduler's
    /// own thread.
    fn commitPark(scheduler: *Scheduler, record: *ProcessRecord) bool {
        const pcb = &record.pcb;
        // Park within the CURRENT episode's epoch: `.running → .parked`, epoch
        // unchanged. The owner is the only writer of the epoch bits, so reading
        // them here is race-free (a concurrent wake seam only flips the state to
        // `.notified`, preserving the epoch).
        const epoch = parkControlEpoch(record.park_control.load(.seq_cst));
        if (record.park_control.cmpxchgStrong(
            packParkControl(epoch, .running),
            packParkControl(epoch, .parked),
            .seq_cst,
            .seq_cst,
        )) |observed| {
            // Not `.running`: a message landed in the park window (`.notified`).
            // The suspension is resolved by that message — a genuine wakeup, so
            // emit `.wake` (the trace's "a waiting process became runnable"
            // event) exactly as the wake-stack drain does for a message that
            // arrives after the park commits. This keeps the wait/wake tallies
            // matched and the deterministic trace complete.
            std.debug.assert(parkControlState(observed) == .notified);
            record.park_control.store(packParkControl(epoch, .running), .seq_cst);
            pcb.transitionTo(.runnable);
            scheduler.emitTrace(.wake, pcb.pid);
            scheduler.reviveEnqueue(record);
            return false;
        }
        return true;
    }

    // -------------------------------------------------------------------------
    // Kernel signal mechanism (P5-J1, `signal.zig`): links, monitors, exit
    // signals, trap_exit. The genuine intrinsics over which J2/J3 write
    // spawn_link/spawn_monitor/supervisors in PURE ZAP. Every cross-core touch
    // of a target (deliver a signal, mutate its sets) rides the SAME pin
    // (`beginSend`/`endSend`) + `isAlive` re-check the copy send uses, so it is
    // race-free against the target's concurrent teardown; teardown propagation
    // runs after `closeAndQuiesce`, which drains those pins, so no set-mutation
    // is ever missed or double-fired (P4-R1 grace period).
    // -------------------------------------------------------------------------

    /// The kernel signal runtime, or null when this scheduler has none wired (a
    /// standalone non-signal scheduler). Teardown propagation treats null as
    /// "no links/monitors possible" (a no-op); the signal intrinsics require it.
    inline fn signalRuntimePtr(scheduler: *Scheduler) ?*signal_module.SignalRuntime {
        return scheduler.options.signal_runtime;
    }

    /// The registered `normal` reason term (0 with no signal runtime — only
    /// reachable when no process has links/monitors, so the term is unused).
    fn normalReasonTerm(scheduler: *Scheduler) u64 {
        return if (scheduler.options.signal_runtime) |sr| sr.reason_atoms.normalTerm() else 0;
    }

    /// The registered `killed` reason term.
    fn killedReasonTerm(scheduler: *Scheduler) u64 {
        return if (scheduler.options.signal_runtime) |sr| sr.reason_atoms.killedTerm() else 0;
    }

    /// The exit status of a normally-finishing process.
    fn normalStatus(scheduler: *Scheduler) signal_module.ExitStatus {
        return signal_module.ExitStatus.normalStatus(scheduler.normalReasonTerm());
    }

    /// The exit status of a process torn down because `pending_kill` was set:
    /// the reason a signal recorded (`pending_exit`), or `killed` for a plain
    /// same-core kill / self-exit that recorded none.
    fn exitStatusForPending(scheduler: *Scheduler, record: *ProcessRecord) signal_module.ExitStatus {
        return record.pcb.signal_state.getPendingExit() orelse
            signal_module.ExitStatus.abnormalStatus(scheduler.killedReasonTerm());
    }

    /// Push one exit/`DOWN` signal MESSAGE onto `target_pcb`'s mailbox from
    /// `sender_record`'s envelope handle. The payload (`signal.SignalPayload`)
    /// is a runtime ledger block (via the payload seam) so the receiver's
    /// ordinary `zap_proc_envelope_free` reclaims it exactly like a copied user
    /// payload; the `Fragment.signal_kind` discriminator marks it a signal. The
    /// caller holds a `beginSend` pin on the target (mailbox-race-free). A
    /// payload/envelope OOM drops the signal (best-effort, Erlang-faithful — a
    /// signal is not guaranteed under memory pressure).
    fn pushSignalMessage(
        scheduler: *Scheduler,
        sender_record: *ProcessRecord,
        target_pcb: *ProcessControlBlock,
        kind: signal_module.SignalKind,
        payload: signal_module.SignalPayload,
    ) void {
        const sr = scheduler.signalRuntimePtr() orelse return;
        const seam = sr.payload_seam;
        const allocate = seam.allocate orelse return;
        const body = allocate(seam.context, @sizeOf(signal_module.SignalPayload)) orelse return;
        const payload_slot: *signal_module.SignalPayload = @ptrCast(@alignCast(body));
        payload_slot.* = payload;
        const envelope = sender_record.envelope_handle.allocate() catch {
            if (seam.free) |free_payload| free_payload(seam.context, body, @sizeOf(signal_module.SignalPayload));
            return;
        };
        envelope.fragment = .{
            .payload_pointer = body,
            .payload_byte_length = @sizeOf(signal_module.SignalPayload),
            .payload_origin_page = null,
            .signal_kind = kind,
        };
        _ = target_pcb.mailbox.push(envelope);
    }

    /// Doom `target_record` with `status`: record the reason (`pending_exit`,
    /// first-wins unless `override` — an untrappable `kill` overriding to
    /// `killed`), set `pending_kill` (release), and revive the target if parked
    /// so it observes the kill at its next scheduling point / receive. Race-free
    /// cross-core: the target's own core performs the teardown (its fiber stack
    /// is core-local); the release store + the revive handshake publish the kill
    /// to it. The caller holds a `beginSend` pin, so the record is not recycled.
    fn killWithReason(
        scheduler: *Scheduler,
        target_record: *ProcessRecord,
        status: signal_module.ExitStatus,
        override: bool,
    ) void {
        _ = scheduler;
        target_record.pcb.signal_state.setPendingExit(status, override);
        target_record.pending_kill.store(true, .release);
        reviveIfParked(target_record);
    }

    /// Deliver an exit signal from `from_bits` to `target_pid` per the
    /// Erlang-fidelity reason rules (research.md §6.7): `normal` never kills a
    /// non-trapping process (a trapping one still gets the message); an abnormal
    /// reason kills a non-trapping process (via `killWithReason`) or is
    /// delivered as an `{'EXIT', From, Reason}` message to a trapping one.
    /// `break_link` (teardown propagation) also removes `from_bits` from the
    /// target's link set (a dying process breaks its links). A dead/stale target
    /// silently drops (Erlang: a signal to a dead process is a no-op).
    fn deliverExitSignalTo(
        scheduler: *Scheduler,
        sender_record: *ProcessRecord,
        target_pid: Pid,
        from_bits: u64,
        status: signal_module.ExitStatus,
        break_link: bool,
    ) SendOutcome {
        const target_pcb = scheduler.pid_table.lookupSilent(target_pid) orelse return .dead_lettered;
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) return .dead_lettered;
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(target_pid)) return .dead_lettered;

        if (break_link) {
            if (scheduler.signalRuntimePtr()) |sr| {
                _ = target_pcb.signal_state.unlinkPeer(&sr.node_pool, from_bits);
            }
        }

        const traps = target_pcb.signal_state.trapsExits();
        if (status.category == .normal) {
            // A normal exit does not kill a non-trapping process; a trapping one
            // still receives it as a message.
            if (traps) scheduler.pushSignalMessage(sender_record, target_pcb, .exit, .{
                .from_bits = from_bits,
                .reason_term = status.term,
            });
        } else if (traps) {
            scheduler.pushSignalMessage(sender_record, target_pcb, .exit, .{
                .from_bits = from_bits,
                .reason_term = status.term,
            });
        } else {
            scheduler.killWithReason(target_record, status, false);
        }
        return .delivered;
    }

    /// Fire a monitor `DOWN` from `monitored_bits` to `monitor_pid` under `ref`
    /// with `reason_term`. Always a message (monitors are NOT affected by
    /// `trap_exit`). A dead monitor silently drops.
    fn deliverDownTo(
        scheduler: *Scheduler,
        sender_record: *ProcessRecord,
        monitor_pid: Pid,
        ref: signal_module.Ref,
        monitored_bits: u64,
        reason_term: u64,
    ) SendOutcome {
        const target_pcb = scheduler.pid_table.lookupSilent(monitor_pid) orelse return .dead_lettered;
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) return .dead_lettered;
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(monitor_pid)) return .dead_lettered;
        scheduler.pushSignalMessage(sender_record, target_pcb, .down, .{
            .from_bits = monitored_bits,
            .ref = ref,
            .reason_term = reason_term,
        });
        return .delivered;
    }

    /// Remove the incoming-monitor entry `ref` from `target_pid` (a monitoring
    /// process cleaning a target's `monitored_by` at its own teardown, or a
    /// `demonitor`). Silent no-op if the target is gone (its set was freed with
    /// it). Race-free via the `beginSend` pin.
    ///
    /// Returns whether it is now GUARANTEED that no `DOWN` for `ref` is
    /// queued or can ever be delivered: `true` iff the target was pinned
    /// alive. The pin gates the target's teardown BEFORE
    /// `propagateExitSignals` runs (`closeAndQuiesce` waits for it), so a
    /// successful pin means the target has not fired — and after this
    /// removal never will fire — a `DOWN` for `ref`. Every bail-out path
    /// (`false`) means the target is dead or tearing down, so its
    /// propagation may already have delivered the `DOWN` or still has it
    /// in flight — the `signalDemonitorFlush` caller must flush/await it.
    fn cleanRemoteMonitor(scheduler: *Scheduler, target_pid: Pid, ref: signal_module.Ref) bool {
        const sr = scheduler.signalRuntimePtr() orelse return false;
        const target_pcb = scheduler.pid_table.lookupSilent(target_pid) orelse return false;
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) return false;
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(target_pid)) return false;
        // Pinned alive ⇒ propagation has not run ⇒ no DOWN was ever fired
        // for this monitor; removing the entry (idempotently — it can only
        // be absent if this monitor was never fully installed) prevents any
        // future one.
        _ = target_pcb.signal_state.removeMonitoredByRef(&sr.node_pool, ref);
        return true;
    }

    /// Propagate `record`'s exit at teardown: send exit signals to every linked
    /// peer (breaking each link), fire `DOWN` to every monitor watching it, and
    /// clean each monitored target's `monitored_by` of this process's outgoing
    /// monitors — then free every set node. Runs after `closeAndQuiesce` and
    /// before `abandon` (see `teardownProcess`). A no-op with no signal runtime.
    fn propagateExitSignals(
        scheduler: *Scheduler,
        record: *ProcessRecord,
        exit_pid: Pid,
        status: signal_module.ExitStatus,
    ) void {
        const sr = scheduler.signalRuntimePtr() orelse return;
        const state = &record.pcb.signal_state;
        const from_bits = exit_pid.toBits();

        var link_node = state.takeLinks();
        while (link_node) |node| {
            link_node = node.next;
            _ = scheduler.deliverExitSignalTo(record, Pid.fromBits(node.pid_bits), from_bits, status, true);
            sr.node_pool.free(node);
        }

        var monitored_node = state.takeMonitoredBy();
        while (monitored_node) |node| {
            monitored_node = node.next;
            _ = scheduler.deliverDownTo(record, Pid.fromBits(node.pid_bits), node.ref, from_bits, status.term);
            sr.node_pool.free(node);
        }

        var outgoing_node = state.takeMonitors();
        while (outgoing_node) |node| {
            outgoing_node = node.next;
            _ = scheduler.cleanRemoteMonitor(Pid.fromBits(node.pid_bits), node.ref);
            sr.node_pool.free(node);
        }
    }

    // -------------------------------------------------------------------------
    // Signal operations (invoked from a running process through `ProcessContext`)
    // -------------------------------------------------------------------------

    /// `link(target)`: establish a bidirectional link (idempotent, one-per-pair;
    /// research.md §6.7). Returns true if the link was established (or already
    /// existed). Linking a DEAD process delivers an exit signal with `noproc` to
    /// the caller instead (Erlang `link/1` semantics) and returns false.
    fn signalLink(scheduler: *Scheduler, self_record: *ProcessRecord, target_pid: Pid) bool {
        const sr = scheduler.signalRuntimePtr() orelse return false;
        const self_bits = self_record.pcb.pid.toBits();
        const target_pcb = scheduler.pid_table.lookupSilent(target_pid) orelse {
            scheduler.linkNoproc(self_record, target_pid);
            return false;
        };
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) {
            scheduler.linkNoproc(self_record, target_pid);
            return false;
        }
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(target_pid)) {
            scheduler.linkNoproc(self_record, target_pid);
            return false;
        }
        // Add on the target side (pinned) then the self side; the pin gates the
        // target's teardown so its propagation sees this link (or, if it already
        // closed, `beginSend` failed above and we took the noproc path).
        _ = target_pcb.signal_state.linkPeer(&sr.node_pool, self_bits) catch return false;
        _ = self_record.pcb.signal_state.linkPeer(&sr.node_pool, target_pid.toBits()) catch {
            _ = target_pcb.signal_state.unlinkPeer(&sr.node_pool, self_bits);
            return false;
        };
        return true;
    }

    /// A `link` to an already-dead process: deliver a `noproc` exit signal to
    /// the caller (which dies if not trapping, or receives `{'EXIT', Dead,
    /// noproc}` if trapping). The signal is delivered to SELF, so it uses the
    /// same delivery path (self is always alive/pinned trivially here).
    fn linkNoproc(scheduler: *Scheduler, self_record: *ProcessRecord, dead_pid: Pid) void {
        const status = signal_module.ExitStatus.abnormalStatus(scheduler.reasonNoproc());
        const self_pcb = &self_record.pcb;
        if (self_pcb.signal_state.trapsExits()) {
            scheduler.pushSignalMessage(self_record, self_pcb, .exit, .{
                .from_bits = dead_pid.toBits(),
                .reason_term = status.term,
            });
        } else {
            scheduler.killWithReason(self_record, status, false);
        }
    }

    fn reasonNoproc(scheduler: *Scheduler) u64 {
        return if (scheduler.options.signal_runtime) |sr| sr.reason_atoms.noprocTerm() else 0;
    }

    /// `unlink(target)`: break the bidirectional link (idempotent). Returns
    /// whether a link existed on the self side.
    fn signalUnlink(scheduler: *Scheduler, self_record: *ProcessRecord, target_pid: Pid) bool {
        const sr = scheduler.signalRuntimePtr() orelse return false;
        const removed = self_record.pcb.signal_state.unlinkPeer(&sr.node_pool, target_pid.toBits());
        // Break the peer side too (best-effort; a dead peer already freed its set).
        if (scheduler.pid_table.lookupSilent(target_pid)) |target_pcb| {
            const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
            if (target_record.beginSend()) {
                defer target_record.endSend();
                if (scheduler.pid_table.isAlive(target_pid)) {
                    _ = target_pcb.signal_state.unlinkPeer(&sr.node_pool, self_record.pcb.pid.toBits());
                }
            }
        }
        return removed;
    }

    /// `monitor(target) -> Ref`: install a unidirectional, stackable monitor and
    /// return its fresh reference. Monitoring a DEAD process fires `DOWN` with
    /// `noproc` to the caller immediately (research.md §6.7) and still returns a
    /// (now spent) ref.
    fn signalMonitor(scheduler: *Scheduler, self_record: *ProcessRecord, target_pid: Pid) signal_module.Ref {
        const sr = scheduler.signalRuntimePtr() orelse return 0;
        const ref = sr.mintRef();
        const self_bits = self_record.pcb.pid.toBits();
        const target_pcb = scheduler.pid_table.lookupSilent(target_pid) orelse {
            scheduler.fireNoprocDown(self_record, ref, target_pid);
            return ref;
        };
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) {
            scheduler.fireNoprocDown(self_record, ref, target_pid);
            return ref;
        }
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(target_pid)) {
            scheduler.fireNoprocDown(self_record, ref, target_pid);
            return ref;
        }
        target_pcb.signal_state.addMonitoredBy(&sr.node_pool, ref, self_bits) catch return ref;
        self_record.pcb.signal_state.addMonitor(&sr.node_pool, ref, target_pid.toBits()) catch {
            _ = target_pcb.signal_state.removeMonitoredByRef(&sr.node_pool, ref);
            return ref;
        };
        return ref;
    }

    /// Fire a `noproc` `DOWN` to `self_record` immediately (monitoring a dead
    /// process). Delivered to self (always alive), so it goes straight into the
    /// caller's own mailbox.
    fn fireNoprocDown(scheduler: *Scheduler, self_record: *ProcessRecord, ref: signal_module.Ref, dead_pid: Pid) void {
        scheduler.pushSignalMessage(self_record, &self_record.pcb, .down, .{
            .from_bits = dead_pid.toBits(),
            .ref = ref,
            .reason_term = scheduler.reasonNoproc(),
        });
    }

    /// `demonitor(ref)`: drop a monitor this process holds. Removes it from the
    /// caller's outgoing set and from the target's `monitored_by`. Returns
    /// whether the ref was a live outgoing monitor. A pending `DOWN` already in
    /// the mailbox is NOT flushed (plain `demonitor`, not `demonitor(_, flush)`).
    fn signalDemonitor(scheduler: *Scheduler, self_record: *ProcessRecord, ref: signal_module.Ref) bool {
        const sr = scheduler.signalRuntimePtr() orelse return false;
        const target_bits = self_record.pcb.signal_state.takeMonitorRef(&sr.node_pool, ref) orelse return false;
        _ = scheduler.cleanRemoteMonitor(Pid.fromBits(target_bits), ref);
        return true;
    }

    /// `demonitor(ref)` + FLUSH — Elixir `Process.demonitor(ref, [:flush])`
    /// semantics, the cleanup the `call`/`Task.await` reply and timeout
    /// paths require (P5-J4): after this returns, NO `DOWN` for `ref` will
    /// ever be observed by the calling process. Three cases, decided by
    /// where the monitored target is in its lifecycle:
    ///
    /// 1. Target pinned ALIVE (`cleanRemoteMonitor` true): its
    ///    `monitored_by` entry is removed before its teardown can run, so
    ///    no `DOWN` was or will be fired. Nothing to flush — O(1), the
    ///    common live-server case (the R8 O(1) budget depends on this: no
    ///    queue scan happens here).
    /// 2. Target dead or tearing down: exactly one `DOWN` for `ref` is
    ///    queued or in flight (its propagation fires every `monitored_by`
    ///    entry exactly once, and ours could not be removed). Await it
    ///    with the correlated receive — `down_only`, so a late user reply
    ///    is never eaten — and discard it. The wait starts at the
    ///    receive-mark when still armed for `ref` (the `DOWN` was pushed
    ///    after the mark, so this stays O(1)-from-mark) and is bounded by
    ///    the target's in-progress teardown, which cannot block on this
    ///    process.
    /// 3. No outgoing entry for `ref` (an immediately-fired `noproc`
    ///    monitor, whose `DOWN` was delivered at monitor() time and never
    ///    had a remote entry): flush a queued `DOWN` non-blockingly (one
    ///    scan; nothing can still be in flight).
    ///
    /// Returns whether `ref` named a live outgoing monitor (mirroring
    /// `signalDemonitor`).
    ///
    /// PRECONDITION (internal machinery, decision 7): the `DOWN` for `ref`
    /// has not already been consumed — the call/await paths use this only
    /// after taking a correlated REPLY or timing out, never after a
    /// `.down_consumed` outcome (which uses the plain `signalDemonitor`).
    fn signalDemonitorFlush(scheduler: *Scheduler, context: *ProcessContext, ref: signal_module.Ref) bool {
        const sr = scheduler.signalRuntimePtr() orelse return false;
        const self_record = context.record;
        const removed_target_bits = self_record.pcb.signal_state.takeMonitorRef(&sr.node_pool, ref);
        if (removed_target_bits) |target_bits| {
            if (scheduler.cleanRemoteMonitor(Pid.fromBits(target_bits), ref)) {
                // Case 1: provably no DOWN anywhere. O(1).
                return true;
            }
            // Case 2: exactly one DOWN queued or in flight — consume it.
            switch (context.receiveCorrelated(ref, .down_only, null)) {
                .matched => |envelope| scheduler.freeSignalEnvelope(envelope),
                .timed_out => unreachable, // no deadline was armed
            }
            return true;
        }
        // Case 3: no outgoing entry — flush a queued noproc DOWN, if any
        // (single non-blocking scan: timeout 0 concedes after one pass).
        switch (context.receiveCorrelated(ref, .down_only, 0)) {
            .matched => |envelope| scheduler.freeSignalEnvelope(envelope),
            .timed_out => {},
        }
        return false;
    }

    /// Free a consumed signal envelope (an exit/`DOWN` popped or extracted
    /// by this process): release its `SignalPayload` block through the
    /// payload seam, then return the header to the pool — exactly
    /// `awaitSignal`'s reclaim, factored for the correlated paths.
    fn freeSignalEnvelope(scheduler: *Scheduler, envelope: *mailbox_module.Envelope) void {
        std.debug.assert(envelope.fragment.signal_kind != .none);
        if (scheduler.signalRuntimePtr()) |sr| {
            if (sr.payload_seam.free) |free_payload| {
                if (envelope.fragment.payload_pointer) |payload| {
                    free_payload(sr.payload_seam.context, payload, envelope.fragment.payload_byte_length);
                }
            }
        }
        envelope.fragment = .{};
        envelope_pool_module.free(envelope);
    }

    /// `exit(target, reason)`: send a trappable exit signal (`kind` selects the
    /// `normal`/`abnormal` category — the Zap surface classifies the atom).
    /// Returns whether the target resolved.
    fn signalExit(
        scheduler: *Scheduler,
        self_record: *ProcessRecord,
        target_pid: Pid,
        category: signal_module.ReasonCategory,
        reason_term: u64,
    ) SendOutcome {
        const status: signal_module.ExitStatus = .{ .category = category, .term = reason_term };
        return scheduler.deliverExitSignalTo(self_record, target_pid, self_record.pcb.pid.toBits(), status, false);
    }

    /// `exit(target, kill)`: the UNTRAPPABLE kill. The target dies with reason
    /// `killed` REGARDLESS of `trap_exit` (research.md §6.7), so its own links
    /// then receive the trappable `killed`, never `kill`. Returns whether the
    /// target resolved.
    fn signalKill(scheduler: *Scheduler, self_record: *ProcessRecord, target_pid: Pid) SendOutcome {
        _ = self_record;
        const target_pcb = scheduler.pid_table.lookupSilent(target_pid) orelse return .dead_lettered;
        const target_record: *ProcessRecord = @fieldParentPtr("pcb", target_pcb);
        if (!target_record.beginSend()) return .dead_lettered;
        defer target_record.endSend();
        if (!scheduler.pid_table.isAlive(target_pid)) return .dead_lettered;
        // Untrappable: override any trappable pending reason to `killed`.
        scheduler.killWithReason(target_record, signal_module.ExitStatus.abnormalStatus(scheduler.killedReasonTerm()), true);
        return .delivered;
    }

    /// Blocking receive of the next SIGNAL message (an exit/`DOWN`) — the raw J1
    /// observation surface a trapping/monitoring process uses to inspect a
    /// signal. Extracts the OLDEST signal envelope from the mailbox — ordinary
    /// user messages are SKIPPED and stay queued, in order, for the
    /// steady-state receive (P5-R1: Erlang's selective receive leaves what a
    /// wait does not match; a supervisor sent a stray user message must not
    /// abort) — caches its fields in `record.last_signal`, frees the payload +
    /// envelope, and returns the reason term.
    fn awaitSignal(scheduler: *Scheduler, context: *ProcessContext) u64 {
        switch (context.receiveCorrelated(0, .signal_any, null)) {
            .matched => |envelope| return scheduler.consumeSignalEnvelope(context, envelope),
            .timed_out => unreachable, // no deadline was armed
        }
    }

    /// `awaitSignal` bounded by a deadline — the timed signal wait a
    /// supervisor's `:timeout` shutdown protocol needs (`lib/supervisor.zap`
    /// `wait_exit`). Returns the consumed signal's reason term (fields cached
    /// exactly like `awaitSignal`), or null when `timeout_nanoseconds`
    /// elapsed with no signal. User messages are skipped and stay queued.
    fn awaitSignalTimeout(scheduler: *Scheduler, context: *ProcessContext, timeout_nanoseconds: u64) ?u64 {
        switch (context.receiveCorrelated(0, .signal_any, timeout_nanoseconds)) {
            .matched => |envelope| return scheduler.consumeSignalEnvelope(context, envelope),
            .timed_out => return null,
        }
    }

    /// Consume one extracted SIGNAL envelope: cache its fields in
    /// `record.last_signal` (the `zap_proc_last_signal_*` read surface), free
    /// the payload + envelope, and return the reason term — the shared tail of
    /// `awaitSignal`/`awaitSignalTimeout`.
    fn consumeSignalEnvelope(
        scheduler: *Scheduler,
        context: *ProcessContext,
        envelope: *mailbox_module.Envelope,
    ) u64 {
        const sr = scheduler.signalRuntimePtr().?;
        std.debug.assert(envelope.fragment.signal_kind != .none);
        const payload: *const signal_module.SignalPayload = @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
        context.record.last_signal = payload.*;
        context.record.last_signal_kind = envelope.fragment.signal_kind;
        const reason_term = payload.reason_term;
        if (sr.payload_seam.free) |free_payload| {
            free_payload(sr.payload_seam.context, envelope.fragment.payload_pointer.?, envelope.fragment.payload_byte_length);
        }
        envelope.fragment = .{};
        envelope_pool_module.free(envelope);
        return reason_term;
    }

    // -------------------------------------------------------------------------
    // Local process registry (P5-J2, `registry.zig`): the registry table is a
    // pure name→pid map; these methods COMPOSE it with the pid table so
    // registration and lookup are generation-validated (a name resolving to a
    // dead/reused pid is a miss, never a stale hit).
    // -------------------------------------------------------------------------

    /// This scheduler's pid-liveness predicate for the registry, wrapping
    /// `PidTable.isAlive` (shared across cores under M:N). A registry entry's pid
    /// is "alive" iff the pid table still holds exactly that slot+generation
    /// occupied — the same §2.4 validation a send does.
    fn registryLivenessIsAlive(context: ?*anyopaque, pid_bits: u64) bool {
        const table: *PidTable = @ptrCast(@alignCast(context.?));
        return table.isAlive(Pid.fromBits(pid_bits));
    }

    fn registryLiveness(scheduler: *Scheduler) registry_module.Liveness {
        return .{ .context = scheduler.pid_table, .is_alive = registryLivenessIsAlive };
    }

    /// `register(name)`: register `self_record` under `name`. Fails (false) when
    /// the process already holds a name (one-name-per-process, Erlang), when the
    /// name is taken by another live process, or when the registry is saturated.
    /// On success the name is recorded in the PCB's `registered_name` so teardown
    /// releases it (the register-then-crash race resolution). A no-op returning
    /// false when this scheduler has no registry wired.
    fn registryRegister(scheduler: *Scheduler, self_record: *ProcessRecord, name: u64) bool {
        const registry = scheduler.options.registry orelse return false;
        // One name per process: refuse a second registration.
        if (self_record.pcb.registered_name != 0) return false;
        const outcome = registry.register(name, self_record.pcb.pid.toBits(), scheduler.registryLiveness()) catch
            return false; // RegistryFull — documented capacity policy
        switch (outcome) {
            .registered => {
                self_record.pcb.registered_name = name;
                return true;
            },
            .name_taken => return false,
        }
    }

    /// `unregister(name)`: release `name` if `self_record` holds it. Returns
    /// whether an entry was removed. Owner-scoped: the registry removal is
    /// guarded by this process's pid bits, so it never clobbers another process's
    /// (re-)registration of the same name.
    fn registryUnregister(scheduler: *Scheduler, self_record: *ProcessRecord, name: u64) bool {
        const registry = scheduler.options.registry orelse return false;
        const removed = registry.unregister(name, self_record.pcb.pid.toBits());
        if (removed and self_record.pcb.registered_name == name) {
            self_record.pcb.registered_name = 0;
        }
        return removed;
    }

    /// `whereis(name) -> pid bits`: resolve `name` to the raw bits of its LIVE
    /// registrant, or `Pid.invalid` bits (`0`) when unregistered or resolving to
    /// a dead pid (generation-validated). Lock-free.
    fn registryWhereis(scheduler: *Scheduler, name: u64) u64 {
        const registry = scheduler.options.registry orelse return Pid.invalid.toBits();
        return registry.whereis(name, scheduler.registryLiveness()) orelse Pid.invalid.toBits();
    }

    /// Release `record`'s registered name at teardown (the register-then-crash
    /// race resolution — research.md §6.7): a registered process that exits or
    /// crashes frees its name so it becomes re-registrable. The removal is
    /// guarded by the process's own pid bits (`exit_pid_bits`), so a name already
    /// re-registered to a successor is left untouched. A no-op when the process
    /// held no name or this scheduler has no registry.
    fn releaseRegisteredName(scheduler: *Scheduler, record: *ProcessRecord, exit_pid_bits: u64) void {
        const registry = scheduler.options.registry orelse return;
        const name = record.pcb.registered_name;
        if (name == 0) return;
        _ = registry.unregister(name, exit_pid_bits);
        record.pcb.registered_name = 0;
    }

    // -------------------------------------------------------------------------
    // Teardown (module doc, "Exit and crash teardown" — the ONE path)
    // -------------------------------------------------------------------------

    fn teardownProcess(scheduler: *Scheduler, record: *ProcessRecord, status: signal_module.ExitStatus) void {
        const pcb = &record.pcb;
        const exit_pid = pcb.pid; // captured: unregister resets it
        // The crash-report label and exit-counter classification (the legacy
        // `ExitReason` enum): a `normal` category is a clean exit, everything
        // else a kill/crash. The reason TERM lives in `status` for propagation.
        const reason: ExitReason = if (status.category == .normal) .normal else .killed;

        // (0) Cancel any live `receive … after` timer and END its park episode
        // (bump the epoch) BEFORE the record can recycle. This is mandatory for
        // correctness: without the epoch bump a stale wheel entry (epoch e)
        // could later fire against this record reused for a new process that
        // reaches episode e again — the recycle-aliasing hazard. Same-core
        // (owning-wheel) entries are cancelled eagerly; a cross-core entry is
        // reaped lazily by its owning wheel, whose fire callback now sees the
        // bumped epoch and discards it.
        scheduler.cancelProcessTimer(record);

        // (1) Crash report FIRST (plan 1.6, `crash_report.zig`): the
        // report snapshots the pid, state, mailbox depth, and — for a
        // suspended fiber — the stack trace from the last suspend point,
        // all of which the steps below destroy.
        if (scheduler.options.crash_report_hook) |report_hook| {
            const report = crash_report_module.captureForTeardown(pcb, reason);
            report_hook(scheduler.options.crash_report_context, &report);
        }

        pcb.transitionTo(.exiting);

        // (1b) Release this process's registered name (P5-J2): a registered
        // process that exits/crashes frees its name so it becomes re-registrable
        // — the register-then-crash race resolution (research.md §6.7). Done
        // BEFORE the pid is released (2), so the name never lingers pointing at a
        // reused slot; the removal is pid-guarded, so a name a successor already
        // re-registered is left intact.
        scheduler.releaseRegisteredName(record, exit_pid.toBits());

        // (2) Pid first: every outstanding copy dead-letters from here on.
        pcb.unregister(scheduler.pid_table);

        // (3) Flush the wake stack so no consumed entry can reference
        // this record after it recycles (drain treats `.exiting` as a
        // no-op; other processes' pending wakes are simply processed a
        // little earlier than the loop top would have).
        scheduler.drainWakeStack();

        // (4) Drop-list destructors, LIFO (newest-first).
        while (pcb.drop_list_head) |node| {
            pcb.drop_list_head = node.next;
            node.destructor(node);
        }

        // (4b) Drain the blob ledger (P6-J2): release every `Zap.Blob`
        // reference this process still owns — atomic decrements into the
        // shared blob domain, safe from any thread by design (the one
        // sanctioned atomic tier). This is what makes "sender dies,
        // receiver's blob survives; last holder dies, blob freed" hold:
        // a crashed process merely drops its references, never another
        // heap's memory. Blob payloads live in the blob domain, not this
        // process's manager heap, so ordering against the manager
        // teardown below is immaterial; the ledger's storage itself is
        // freed here.
        pcb.blob_ledger.releaseAllOwned(scheduler.options.blob_domain);

        // (5) Close the mailbox to cross-core senders and wait out every send
        // that passed lookup before the unregister above (the P4 PCB-lifetime
        // grace period — `pid_table.zig` "Deferred to Phase 4"). unregister (2)
        // stopped NEW lookups; this stops in-flight senders, so the drain below
        // reclaims every envelope any of them pushes. Without it a push landing
        // after the drain orphans its envelope — and the sender's abandoned
        // page — the message-vs-timer envelope-page leak.
        record.closeAndQuiesce();

        // (5b) Propagate exit signals to links and fire `DOWN` to monitors
        // (P5-J1, `signal.zig`). Placed AFTER `closeAndQuiesce`: that gate
        // (send_closed + in-flight-send drain) waits out every `link`/`monitor`/
        // exit-signal that pinned this process before the close, so their
        // set-mutations have landed and this snapshot sees them; a `link`/
        // `monitor` that pins AFTER the close is rejected (dead-letters, fires
        // `noproc`), so no entry is ever missed or double-fired — the same
        // grace-period discipline that makes cross-core sends race-free (P4-R1).
        // Placed BEFORE `abandon` (7): signal messages are pushed from THIS
        // process's still-live envelope handle to the peers' mailboxes.
        scheduler.propagateExitSignals(record, exit_pid, status);

        // (5c) Free a correlated reply stashed between the two calls of the
        // await protocol (P5-J4, `pending_correlated_envelope`): the process
        // died after `awaitCorrelated` extracted the reply but before the
        // typed decode took it. Same reclaim discipline as the drain below —
        // the envelope was already popped from the mailbox, so the drain
        // cannot see it.
        if (record.pending_correlated_envelope) |stashed| {
            record.pending_correlated_envelope = null;
            scheduler.reclaimUndeliveredEnvelope(stashed);
        }

        // (6) Drain the mailbox: every envelope back to its origin page.
        scheduler.drainMailboxForTeardown(&pcb.mailbox);

        // (7) Abandon the sender side: empty pages return now; in-flight
        // pages flip to `.abandoned` for their receivers to reclaim.
        record.envelope_handle.abandon();

        // (8) Stack via the invariant path.
        switch (pcb.fiber.lifecycle_state) {
            // Normal exit: resumeFiber's post-switch path already
            // released the stack.
            .reclaimed => {},
            // Kill of a never-run or suspended process.
            .ready, .suspended => fiber_context.reclaimWithoutResume(&pcb.fiber),
            // `.running` cannot reach teardown (the quantum has returned)
            // and `.finished` always becomes `.reclaimed` inside
            // resumeFiber before it returns.
            .running, .finished => unreachable,
        }

        // (9) Wholesale heap free (plan Phase 1 item 1.4: bulk arena/slab
        // free on exit — module doc, "Exit and crash teardown").
        pcb.manager.teardown();

        scheduler.emitTrace(switch (reason) {
            .normal => .exit,
            .killed => .kill,
        }, exit_pid);
        switch (reason) {
            .normal => scheduler.normal_exit_total += 1,
            .killed => scheduler.kill_total += 1,
        }
        // Live count: pool-authoritative under M:N, per-scheduler standalone
        // (see `spawn`). The record recycles to THIS (tearing-down) core's own
        // cache — always the local thread, race-free — and is freed once at
        // `deinit` through the shared allocator.
        if (scheduler.pool_hooks) |hooks| {
            hooks.liveCountDelta(hooks.context, -1);
        } else {
            std.debug.assert(scheduler.live_record_count > 0);
            scheduler.live_record_count -= 1;
        }
        scheduler.recycleRecord(record);
        // Notify the pool of the completed exit LAST (after the record is safe
        // to reuse): the pool checks whether this was the root process and, if
        // so, signals every core to stop.
        if (scheduler.pool_hooks) |hooks| {
            hooks.onProcessExit(hooks.context, exit_pid.toBits());
        }
    }

    /// Bound on consecutive transient-gap observations while draining a
    /// mailbox at teardown. A gap window is two producer instructions
    /// (`mailbox.zig`), so any bound this large only trips when a FOREIGN
    /// thread's send races teardown — out of the Phase 1 contract (module
    /// doc) and a kernel bug to surface loudly, never to leak past.
    const teardown_drain_gap_spin_limit: u32 = 100_000;

    /// Reclaim one envelope this process owned but never delivered to Zap
    /// code — the teardown-drain discipline, factored so the correlated-
    /// reply stash (P5-J4) reclaims identically. Leak-exactness for an
    /// undelivered MOVED payload: the graph was detached from a sender but
    /// this receiver dies before adopting it, so reclaim it (munmap) before
    /// the header goes back to the pool. Leak-exactness for an undelivered
    /// SIGNAL payload (P5-J1): free its payload block through the seam (the
    /// same free the receiver's `envelope_free` would have run). A copied
    /// payload's ledger block is reclaimed at runtime-ledger teardown, as
    /// before.
    fn reclaimUndeliveredEnvelope(scheduler: *Scheduler, envelope: *mailbox_module.Envelope) void {
        if (envelope.fragment.moved_reclaim) |reclaim| {
            if (envelope.fragment.payload_pointer) |payload| reclaim(payload);
            envelope.fragment = .{};
        } else if (envelope.fragment.signal_kind != .none) {
            if (scheduler.signalRuntimePtr()) |sr| {
                if (sr.payload_seam.free) |free_payload| {
                    if (envelope.fragment.payload_pointer) |payload| {
                        free_payload(sr.payload_seam.context, payload, envelope.fragment.payload_byte_length);
                    }
                }
            }
            envelope.fragment = .{};
        }
        envelope_pool_module.free(envelope);
    }

    fn drainMailboxForTeardown(scheduler: *Scheduler, mailbox: *mailbox_module.Mailbox) void {
        var consecutive_gap_spins: u32 = 0;
        while (true) {
            switch (mailbox.pop()) {
                .envelope => |envelope| {
                    scheduler.reclaimUndeliveredEnvelope(envelope);
                    consecutive_gap_spins = 0;
                },
                .empty => return,
                .transient_gap => {
                    consecutive_gap_spins += 1;
                    if (consecutive_gap_spins >= teardown_drain_gap_spin_limit) {
                        @panic("teardown mailbox drain stuck in a transient gap " ++
                            "(a foreign send racing teardown violates the Phase 1 contract) — kernel bug");
                    }
                    std.atomic.spinLoopHint();
                },
            }
        }
    }

    // -------------------------------------------------------------------------
    // Ready queue (intrusive FIFO; Phase 4 upgrade path in the module doc)
    // -------------------------------------------------------------------------

    /// Acquire the run-queue spinlock when `work_stealing` (a no-op for a
    /// standalone scheduler — the FIFO is then owner-only, byte-identical to
    /// Phase 1). `std.atomic.Mutex` + `spinLoopHint`, kernel convention.
    inline fn lockRunQueue(scheduler: *Scheduler) void {
        if (scheduler.work_stealing) {
            while (!scheduler.run_queue_lock.tryLock()) std.atomic.spinLoopHint();
        }
    }

    inline fn unlockRunQueue(scheduler: *Scheduler) void {
        if (scheduler.work_stealing) scheduler.run_queue_lock.unlock();
    }

    /// Admit a runnable process to the FIFO tail (spawn admission, voluntary
    /// yield re-enqueue, timeout fire, and the non-locality wake path). Takes
    /// the run-queue lock under `work_stealing` so a thief sees a consistent
    /// queue; owner-only and lock-free otherwise.
    fn readyEnqueue(scheduler: *Scheduler, record: *ProcessRecord) void {
        scheduler.lockRunQueue();
        scheduler.readyEnqueueLocked(record);
        // Spill surplus to the global overflow queue while holding the lock, so
        // an idle core can grab it in O(1) rather than hunting for a victim
        // (research.md §6.1). The spilled records leave this core's FIFO, so its
        // `ready_count` is decremented consistently under the same lock.
        scheduler.spillOverflowLocked();
        scheduler.unlockRunQueue();
        // A runnable process is now stealable from this core's FIFO (or the
        // global queue) — wake one idle worker so a parked core comes back to
        // run it (netpoller wakeup). Outside the run-queue lock (it futex-wakes).
        // No-op for a standalone scheduler. `stealInto`/`reviveEnqueue`
        // deliberately use `readyEnqueueLocked`, so a steal-splice or a LIFO-slot
        // displacement does not itself fan out another wake.
        if (scheduler.pool_hooks) |hooks| hooks.notifyWork(hooks.context);
    }

    /// Move half of an over-long local FIFO to the global overflow queue, with
    /// the run-queue lock already held. Oldest-first (the freshest work stays
    /// local for cache locality). No-op unless both a `global_queue` and a
    /// non-zero `spill_threshold` are configured and the backlog exceeds it.
    fn spillOverflowLocked(scheduler: *Scheduler) void {
        const global = scheduler.global_queue orelse return;
        const threshold = scheduler.options.spill_threshold;
        if (threshold == 0 or scheduler.ready_count <= threshold) return;
        const spill = scheduler.ready_count / 2;
        var chain_head: ?*ProcessRecord = null;
        var chain_tail: ?*ProcessRecord = null;
        var moved: usize = 0;
        while (moved < spill) : (moved += 1) {
            const record = scheduler.dequeueReadyAtLocked(0) orelse break;
            record.ready_next = null;
            if (chain_tail) |tail| {
                tail.ready_next = record;
            } else {
                chain_head = record;
            }
            chain_tail = record;
        }
        if (moved == 0) return;
        global.acquire();
        global.pushChainLocked(chain_head.?, chain_tail.?, moved);
        global.lock.unlock();
    }

    /// FIFO-tail append with the run-queue lock already held (or not needed).
    fn readyEnqueueLocked(scheduler: *Scheduler, record: *ProcessRecord) void {
        record.ready_next = null;
        if (scheduler.ready_tail) |tail| {
            tail.ready_next = record;
        } else {
            scheduler.ready_head = record;
        }
        scheduler.ready_tail = record;
        scheduler.ready_count += 1;
    }

    /// Enqueue a JUST-WOKEN process for the wake-locality path (P4-J1). Under
    /// `work_stealing` the record lands in the owner-only LIFO slot `runnext`
    /// so the waking core runs it next (the ping-pong partner runs immediately,
    /// research.md §6.1); any prior occupant is bumped to the FIFO tail so no
    /// wake is ever dropped. Without work stealing this is a plain FIFO append,
    /// preserving the Phase-1 wake ordering (and the deterministic trace).
    /// OWNER-THREAD ONLY — called from `drainWakeStack` and the park re-check,
    /// both on this scheduler's own thread; thieves never touch `runnext`.
    fn reviveEnqueue(scheduler: *Scheduler, record: *ProcessRecord) void {
        if (!scheduler.work_stealing) {
            scheduler.readyEnqueue(record);
            return;
        }
        record.ready_next = null;
        const displaced = scheduler.runnext;
        scheduler.runnext = record;
        if (displaced) |previous| scheduler.readyEnqueue(previous);
    }

    /// Pick the next runnable process: the LIFO slot first (wake locality),
    /// then the FIFO through the Decisions seam — EXCEPT on the periodic
    /// fairness tick, which bypasses the LIFO slot (P4-R2 finding #3). Under
    /// work stealing a hot mutual-wake pair refills `runnext` every quantum, so
    /// serving `runnext` unconditionally would starve any process stranded in
    /// the global queue or the local FIFO (stealing rescues them only while an
    /// idle core exists — with every core hot, none does). So every
    /// `runnext_fairness_interval`-th pick BYPASSES `runnext` and serves the
    /// global overflow queue then the local FIFO first, guaranteeing bounded
    /// progress for stranded work while preserving the LIFO-locality fast path
    /// on the other 60 of every 61 picks (Go's `schedtick % 61`). A stranded
    /// record found on the fairness tick is returned WITHOUT consuming
    /// `runnext`, so the just-woken partner still runs next. Owner-thread only.
    fn dequeueNextRunnable(scheduler: *Scheduler) ?*ProcessRecord {
        if (scheduler.work_stealing) {
            scheduler.schedule_tick +%= 1;
            if (scheduler.schedule_tick % runnext_fairness_interval == 0) {
                // Fairness tick: serve the global queue, then the local FIFO,
                // BYPASSING `runnext`. `runnext` is left intact when a stranded
                // record is found, so the wake-locality partner runs the very
                // next pick — the poll costs the pair one quantum every 61.
                if (scheduler.global_queue) |global| {
                    if (global.pop()) |record| return record;
                }
                if (scheduler.dequeueLocalFifo()) |record| return record;
            }
            if (scheduler.runnext) |record| {
                scheduler.runnext = null;
                return record;
            }
        }
        return scheduler.dequeueLocalFifo();
    }

    /// Pick from the local FIFO through the Decisions seam, taking the
    /// run-queue lock. Null when the FIFO is empty. The common (non-fairness)
    /// pick and the periodic fairness bypass share this one body so both honor
    /// the Decisions policy identically. Owner-thread only.
    fn dequeueLocalFifo(scheduler: *Scheduler) ?*ProcessRecord {
        scheduler.lockRunQueue();
        defer scheduler.unlockRunQueue();
        if (scheduler.ready_count == 0) return null;
        const chosen_index = scheduler.options.decisions.vtable.chooseNextReadyIndex(
            scheduler.options.decisions.decision_context,
            scheduler.ready_count,
        );
        std.debug.assert(chosen_index < scheduler.ready_count);
        return scheduler.dequeueReadyAtLocked(chosen_index);
    }

    /// Unlink and return the `index`-th queued record (0 = oldest), taking the
    /// run-queue lock. Used by `shutdownAllProcesses` (fixed index 0).
    fn dequeueReadyAt(scheduler: *Scheduler, index: usize) ?*ProcessRecord {
        scheduler.lockRunQueue();
        defer scheduler.unlockRunQueue();
        return scheduler.dequeueReadyAtLocked(index);
    }

    /// Unlink and return the `index`-th queued record (0 = oldest), or null
    /// when the queue is empty, with the run-queue lock already held (or not
    /// needed). O(index) — production FIFO always asks for 0.
    fn dequeueReadyAtLocked(scheduler: *Scheduler, index: usize) ?*ProcessRecord {
        var previous: ?*ProcessRecord = null;
        var current = scheduler.ready_head orelse return null;
        var remaining = index;
        while (remaining > 0) : (remaining -= 1) {
            previous = current;
            current = current.ready_next.?;
        }
        if (previous) |previous_record| {
            previous_record.ready_next = current.ready_next;
        } else {
            scheduler.ready_head = current.ready_next;
        }
        if (scheduler.ready_tail == current) {
            scheduler.ready_tail = previous;
        }
        current.ready_next = null;
        scheduler.ready_count -= 1;
        return current;
    }

    /// Work-stealing (P4-J1, research.md §6.1): a thief scheduler with an empty
    /// run queue splices up to half of THIS (victim) scheduler's FIFO onto the
    /// end of the thief's own FIFO, and returns the count moved. Steals from the
    /// OLD end (head) so the victim keeps its freshest (tail/`runnext`) work —
    /// the standard deque discipline — and never touches the victim's `runnext`,
    /// so a just-woken ping-pong partner is never stolen from under its waking
    /// core. The two `run_queue_lock`s are NEVER held at the same time: the
    /// victim lock is taken and RELEASED to detach a chain, and only then is the
    /// thief lock taken to splice it. Because no thief ever holds both locks,
    /// there is no lock-ordering hazard — two schedulers stealing from each other
    /// concurrently (A↔B) cannot deadlock regardless of the pool's scan order
    /// (`SchedulerPool.tryStealFor`). Returns 0 when the victim has nothing
    /// stealable. Runs on the THIEF's thread.
    pub fn stealInto(victim: *Scheduler, thief: *Scheduler) usize {
        std.debug.assert(victim.work_stealing and thief.work_stealing);
        std.debug.assert(victim != thief);
        // Snapshot half the victim's FIFO under the victim lock into a local
        // detached chain, releasing the victim lock BEFORE touching the thief
        // queue: the two run-queue locks are never held nested, so no A-steals-B
        // / B-steals-A pair can deadlock, whatever order the pool scans victims.
        victim.lockRunQueue();
        const available = victim.ready_count;
        if (available == 0) {
            victim.unlockRunQueue();
            return 0;
        }
        const take = (available + 1) / 2; // ceil(half): a lone runnable is stolen
        var chain_head: ?*ProcessRecord = null;
        var chain_tail: ?*ProcessRecord = null;
        var moved: usize = 0;
        while (moved < take) : (moved += 1) {
            const record = victim.dequeueReadyAtLocked(0) orelse break;
            record.ready_next = null;
            if (chain_tail) |tail| {
                tail.ready_next = record;
            } else {
                chain_head = record;
            }
            chain_tail = record;
        }
        victim.unlockRunQueue();
        if (moved == 0) return 0;
        // Splice the detached chain onto the thief's FIFO tail under the thief
        // lock. The stolen records carry no scheduler-local state that the
        // victim still touches (they are `.runnable`, off the victim queue), so
        // the thief may now run them — the run-queue atomics supply the
        // happens-before that lets the thief's quantum follow the victim's.
        thief.lockRunQueue();
        var cursor = chain_head;
        while (cursor) |record| {
            cursor = record.ready_next;
            record.ready_next = null;
            thief.readyEnqueueLocked(record);
        }
        thief.unlockRunQueue();
        return moved;
    }

    // -------------------------------------------------------------------------
    // Wake stack (cross-thread producers, scheduler consumer)
    // -------------------------------------------------------------------------

    /// Consume every pending wake signal: pop-all (swap — no ABA), restore push
    /// order, and admit each revived process to run. Each record on this stack
    /// was pushed by the UNIQUE `.parked → .running` handshake winner
    /// (`mailboxWakeCallback` / the park re-check via `pushWake`), so it is a
    /// process this core owns the revival of; the drain makes it runnable and
    /// enqueues it (the LIFO slot under `work_stealing`, for wake locality).
    /// Runs on this scheduler's own thread.
    fn drainWakeStack(scheduler: *Scheduler) void {
        var popped: ?*ProcessRecord = scheduler.wake_stack_head.swap(null, .acquire) orelse return;
        // The Treiber stack yields newest-first; reverse to process wake
        // signals in arrival order (fairness + deterministic replay).
        var oldest_first: ?*ProcessRecord = null;
        while (popped) |record| {
            popped = record.wake_next;
            record.wake_next = oldest_first;
            oldest_first = record;
        }
        while (oldest_first) |record| {
            oldest_first = record.wake_next;
            record.wake_next = null;
            const pcb = &record.pcb;
            // The unique wake-seam winner swapped `.notified` in over `.parked`
            // before pushing this record, so this core is its sole reviver. END
            // the park episode: bump the epoch (invalidating any stale
            // `receive … after` timer for it — in this or another core's wheel)
            // and reset the state to `.running` for the process's next life.
            const ended_epoch = parkControlEpoch(record.park_control.load(.seq_cst));
            record.park_control.store(packParkControl(ended_epoch + 1, .running), .seq_cst);
            // A `receive … after` waiter whose timer lives in THIS core's wheel
            // (a same-core message wake) gets its entry cancelled eagerly — O(1),
            // same thread. A cross-core wake leaves the entry for the owning
            // wheel to reap lazily (its epoch now mismatches, so the fire
            // callback discards it). `ended_epoch` proves the entry is the
            // current episode's live node before it is touched.
            if (record.yield_reason == .waiting_for_message_deadline) {
                scheduler.tryEagerCancelReceiveTimer(record, ended_epoch);
            }
            if (pcb.currentState() == .waiting) {
                pcb.transitionTo(.runnable);
                scheduler.reviveEnqueue(record);
                scheduler.emitTrace(.wake, pcb.pid);
            }
        }
    }

    /// If `record`'s live `receive … after` timer lives in THIS scheduler's
    /// wheel and still belongs to episode `episode_epoch`, cancel it in O(1).
    /// Same-core only: a cross-core caller (`timer_wheel_owner != scheduler`)
    /// returns without touching the entry, leaving it for the owning wheel to
    /// reap lazily. The `timer_epoch` check proves the entry is the current
    /// episode's live node so a freed node is never dereferenced. Scheduler-thread
    /// only.
    fn tryEagerCancelReceiveTimer(scheduler: *Scheduler, record: *ProcessRecord, episode_epoch: u64) void {
        if (record.timer_wheel_owner != scheduler) return;
        if (record.timer_epoch != episode_epoch) return;
        if (record.timer_entry) |entry| {
            scheduler.receive_timer_wheel.cancel(entry);
            record.timer_entry = null;
        }
    }

    /// Cancel any live `receive … after` timer for a process being torn down and
    /// END its park episode (bump the epoch). The epoch bump is what prevents a
    /// stale wheel entry from ever firing against a recycled record's later
    /// episode (the epoch is monotonic for a record's whole life). A same-core
    /// entry is cancelled in O(1); a cross-core entry is left for its owning
    /// wheel to reap lazily (its fire callback now sees the bumped epoch and
    /// discards it). Scheduler-thread only.
    fn cancelProcessTimer(scheduler: *Scheduler, record: *ProcessRecord) void {
        const control = record.park_control.load(.seq_cst);
        const epoch = parkControlEpoch(control);
        // Only a `.waiting_for_message_deadline` waiter can hold a live entry;
        // for any other teardown the timer (if it ever existed) already ended.
        if (record.yield_reason == .waiting_for_message_deadline) {
            scheduler.tryEagerCancelReceiveTimer(record, epoch);
        }
        record.park_control.store(packParkControl(epoch + 1, .running), .seq_cst);
    }

    /// Push a revived record onto `target`'s wake stack (lock-free Treiber) and
    /// wake `target` — the cross-thread enqueue channel for a process the caller
    /// won the revival of. Only the unique handshake winner calls this (per park
    /// episode), so a record is on at most one wake stack at a time. `target` is
    /// the producer's own core when the producer is a scheduler thread (wake
    /// locality) or the process's last-running scheduler for a foreign producer.
    fn pushWake(target: *Scheduler, record: *ProcessRecord) void {
        var observed_head = target.wake_stack_head.load(.monotonic);
        while (true) {
            record.wake_next = observed_head;
            observed_head = target.wake_stack_head.cmpxchgWeak(
                observed_head,
                record,
                .release,
                .monotonic,
            ) orelse break;
        }
        target.wake();
    }

    /// The mailbox wake seam (installed per process at spawn): runs on the
    /// PRODUCER's thread after an empty→nonempty push (`mailbox.zig`). The
    /// cross-thread wake handshake (P4-J1): a `seq_cst` fence orders the
    /// producer's message push BEFORE the state observation, then a single
    /// `cmpxchg(.parked → .running)` decides whether THIS producer revives the
    /// target. Only the winner enqueues it — no lost wake, no double enqueue,
    /// across any number of concurrent producers and the suspending scheduler.
    /// A wake to a `.running`/`.runnable` process fails the CAS and is a no-op
    /// (the message is already visible to the target's next receive).
    fn mailboxWakeCallback(wake_context: ?*anyopaque) void {
        const record: *ProcessRecord = @ptrCast(@alignCast(wake_context.?));
        reviveIfParked(record);
    }

    /// The cross-thread wake handshake core (P4-J1), shared by the mailbox wake
    /// seam and the exit-signal kill path (P5-J1). Mark `record` notified (a
    /// single seq_cst RMW — the whole handshake linearizes here) and, iff this
    /// displaced `.parked` (the process was genuinely suspended), own its
    /// revival and push it to a core's wake stack. Displacing `.running`/
    /// `.notified` means the process is active — it observes the message (or the
    /// pending kill) via its own receive/safepoint, or self-revives at
    /// `commitPark` (whose `.running → .parked` CAS now fails against the
    /// `.notified` we set) — so no push. The whatever-woke-it write (a mailbox
    /// push, or a `pending_kill` store) is sequenced-before this RMW, so the
    /// revived process sees it. The seq_cst CAS loop preserves the epoch bits
    /// (owned by the process; the waker must not disturb them — `packParkControl`),
    /// and retries essentially never (only the owner's cold paths change epoch).
    fn reviveIfParked(record: *ProcessRecord) void {
        var control = record.park_control.load(.seq_cst);
        const displaced = while (true) {
            const state = parkControlState(control);
            if (state == .notified) return; // already notified — nothing to own
            const desired = packParkControl(parkControlEpoch(control), .notified);
            if (record.park_control.cmpxchgWeak(control, desired, .seq_cst, .seq_cst)) |actual| {
                control = actual;
                continue;
            }
            break state;
        };
        if (displaced != .parked) return; // displaced `.running` — process is active
        // We own the revival. Route onto the waker's core for wake locality;
        // a foreign waker falls back to the target's last-running scheduler.
        const target = current_scheduler orelse record.scheduler;
        pushWake(target, record);
    }

    // -------------------------------------------------------------------------
    // Idle parking (module doc, "Idle parking")
    // -------------------------------------------------------------------------

    /// Whether a cross-thread producer has left this core work to revive — a
    /// pending message wake (`wake_stack_head`) or a pending blocking-pool
    /// re-attach (`reattach_stack_head`). The pre-park re-check reads both so no
    /// wake source is slept through; the `wake()` epoch bump each producer pairs
    /// with its push closes the race with an already-committed park.
    inline fn hasPendingCrossThreadWork(scheduler: *Scheduler) bool {
        return scheduler.wake_stack_head.load(.acquire) != null or
            scheduler.reattach_stack_head.load(.acquire) != null;
    }

    fn parkUntilWakeSignal(scheduler: *Scheduler) void {
        // Spin phase: E9 crossover — a handoff lands in ~83 ns while a
        // parked wake costs ~900 ns, so spend up to ~1–2 µs spinning
        // before paying a park.
        var spin_iteration: u32 = 0;
        while (spin_iteration < scheduler.options.spin_iterations_before_park) : (spin_iteration += 1) {
            if (scheduler.hasPendingCrossThreadWork()) return;
            std.atomic.spinLoopHint();
        }

        // Eventcount park: the futex value check closes the race between
        // the work re-check and the wait entry (module doc). A blocking-pool
        // re-attach (`reattach_stack_head`) is a wake source too — checked here
        // AND paired with the `wake()` epoch bump `pushReattach` issues, so a
        // re-attach that races this park is never slept through.
        const observed_epoch = scheduler.wake_epoch.load(.seq_cst);
        if (scheduler.hasPendingCrossThreadWork()) return;
        scheduler.parked_hint.store(true, .seq_cst);
        _ = scheduler.park_count.fetchAdd(1, .monotonic);
        parking_futex.waitBounded(
            &scheduler.wake_epoch,
            observed_epoch,
            scheduler.idleParkTimeoutNanoseconds(),
        );
        scheduler.parked_hint.store(false, .seq_cst);
    }

    /// The bound for one idle futex park: the default defense-in-depth
    /// re-check period, shortened to the time remaining until the earliest
    /// timing-wheel deadline so that timeout fires on schedule (the wake then
    /// re-runs the loop, whose `advanceReceiveTimers` makes the expired waiter
    /// runnable). No armed timers ⇒ the default bound.
    fn idleParkTimeoutNanoseconds(scheduler: *Scheduler) u64 {
        const default_bound = scheduler.options.park_timeout_nanoseconds;
        const deadline = scheduler.receive_timer_wheel.earliestDeadlineNanoseconds() orelse return default_bound;
        const now = monotonicNowNanoseconds();
        if (now >= deadline) return 1; // already due — wake promptly to fire it
        return @min(default_bound, deadline - now);
    }

    // -------------------------------------------------------------------------
    // Record cache
    // -------------------------------------------------------------------------

    fn acquireRecord(scheduler: *Scheduler) error{OutOfMemory}!*ProcessRecord {
        if (scheduler.free_records) |record| {
            scheduler.free_records = record.ready_next;
            scheduler.cached_record_count -= 1;
            return record;
        }
        const record = try scheduler.backing_allocator.create(ProcessRecord);
        // A brand-new record starts at park epoch 0 and an empty send grace
        // count (recycled records retain both — the monotonic epoch and the
        // provably-zero in-flight count — see `spawn`); `spawn` sets every other
        // field and re-opens `send_closed`.
        record.park_control = .init(packParkControl(0, .running));
        record.in_flight_send_count = .init(0);
        record.send_closed = .init(false);
        record.pending_kill = .init(false);
        return record;
    }

    fn recycleRecord(scheduler: *Scheduler, record: *ProcessRecord) void {
        record.ready_next = scheduler.free_records;
        scheduler.free_records = record;
        scheduler.cached_record_count += 1;
    }

    // -------------------------------------------------------------------------
    // Trace seam
    // -------------------------------------------------------------------------

    inline fn emitTrace(scheduler: *Scheduler, kind: TraceEvent.Kind, pid: Pid) void {
        if (scheduler.options.trace_hook) |hook| {
            hook(scheduler.options.trace_context, .{ .kind = kind, .pid_bits = pid.toBits() });
        }
    }
};

/// First function on every process fiber: builds the `ProcessContext`
/// capability on the fiber stack and runs the process body. Returning
/// finishes the fiber (normal exit). Publishing the context through
/// `record.active_context` is what makes the ambient-lookup seam
/// (`Scheduler.currentProcessContext`) work: the frame lives for the
/// process's entire lifetime, so the pointer stays valid across every
/// suspend/resume until teardown reclaims the stack.
fn processFiberEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    const record: *ProcessRecord = @ptrCast(@alignCast(argument.?));
    var context = ProcessContext{
        .scheduler = record.scheduler,
        .record = record,
        .execution = execution,
    };
    record.active_context = &context;
    record.entry_function(&context, record.entry_argument);
}

// ---------------------------------------------------------------------------
// Futex parking primitives (module doc, "Darwin futex mapping")
// ---------------------------------------------------------------------------

/// OS futex wait/wake over a 32-bit eventcount word. Extracted (P4-J3) to the
/// shared leaf module `futex.zig` so the M:N core schedulers (idle parking,
/// here) and the blocking / dirty-scheduler pool (`blocking_pool.zig`, worker
/// parking) share ONE OS-portable surface. Waits are always time-bounded and
/// may return spuriously — callers re-check their condition in a loop (the
/// scheduler's run loop does).
const parking_futex = @import("futex.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The shared Phase 1 test-manager shape (`test_support.zig`).
const TestProcessManager = @import("test_support.zig").CountingArenaManager;

/// One scheduler + shared structures, wired for a test.
const TestKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,

    fn init(kernel: *TestKernel, scheduler_options: Scheduler.Options) !void {
        kernel.pid_table = try PidTable.init(testing.allocator, .{ .capacity = 64 });
        kernel.envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
        kernel.scheduler = Scheduler.init(
            testing.allocator,
            &kernel.pid_table,
            &kernel.envelope_pool,
            scheduler_options,
        );
    }

    fn deinit(kernel: *TestKernel) void {
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }

    /// Assert the exact-accounting quiescent state: nothing live in the
    /// pid table, the envelope pool, or the stack pool.
    fn expectExactAccounting(kernel: *TestKernel) !void {
        try testing.expectEqual(@as(u32, 0), kernel.pid_table.statistics().live_process_count);
        const envelope_stats = kernel.envelope_pool.statistics();
        try testing.expectEqual(@as(u32, 0), envelope_stats.live_page_count);
        try testing.expectEqual(@as(u32, 0), envelope_stats.abandoned_page_count);
        const stack_stats = kernel.scheduler.stackPoolStatistics();
        try testing.expectEqual(@as(u32, 0), stack_stats.live_stack_count);
        try testing.expectEqual(@as(u32, 0), kernel.scheduler.statistics().live_process_count);
    }
};

const test_scheduler_options = Scheduler.Options{
    .stack_usable_size = 64 * 1024,
    .preemption_budget = 128,
};

// -- trace capture -------------------------------------------------------------

const TestTraceLog = struct {
    events: [256]TraceEvent = undefined,
    count: usize = 0,

    fn hook(trace_context: ?*anyopaque, event: TraceEvent) void {
        const log: *TestTraceLog = @ptrCast(@alignCast(trace_context.?));
        if (log.count == log.events.len) @panic("TestTraceLog overflow");
        log.events[log.count] = event;
        log.count += 1;
    }

    fn recorded(log: *const TestTraceLog) []const TraceEvent {
        return log.events[0..log.count];
    }

    fn countKind(log: *const TestTraceLog, kind: TraceEvent.Kind) usize {
        var total: usize = 0;
        for (log.recorded()) |event| {
            if (event.kind == kind) total += 1;
        }
        return total;
    }
};

// -- spawn → run → exit lifecycle -----------------------------------------------

const LifecycleProbe = struct {
    observed_self_pid_bits: u64 = 0,
    entered: bool = false,
};

fn lifecycleEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *LifecycleProbe = @ptrCast(@alignCast(argument.?));
    probe.entered = true;
    probe.observed_self_pid_bits = context.selfPid().toBits();
}

test "Scheduler: spawn → run → exit lifecycle with lazy-start admission" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = LifecycleProbe{};
    const pid = try kernel.scheduler.spawn(.{
        .entry = lifecycleEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    // Lazy-start shape: the process is admitted runnable, its stack is
    // reserved (pool acquire), but NO code has run — the fiber is still
    // `.ready` and the entry frame is written only at first schedule.
    const pcb = kernel.pid_table.lookup(pid).?;
    try testing.expectEqual(process_module.ProcessState.runnable, pcb.currentState());
    try testing.expectEqual(fiber_context.LifecycleState.ready, pcb.fiber.lifecycle_state);
    try testing.expect(!probe.entered);
    try testing.expectEqual(@as(u32, 1), kernel.scheduler.stackPoolStatistics().live_stack_count);
    try testing.expectEqual(@as(u32, 1), kernel.scheduler.statistics().live_process_count);

    try kernel.scheduler.runUntilQuiescent();

    try testing.expect(probe.entered);
    try testing.expectEqual(pid.toBits(), probe.observed_self_pid_bits);
    try testing.expectEqual(@as(usize, 1), manager.teardown_count);
    // The pid is dead: any outstanding copy dead-letters.
    try testing.expectEqual(@as(?*ProcessControlBlock, null), kernel.pid_table.lookup(pid));
    try kernel.expectExactAccounting();

    const stats = kernel.scheduler.statistics();
    try testing.expectEqual(@as(u64, 1), stats.spawn_total);
    try testing.expectEqual(@as(u64, 1), stats.normal_exit_total);
    try testing.expectEqual(@as(u64, 0), stats.kill_total);
    try testing.expectEqual(@as(u32, 1), stats.cached_record_count);
}

test "Scheduler: spawn failure on pid-table exhaustion leaves accounting exact" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 1 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
    defer envelope_pool.deinit();
    var scheduler = Scheduler.init(testing.allocator, &pid_table, &envelope_pool, test_scheduler_options);
    defer scheduler.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = LifecycleProbe{};
    _ = try scheduler.spawn(.{
        .entry = lifecycleEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.ProcessTableExhausted, scheduler.spawn(.{
        .entry = lifecycleEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    }));

    // The failed spawn released its stack and recycled its record.
    try testing.expectEqual(@as(u32, 1), scheduler.stackPoolStatistics().live_stack_count);
    try testing.expectEqual(@as(u32, 1), scheduler.statistics().live_process_count);
    try testing.expectEqual(@as(u32, 1), scheduler.statistics().cached_record_count);

    try scheduler.runUntilQuiescent();
    try testing.expectEqual(@as(u32, 0), scheduler.stackPoolStatistics().live_stack_count);
    try testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
}

// -- budget / fairness / watchdog -----------------------------------------------

const WorkLogProbe = struct {
    log: *WorkLog,
    identity: u8,
    total_steps: usize,
};

const WorkLog = struct {
    entries: [128]u8 = undefined,
    count: usize = 0,

    fn append(log: *WorkLog, identity: u8) void {
        if (log.count == log.entries.len) @panic("WorkLog overflow");
        log.entries[log.count] = identity;
        log.count += 1;
    }

    fn recorded(log: *const WorkLog) []const u8 {
        return log.entries[0..log.count];
    }
};

fn workLoggingEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *WorkLogProbe = @ptrCast(@alignCast(argument.?));
    var step: usize = 0;
    while (step < probe.total_steps) : (step += 1) {
        probe.log.append(probe.identity);
        context.yieldCheck();
    }
}

test "Scheduler: round-robin fairness under the preemption budget (FIFO policy)" {
    var kernel: TestKernel = undefined;
    try kernel.init(.{ .stack_usable_size = 64 * 1024, .preemption_budget = 4 });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probes = [_]WorkLogProbe{
        .{ .log = &log, .identity = 'a', .total_steps = 12 },
        .{ .log = &log, .identity = 'b', .total_steps = 12 },
        .{ .log = &log, .identity = 'c', .total_steps = 12 },
    };
    for (&probes) |*probe| {
        _ = try kernel.scheduler.spawn(.{
            .entry = workLoggingEntry,
            .argument = probe,
            .manager = manager.managerContext(),
        });
    }
    try kernel.scheduler.runUntilQuiescent();

    // Budget 4 + FIFO: strict round-robin in chunks of 4 — every process
    // makes progress each cycle and the order is the admission order.
    try testing.expectEqualSlices(
        u8,
        "aaaabbbbccccaaaabbbbccccaaaabbbbcccc",
        log.recorded(),
    );
    try testing.expectEqual(@as(usize, 3), manager.teardown_count);
    try kernel.expectExactAccounting();
}

// -- runnext fairness poll (P4-R2 finding #3) ----------------------------------

/// A trivial process body: increment a `*usize` run counter and exit. Used to
/// mint valid, immediately-exiting records for the white-box fairness test.
fn fairnessExitBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const run_count: *usize = @ptrCast(@alignCast(argument.?));
    run_count.* += 1;
}

test "Scheduler: the runnext fairness poll serves stranded global/FIFO work past a saturated LIFO slot (P4-R2 finding #3)" {
    // White-box proof at the pick chokepoint. A hot mutual-wake pair refills
    // `runnext` before EVERY pick; a plain "runnext first" policy would then
    // return the hot partner on all 122 picks and never serve the two stranded
    // records. The fairness poll instead bypasses `runnext` on each 61st pick,
    // serving the GLOBAL-queued record on the first tick and the FIFO-queued
    // record on the second — each WITHOUT consuming `runnext`.
    var global_queue = GlobalRunQueue.init();
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .work_stealing = true,
        .global_queue = &global_queue,
        // Disable spawn-time spilling so the three fresh records stay in the
        // local FIFO for us to relocate deterministically.
        .spill_threshold = 0,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var hot_run_count: usize = 0;
    var global_run_count: usize = 0;
    var fifo_run_count: usize = 0;
    _ = try kernel.scheduler.spawn(.{ .entry = fairnessExitBody, .argument = &hot_run_count, .manager = manager.managerContext() });
    _ = try kernel.scheduler.spawn(.{ .entry = fairnessExitBody, .argument = &global_run_count, .manager = manager.managerContext() });
    _ = try kernel.scheduler.spawn(.{ .entry = fairnessExitBody, .argument = &fifo_run_count, .manager = manager.managerContext() });

    // Detach the three fresh records from the FIFO the spawns queued them into.
    const hot_record = kernel.scheduler.dequeueReadyAt(0).?;
    const global_stranded_record = kernel.scheduler.dequeueReadyAt(0).?;
    const fifo_stranded_record = kernel.scheduler.dequeueReadyAt(0).?;

    // One record stranded in the global overflow queue, one in the local FIFO.
    global_queue.acquire();
    global_queue.pushChainLocked(global_stranded_record, global_stranded_record, 1);
    global_queue.lock.unlock();
    kernel.scheduler.readyEnqueue(fifo_stranded_record);

    var global_served_at_pick: ?u64 = null;
    var fifo_served_at_pick: ?u64 = null;
    var runnext_picks: u64 = 0;
    const total_picks = runnext_fairness_interval * 2;
    var pick: u64 = 0;
    while (pick < total_picks) : (pick += 1) {
        kernel.scheduler.runnext = hot_record; // the ever-refilled LIFO slot
        const chosen = kernel.scheduler.dequeueNextRunnable().?;
        if (chosen == hot_record) {
            runnext_picks += 1;
        } else if (chosen == global_stranded_record) {
            global_served_at_pick = pick + 1;
        } else if (chosen == fifo_stranded_record) {
            fifo_served_at_pick = pick + 1;
        } else unreachable;
    }

    // The global-stranded record surfaces on the first fairness tick (global is
    // served before the FIFO), the FIFO-stranded record on the second. Every
    // other pick returned `runnext` — the exact starvation a plain "runnext
    // first" policy would make permanent.
    try testing.expectEqual(@as(?u64, runnext_fairness_interval), global_served_at_pick);
    try testing.expectEqual(@as(?u64, runnext_fairness_interval * 2), fifo_served_at_pick);
    try testing.expectEqual(total_picks - 2, runnext_picks);

    // The fairness ticks handed us the two stranded records (now detached) and
    // left `hot_record` in `runnext`. Re-enqueue and drain to leak-exact exit.
    kernel.scheduler.readyEnqueue(global_stranded_record);
    kernel.scheduler.readyEnqueue(fifo_stranded_record);
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 1), hot_run_count);
    try testing.expectEqual(@as(usize, 1), global_run_count);
    try testing.expectEqual(@as(usize, 1), fifo_run_count);
    try testing.expectEqual(@as(usize, 3), manager.teardown_count);
    try kernel.expectExactAccounting();
}

/// Shared state for the mutual-wake fairness scenario. Single-threaded (one
/// standalone scheduler), so plain fields — no atomics.
const FairnessPairState = struct {
    pinger_pid: Pid = undefined,
    ponger_pid: Pid = undefined,
    rounds: usize,
    pinger_rounds: usize = 0,
    ponger_rounds: usize = 0,
    stranded_ran: bool = false,
    /// The pinger's completed-round count at the instant the stranded process
    /// first ran — the starvation-vs-progress signal. Without the fairness
    /// poll this equals `rounds` (the stranded process runs only after the pair
    /// exhausts); with it, far less (the poll runs it mid-flight).
    stranded_pinger_rounds_at_run: usize = 0,
};

fn fairnessPingerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *FairnessPairState = @ptrCast(@alignCast(argument.?));
    // Bootstrap the loop: the ponger is parked on its first receive.
    _ = context.send(state.ponger_pid, .{}) catch @panic("pinger bootstrap send failed");
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        envelope_pool_module.free(context.receive());
        state.pinger_rounds += 1;
        if (round + 1 < state.rounds) {
            _ = context.send(state.ponger_pid, .{}) catch @panic("pinger send failed");
        }
    }
}

fn fairnessPongerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const state: *FairnessPairState = @ptrCast(@alignCast(argument.?));
    var round: usize = 0;
    while (round < state.rounds) : (round += 1) {
        envelope_pool_module.free(context.receive());
        state.ponger_rounds += 1;
        _ = context.send(state.pinger_pid, .{}) catch @panic("ponger send failed");
    }
}

fn fairnessStrandedBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *FairnessPairState = @ptrCast(@alignCast(argument.?));
    state.stranded_ran = true;
    state.stranded_pinger_rounds_at_run = state.pinger_rounds;
}

test "Scheduler: a hot mutual-wake pair cannot starve a FIFO-stranded process — the fairness poll runs it mid-flight (P4-R2 finding #3)" {
    // A standalone work-stealing scheduler is single-threaded and fully
    // deterministic here: every wake is in-process (routes through `runnext`)
    // and the scheduler never futex-parks (the stranded process is always
    // runnable). The pair ping-pongs `rounds` times, refilling `runnext` every
    // quantum; the stranded process sits in the FIFO the whole time. WITHOUT
    // the fairness poll it runs only AFTER the pair exhausts
    // (`stranded_pinger_rounds_at_run == rounds`); WITH it, the 61st pick
    // bypasses `runnext` and runs it while the pair is still hot
    // (`stranded_pinger_rounds_at_run` well below one fairness interval).
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .work_stealing = true,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var state = FairnessPairState{ .rounds = 200 };
    // Spawn order [ponger, pinger, stranded]: the ponger parks first, the
    // pinger's bootstrap wakes it into `runnext`, and the pair then cycles
    // through `runnext` while the stranded process waits at the FIFO head.
    const ponger_pid = try kernel.scheduler.spawn(.{
        .entry = fairnessPongerBody,
        .argument = &state,
        .manager = manager.managerContext(),
    });
    const pinger_pid = try kernel.scheduler.spawn(.{
        .entry = fairnessPingerBody,
        .argument = &state,
        .manager = manager.managerContext(),
    });
    _ = try kernel.scheduler.spawn(.{
        .entry = fairnessStrandedBody,
        .argument = &state,
        .manager = manager.managerContext(),
    });
    state.ponger_pid = ponger_pid;
    state.pinger_pid = pinger_pid;

    try kernel.scheduler.runUntilQuiescent();

    // Every round completed (no lost wake), and the stranded process ran while
    // the pair was still mid-flight — impossible without the fairness poll.
    try testing.expectEqual(state.rounds, state.pinger_rounds);
    try testing.expectEqual(state.rounds, state.ponger_rounds);
    try testing.expect(state.stranded_ran);
    try testing.expect(state.stranded_pinger_rounds_at_run < state.rounds);
    try testing.expect(state.stranded_pinger_rounds_at_run < runnext_fairness_interval);
    try testing.expectEqual(@as(usize, 3), manager.teardown_count);
    try kernel.expectExactAccounting();
}

test "Scheduler: budget exhaustion forces yield — quantum and yield counts are exact" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 3,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe = WorkLogProbe{ .log = &log, .identity = 'x', .total_steps = 10 };
    _ = try kernel.scheduler.spawn(.{
        .entry = workLoggingEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    // 10 steps at budget 3: yields after steps 3, 6, 9 → 4 quanta.
    try testing.expectEqual(@as(usize, 10), log.count);
    try testing.expectEqual(@as(usize, 4), trace_log.countKind(.schedule));
    try testing.expectEqual(@as(usize, 3), trace_log.countKind(.yield));
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.exit));
    try kernel.expectExactAccounting();
}

test "Scheduler: quantum counter counts every executed quantum exactly" {
    var kernel: TestKernel = undefined;
    try kernel.init(.{ .stack_usable_size = 64 * 1024, .preemption_budget = 3 });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    try testing.expectEqual(@as(u64, 0), kernel.scheduler.statistics().quantum_total);

    var log = WorkLog{};
    var probe = WorkLogProbe{ .log = &log, .identity = 'q', .total_steps = 10 };
    _ = try kernel.scheduler.spawn(.{
        .entry = workLoggingEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    // 10 steps at budget 3: yields after steps 3, 6, 9 → exactly 4 quanta.
    try testing.expectEqual(@as(u64, 4), kernel.scheduler.statistics().quantum_total);
    try kernel.expectExactAccounting();
}

const WatchdogProbe = struct {
    log: *WorkLog,
    total_steps: usize,
};

fn watchdogEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *WatchdogProbe = @ptrCast(@alignCast(argument.?));
    var step: usize = 0;
    while (step < probe.total_steps) : (step += 1) {
        probe.log.append('w');
        context.yieldCheck();
    }
}

test "Scheduler: watchdog flag preempts at the next yieldCheck and is consumed once" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        // Budget far larger than the workload: without the watchdog the
        // process would finish in ONE quantum.
        .preemption_budget = 1000,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe = WatchdogProbe{ .log = &log, .total_steps = 8 };
    _ = try kernel.scheduler.spawn(.{
        .entry = watchdogEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    kernel.scheduler.requestWatchdogPreemption();
    try kernel.scheduler.runUntilQuiescent();

    // The flag forced a yield at the FIRST safepoint (one step of work),
    // was consumed at that quantum's end, and the process then completed
    // uninterrupted: exactly 2 quanta, 1 forced yield.
    try testing.expectEqual(@as(usize, 8), log.count);
    try testing.expectEqual(@as(usize, 2), trace_log.countKind(.schedule));
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.yield));
    try testing.expect(!kernel.scheduler.watchdog_preempt_flag.load(.monotonic));
    try kernel.expectExactAccounting();
}

// -- reductionSafepoint (P2-J6 compiled-code safepoint slow path) -----------------

const ReductionProbe = struct {
    log: *WorkLog,
    identity: u8,
    total_steps: usize,
};

fn reductionSafepointEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ReductionProbe = @ptrCast(@alignCast(argument.?));
    var step: usize = 0;
    while (step < probe.total_steps) : (step += 1) {
        probe.log.append(probe.identity);
        context.reductionSafepoint();
    }
}

test "Scheduler: reductionSafepoint runs a sole process switch-free (E2 sole-runnable path)" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 1000,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe = ReductionProbe{ .log = &log, .identity = 'r', .total_steps = 8 };
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    // A sole runnable process with no watchdog/kill request must NOT yield
    // at reductionSafepoint — it re-arms and runs to completion in ONE
    // quantum. This is the property the E2 gate depends on: a CLBG hot loop
    // compiled with concurrency on and no co-runnable peer stays switch-free.
    try testing.expectEqual(@as(usize, 8), log.count);
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.schedule));
    try testing.expectEqual(@as(usize, 0), trace_log.countKind(.yield));
    try kernel.expectExactAccounting();
}

test "Scheduler: reductionSafepoint honors the watchdog flag (layer 3)" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        // Budget far larger than the workload: without the watchdog the
        // process finishes in ONE quantum (see the sole-runnable test).
        .preemption_budget = 1000,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe = ReductionProbe{ .log = &log, .identity = 'r', .total_steps = 8 };
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    kernel.scheduler.requestWatchdogPreemption();
    try kernel.scheduler.runUntilQuiescent();

    // The flag forced a yield at the first reductionSafepoint, was consumed
    // at that quantum's end, and the process then ran uninterrupted: 2
    // quanta, 1 forced yield — the wasm-safe flag-only watchdog (layer 3)
    // reaching the compiled-code safepoint slow path exactly as it reaches
    // the kernel `yieldCheck` path.
    try testing.expectEqual(@as(usize, 8), log.count);
    try testing.expectEqual(@as(usize, 2), trace_log.countKind(.schedule));
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.yield));
    try testing.expect(!kernel.scheduler.watchdog_preempt_flag.load(.monotonic));
    try kernel.expectExactAccounting();
}

fn reductionSafepointViaResolutionEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    // Mimics the compiled-code path: reach the safepoint through the ambient
    // `currentProcessContext` resolver (as `abi.zap_proc_safepoint_slow`
    // does) rather than the entry-delivered context, so this test covers the
    // resolution seam the full runtime uses — not just the direct method call.
    const probe: *ReductionProbe = @ptrCast(@alignCast(argument.?));
    var step: usize = 0;
    while (step < probe.total_steps) : (step += 1) {
        probe.log.append(probe.identity);
        const resolved = context.record.scheduler.currentProcessContext().?;
        resolved.reductionSafepoint();
    }
}

test "Scheduler: reductionSafepoint via currentProcessContext resolution still interleaves (full-runtime seam)" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 1000,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe_a = ReductionProbe{ .log = &log, .identity = 'a', .total_steps = 3 };
    var probe_b = ReductionProbe{ .log = &log, .identity = 'b', .total_steps = 3 };
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointViaResolutionEntry,
        .argument = &probe_a,
        .manager = manager.managerContext(),
    });
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointViaResolutionEntry,
        .argument = &probe_b,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    // The ambient-resolution path yields exactly as the direct path does —
    // the full-runtime `zap_proc_safepoint_slow` seam preserves preemption.
    try testing.expectEqual(@as(usize, 6), log.count);
    try testing.expectEqualStrings("ababab", log.recorded());
    try kernel.expectExactAccounting();
}

test "Scheduler: reductionSafepoint interleaves co-runnable processes (layer-2 budget preemption)" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 1000,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe_a = ReductionProbe{ .log = &log, .identity = 'a', .total_steps = 3 };
    var probe_b = ReductionProbe{ .log = &log, .identity = 'b', .total_steps = 3 };
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointEntry,
        .argument = &probe_a,
        .manager = manager.managerContext(),
    });
    _ = try kernel.scheduler.spawn(.{
        .entry = reductionSafepointEntry,
        .argument = &probe_b,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    // With a co-runnable peer, each reductionSafepoint yields, so the two
    // processes interleave step-for-step under production FIFO rather than
    // one running to completion first ("aaabbb"). This is the deterministic
    // budget-bounded preemption a compiled alloc-free loop relies on so a
    // co-runnable process makes progress (plan item 2.5, layer 2).
    try testing.expectEqual(@as(usize, 6), log.count);
    try testing.expectEqualStrings("ababab", log.recorded());
    try kernel.expectExactAccounting();
}

// -- blocking receive + wake ------------------------------------------------------

const ReceiverProbe = struct {
    received_stamp: usize = 0,
    receive_count: usize = 0,
};

fn receiveOnceEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ReceiverProbe = @ptrCast(@alignCast(argument.?));
    const envelope = context.receive();
    probe.received_stamp = envelope.fragment.payload_byte_length;
    probe.receive_count += 1;
    envelope_pool_module.free(envelope);
}

const SenderProbe = struct {
    target: Pid,
    stamp: usize,
    outcome: SendOutcome = .dead_lettered,
};

fn sendOnceEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SenderProbe = @ptrCast(@alignCast(argument.?));
    probe.outcome = context.send(probe.target, .{
        .payload_byte_length = probe.stamp,
    }) catch @panic("send failed to allocate an envelope");
}

test "Scheduler: blocking receive on an empty mailbox — one push wakes it exactly once" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var receiver_probe = ReceiverProbe{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = receiveOnceEntry,
        .argument = &receiver_probe,
        .manager = manager.managerContext(),
    });
    var sender_probe = SenderProbe{ .target = receiver_pid, .stamp = 0xBEEF };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendOnceEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(SendOutcome.delivered, sender_probe.outcome);
    try testing.expectEqual(@as(usize, 0xBEEF), receiver_probe.received_stamp);
    try testing.expectEqual(@as(usize, 1), receiver_probe.receive_count);
    // Exactly one wait and exactly one wake: the receiver suspended once
    // and the (exact, empty→nonempty) push signal resumed it once.
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.wait));
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.wake));
    try kernel.expectExactAccounting();
}

// -- receive … after timeout (plan item 2.3, P2-J3) -------------------------------

const TimeoutProbe = struct {
    outcome: ReceiveWaitOutcome = .message_available,
    stamp: usize = 0,
};

fn timeoutNoSenderEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *TimeoutProbe = @ptrCast(@alignCast(argument.?));
    // A large timeout with no sender: deterministic mode advances virtual
    // time and fires the deadline when nothing else can run.
    probe.outcome = context.receiveWaitTimeout(60 * std.time.ns_per_s);
}

test "Scheduler: receive … after times out when no message arrives (deterministic firing)" {
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .idle_strategy = .forbid_parking,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = TimeoutProbe{};
    _ = try kernel.scheduler.spawn(.{
        .entry = timeoutNoSenderEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(ReceiveWaitOutcome.timed_out, probe.outcome);
    try kernel.expectExactAccounting();
}

fn pollEmptyEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *TimeoutProbe = @ptrCast(@alignCast(argument.?));
    // `after 0` on an empty mailbox: a non-blocking poll — never parks.
    probe.outcome = context.receiveWaitTimeout(0);
}

test "Scheduler: after 0 polls an empty mailbox without parking" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .idle_strategy = .forbid_parking,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = TimeoutProbe{};
    _ = try kernel.scheduler.spawn(.{
        .entry = pollEmptyEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(ReceiveWaitOutcome.timed_out, probe.outcome);
    // A poll never suspends the process: no `.wait` transition at all.
    try testing.expectEqual(@as(usize, 0), trace_log.countKind(.wait));
    try kernel.expectExactAccounting();
}

const PollSeesMessageProbe = struct {
    first_stamp: usize = 0,
    poll_outcome: ReceiveWaitOutcome = .timed_out,
    second_stamp: usize = 0,
};

fn pollSeesQueuedMessageEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *PollSeesMessageProbe = @ptrCast(@alignCast(argument.?));
    // Block for the sender's first message (guarantees the sender ran and
    // enqueued the SECOND one), then poll — which must see it available.
    const first = context.receive();
    probe.first_stamp = first.fragment.payload_byte_length;
    envelope_pool_module.free(first);
    probe.poll_outcome = context.receiveWaitTimeout(0);
    const second = context.receive();
    probe.second_stamp = second.fragment.payload_byte_length;
    envelope_pool_module.free(second);
}

const TwoSendProbe = struct {
    target: Pid,
    first_stamp: usize,
    second_stamp: usize,
};

fn twoSendEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *TwoSendProbe = @ptrCast(@alignCast(argument.?));
    _ = context.send(probe.target, .{ .payload_byte_length = probe.first_stamp }) catch
        @panic("send failed to allocate an envelope");
    _ = context.send(probe.target, .{ .payload_byte_length = probe.second_stamp }) catch
        @panic("send failed to allocate an envelope");
}

test "Scheduler: after 0 poll sees a queued message as available" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var receiver_probe = PollSeesMessageProbe{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = pollSeesQueuedMessageEntry,
        .argument = &receiver_probe,
        .manager = manager.managerContext(),
    });
    var sender_probe = TwoSendProbe{ .target = receiver_pid, .first_stamp = 0xA1, .second_stamp = 0xB2 };
    _ = try kernel.scheduler.spawn(.{
        .entry = twoSendEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 0xA1), receiver_probe.first_stamp);
    try testing.expectEqual(ReceiveWaitOutcome.message_available, receiver_probe.poll_outcome);
    try testing.expectEqual(@as(usize, 0xB2), receiver_probe.second_stamp);
    try kernel.expectExactAccounting();
}

fn timeoutMessageArrivesEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *TimeoutProbe = @ptrCast(@alignCast(argument.?));
    // A generous timeout: the sender's message must arrive first and win.
    probe.outcome = context.receiveWaitTimeout(60 * std.time.ns_per_s);
    const envelope = context.receive();
    probe.stamp = envelope.fragment.payload_byte_length;
    envelope_pool_module.free(envelope);
}

test "Scheduler: a message that arrives before the after deadline wins over the timeout" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var receiver_probe = TimeoutProbe{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = timeoutMessageArrivesEntry,
        .argument = &receiver_probe,
        .manager = manager.managerContext(),
    });
    var sender_probe = SenderProbe{ .target = receiver_pid, .stamp = 0xCC };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendOnceEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(ReceiveWaitOutcome.message_available, receiver_probe.outcome);
    try testing.expectEqual(@as(usize, 0xCC), receiver_probe.stamp);
    try testing.expectEqual(@as(u64, 0), kernel.scheduler.statistics().unexpected_message_total);
    try kernel.expectExactAccounting();
}

// -- drop-list ---------------------------------------------------------------------

const DropLogNode = struct {
    node: process_module.DropListNode,
    log: *WorkLog,
    identity: u8,

    fn destructor(node: *process_module.DropListNode) void {
        const drop_log_node: *DropLogNode = @fieldParentPtr("node", node);
        drop_log_node.log.append(drop_log_node.identity);
    }
};

const DropRegisteringProbe = struct {
    nodes: [3]DropLogNode,
    wait_after_registering: bool,
};

fn dropRegisteringEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *DropRegisteringProbe = @ptrCast(@alignCast(argument.?));
    for (&probe.nodes) |*drop_log_node| {
        context.registerDropResource(&drop_log_node.node);
    }
    if (probe.wait_after_registering) {
        // Wait forever: the test kills this process while it is waiting.
        _ = context.receive();
        @panic("killed waiter must never resume");
    }
}

fn makeDropProbe(log: *WorkLog, wait_after_registering: bool) DropRegisteringProbe {
    var probe = DropRegisteringProbe{
        .nodes = undefined,
        .wait_after_registering = wait_after_registering,
    };
    for (&probe.nodes, 0..) |*drop_log_node, index| {
        drop_log_node.* = .{
            .node = .{ .destructor = DropLogNode.destructor },
            .log = log,
            .identity = @intCast('1' + index),
        };
    }
    return probe;
}

test "Scheduler: drop-list destructors run LIFO on normal exit" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var probe = makeDropProbe(&log, false);
    _ = try kernel.scheduler.spawn(.{
        .entry = dropRegisteringEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    // Registered 1, 2, 3 — destroyed 3, 2, 1 (newest-first).
    try testing.expectEqualSlices(u8, "321", log.recorded());
    try kernel.expectExactAccounting();
}

// -- kill ---------------------------------------------------------------------------

const KillerProbe = struct {
    target: Pid,
    outcome: KillOutcome = .not_found,
};

fn killerEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *KillerProbe = @ptrCast(@alignCast(argument.?));
    probe.outcome = context.kill(probe.target);
}

test "Scheduler: kill of a waiting process tears it down without resuming it (drop-list runs)" {
    var trace_log = TestTraceLog{};
    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        .trace_hook = TestTraceLog.hook,
        .trace_context = &trace_log,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var log = WorkLog{};
    var waiter_probe = makeDropProbe(&log, true);
    const waiter_pid = try kernel.scheduler.spawn(.{
        .entry = dropRegisteringEntry,
        .argument = &waiter_probe,
        .manager = manager.managerContext(),
    });
    var killer_probe = KillerProbe{ .target = waiter_pid };
    _ = try kernel.scheduler.spawn(.{
        .entry = killerEntry,
        .argument = &killer_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    // The waiter was `.waiting` when killed: immediate non-cooperative
    // teardown, drop-list still ran LIFO, and the suspended stack was
    // reclaimed through the invariant path.
    try testing.expectEqual(KillOutcome.killed, killer_probe.outcome);
    try testing.expectEqualSlices(u8, "321", log.recorded());
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.kill));
    try testing.expectEqual(@as(usize, 1), trace_log.countKind(.exit)); // the killer
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    try kernel.expectExactAccounting();

    const stats = kernel.scheduler.statistics();
    try testing.expectEqual(@as(u64, 1), stats.kill_total);
    try testing.expectEqual(@as(u64, 1), stats.normal_exit_total);
}

fn neverRunsEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    _ = argument;
    @panic("a process killed while runnable must never run");
}

test "Scheduler: kill of a queued (never-run) process tears it down without running it" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // FIFO: the killer is admitted FIRST so it runs before its victim.
    var killer_probe = KillerProbe{ .target = Pid.invalid };
    _ = try kernel.scheduler.spawn(.{
        .entry = killerEntry,
        .argument = &killer_probe,
        .manager = manager.managerContext(),
    });
    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = neverRunsEntry,
        .manager = manager.managerContext(),
    });
    killer_probe.target = victim_pid;

    try kernel.scheduler.runUntilQuiescent();

    // The victim was `.runnable`: the kill was pending and consumed at
    // its dequeue — its `.ready` fiber (stack untouched) was reclaimed.
    try testing.expectEqual(KillOutcome.kill_pending, killer_probe.outcome);
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    try testing.expectEqual(@as(u64, 1), kernel.scheduler.statistics().kill_total);
    try kernel.expectExactAccounting();
}

const SelfKillProbe = struct {
    steps_before_kill: usize = 0,
    steps_after_kill: usize = 0,
};

fn selfKillEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SelfKillProbe = @ptrCast(@alignCast(argument.?));
    probe.steps_before_kill += 1;
    const outcome = context.kill(context.selfPid());
    std.debug.assert(outcome == .kill_pending);
    context.yieldCheck(); // the safepoint where the self-kill lands
    probe.steps_after_kill += 1; // must never execute
}

test "Scheduler: self-kill takes effect at the next safepoint" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = SelfKillProbe{};
    _ = try kernel.scheduler.spawn(.{
        .entry = selfKillEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 1), probe.steps_before_kill);
    try testing.expectEqual(@as(usize, 0), probe.steps_after_kill);
    try testing.expectEqual(@as(u64, 1), kernel.scheduler.statistics().kill_total);
    try kernel.expectExactAccounting();
}

test "Scheduler: kill of a dead pid dead-letters" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = LifecycleProbe{};
    const pid = try kernel.scheduler.spawn(.{
        .entry = lifecycleEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    const dead_letters_before = kernel.pid_table.statistics().dead_letter_count;
    try testing.expectEqual(KillOutcome.not_found, kernel.scheduler.kill(pid));
    try testing.expectEqual(dead_letters_before + 1, kernel.pid_table.statistics().dead_letter_count);
}

// -- teardown with a non-empty mailbox + abandoned pages -----------------------------

const BurstSenderProbe = struct {
    target: Pid,
    message_count: usize,
};

fn burstSenderEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *BurstSenderProbe = @ptrCast(@alignCast(argument.?));
    var sequence: usize = 0;
    while (sequence < probe.message_count) : (sequence += 1) {
        const outcome = context.send(probe.target, .{ .payload_byte_length = sequence }) catch
            @panic("send failed to allocate an envelope");
        std.debug.assert(outcome == .delivered);
    }
}

fn exitWithoutReceivingEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    // Yield once so the sender's burst lands while this process is still
    // alive; then exit WITHOUT receiving — teardown must drain and free
    // every foreign envelope.
    context.yieldNow();
}

test "Scheduler: teardown with a non-empty mailbox frees foreign envelopes and reclaims abandoned pages" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    const message_count = 20; // > envelopes_per_page (8): multiple sender pages

    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = exitWithoutReceivingEntry,
        .manager = manager.managerContext(),
    });
    var sender_probe = BurstSenderProbe{ .target = receiver_pid, .message_count = message_count };
    _ = try kernel.scheduler.spawn(.{
        .entry = burstSenderEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    // The sender exited first (FIFO: receiver yields, sender runs to
    // completion, then the receiver exits with 20 queued envelopes):
    // the sender's teardown ABANDONED its in-flight pages, and the
    // receiver's teardown drain freed every envelope — the last free per
    // page RECLAIMED it. Exact accounting proves both directions.
    try kernel.expectExactAccounting();
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    // Pages actually flowed (the burst spanned several).
    try testing.expect(kernel.envelope_pool.statistics().live_page_peak >= 2);
}

// Deterministic proof of the cross-thread send grace period — the fix for the
// message-vs-timer envelope-page leak. A message that raced a receiver's
// timeout-and-teardown could push into the mailbox AFTER the teardown drain had
// already run, orphaning the envelope (and its sender's abandoned page). The
// grace period closes it: `closeAndQuiesce` (in teardown, before the drain) must
// wait for every already-pinned sender to finish, and a mailbox closed first
// rejects the sender so it dead-letters instead of orphaning. This drives both
// halves across two real threads, forcing the exact previously-leaking ordering.
test "Scheduler: send grace period — teardown waits out an in-flight sender, and a closed mailbox rejects new sends" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // Only the grace-period fields participate; the rest of the record is inert
    // for `beginSend`/`endSend`/`closeAndQuiesce` (they touch nothing else).
    var record: ProcessRecord = undefined;
    record.in_flight_send_count = .init(0);
    record.send_closed = .init(false);

    // A sender pins the target while its mailbox is still open: a send is now in
    // flight, exactly as when a message races the receiver's deadline.
    try testing.expect(record.beginSend());
    try testing.expectEqual(@as(u32, 1), record.in_flight_send_count.load(.seq_cst));

    // Teardown closes-and-quiesces on another thread. It MUST block until the
    // in-flight send retires: were it to proceed, the drain could run before the
    // sender's push lands — the leak.
    const Closer = struct {
        record: *ProcessRecord,
        returned: std.atomic.Value(bool) = .init(false),

        fn run(closer: *@This()) void {
            closer.record.closeAndQuiesce();
            closer.returned.store(true, .release);
        }
    };
    var closer = Closer{ .record = &record };
    const closer_thread = try std.Thread.spawn(.{}, Closer.run, .{&closer});

    // While the pin is held, `closeAndQuiesce` cannot return. Observe it stay
    // blocked across a bounded window (a broken wait would return early and trip
    // this) — the parked-observer discipline the pool/pool-family tests use.
    var observation_spins: u32 = 0;
    while (observation_spins < 200_000) : (observation_spins += 1) {
        try testing.expect(!closer.returned.load(.acquire));
        std.atomic.spinLoopHint();
    }

    // Retiring the send releases the quiesce wait: teardown may now drain.
    record.endSend();
    closer_thread.join();
    try testing.expect(closer.returned.load(.acquire));

    // The mailbox is now closed. A sender that arrives after the close is
    // rejected (it dead-letters rather than orphaning an envelope), and the
    // rejection leaves the in-flight count balanced at zero.
    try testing.expect(!record.beginSend());
    try testing.expectEqual(@as(u32, 0), record.in_flight_send_count.load(.seq_cst));
}

// -- shutdown -------------------------------------------------------------------------

fn waitForeverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("shutdown must never resume a waiting process");
}

test "Scheduler: shutdownAllProcesses tears down runnable and waiting processes exactly" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // One process that will be WAITING (run it into its receive), one
    // that stays RUNNABLE (spawned but never run).
    _ = try kernel.scheduler.spawn(.{
        .entry = waitForeverEntry,
        .manager = manager.managerContext(),
    });
    // Drive the waiter into `.waiting`, then hit the deterministic-idle
    // stop instead of parking.
    var idle_kernel_options = kernel.scheduler.options;
    idle_kernel_options.idle_strategy = .forbid_parking;
    kernel.scheduler.options = idle_kernel_options;
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    _ = try kernel.scheduler.spawn(.{
        .entry = neverRunsEntry,
        .manager = manager.managerContext(),
    });

    kernel.scheduler.shutdownAllProcesses();
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    try testing.expectEqual(@as(u64, 2), kernel.scheduler.statistics().kill_total);
    try kernel.expectExactAccounting();
}

// -- ambient current-process context (the P2-J2 `zap_proc_current` seam) --------------

const AmbientContextProbe = struct {
    scheduler: *Scheduler,
    matched_before_yield: bool = false,
    matched_after_yield: bool = false,
};

fn ambientContextEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *AmbientContextProbe = @ptrCast(@alignCast(argument.?));
    probe.matched_before_yield = probe.scheduler.currentProcessContext() == context;
    context.yieldNow();
    probe.matched_after_yield = probe.scheduler.currentProcessContext() == context;
}

test "Scheduler: currentProcessContext is null between quanta and identity-stable inside them" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // No quantum running: the ambient lookup answers null.
    try testing.expectEqual(@as(?*ProcessContext, null), kernel.scheduler.currentProcessContext());

    // Two interleaving processes (each yields once mid-body): each must
    // observe ITS OWN parameter-threaded context through the ambient
    // lookup both before and after the interleaving yield.
    var first_probe = AmbientContextProbe{ .scheduler = &kernel.scheduler };
    var second_probe = AmbientContextProbe{ .scheduler = &kernel.scheduler };
    _ = try kernel.scheduler.spawn(.{
        .entry = ambientContextEntry,
        .argument = &first_probe,
        .manager = manager.managerContext(),
    });
    _ = try kernel.scheduler.spawn(.{
        .entry = ambientContextEntry,
        .argument = &second_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilQuiescent();

    try testing.expect(first_probe.matched_before_yield);
    try testing.expect(first_probe.matched_after_yield);
    try testing.expect(second_probe.matched_before_yield);
    try testing.expect(second_probe.matched_after_yield);
    // Quiescent again: null.
    try testing.expectEqual(@as(?*ProcessContext, null), kernel.scheduler.currentProcessContext());
    try kernel.expectExactAccounting();
}

// -- run-until-exit (the P2-J2 root-process join) --------------------------------------

test "Scheduler: runUntilProcessExits returns at target exit and leaves stragglers live" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // A straggler that parks forever, then the "root": a receiver that
    // exits after one message, fed by a sender. The join must drive the
    // sender (and the straggler's admission) but return as soon as the
    // root is gone — with the straggler still parked.
    _ = try kernel.scheduler.spawn(.{
        .entry = waitForeverEntry,
        .manager = manager.managerContext(),
    });
    var root_probe = ReceiverProbe{};
    const root_pid = try kernel.scheduler.spawn(.{
        .entry = receiveOnceEntry,
        .argument = &root_probe,
        .manager = manager.managerContext(),
    });
    var sender_probe = SenderProbe{ .target = root_pid, .stamp = 0xF00D };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendOnceEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });

    try kernel.scheduler.runUntilProcessExits(root_pid);

    try testing.expectEqual(SendOutcome.delivered, sender_probe.outcome);
    try testing.expectEqual(@as(usize, 0xF00D), root_probe.received_stamp);
    try testing.expectEqual(@as(?*ProcessControlBlock, null), kernel.pid_table.lookup(root_pid));
    // The straggler is still live and parked.
    try testing.expectEqual(@as(u32, 1), kernel.scheduler.statistics().live_process_count);

    // A second join on the dead pid returns immediately.
    try kernel.scheduler.runUntilProcessExits(root_pid);

    // Program-shutdown semantics: stragglers are torn down wholesale.
    kernel.scheduler.shutdownAllProcesses();
    try kernel.expectExactAccounting();
}

test "Scheduler: runUntilProcessExits surfaces deterministic-mode deadlock" {
    var kernel: TestKernel = undefined;
    var deterministic_options = test_scheduler_options;
    deterministic_options.idle_strategy = .forbid_parking;
    try kernel.init(deterministic_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // The target parks on an empty mailbox with no sender anywhere: a
    // genuine deadlock that deterministic mode must surface rather than
    // park on.
    const target_pid = try kernel.scheduler.spawn(.{
        .entry = waitForeverEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectError(
        error.AllProcessesWaiting,
        kernel.scheduler.runUntilProcessExits(target_pid),
    );

    kernel.scheduler.shutdownAllProcesses();
    try kernel.expectExactAccounting();
}

// -- receive: transient publication gap re-enqueues -----------------------------------

const GapScenario = struct {
    gap_yields_observed: usize = 0,
    received_stamp: usize = 0,
    release_event: std.atomic.Value(bool) = .init(false),
    producer_entered_gap: std.atomic.Value(bool) = .init(false),

    /// Producer-side instrumentation: park inside the XCHG→link window
    /// until the receiving PROCESS (not the test thread — it is inside
    /// the scheduler) releases us after observing gap retries.
    fn parkInGapWindow(instrumentation_context: ?*anyopaque, envelope: *mailbox_module.Envelope) void {
        _ = envelope;
        const scenario: *GapScenario = @ptrCast(@alignCast(instrumentation_context.?));
        scenario.producer_entered_gap.store(true, .release);
        const deadline = mailbox_module.TestDeadline.init(30 * std.time.ns_per_s);
        while (!scenario.release_event.load(.acquire)) {
            if (deadline.expired()) @panic("gap producer was never released");
            std.atomic.spinLoopHint();
        }
    }
};

fn gapReceiverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const scenario: *GapScenario = @ptrCast(@alignCast(argument.?));
    const record = context.record;
    // Reimplement the receive loop shape with observation: count how
    // often the mailbox reports the transient gap before delivery.
    while (true) {
        switch (record.pcb.mailbox.pop()) {
            .envelope => |envelope| {
                scenario.received_stamp = envelope.fragment.payload_byte_length;
                envelope_pool_module.free(envelope);
                return;
            },
            .empty => {
                record.yield_reason = .waiting_for_message;
                context.execution.yield();
            },
            .transient_gap => {
                scenario.gap_yields_observed += 1;
                if (scenario.gap_yields_observed == 3) {
                    // Release the parked producer; its link lands and the
                    // next retry delivers.
                    scenario.release_event.store(true, .release);
                }
                record.yield_reason = .reenqueue;
                context.execution.yield();
            },
        }
    }
}

const GapProducerThread = struct {
    envelope_pool: *EnvelopePool,
    target_mailbox: *mailbox_module.Mailbox,

    fn run(producer: *GapProducerThread) void {
        var handle = EnvelopePool.Handle.init(producer.envelope_pool);
        const envelope = handle.allocate() catch @panic("gap producer allocation failed");
        envelope.fragment = .{ .payload_byte_length = 0xD00D };
        _ = producer.target_mailbox.push(envelope);
        // The envelope is consumed and freed by the receiver; the page
        // empties before abandon, so nothing is left abandoned.
        handle.abandon();
    }
};

test "Scheduler: a transient mailbox gap re-enqueues the receiver instead of blocking it" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var scenario = GapScenario{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = gapReceiverEntry,
        .argument = &scenario,
        .manager = manager.managerContext(),
    });
    const receiver_pcb = kernel.pid_table.lookup(receiver_pid).?;
    receiver_pcb.mailbox.push_instrumentation = .{
        .between_exchange_and_link = GapScenario.parkInGapWindow,
        .instrumentation_context = &scenario,
    };

    var producer = GapProducerThread{
        .envelope_pool = &kernel.envelope_pool,
        .target_mailbox = &receiver_pcb.mailbox,
    };
    const producer_thread = try std.Thread.spawn(.{}, GapProducerThread.run, .{&producer});

    // Wait until the producer is provably inside the gap window so the
    // receiver's first pop observes the gap, not empty.
    const deadline = mailbox_module.TestDeadline.init(30 * std.time.ns_per_s);
    while (!scenario.producer_entered_gap.load(.acquire)) {
        if (deadline.expired()) return error.TestTimeout;
        std.atomic.spinLoopHint();
    }

    try kernel.scheduler.runUntilQuiescent();
    producer_thread.join();

    try testing.expectEqual(@as(usize, 0xD00D), scenario.received_stamp);
    // The receiver saw the gap and yielded runnable (≥3 retries by
    // construction) instead of reporting empty or spinning forever.
    try testing.expect(scenario.gap_yields_observed >= 3);
    try kernel.expectExactAccounting();
}

// -- park / cross-thread wake -----------------------------------------------------------

const ParkedWakeProducer = struct {
    scheduler: *Scheduler,
    envelope_pool: *EnvelopePool,
    target_mailbox: *mailbox_module.Mailbox,
    failed: bool = false,

    fn run(producer: *ParkedWakeProducer) void {
        // Wait until the scheduler has actually parked at least once.
        const deadline = mailbox_module.TestDeadline.init(30 * std.time.ns_per_s);
        while (producer.scheduler.parkCount() == 0) {
            if (deadline.expired()) {
                producer.failed = true;
                return;
            }
            std.atomic.spinLoopHint();
        }
        var handle = EnvelopePool.Handle.init(producer.envelope_pool);
        const envelope = handle.allocate() catch {
            producer.failed = true;
            return;
        };
        envelope.fragment = .{ .payload_byte_length = 0xF00D };
        _ = producer.target_mailbox.push(envelope);
        handle.abandon();
    }
};

test "Scheduler: parks when idle and a producer thread's push wakes it" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var kernel: TestKernel = undefined;
    try kernel.init(.{
        .stack_usable_size = 64 * 1024,
        .preemption_budget = 128,
        // Short spin so the test reaches the park quickly.
        .spin_iterations_before_park = 32,
        .park_timeout_nanoseconds = 50 * std.time.ns_per_ms,
    });
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var receiver_probe = ReceiverProbe{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = receiveOnceEntry,
        .argument = &receiver_probe,
        .manager = manager.managerContext(),
    });
    const receiver_pcb = kernel.pid_table.lookup(receiver_pid).?;

    var producer = ParkedWakeProducer{
        .scheduler = &kernel.scheduler,
        .envelope_pool = &kernel.envelope_pool,
        .target_mailbox = &receiver_pcb.mailbox,
    };
    const producer_thread = try std.Thread.spawn(.{}, ParkedWakeProducer.run, .{&producer});

    // The scheduler parks (receiver waiting, nothing runnable), the
    // producer observes the park and pushes, the push's wake seam wakes
    // the futex, and the run loop resumes the receiver to completion.
    try kernel.scheduler.runUntilQuiescent();
    producer_thread.join();

    try testing.expect(!producer.failed);
    try testing.expectEqual(@as(usize, 0xF00D), receiver_probe.received_stamp);
    try testing.expect(kernel.scheduler.parkCount() >= 1);
    try kernel.expectExactAccounting();
}

// -- send to a dead pid ------------------------------------------------------------------

const DeadSendProbe = struct {
    dead_target: Pid,
    outcome: SendOutcome = .delivered,
};

fn deadSendEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *DeadSendProbe = @ptrCast(@alignCast(argument.?));
    probe.outcome = context.send(probe.dead_target, .{}) catch
        @panic("send failed to allocate an envelope");
}

test "Scheduler: send to a dead pid dead-letters without sending" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    // Create and retire a pid.
    var lifecycle_probe = LifecycleProbe{};
    const dead_pid = try kernel.scheduler.spawn(.{
        .entry = lifecycleEntry,
        .argument = &lifecycle_probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    var probe = DeadSendProbe{ .dead_target = dead_pid };
    _ = try kernel.scheduler.spawn(.{
        .entry = deadSendEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(SendOutcome.dead_lettered, probe.outcome);
    try kernel.expectExactAccounting();
}

// -- spawn from inside a process ------------------------------------------------------------

const NestedSpawnProbe = struct {
    manager_context: ManagerContext,
    child_probe: LifecycleProbe = .{},
    child_pid_bits: u64 = 0,
};

fn nestedSpawnEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *NestedSpawnProbe = @ptrCast(@alignCast(argument.?));
    const child_pid = context.spawn(.{
        .entry = lifecycleEntry,
        .argument = &probe.child_probe,
        .manager = probe.manager_context,
    }) catch @panic("nested spawn failed");
    probe.child_pid_bits = child_pid.toBits();
}

test "Scheduler: a process can spawn a child mid-quantum" {
    var kernel: TestKernel = undefined;
    try kernel.init(test_scheduler_options);
    defer kernel.deinit();
    var manager = TestProcessManager.init(testing.allocator);
    defer manager.deinitBacking();

    var probe = NestedSpawnProbe{ .manager_context = manager.managerContext() };
    _ = try kernel.scheduler.spawn(.{
        .entry = nestedSpawnEntry,
        .argument = &probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    try testing.expect(probe.child_probe.entered);
    try testing.expectEqual(probe.child_pid_bits, probe.child_probe.observed_self_pid_bits);
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    try kernel.expectExactAccounting();
}
