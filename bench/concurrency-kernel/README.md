# Bench: E1 re-measurement on the real concurrency kernel

Phase 1 exit-gate job P1-J6 of the concurrency campaign
(`docs/concurrency-implementation-plan.md`, gate table row E1 "re-run 1").
The Phase 0 E1 spike (`spike/concurrency-e1/`) measured the fork's
`std.Io` backends and failed them; this benchmark measures the landed
bespoke Phase 1 kernel (`src/runtime/concurrency/`) through its REAL
paths. Results are recorded in the E1 section of
`docs/concurrency-bench-results.md` ("Phase 1 kernel re-measurement").

Unlike the Phase 0 spikes this is NOT throwaway code: the E1 gate re-runs
again in Phase 4 (cross-scheduler) and Phase 3 re-measures spawn
per-manager, both against these same modes.

## What it measures

| Mode | What it does | Per-op meaning |
|---|---|---|
| `spawn` | timed batches of 256 spawns (pool-hit steady state); untimed run-to-quiescence between batches | spawn admission only: pid acquire + PCB init + pooled stack + fiber init + ready enqueue |
| `spawn-serial` | spawn one trivial process, run to quiescence, repeat | full spawn→run→exit→teardown round trip |
| `spawn-lifecycle` | timed (spawn 256 + run all to quiescence) batches | amortized full lifecycle |
| `pingpong` | two kernel processes exchange envelopes via `ProcessContext.send`/`receive` through the real scheduler and real mailboxes | one same-scheduler message round trip |
| `wake` | a producer THREAD pushes to a parked scheduler's blocked receiver; wake-to-receive latency (the Phase 4 cross-scheduler RTT bound) | one parked-wake delivery: futex wake → unpark → wake-stack drain → schedule → receive returns |

The spawn batch size (256) equals the stack pool's cache ceiling and a
512-process warmup wave raises the pool peak so the whole ceiling is
available — every timed spawn is then the plan-1.4 pool-only hot path.
The bench asserts this (`pool_miss_batches` must print 0) rather than
assuming it.

**Manager caveat:** per-process managers are the Phase 1 TEST manager
shape (arena + byte accounting, as in the kernel's own tests); the real
per-spawn manager ABI is Phase 3. Spawn numbers measure the kernel path
with a cheap manager init/teardown, not the eventual ARC-manager cost.

## Build

MUST be compiled with the Zap Zig fork (≥ `6a425dbaeb`): stock Zig 0.16.0
silently drops the aarch64 x30 asm clobber of `std.Io.fiber.contextSwitch`
and miscompiles every optimized fiber build (E9 FORK BUG,
`docs/concurrency-bench-results.md`).

```sh
~/projects/zig/zig-out/bin/zig build-exe -OReleaseFast --name bench \
  --dep concurrency -Mmain=bench.zig \
  -Mconcurrency=../../src/runtime/concurrency/concurrency.zig
```

## Run

One measurement at a time, foreground; record `uptime` immediately before
every timed invocation (ledger convention):

```sh
uptime && ./bench <spawn|spawn-serial|spawn-lifecycle|pingpong|wake> [ops]
```

Defaults: 102,400 ops for the spawn modes (400 batches of 256), 100,000
for `pingpong` and `wake`; 5 timed repetitions after one unrecorded
warmup pass sized at workload/10 with a CLAMPED MINIMUM — at least 1,000
ops for the spawn and pingpong modes and at least 100 messages for
`wake` — so a small `[ops]` override still warms the pools/caches enough
for the timed reps to measure the steady state instead of first-touch
growth. Timing uses `CLOCK_UPTIME_RAW` directly, never through kernel
code under test. Each mode prints per-rep totals and a `RESULT` line
with median + min per-op nanoseconds (`wake` reports the per-rep
median/min/p99/max and a `RESULT` with the median of rep medians, the
global min, and the p99 range across reps, per the E9 wakeup
convention).

`pingpong` self-verifies instead of trusting its own label: every timed
repetition must execute ≈ 2×rounds scheduler quanta (one per process per
round trip, +1 entry quantum, small documented slack) and the whole mode
must record zero futex parks — violations abort the run with a nonzero
exit instead of printing a contaminated RTT.

`wake` notes: the producer waits for the scheduler's park counter to
advance, then settles 20 µs so the scheduler is inside (not merely
entering) the futex wait before the timed push — the E9 wakeup-bench
discipline. The bench raises the scheduler's park timeout to 1 s so
defensive timeout re-parks cannot contaminate the parked-wake
distribution.
