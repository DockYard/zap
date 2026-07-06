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
//! — the API compiler-inserted safepoints will call from Phase 2 on;
//! Phase 1 kernel tests call it explicitly — decrements the budget and
//! yields when it reaches zero, when the watchdog flag is set, or when a
//! kill is pending. The watchdog is FLAG-ONLY in Phase 1: any thread may
//! set it (`requestWatchdogPreemption`), the running process observes it
//! at its next yieldCheck and yields, and the scheduler clears it at the
//! end of that quantum (one-shot consume). The timer thread that sets it
//! periodically is Phase 4; tests exercise the seam by setting the flag
//! directly.
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
    /// Kill requested (untrappable). Scheduler-thread only: set by
    /// `kill`, observed at scheduling points and safepoints.
    pending_kill: bool,
    /// True while this record sits on the scheduler's wake stack —
    /// coalesces concurrent wake signals into one entry. Any thread CASes
    /// it false→true (push); the scheduler resets it when consuming.
    wake_pending: std.atomic.Value(bool),
    /// Intrusive Treiber link in the scheduler's wake stack. Written by
    /// the pushing thread before the head CAS publishes it.
    wake_next: ?*ProcessRecord,
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
};

/// Default spin iterations before parking: sized to the E9 crossover
/// (spin ~1–2 µs — a few hundred `spinLoopHint`s on M4 — before paying
/// the ~900 ns parked-wake cost; plan A.2.3).
pub const default_spin_iterations_before_park: u32 = 512;

/// Default bound on one futex park (defense-in-depth re-check period; the
/// eventcount protocol needs no timeout for correctness — see the module
/// doc's parking section).
pub const default_park_timeout_nanoseconds: u64 = 100 * std.time.ns_per_ms;

