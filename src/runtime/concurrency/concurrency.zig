//! Zap concurrency runtime kernel — root module.
//!
//! The Zig-side kernel of the concurrency campaign
//! (`docs/concurrency-implementation-plan.md` §3/§4): the genuine runtime
//! primitives that BEAM-style Zap processes stand on. Per the plan's
//! division of labor, ONLY scheduler/fiber/memory mechanics live here;
//! everything user-facing (`Process`, `Task`, `Supervisor`, `receive`
//! semantics) is Zap code in `lib/*.zap` layered on intrinsics in later
//! phases.
//!
//! ## The scheduler model (P1-J4)
//!
//! Phase 1 runs ONE bespoke run-queue scheduler built directly on the
//! fork's `std.Io.fiber` context switch (the Appendix A / S0.5 decision):
//! processes are COOPERATIVE — a quantum runs until the process yields,
//! suspends on its mailbox, exhausts its preemption budget at a
//! `yieldCheck` safepoint, observes the flag-only watchdog, or exits —
//! and the scheduler parks on an OS futex when nothing is runnable
//! (Darwin: `os_sync_wait_on_address`/`__ulock` per E9; spin ~1–2 µs
//! first). Every structure is INSTANCE-based (no module-level mutable
//! state): Phase 4 multiplies scheduler instances over the shared,
//! already-M:N-safe pid table and envelope pool for the per-core
//! queues + LIFO slot + work-stealing design of research.md §6.1.
//!
//! A seeded DETERMINISTIC mode (plan 1.5, decision 11) funnels all
//! scheduler nondeterminism — next-runnable choice, per-quantum budget —
//! through the `Decisions` seam: same seed ⇒ byte-identical event trace,
//! single-threaded, parking forbidden; a failing seeded scenario prints
//! its seed for exact replay (`deterministic.zig`).
//!
//! ## Phase status
//!
//! Phase 1, jobs P1-J1 (kernel skeleton, plan item 1.1), P1-J2
//! (generational pid table, plan item 1.2), P1-J3 (mailbox +
//! envelope pool, plan item 1.3), P1-J4 (scheduler core, plan items
//! 1.4 + 1.5), and P1-J5 (observability + crash reports + teardown
//! stress, plan items 1.6 + 1.7):
//!
//! * `stack_pool.zig` — pooled fixed-reservation guard-paged lazy-commit
//!   fiber stacks with a live-peak-bounded free list (plan A.2.1).
//! * `fiber_context.zig` — fiber create/resume/yield/finish over the
//!   fork's `std.Io.fiber` primitive, structurally enforcing the
//!   stack-lifetime invariant from the G2 triage (a finished fiber's stack
//!   is released only by the scheduler, after the final switch away).
//! * `process.zig` — the process control block: fiber + manager context +
//!   mailbox + preemption budget + drop-list head + state machine + pid
//!   identity (register/unregister seams for 1.4).
//! * `pid_table.zig` — generational pid table: packed `{slot, generation,
//!   model, node}` pids (§2.4 invariant: generation+model validated as
//!   one atomic unit, dead-letter on mismatch), lock-free tagged free
//!   list, and OTP-28-style snapshot-free live-process iteration.
//! * `mailbox.zig` — Vyukov intrusive MPSC mailbox over envelopes: one
//!   XCHG per push (wait-free producers), single-consumer pop with the
//!   null-next-but-nonempty transient gap surfaced as its own outcome,
//!   exact empty→nonempty wake-signal seam, approximate depth counter.
//! * `envelope_pool.zig` — the shared envelope page pool (the third
//!   allocation domain: in-flight envelopes owned by neither manager)
//!   with mimalloc-style abandon/reclaim for sender death and a
//!   high-watermark-bounded empty-page cache.
//! * `scheduler.zig` — spawn (pool-only hot path, eager pooled stack +
//!   lazy entry frame), the run loop (intrusive-FIFO ready queue +
//!   `Decisions` seam), preemption budgets + `yieldCheck`, the flag-only
//!   watchdog seam, exit/kill teardown (drop-list LIFO → mailbox drain →
//!   handle abandon → invariant stack release → pid generation bump →
//!   wholesale manager free; EXACT accounting), and futex idle parking
//!   with cross-thread mailbox-push wakes.
//! * `deterministic.zig` — the seeded deterministic mode: seeded
//!   `Decisions`, append-only trace recording with equality comparison,
//!   scenario harness + seed sweeps, failing-seed printing.
//! * `introspection.zig` — the plan-1.6 observability skeleton:
//!   per-process snapshots (state, approximate mailbox depth, manager
//!   heap bytes, last-suspend pc/fp), process listing over the pid
//!   table's lock-free iterator, and the scheduler counter roster
//!   (run-queue depth, quanta, parks/wakes, dead letters, spawn/exit
//!   totals). Per research.md §6.9, these double as the testing hooks.
//! * `crash_report.zig` — plan-1.6 crash reports: on every teardown
//!   (normal exit, kill/simulated crash) an optional sink receives the
//!   pid, reason, state and mailbox depth at death, and a native stack
//!   trace walked from the fiber's last suspend point (a bounded,
//!   stack-bounds-validated frame-pointer walk that avoids the fork-std
//!   MachO compact-unwind defect — adjudication note in the module doc).
//! * `teardown_stress.zig` — the plan-1.7 Darwin teardown campaign
//!   (mimalloc-#164 class): thousands of mixed-shape spawn/die cycles
//!   with exact per-wave resource accounting;
//!   `ZAP_TEARDOWN_STRESS_CYCLES` scales it to a soak.
//! * `adversarial_stress.zig` — the Phase 1 half of exit gate E3
//!   (P1-J6): producer THREADS storm the kernel's shared machinery
//!   (stale-pid dead-letter storms racing slot transitions, mid-flight
//!   sender death with abandon/reclaim churn, teardown of populated
//!   mailboxes concurrent with live pushes, futex wake/park pressure)
//!   with exact accounting per round; `ZAP_ADVERSARIAL_STRESS_ROUNDS`
//!   scales it to a soak. Run under TSan for the E3 gate.
//!
//! NOT here yet: timers, links/monitors,
//! and the `std.Io` vtable. This tree is NOT wired
//! into Zap compilation — it is exercised by `zig build test-kernel`
//! (both the selected optimize mode and a ReleaseFast run for the
//! miscompilation canary; fork compiler required for the latter). The
//! selected-optimize run is also part of plain `zig build test`.
//!
//! ## Toolchain requirement
//!
//! Optimized builds of this kernel REQUIRE the Zap Zig fork at or after
//! commit `6a425dbaeb` (subsuming `74c0b87fe5`). Stock Zig 0.16.0 silently
//! drops the aarch64 `.x30` clobber of `std.Io.fiber.contextSwitch`
//! (translating Zig register names to LLVM constraint names is a fork
//! fix), so LLVM keeps live values in x30 across the switch and every
//! ReleaseFast/ReleaseSafe fiber build miscompiles — see the E9 "FORK BUG"
//! section of `docs/concurrency-bench-results.md`. The miscompilation
//! canary test in `fiber_context.zig` fails loudly under such a compiler;
//! `zig build test-kernel` runs it at ReleaseFast on purpose.
//!
//! Portability tracking (Phase 4 Linux CI leg): the kernel test/stress env
//! knobs (`adversarial_stress.zig`, `teardown_stress.zig`, `panic_guards.zig`)
//! read their configuration via libc `std.c.getenv`, so the Linux leg must
//! either link libc for kernel tests or migrate the knobs to
//! `std.posix.getenv`. Failure mode today is a loud link error, not silent
//! misbehavior.
//!
//! ## Why this is not under `src/runtime.zig`
//!
//! The kernel compiles as a self-contained source tree with no dependency
//! on `libzap_compiler.a`, mirroring how manager sources are standalone
//! compilation units; when the intrinsic surface lands it will be compiled
//! per target via `zap_fork_compile_zig_to_object` exactly like manager
//! sources (plan §4), never text codegen.

