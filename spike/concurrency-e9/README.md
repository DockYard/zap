# Spike: E9 — fiber-switch floor + Darwin wakeup mechanism comparison

**THROWAWAY SPIKE CODE.** Job S0.3 (experiment E9, reframed after E1) of the
concurrency campaign (`docs/concurrency-implementation-plan.md`, Phase 0).
This directory is not product code, is not wired into any build, and will be
deleted once the S0.5 scheduler-architecture decision is made. Results are
recorded in the E9 section of `docs/concurrency-bench-results.md`.

## What it measures

E1 disqualified both fork `std.Io` backends as the scheduler substrate, so
the campaign direction is a bespoke scheduler built on raw stackful context
switching (`~/projects/zig` `lib/std/Io/fiber.zig`) with our own run queues.
E9 answers two substrate questions:

1. **`fiber_switch.zig`** — the scheduler's floor costs on one thread:

   | Benchmark | What it does | Per-op meaning |
   |---|---|---|
   | `pingpong` | two fibers hand control back and forth N round trips | one one-way context switch (RTT = 2x) |
   | `spawn` | init a fiber context on a pooled stack, switch in, body immediately switches back | spawn -> run -> complete floor with stack pooling |
   | `stack` | mmap a 256 KiB stack + PROT_NONE guard page, fault in the top page, munmap | fresh (unpooled) stack creation cost |

   Fiber stacks use the exact layout `Io/Dispatch.zig`/`Io/Uring.zig` use
   internally: argument block at the top of the stack, initial sp = argument
   block, naked entry trampoline that forwards sp as the first parameter,
   fp = 0. Each benchmark asserts (outside the timed region) via a
   `wake_count` counter that every switch really executed.

2. **`wakeup.zig`** — cross-thread wakeup latency of a parked scheduler
   thread on Darwin, one mechanism at a time: `spin` (userspace handoff, the
   no-syscall floor), `ulock` (`__ulock_wait2`/`__ulock_wake`
   COMPARE_AND_WAIT — the exact pair the fork's `Io.Threaded` futex uses;
   the fork has **no** `std.Thread.Futex`), `os-sync`
   (`os_sync_wait_on_address_with_timeout`/`os_sync_wake_by_address_any`,
   Apple's public futex API, macOS 14.4+, declared extern), `kqueue`
   (EVFILT_USER NOTE_TRIGGER -> kevent wait return), `gcd-sem`
   (`dispatch_semaphore_signal` -> `dispatch_semaphore_wait` return).

   Protocol per iteration: main records t0, signals the worker's channel,
   parks on its own channel; the worker (parked) wakes, records t1, echoes
   back. Only main -> worker is timed (delta = t1 - t0, same
   CLOCK_UPTIME_RAW clock, ~41.7 ns granularity on Apple Silicon). Between
   iterations main busy-waits 20 us (`delay_ns` argument) so the worker is
   reliably parked again before the next wake; every blocking wait has a 5 s
   timeout that panics (a lost wakeup is a finding, not a hang).

## FORK BUG found by this spike: `~{x30}` clobber silently dropped (aarch64)

The fork's `std.Io.fiber.contextSwitch` declares `.x30 = true` in its
clobber set, but at `-OReleaseFast` LLVM still allocates live values into
x30 across the switch asm. Root cause: the Zig LLVM backend
(`src/codegen/llvm/FuncGen.zig`, clobber loop) emits the clobber under the
Zig field name — `~{x30}` — while LLVM's AArch64 register is named `lr`.
Clang translates user clobber "x30" to "lr"; Zig does not, and LLVM
**silently ignores** unknown clobber names in IR inline asm.

Observed consequences (this spike, before the workaround):

- `fiberMain` kept its `*FiberArgs` in x30 (`mov x30, x0`) and reloaded
  `[x30]` after every switch; a resumed fiber therefore saw the *other*
  fiber's args. A 10,000,000-round-trip ping-pong "completed" in 0.01 s
  real with `total_ns=0` — control flow collapsed after the first switches.
- Minimal repro (`zig build-obj -OReleaseFast -femit-llvm-ir`): the IR
  contains `~{x30}`, and the disassembly moves a live pointer into x30
  before `contextSwitch` and dereferences it after.
- Debug builds are unaffected (no values kept in registers across the asm),
  matching E1's "works at `-ODebug`, segfaults at ReleaseFast/ReleaseSafe"
  Dispatch crash signature. This dropped clobber is the most plausible root
  cause of E1 crashes 1–2 (the ReleaseSafe PAC-looking garbage fault
  address is consistent with control state derived from a stale x30).

The proper fix is in the fork (map AArch64 clobber `x30` -> `lr` when
emitting LLVM constraints, as clang does) and is out of scope for this
measurement job (no fork-source changes). To obtain valid numbers,
`fiber_switch.zig` uses a spike-local copy of the primitive whose only
change is a fourth `Context` word: the switch saves/restores x30
per-context (one extra instruction), which is correct under either compiler
behavior. The measured floor therefore *includes* that extra instruction;
a fixed fork primitive would be marginally cheaper.

## Build

Compiled with the asdf-managed Zig 0.16.0 binary against the fork's std
(fork `~/projects/zig` @ `b8fc76ac3f7cc11580a6801d3ccaa2d520f0af06`, clean):

```sh
zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast fiber_switch.zig
zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast wakeup.zig
```

## Run

One measurement at a time, foreground, `uptime` recorded immediately before
each run:

```sh
./fiber_switch <pingpong|spawn|stack> [ops] [reps] [warmup]
./wakeup <spin|ulock|os-sync|kqueue|gcd-sem> [ops] [reps] [warmup] [delay_ns]
```

Defaults: `fiber_switch` 1,000,000 ops (100,000 for `stack`), 5 reps,
warmup = ops/10; `wakeup` 100,000 wakeups, 5 reps, warmup = ops/10,
delay_ns = 20,000. Both threads run at default QoS; threads are not pinned
(macOS exposes no affinity control on Apple Silicon).
