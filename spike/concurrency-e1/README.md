# Spike: E1 — spawn cost + ping-pong RTT on the fork's `std.Io` backends

**THROWAWAY SPIKE CODE.** Job S0.2 (experiment E1) of the concurrency campaign
(`docs/concurrency-implementation-plan.md`, Phase 0). This directory is not
product code and is not wired into any build. It is retained until the
Phase 1 E1 re-run gate completes (the re-run gates against this spike's
post-fix ledger rows, and the `triage/` crash captures here are referenced by
the ledger's E1 section); it is deleted after that gate. Results are recorded
in the E1 section of `docs/concurrency-bench-results.md`.

## What it measures

`bench.zig` benchmarks the Zig fork's (`~/projects/zig`) `std.Io`
implementations — `Io.Evented` (which resolves to the Dispatch/GCD backend on
macOS) and `Io.Threaded` — on five micro-benchmarks:

| Benchmark | What it does | Per-op meaning |
|---|---|---|
| `spawn` | `Io.async` trivial tasks with at most 64 futures in flight, await all | amortized spawn + await |
| `spawn-serial` | `Io.async` one trivial task, await immediately, repeat | full spawn→complete→await round trip |
| `spawn-group` | `Io.Group.async` all tasks into one group, await the group | amortized batch spawn |
| `pingpong` | two `Io.concurrent` actors exchange a token through two capacity-1 `Io.Queue(u64)`s | one message round trip (RTT) |
| `queue` | single task alternates non-blocking `putOne`/`getOne` on a capacity-1 `Io.Queue(u64)` | one put+get pair (floor reference) |

The 64-future window on `spawn` exists because Dispatch fibers each reserve
~60 MB of lazily-committed address space (`Io/Dispatch.zig`
`Fiber.min_stack_size`); holding 100k futures at once is not feasible there.

Timing uses `CLOCK_UPTIME_RAW` directly (not the `Io` clock vtable) so the
timer never routes through the implementation under test. Each invocation
does one unrecorded warmup pass (a tenth of the workload, min 1000 ops,
overridable) followed by the timed repetitions, and prints per-rep totals
plus a `RESULT` line with median and min per-op nanoseconds. The `eager`
counter reports how many `Io.async` calls completed inline
(`Future.any_future == null`) instead of being assigned a task — on
`Io.Threaded` this happens whenever the pool is saturated.

## Build

Compiled with the asdf-managed Zig 0.16.0 binary against the fork's std:

```sh
zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast bench.zig
```

## Run

One measurement at a time, foreground:

```sh
./bench <evented|threaded> <spawn|spawn-serial|spawn-group|pingpong|queue> [ops] [reps] [warmup]
```

Defaults: 100,000 ops (1,000,000 for `queue`), 5 reps.

## Known fork-backend failures found by this spike (2026-07-04)

Reproductions assume the ReleaseFast build above unless stated; full detail
in the E1 section of `docs/concurrency-bench-results.md`.

1. **`Io.Evented` (Dispatch) blocking-queue fiber suspend/resume segfaults in
   optimized builds.** `./bench evented pingpong 1 1 0` — a single round trip
   — dies with SIGSEGV deterministically at ReleaseFast and ReleaseSafe
   (ReleaseSafe reports a garbage fault address, e.g.
   `0xa907a3e0910043e8`). The identical binary logic completes fine at
   `-ODebug`. Non-blocking fiber paths (spawn/await, non-blocking queue ops)
   work at ReleaseFast.
2. **`Io.Evented` `Group.async` segfaults at ReleaseFast.**
   `./bench evented spawn-group 2000 2 200` → SIGSEGV. At `-ODebug` it runs
   but pathologically slowly (~32–45 ms per trivial task).
3. **`Io.Evented.deinit` does not compile.** `Io/Dispatch.zig:584` passes
   `ev.main_loop_stack[0..main_loop_stack_size]` (comptime-known length, so
   type `*[8192]u8`, a pointer-to-array rather than a slice) to
   `Allocator.free`, which comptime-asserts a slice. `bench.zig` skips
   `deinit` on the evented path and lets process exit reclaim resources.
