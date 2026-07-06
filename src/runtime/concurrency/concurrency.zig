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
//! ## Phase status
//!
//! Phase 1, jobs P1-J1 (kernel skeleton, plan item 1.1), P1-J2
//! (generational pid table, plan item 1.2), and P1-J3 (mailbox +
//! envelope pool, plan item 1.3):
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
//!
//! NOT here yet: run-queue scheduler, spawn/exit orchestration (1.4),
//! deterministic mode (1.5), observability (1.6). This tree is NOT wired
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

test {
    _ = stack_pool;
    _ = fiber_context;
    _ = process;
    _ = pid_table;
    _ = mailbox;
    _ = envelope_pool;
}