pub const stack_pool = @import("stack_pool.zig");
pub const fiber_context = @import("fiber_context.zig");
pub const process = @import("process.zig");
pub const pid_table = @import("pid_table.zig");
pub const mailbox = @import("mailbox.zig");
pub const envelope_pool = @import("envelope_pool.zig");
pub const scheduler = @import("scheduler.zig");
pub const deterministic = @import("deterministic.zig");
pub const introspection = @import("introspection.zig");
pub const crash_report = @import("crash_report.zig");

pub const StackPool = stack_pool.StackPool;
pub const Stack = stack_pool.Stack;
pub const KernelFiber = fiber_context.KernelFiber;
pub const FiberExecution = fiber_context.FiberExecution;
pub const SchedulerContext = fiber_context.SchedulerContext;
pub const ProcessControlBlock = process.ProcessControlBlock;
pub const ProcessState = process.ProcessState;
pub const Pid = pid_table.Pid;
pub const PidTable = pid_table.PidTable;
pub const ReclamationModel = pid_table.ReclamationModel;
pub const LiveProcessIterator = pid_table.LiveProcessIterator;
pub const Mailbox = mailbox.Mailbox;
pub const Envelope = mailbox.Envelope;
pub const Fragment = mailbox.Fragment;
pub const PopOutcome = mailbox.PopOutcome;
pub const WakeCallback = mailbox.WakeCallback;
pub const EnvelopePool = envelope_pool.EnvelopePool;
pub const EnvelopePage = envelope_pool.EnvelopePage;
pub const Scheduler = scheduler.Scheduler;
pub const ProcessContext = scheduler.ProcessContext;
pub const ProcessEntry = scheduler.ProcessEntry;
pub const Decisions = scheduler.Decisions;
pub const TraceEvent = scheduler.TraceEvent;
pub const TraceHook = scheduler.TraceHook;
pub const IdleStrategy = scheduler.IdleStrategy;
pub const ExitReason = scheduler.ExitReason;
pub const KillOutcome = scheduler.KillOutcome;
pub const SendOutcome = scheduler.SendOutcome;
pub const SeededDecisions = deterministic.SeededDecisions;
pub const TraceRecorder = deterministic.TraceRecorder;
pub const DeterministicHarness = deterministic.Harness;
pub const ProcessSnapshot = introspection.ProcessSnapshot;
pub const ProcessListIterator = introspection.ProcessListIterator;
pub const KernelCounters = introspection.KernelCounters;
pub const CrashReport = crash_report.CrashReport;
pub const ReportHook = crash_report.ReportHook;

test {
    // FIRST on purpose: the expect-panic guard tests dispatch child
    // processes through their own test bodies, and front-of-suite
    // placement lets a guard child reach its scenario without re-running
    // the rest of the kernel suite (`panic_guards.zig`, "Dispatch
    // discipline" — placement is a speed optimization, not a correctness
    // requirement).
    _ = @import("panic_guards.zig");
    _ = stack_pool;
    _ = fiber_context;
    _ = process;
    _ = pid_table;
    _ = mailbox;
    _ = envelope_pool;
    _ = scheduler;
    _ = deterministic;
    _ = introspection;
    _ = crash_report;
    _ = @import("teardown_stress.zig");
    _ = @import("adversarial_stress.zig");
}