/// The Phase 1 single scheduler (plan 1.4/1.5; instance-based — see the
/// module doc). NOT thread-safe as a whole: exactly one thread drives
/// `spawn`/`kill`/`runUntilQuiescent`/`statistics`; the documented
/// cross-thread surface is `wake()`, `requestWatchdogPreemption()`,
/// `parkCount()`, and the mailbox-push wake seam. The value is PINNED
/// from the first `spawn` on (records hold back-pointers).
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
    /// Saved scheduler-side cpu state while a process fiber runs.
    fiber_scheduler_context: fiber_context.SchedulerContext,
    /// THE per-quantum current process (plan A.2.4/E10): written once at
    /// quantum entry, cleared at quantum exit, null between quanta.
    /// Kernel code never reads it on hot paths — it receives the process
    /// as a parameter; this field is the seam Phase 2's compiled-code
    /// exposure hooks into (module doc).
    current_process: ?*ProcessControlBlock,

    // -- ready queue (scheduler-thread only) --------------------------------
    /// Intrusive FIFO of `.runnable` processes: oldest.
    ready_head: ?*ProcessRecord,
    /// Newest.
    ready_tail: ?*ProcessRecord,
    /// Queue length.
    ready_count: usize,

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
            .stack_pool = StackPool.init(.{ .usable_size = options.stack_usable_size }),
            .options = options,
            .fiber_scheduler_context = .{},
            .current_process = null,
            .ready_head = null,
            .ready_tail = null,
            .ready_count = 0,
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
        };
    }

    /// Tear the scheduler down. Every process must already have exited or
    /// been killed (`shutdownAllProcesses` handles stragglers) — asserted.
    /// Frees the record cache and the stack pool.
    pub fn deinit(scheduler: *Scheduler) void {
        std.debug.assert(scheduler.live_record_count == 0);
        std.debug.assert(scheduler.ready_count == 0);
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
        record.wake_pending = .init(false);
        record.wake_next = null;
        ProcessControlBlock.init(&record.pcb, kernel_fiber, options.manager);
        errdefer fiber_context.reclaimWithoutResume(&record.pcb.fiber);

        const pid = try record.pcb.register(scheduler.pid_table, options.model);
        record.envelope_handle = EnvelopePool.Handle.init(scheduler.envelope_pool);
        record.pcb.mailbox.wake_callback = mailboxWakeCallback;
        record.pcb.mailbox.wake_context = record;

        record.pcb.transitionTo(.runnable);
        scheduler.readyEnqueue(record);
        scheduler.live_record_count += 1;
        if (scheduler.live_record_count > scheduler.live_record_peak) {
            scheduler.live_record_peak = scheduler.live_record_count;
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
        switch (target_pcb.state) {
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
                    if (live.pcb.state == .waiting) {
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
    // Run loop (module doc)
    // -------------------------------------------------------------------------

    /// Run until every process has exited (quiescence). Parks when idle
    /// under `.futex_park`; surfaces `error.AllProcessesWaiting` under
    /// `.forbid_parking` (deterministic mode). Scheduler-thread only.
    pub fn runUntilQuiescent(scheduler: *Scheduler) RunError!void {
        while (true) {
            scheduler.drainWakeStack();
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
                .futex_park => scheduler.parkUntilWakeSignal(),
                .forbid_parking => {
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
        pcb.transitionTo(.running);
        pcb.preemption_budget = scheduler.options.decisions.vtable.chooseQuantumBudget(
            scheduler.options.decisions.decision_context,
            scheduler.options.preemption_budget,
        );
        scheduler.emitTrace(.schedule, pcb.pid);
        scheduler.quantum_total += 1;
        scheduler.current_process = pcb;
        const outcome = fiber_context.resumeFiber(&scheduler.fiber_scheduler_context, &pcb.fiber);
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
                        // A push that raced the final empty-check already
                        // fired the wake seam; the wake-stack drain at the
                        // top of the run loop converts it to runnable —
                        // no lost-wake window (module doc).
                    },
                }
            },
        }
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
        std.debug.assert(scheduler.live_record_count > 0);
        scheduler.live_record_count -= 1;
        scheduler.recycleRecord(record);
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

    fn readyEnqueue(scheduler: *Scheduler, record: *ProcessRecord) void {
        record.ready_next = null;
        if (scheduler.ready_tail) |tail| {
            tail.ready_next = record;
        } else {
            scheduler.ready_head = record;
        }
        scheduler.ready_tail = record;
        scheduler.ready_count += 1;
    }

    /// Pick the next runnable process through the Decisions seam.
    fn dequeueNextRunnable(scheduler: *Scheduler) ?*ProcessRecord {
        if (scheduler.ready_count == 0) return null;
        const chosen_index = scheduler.options.decisions.vtable.chooseNextReadyIndex(
            scheduler.options.decisions.decision_context,
            scheduler.ready_count,
        );
        std.debug.assert(chosen_index < scheduler.ready_count);
        return scheduler.dequeueReadyAt(chosen_index);
    }

    /// Unlink and return the `index`-th queued record (0 = oldest), or
    /// null when the queue is empty. O(index) — production FIFO always
    /// asks for 0.
    fn dequeueReadyAt(scheduler: *Scheduler, index: usize) ?*ProcessRecord {
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

    // -------------------------------------------------------------------------
    // Wake stack (cross-thread producers, scheduler consumer)
    // -------------------------------------------------------------------------

    /// Consume every pending wake signal: pop-all (swap — no ABA),
    /// restore push order, and convert `.waiting` targets to runnable.
    /// Targets in any other state are no-ops (module doc).
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
            // Re-arm the coalescing flag BEFORE inspecting state so a
            // producer signaling right now pushes a fresh entry rather
            // than being lost.
            record.wake_pending.store(false, .seq_cst);
            const pcb = &record.pcb;
            if (pcb.state == .waiting) {
                pcb.transitionTo(.runnable);
                scheduler.readyEnqueue(record);
                scheduler.emitTrace(.wake, pcb.pid);
            }
        }
    }

    /// The mailbox wake seam (installed per process at spawn): runs on
    /// the PRODUCER's thread after the empty→nonempty push. Coalesces via
    /// the record's wake-pending flag, publishes the record on the wake
    /// stack, and signals the futex. Cheap, non-blocking, thread-safe —
    /// the seam's contract (`mailbox.zig`).
    fn mailboxWakeCallback(wake_context: ?*anyopaque) void {
        const record: *ProcessRecord = @ptrCast(@alignCast(wake_context.?));
        if (record.wake_pending.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            return; // already signaled; the pending entry covers this wake
        }
        const scheduler = record.scheduler;
        var observed_head = scheduler.wake_stack_head.load(.monotonic);
        while (true) {
            record.wake_next = observed_head;
            observed_head = scheduler.wake_stack_head.cmpxchgWeak(
                observed_head,
                record,
                .release,
                .monotonic,
            ) orelse break;
        }
        scheduler.wake();
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
            scheduler.options.park_timeout_nanoseconds,
        );
        scheduler.parked_hint.store(false, .seq_cst);
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
/// finishes the fiber (normal exit).
fn processFiberEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    const record: *ProcessRecord = @ptrCast(@alignCast(argument.?));
    var context = ProcessContext{
        .scheduler = record.scheduler,
        .record = record,
        .execution = execution,
    };
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
    try testing.expectEqual(process_module.ProcessState.runnable, pcb.state);
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
