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
pub const ParkState = enum(u8) {
    /// Running or runnable — not suspended. A wake seam `swap(.notified)`
    /// displacing this is a no-op (the process observes the message itself).
    running,
    /// Suspended on an empty mailbox — a wake must revive it. A wake seam
    /// `swap(.notified)` displacing this means the displacing producer owns the
    /// revival.
    parked,
    /// A message arrived in the park window (the wake seam swapped this in over
    /// `.running`): the process's own park attempt sees it and self-revives
    /// instead of suspending, so the wake is never lost.
    notified,
};

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
    /// `.waiting_for_message_deadline` suspension (`receive … after`).
    /// Meaningful only while the record is `.waiting` with that yield
    /// reason; ignored otherwise. Scheduler-thread only.
    wake_deadline_nanoseconds: u64,
    /// Set by the scheduler when it wakes a timed waiter because its
    /// deadline elapsed (rather than a message arriving); read and cleared
    /// by `receiveWaitTimeout` on resume. Scheduler-thread + owning-fiber
    /// (same thread) only.
    receive_timed_out: bool,
    /// Kill requested (untrappable). Scheduler-thread only: set by
    /// `kill`, observed at scheduling points and safepoints.
    pending_kill: bool,
    /// The cross-thread wake handshake state (P4-J1; see `ParkState`). A
    /// spawned process is `.running`; the scheduler suspending it publishes
    /// `.parked`; the unique `.parked → .running` CAS winner (a producer that
    /// delivered a message, or the suspending scheduler's own re-check) owns the
    /// revival and pushes the record onto a scheduler's wake stack exactly once.
    /// Replaces the Phase-1 `wake_pending` coalescing flag: the CAS both
    /// coalesces (one winner) and arbitrates the park/signal race, which a plain
    /// flag could not do across two scheduler threads.
    park_state: std.atomic.Value(ParkState),
    /// Intrusive Treiber link in the target scheduler's wake stack. Written by
    /// the revival CAS winner before the head CAS publishes it.
    wake_next: ?*ProcessRecord,
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
        if (pcb.preemption_budget == 0 or watchdog_requested or record.pending_kill) {
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
        if (record.pending_kill or watchdog_requested or scheduler.ready_count > 0) {
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
            if (record.pending_kill) {
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

    /// Blocking receive with a timeout — the `receive … after` mechanism
    /// (plan item 2.3, P2-J3). Parks (non-consuming) until a message is at
    /// the mailbox head or `timeout_nanoseconds` elapses, returning which
    /// happened WITHOUT consuming the message (a following `receive`
    /// pops it). `timeout_nanoseconds == 0` polls once without parking
    /// (`after 0`). A message that races the deadline wins. If the process
    /// is killed while waiting, the suspension never returns.
    pub fn receiveWaitTimeout(context: *ProcessContext, timeout_nanoseconds: u64) ReceiveWaitOutcome {
        const record = context.record;

        // `after 0`: poll once without parking. A bounded spin resolves a
        // producer mid-publish (a materializing message the poll must see).
        if (timeout_nanoseconds == 0) {
            var gap_spins: u32 = 0;
            while (true) {
                if (record.pending_kill) {
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                    continue;
                }
                switch (record.pcb.mailbox.peek()) {
                    .available => return .message_available,
                    .empty => return .timed_out,
                    .transient_gap => {
                        gap_spins += 1;
                        if (gap_spins >= poll_transient_gap_spin_limit) return .timed_out;
                        std.atomic.spinLoopHint();
                    },
                }
            }
        }

        const deadline_nanoseconds = monotonicNowNanoseconds() +| timeout_nanoseconds;
        while (true) {
            if (record.pending_kill) {
                record.yield_reason = .reenqueue;
                context.execution.yield();
                continue;
            }
            switch (record.pcb.mailbox.peek()) {
                .available => return .message_available,
                .transient_gap => {
                    // A producer is mid-publish — a message is arriving.
                    // Retry next quantum rather than parking on it.
                    record.yield_reason = .reenqueue;
                    context.execution.yield();
                },
                .empty => {
                    if (monotonicNowNanoseconds() >= deadline_nanoseconds) return .timed_out;
                    // Park with the deadline: the scheduler re-runs this
                    // process on a message wake OR when the deadline
                    // elapses (setting `receive_timed_out`).
                    record.receive_timed_out = false;
                    record.wake_deadline_nanoseconds = deadline_nanoseconds;
                    record.yield_reason = .waiting_for_message_deadline;
                    context.execution.yield();
                    if (record.receive_timed_out) {
                        record.receive_timed_out = false;
                        // A message that raced the timeout wins.
                        if (record.pcb.mailbox.peek() == .available) return .message_available;
                        return .timed_out;
                    }
                    // Message wake or spurious resume: loop re-checks the
                    // mailbox and the deadline.
                },
            }
        }
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

    /// Count of `.waiting` processes suspended with a `receive … after`
    /// deadline. Zero for any program that never uses `after`, so the
    /// run loop's deadline scan (`fireExpiredReceiveTimeouts`) and the
    /// deadline-bounded idle park are entirely skipped — the zero-`after`
    /// fast path. Recomputed exactly by each `fireExpiredReceiveTimeouts`
    /// scan (so a message-woken or killed timed waiter self-corrects the
    /// count on the next scan). Scheduler-thread only.
    timed_waiter_count: usize,
    /// The earliest not-yet-expired timed-waiter deadline (absolute
    /// monotonic ns), or 0 when there are none. Written by
    /// `fireExpiredReceiveTimeouts`; read by the idle park to bound its
    /// futex wait so a timeout fires on schedule. Scheduler-thread only.
    earliest_deadline_nanoseconds: u64,

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
    /// and unused when `work_stealing` is false.
    runnext: ?*ProcessRecord,
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
            .timed_waiter_count = 0,
            .earliest_deadline_nanoseconds = 0,
            .work_stealing = options.work_stealing,
            .runnext = null,
            .ready_head = null,
            .ready_tail = null,
            .ready_count = 0,
            .run_queue_lock = .unlocked,
            .free_records = null,
            .cached_record_count = 0,
            .live_record_count = 0,
            .live_record_peak = 0,
            .wake_stack_head = .init(null),
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
        while (scheduler.free_records) |record| {
            scheduler.free_records = record.ready_next;
            scheduler.backing_allocator.destroy(record);
        }
        scheduler.cached_record_count = 0;
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
        record.pending_kill = false;
        record.park_state = .init(.running);
        record.wake_next = null;
        record.active_context = null;
        record.wake_deadline_nanoseconds = 0;
        record.receive_timed_out = false;
        ProcessControlBlock.init(&record.pcb, kernel_fiber, options.manager);
        errdefer fiber_context.reclaimWithoutResume(&record.pcb.fiber);

        const pid = try record.pcb.register(scheduler.pid_table, options.model);
        record.envelope_handle = EnvelopePool.Handle.init(scheduler.envelope_pool);
        record.pcb.mailbox.wake_callback = mailboxWakeCallback;
        record.pcb.mailbox.wake_context = record;

        record.pcb.transitionTo(.runnable);
        scheduler.readyEnqueue(record);
        // Live count: the pool's authoritative count under M:N (a stolen
        // process is torn down on a different core, so a per-scheduler count
        // would drift); the per-scheduler count for a standalone scheduler.
        if (scheduler.pool_hooks) |hooks| {
            hooks.liveCountDelta(hooks.context, 1);
        } else {
            scheduler.live_record_count += 1;
            if (scheduler.live_record_count > scheduler.live_record_peak) {
                scheduler.live_record_peak = scheduler.live_record_count;
            }
        }
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
                scheduler.teardownProcess(record, .killed);
                return .killed;
            },
            .runnable, .running => {
                record.pending_kill = true;
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
                scheduler.teardownProcess(record, .killed);
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
            scheduler.teardownProcess(waiting_record, .killed);
        }
        // Every live process is either runnable (queued) or waiting, so
        // the two sweeps above are exhaustive.
        std.debug.assert(scheduler.live_record_count == 0);
    }

    // -------------------------------------------------------------------------
    // `receive … after` timeout firing (plan item 2.3, P2-J3)
    // -------------------------------------------------------------------------

    /// Fire every `receive … after` waiter whose deadline has elapsed —
    /// make it runnable and mark `receive_timed_out` — and recompute
    /// `timed_waiter_count` + `earliest_deadline_nanoseconds` from the live
    /// set (so a message-woken or killed timed waiter self-corrects the
    /// count here rather than needing a decrement on every wake/kill path).
    /// A no-op when no timed waiters exist — the zero-`after` fast path.
    /// Scheduler-thread only; runs at the top of every run-loop iteration.
    fn fireExpiredReceiveTimeouts(scheduler: *Scheduler) void {
        if (scheduler.timed_waiter_count == 0) {
            scheduler.earliest_deadline_nanoseconds = 0;
            return;
        }
        const now = monotonicNowNanoseconds();
        var remaining: usize = 0;
        var earliest: u64 = 0;
        var iterator = scheduler.pid_table.iterateLiveProcesses();
        while (iterator.next()) |live| {
            const pcb = live.pcb;
            const record: *ProcessRecord = @fieldParentPtr("pcb", pcb);
            // Handshake state (acquire) FIRST: only a genuinely `.parked`
            // process has its deadline fields published (the parker released
            // `.parked` after writing `yield_reason`/`wake_deadline`), so this
            // acquire is what makes the non-atomic reads below race-free when a
            // sibling scheduler scans the same shared pid table (P4-J1).
            if (record.park_state.load(.acquire) != .parked) continue;
            if (record.yield_reason != .waiting_for_message_deadline) continue;
            if (now >= record.wake_deadline_nanoseconds) {
                // Win the revival against a racing message wake: only the
                // `.parked → .running` CAS winner fires the timeout. A loss
                // means a producer notified this waiter (`.notified`) and its
                // wake owns the enqueue — skip it here.
                if (record.park_state.cmpxchgStrong(.parked, .running, .seq_cst, .seq_cst) == null) {
                    record.receive_timed_out = true;
                    pcb.transitionTo(.runnable);
                    scheduler.readyEnqueue(record);
                    scheduler.emitTrace(.wake, pcb.pid);
                }
            } else {
                remaining += 1;
                if (earliest == 0 or record.wake_deadline_nanoseconds < earliest) {
                    earliest = record.wake_deadline_nanoseconds;
                }
            }
        }
        scheduler.timed_waiter_count = remaining;
        scheduler.earliest_deadline_nanoseconds = earliest;
    }

    /// Deterministic-mode (`.forbid_parking`) timeout firing: with no wall
    /// clock to sleep on, when nothing else can run, advance virtual time
    /// to the EARLIEST timed-waiter deadline and fire exactly that waiter.
    /// Returns whether one was fired. This is what gives `receive … after`
    /// deterministic semantics under the seeded scheduler (a timeout fires
    /// precisely when the system would otherwise deadlock). Scheduler-thread
    /// only.
    fn fireEarliestReceiveTimeout(scheduler: *Scheduler) bool {
        if (scheduler.timed_waiter_count == 0) return false;
        var earliest_record: ?*ProcessRecord = null;
        var live_timed_waiters: usize = 0;
        var iterator = scheduler.pid_table.iterateLiveProcesses();
        while (iterator.next()) |live| {
            const pcb = live.pcb;
            const record: *ProcessRecord = @fieldParentPtr("pcb", pcb);
            // Handshake acquire before the non-atomic deadline read (see
            // `fireExpiredReceiveTimeouts`). Deterministic mode is single-
            // threaded, so `.parked` always holds for a live timed waiter here.
            if (record.park_state.load(.acquire) != .parked) continue;
            if (record.yield_reason != .waiting_for_message_deadline) continue;
            live_timed_waiters += 1;
            const current = earliest_record orelse {
                earliest_record = record;
                continue;
            };
            if (record.wake_deadline_nanoseconds < current.wake_deadline_nanoseconds) {
                earliest_record = record;
            }
        }
        const fire = earliest_record orelse {
            scheduler.timed_waiter_count = 0;
            scheduler.earliest_deadline_nanoseconds = 0;
            return false;
        };
        // Win the revival against a racing message wake (a no-op contention in
        // single-threaded deterministic mode). If a producer notified it first,
        // fall through and re-scan next call.
        if (fire.park_state.cmpxchgStrong(.parked, .running, .seq_cst, .seq_cst) != null) {
            scheduler.timed_waiter_count = live_timed_waiters;
            return true;
        }
        fire.receive_timed_out = true;
        fire.pcb.transitionTo(.runnable);
        scheduler.readyEnqueue(fire);
        scheduler.emitTrace(.wake, fire.pcb.pid);
        scheduler.timed_waiter_count = live_timed_waiters - 1;
        return true;
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
            scheduler.fireExpiredReceiveTimeouts();
            if (scheduler.dequeueNextRunnable()) |record| {
                if (record.pending_kill) {
                    // Killed while queued: torn down without ever running
                    // (legal `runnable → exiting`).
                    scheduler.teardownProcess(record, .killed);
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
            scheduler.fireExpiredReceiveTimeouts();
            if (scheduler.dequeueNextRunnable()) |record| {
                if (record.pending_kill) {
                    // Killed while queued: torn down without ever running
                    // (legal `runnable → exiting`).
                    scheduler.teardownProcess(record, .killed);
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

    /// Service this core's cross-thread events once: convert freshly-woken
    /// processes to runnable (drain the wake stack) and fire any elapsed
    /// `receive … after` deadlines. Run at the top of every worker iteration.
    pub fn serviceLocalEvents(scheduler: *Scheduler) void {
        scheduler.drainWakeStack();
        scheduler.fireExpiredReceiveTimeouts();
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
        if (record.pending_kill) {
            scheduler.teardownProcess(record, .killed);
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
        scheduler.teardownProcess(record, .killed);
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
            .finished => scheduler.teardownProcess(record, .normal),
            .yielded => {
                if (record.pending_kill) {
                    // Killed at a safepoint (or while it happened to
                    // yield): `running → exiting`.
                    scheduler.teardownProcess(record, .killed);
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
                        scheduler.emitTrace(.wait, pcb.pid);
                        pcb.transitionTo(.waiting);
                        // A `receive … after` waiter: same handshake, and it is
                        // countable so the run loop scans deadlines and bounds
                        // its idle park — but ONLY while it actually stayed
                        // parked. If the re-check revived it (a message beat the
                        // park), it is runnable, not a timed waiter. The count
                        // self-corrects on the next scan regardless (a woken or
                        // killed waiter is no longer a `.waiting` deadline
                        // waiter), so it is only ever incremented here.
                        if (scheduler.commitPark(record)) {
                            scheduler.timed_waiter_count += 1;
                        }
                    },
                }
            },
        }
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
        if (record.park_state.cmpxchgStrong(.running, .parked, .seq_cst, .seq_cst)) |observed| {
            // Not `.running`: a message landed in the park window (`.notified`).
            // The suspension is resolved by that message — a genuine wakeup, so
            // emit `.wake` (the trace's "a waiting process became runnable"
            // event) exactly as the wake-stack drain does for a message that
            // arrives after the park commits. This keeps the wait/wake tallies
            // matched and the deterministic trace complete.
            std.debug.assert(observed == .notified);
            record.park_state.store(.running, .seq_cst);
            pcb.transitionTo(.runnable);
            scheduler.emitTrace(.wake, pcb.pid);
            scheduler.reviveEnqueue(record);
            return false;
        }
        return true;
    }

    // -------------------------------------------------------------------------
    // Teardown (module doc, "Exit and crash teardown" — the ONE path)
    // -------------------------------------------------------------------------

    fn teardownProcess(scheduler: *Scheduler, record: *ProcessRecord, reason: ExitReason) void {
        const pcb = &record.pcb;
        const exit_pid = pcb.pid; // captured: unregister resets it

        // (1) Crash report FIRST (plan 1.6, `crash_report.zig`): the
        // report snapshots the pid, state, mailbox depth, and — for a
        // suspended fiber — the stack trace from the last suspend point,
        // all of which the steps below destroy.
        if (scheduler.options.crash_report_hook) |report_hook| {
            const report = crash_report_module.captureForTeardown(pcb, reason);
            report_hook(scheduler.options.crash_report_context, &report);
        }

        pcb.transitionTo(.exiting);

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

        // (5) Drain the mailbox: every envelope back to its origin page.
        drainMailboxForTeardown(&pcb.mailbox);

        // (6) Abandon the sender side: empty pages return now; in-flight
        // pages flip to `.abandoned` for their receivers to reclaim.
        record.envelope_handle.abandon();

        // (7) Stack via the invariant path.
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

        // (8) Wholesale heap free (plan Phase 1 item 1.4: bulk arena/slab
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

    fn drainMailboxForTeardown(mailbox: *mailbox_module.Mailbox) void {
        var consecutive_gap_spins: u32 = 0;
        while (true) {
            switch (mailbox.pop()) {
                .envelope => |envelope| {
                    // Leak-exactness for an undelivered MOVED payload: the graph
                    // was detached from a sender but this receiver dies before
                    // adopting it, so reclaim it (munmap) before the header goes
                    // back to the pool. A copied payload's ledger block is
                    // reclaimed at runtime-ledger teardown, as before.
                    if (envelope.fragment.moved_reclaim) |reclaim| {
                        if (envelope.fragment.payload_pointer) |payload| reclaim(payload);
                        envelope.fragment = .{};
                    }
                    envelope_pool_module.free(envelope);
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
    /// then the FIFO through the Decisions seam. Owner-thread only.
    fn dequeueNextRunnable(scheduler: *Scheduler) ?*ProcessRecord {
        if (scheduler.work_stealing) {
            if (scheduler.runnext) |record| {
                scheduler.runnext = null;
                return record;
            }
        }
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
    /// core. Both queues are taken under their own `run_queue_lock`, thief
    /// first then victim, in the fixed pool-index order the pool's steal loop
    /// enforces (thief only steals from higher-... — see `SchedulerPool.steal`),
    /// so no two schedulers ever lock the same pair in opposite orders. Returns
    /// 0 when the victim has nothing stealable. Runs on the THIEF's thread.
    pub fn stealInto(victim: *Scheduler, thief: *Scheduler) usize {
        std.debug.assert(victim.work_stealing and thief.work_stealing);
        std.debug.assert(victim != thief);
        // Snapshot half the victim's FIFO under the victim lock into a local
        // detached chain, releasing the victim lock before touching the thief
        // queue (so the two locks are never held nested here — the pool's steal
        // order is what prevents A-steals-B / B-steals-A deadlock).
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
            // before pushing this record, so this core is its sole reviver.
            // Reset the handshake to `.running` for the process's next life, and
            // if it is still `.waiting` (not torn down between park and drain)
            // make it runnable and enqueue it (LIFO slot under `work_stealing`).
            record.park_state.store(.running, .seq_cst);
            if (pcb.currentState() == .waiting) {
                pcb.transitionTo(.runnable);
                scheduler.reviveEnqueue(record);
                scheduler.emitTrace(.wake, pcb.pid);
            }
        }
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
        // Mark the process notified (single seq_cst RMW — the whole handshake
        // linearizes here). Only if this displaced `.parked` was the process
        // actually suspended and does THIS producer own its revival; displacing
        // `.running`/`.notified` means the process is active (it will observe
        // the message via its own receive, or self-revive at `commitPark`) — no
        // push. The message push in `mailbox.push` is sequenced-before this RMW,
        // so the reviver sees it.
        if (record.park_state.swap(.notified, .seq_cst) != .parked) return;
        // We own the revival. Route onto the producer's core for wake locality;
        // a foreign producer falls back to the target's last-running scheduler.
        const target = current_scheduler orelse record.scheduler;
        pushWake(target, record);
    }

    // -------------------------------------------------------------------------
    // Idle parking (module doc, "Idle parking")
    // -------------------------------------------------------------------------

    fn parkUntilWakeSignal(scheduler: *Scheduler) void {
        // Spin phase: E9 crossover — a handoff lands in ~83 ns while a
        // parked wake costs ~900 ns, so spend up to ~1–2 µs spinning
        // before paying a park.
        var spin_iteration: u32 = 0;
        while (spin_iteration < scheduler.options.spin_iterations_before_park) : (spin_iteration += 1) {
            if (scheduler.wake_stack_head.load(.acquire) != null) return;
            std.atomic.spinLoopHint();
        }

        // Eventcount park: the futex value check closes the race between
        // the work re-check and the wait entry (module doc).
        const observed_epoch = scheduler.wake_epoch.load(.seq_cst);
        if (scheduler.wake_stack_head.load(.acquire) != null) return;
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
    /// `receive … after` deadline so that timeout fires on schedule (the
    /// wake then re-runs the loop, whose `fireExpiredReceiveTimeouts` makes
    /// the expired waiter runnable). No timed waiters ⇒ the default bound.
    fn idleParkTimeoutNanoseconds(scheduler: *Scheduler) u64 {
        const default_bound = scheduler.options.park_timeout_nanoseconds;
        const deadline = scheduler.earliest_deadline_nanoseconds;
        if (deadline == 0) return default_bound;
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
        return scheduler.backing_allocator.create(ProcessRecord);
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

/// OS futex wait/wake over a 32-bit word. Darwin: `os_sync_*` (macOS ≥
/// 14.4 minimum-target) or `__ulock_*` (the fork's own `Io.Threaded`
/// primitive pair, comptime-gated the same way). Linux: `futex(2)`.
/// Waits are always time-bounded and may return spuriously — callers
/// re-check their condition in a loop (the scheduler's run loop does).
const parking_futex = struct {
    fn waitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
        switch (comptime builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
                darwinWaitBounded(word, expected, timeout_nanoseconds);
            },
            .linux => linuxWaitBounded(word, expected, timeout_nanoseconds),
            else => @compileError(
                "scheduler idle parking is not implemented for this OS (Phase 4/7 ports)",
            ),
        }
    }

    fn wakeOne(word: *std.atomic.Value(u32)) void {
        switch (comptime builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => darwinWakeOne(word),
            .linux => linuxWakeOne(word),
            else => @compileError(
                "scheduler idle parking is not implemented for this OS (Phase 4/7 ports)",
            ),
        }
    }

    // -- Darwin ---------------------------------------------------------------

    /// Whether the minimum targeted Darwin version has the public
    /// `os_sync_wait_on_address` family (macOS 14.4). Gated at comptime
    /// on `builtin.os.version_range` exactly as the fork's `Io.Threaded`
    /// gates `__ulock_wait2` (macOS 11).
    const darwin_minimum_target_has_os_sync = darwin_gate: {
        if (!builtin.os.tag.isDarwin()) break :darwin_gate false;
        const minimum = builtin.os.version_range.semver.min;
        break :darwin_gate minimum.order(.{ .major = 14, .minor = 4, .patch = 0 }) != .lt;
    };

    /// See the fork's `Io/Threaded.zig` `darwin_supports_ulock_wait2`.
    const darwin_minimum_target_has_ulock_wait2 = darwin_gate: {
        if (!builtin.os.tag.isDarwin()) break :darwin_gate false;
        break :darwin_gate builtin.os.version_range.semver.min.major >= 11;
    };

    /// `OS_SYNC_WAIT_ON_ADDRESS_NONE` / `OS_SYNC_WAKE_BY_ADDRESS_NONE`
    /// from `<os/os_sync_wait_on_address.h>`.
    const os_sync_flags_none: u32 = 0;
    /// `OS_CLOCK_MACH_ABSOLUTE_TIME` from `<os/clock.h>` — the only clock
    /// id the os_sync timeout API accepts as of macOS 14.4.
    const os_clock_mach_absolute_time: u32 = 32;

    extern "c" fn os_sync_wait_on_address_with_timeout(
        addr: *anyopaque,
        value: u64,
        size: usize,
        flags: u32,
        clockid: u32,
        timeout_ns: u64,
    ) c_int;
    extern "c" fn os_sync_wake_by_address_any(addr: *anyopaque, size: usize, flags: u32) c_int;

    const darwin_ulock_flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };

    fn darwinWaitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
        // Timeout 0 means "infinite" to both APIs; the caller always
        // bounds the wait, and a zero bound degenerates to a re-check.
        const bounded_timeout = @max(timeout_nanoseconds, 1);
        if (comptime darwin_minimum_target_has_os_sync) {
            const return_code = os_sync_wait_on_address_with_timeout(
                &word.raw,
                expected,
                @sizeOf(u32),
                os_sync_flags_none,
                os_clock_mach_absolute_time,
                bounded_timeout,
            );
            if (return_code >= 0) return;
            switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
                // Spurious return, paged-out word, or timeout: the caller
                // re-checks its condition either way.
                .INTR, .FAULT, .TIMEDOUT => {},
                else => unreachable, // misuse of the futex word — kernel bug
            }
            return;
        }
        const status = if (comptime darwin_minimum_target_has_ulock_wait2)
            std.c.__ulock_wait2(darwin_ulock_flags, &word.raw, expected, bounded_timeout, 0)
        else
            std.c.__ulock_wait(
                darwin_ulock_flags,
                &word.raw,
                expected,
                @max(std.math.lossyCast(u32, bounded_timeout / std.time.ns_per_us), 1),
            );
        if (status >= 0) return;
        switch (@as(std.c.E, @enumFromInt(-status))) {
            .INTR, .FAULT, .TIMEDOUT => {},
            else => unreachable, // misuse of the futex word — kernel bug
        }
    }

    fn darwinWakeOne(word: *std.atomic.Value(u32)) void {
        if (comptime darwin_minimum_target_has_os_sync) {
            const return_code = os_sync_wake_by_address_any(&word.raw, @sizeOf(u32), os_sync_flags_none);
            if (return_code >= 0) return;
            switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
                .NOENT => {}, // nobody parked — the desired no-op
                else => unreachable,
            }
            return;
        }
        while (true) {
            const status = std.c.__ulock_wake(darwin_ulock_flags, &word.raw, 0);
            if (status >= 0) return;
            switch (@as(std.c.E, @enumFromInt(-status))) {
                .INTR, .CANCELED => continue,
                .NOENT => return, // nobody parked — the desired no-op
                else => unreachable,
            }
        }
    }

    // -- Linux ------------------------------------------------------------------

    fn linuxWaitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
        const linux = std.os.linux;
        const timeout = linux.timespec{
            .sec = @intCast(timeout_nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(timeout_nanoseconds % std.time.ns_per_s),
        };
        const return_code = linux.futex_4arg(
            &word.raw,
            .{ .cmd = .WAIT, .private = true },
            expected,
            &timeout,
        );
        switch (linux.errno(return_code)) {
            // Woken, raced (word already changed), interrupted, or timed
            // out: the caller re-checks its condition either way.
            .SUCCESS, .AGAIN, .INTR, .TIMEDOUT => {},
            else => unreachable, // misuse of the futex word — kernel bug
        }
    }

    fn linuxWakeOne(word: *std.atomic.Value(u32)) void {
        const linux = std.os.linux;
        _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }
};

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
