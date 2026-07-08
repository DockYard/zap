# Concurrency Campaign — Benchmark Results

Results ledger for the concurrency implementation campaign
(`docs/concurrency-implementation-plan.md`). Job **S0.1** (Phase 0) recorded the
CLBG performance baseline below on pre-concurrency `main` so that every later
phase — especially the **E2** safepoint-overhead gate — has an apples-to-apples
reference. Zap's CLBG standing (n-body, spectral-norm wins) is a hard
requirement of the campaign. The E2 kill criterion is >2–3% regression on
n-body/spectral-norm → the unrolling mitigation before concurrency-on ships;
the gate itself is decided by the **paired protocol** — interleaved,
same-session, quiet-machine re-runs of the baseline binaries against the
safepoint binaries, compared on paired medians/minima, as prescribed in the
S0.1 methodology section below. The S0.1 table is the archival snapshot and
drift context, not the gate: no run is gated by absolute comparison against
its numbers.

## CLBG baseline (S0.1) — pre-concurrency `main`

### Methodology

- **Date:** 2026-07-04.
- **Machine:** MacBook Air (`Mac16,13`), Apple M4, 10 cores (4 performance +
  6 efficiency), 32 GB RAM, macOS 26.2 (build 25C56). Fanless chassis; machine
  was on AC power with the battery charging (16%) during the run — see the
  variance note below.
- **Zap compiler:** repo `main` @ `c1a0900210281a2ee5f28d4aa3c82115a41dab74`,
  built with:

  ```sh
  zig build -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
            -Dllvm-lib-path=zap-deps/aarch64-macos-none/llvm-libs
  ```

  using Zig 0.16.0 (asdf toolchain) and the Zig fork
  (`~/projects/zig`) @ `b8fc76ac3f7cc11580a6801d3ccaa2d520f0af06`
  (`libzap_compiler.a`, ReleaseSafe, `aarch64-macos-none`).
- **Benchmark suite:** `~/projects/lang-benches` @
  `6f05efdeac11a5bf74e19ffe85f9bee483e9f3ca` with uncommitted working-tree
  fixes that wrap `Integer.parse` in a `case … nil ->` default (required by
  current `main`'s optional-returning `Integer.parse`). Bench-source
  sha256 prefixes at measurement time:

  | Source | sha256 (first 12) |
  |---|---|
  | `nbody/nbody.zap` | `fa672e34ef39` |
  | `mandelbrot/mandelbrot.zap` | `00744d284d96` |
  | `binarytrees/binarytrees.zap` | `8ad10097d93a` |
  | `fannkuch-redux/fannkuch_redux.zap` | `3f32da24e152` |
  | `spectral-norm/spectral_norm.zap` | `3697f9434abb` |
  | `k-nucleotide/k_nucleotide.zap` | `763abe1414e3` |
  | `k-nucleotide/input.fasta` | `d4a2d94374f2` |

  *Reproducibility update (2026-07-05):* the working-tree `Integer.parse`
  wrappers described above were committed to `lang-benches` as
  `49287c676a0e3c1d649b7446e7f0e07780134f28` (`fix: wrap Integer.parse for
  optional-returning API (zap main)`), so the measured bench sources are now
  pinned by that commit; the sha256 prefixes above remain the byte-level
  ground truth.

- **Binary acquisition** (the suite's established `zap run` script-mode
  protocol, `lang-benches/scripts/zap-script-bin.sh`):
  `zap run -Doptimize=ReleaseFast [-Dmemory=Memory.Arena] <bench>.zap <args>`
  compiles into the content-addressed script cache; a second identical run
  must report `[script-cache hit] <path>` and that native binary is what gets
  timed — zero wrapper overhead. Because the script cache is **not** keyed on
  the compiler binary, the run used a fresh `XDG_CACHE_HOME` so every timed
  binary was provably compiled by the HEAD compiler above. `Zap (ARC)` is the
  default manager (no `-Dmemory` flag); `Zap (Arena)` is
  `-Dmemory=Memory.Arena`.
- **Timing:** `hyperfine --warmup 2 --runs 10` per bench, both manager rows in
  one invocation (the suite's `run-all.sh` convention uses 5 runs; 10 were
  used here for a tighter median). Statistics below are computed from the raw
  per-run times in the exported hyperfine JSON. Two full passes were taken
  (same binaries — the second pass resolved every binary as a script-cache
  hit): **pass 1** is the primary table; **pass 2** is the repeatability
  appendix. Raw hyperfine JSON exports and the runner script are committed
  under `bench/concurrency-baseline/`
  (`pass1-hyperfine-json/`, `pass2-hyperfine-json/`, `run-baseline.sh`).
- **Input sizes** (the suite's standard sizes from
  `lang-benches/scripts/run-all.sh`, reduced from CLBG defaults to keep wall
  time tractable while still separating fast/slow implementations):
  n-body N = 5,000,000 (CLBG standard 50,000,000); mandelbrot N = 8,000 (CLBG
  16,000); binary-trees N = 21 (CLBG standard); fannkuch-redux N = 11;
  spectral-norm N = 2,500; k-nucleotide reads a generated 250,000-sequence
  FASTA fixture on stdin.

### Baseline table (pass 1 — primary)

| Benchmark | Input | Manager | Median (s) | Min (s) | Stddev (s) | CV |
|---|---|---|---:|---:|---:|---:|
| n-body | N = 5,000,000 | Zap (ARC) | 0.1331 | 0.1274 | 0.0038 | 2.9% |
| n-body | N = 5,000,000 | Zap (Arena) | 0.1310 | 0.1281 | 0.0019 | 1.4% |
| mandelbrot | N = 8,000 | Zap (ARC) | 2.4658 | 2.3364 | 0.1701 | 6.9% |
| mandelbrot | N = 8,000 | Zap (Arena) | 2.6301 | 2.3420 | 0.7129 | 27.1% |
| binary-trees | N = 21 | Zap (ARC) | 12.6498 | 9.1220 | 2.4485 | 19.4% |
| binary-trees | N = 21 | Zap (Arena) | 5.9417 | 4.0271 | 2.1338 | 35.9% |
| fannkuch-redux | N = 11 | Zap (ARC) | 6.4123 | 4.8445 | 0.6537 | 10.2% |
| fannkuch-redux | N = 11 | Zap (Arena) | 5.3729 | 3.5393 | 1.0054 | 18.7% |
| spectral-norm | N = 2,500 | Zap (ARC) | 0.2129 | 0.2067 | 0.0062 | 2.9% |
| spectral-norm | N = 2,500 | Zap (Arena) | 0.2164 | 0.2049 | 0.0062 | 2.9% |
| k-nucleotide | 250,000-sequence FASTA stdin | Zap (ARC) | 0.3944 | 0.3643 | 0.0705 | 17.9% |
| k-nucleotide | 250,000-sequence FASTA stdin | Zap (Arena) | 0.4314 | 0.4171 | 0.0216 | 5.0% |

**Load-contamination caveat (read before gating against this table).** Both
passes ran while other agent sessions were active on this machine — during
pass 1 a foreign Elixir `mix test --include heavy_corpus` suite held ~1 full
core the entire time (load average 4–7 on 10 cores); pass 2 saw load average
4–12 from other concurrent workloads. The battery was also charging (16%) on
a fanless chassis. Consequences:

- **Medians in this table are upper bounds**, not quiet-machine numbers. The
  committed 2026-07-03 full-suite run (context table below) was quieter and
  shows lower medians for the same code generation (e.g. n-body ARC 0.107 s
  vs 0.133 s here).
- **The `Min (s)` column and the cross-pass best-min table below are the
  usable floor** — minima are far more load-robust than medians.
- **E2 gating protocol:** never compare a concurrency-on run against this
  table in absolute terms. Re-run the baseline binaries and the safepoint
  binaries *interleaved in the same session on a quiet machine* and compare
  paired medians/minima. A delta smaller than the row's baseline CV is noise,
  not a regression.

### Cross-pass best-observed minimum (load-robust floor)

Minimum wall time observed across both 10-run passes (20 runs + 4 warmups
per row):

| Benchmark | Zap (ARC) min (s) | Zap (Arena) min (s) |
|---|---:|---:|
| n-body | 0.1274 | 0.1281 |
| mandelbrot | 2.3364 | 2.3420 |
| binary-trees | 6.8626 | 2.9308 |
| fannkuch-redux | 4.3435 | 3.5393 |
| spectral-norm | 0.2067 | 0.2049 |
| k-nucleotide | 0.3643 | 0.4171 |

### Pass 2 (repeatability appendix — heavier load)

Same binaries (script-cache hits), same protocol, later the same session;
load average peaked at 12 during this pass:

| Benchmark | Input | Manager | Median (s) | Min (s) | Stddev (s) | CV |
|---|---|---|---:|---:|---:|---:|
| n-body | N = 5,000,000 | Zap (ARC) | 0.1509 | 0.1444 | 0.0148 | 9.8% |
| n-body | N = 5,000,000 | Zap (Arena) | 0.1593 | 0.1377 | 0.0202 | 12.7% |
| mandelbrot | N = 8,000 | Zap (ARC) | 2.6392 | 2.5187 | 0.1284 | 4.9% |
| mandelbrot | N = 8,000 | Zap (Arena) | 4.6749 | 2.6482 | 1.1750 | 25.1% |
| binary-trees | N = 21 | Zap (ARC) | 10.7886 | 6.8626 | 2.0718 | 19.2% |
| binary-trees | N = 21 | Zap (Arena) | 2.9922 | 2.9308 | 0.0597 | 2.0% |
| fannkuch-redux | N = 11 | Zap (ARC) | 4.7430 | 4.3435 | 0.8157 | 17.2% |
| fannkuch-redux | N = 11 | Zap (Arena) | 6.7513 | 5.4860 | 0.6121 | 9.1% |
| spectral-norm | N = 2,500 | Zap (ARC) | 0.4289 | 0.2372 | 0.1572 | 36.7% |
| spectral-norm | N = 2,500 | Zap (Arena) | 0.4209 | 0.4122 | 0.0073 | 1.7% |
| k-nucleotide | 250,000-sequence FASTA stdin | Zap (ARC) | 0.7498 | 0.5997 | 0.0976 | 13.0% |
| k-nucleotide | 250,000-sequence FASTA stdin | Zap (Arena) | 0.4711 | 0.4321 | 0.0421 | 8.9% |

### Cross-language context (prior full-suite run)

For scale only — from the `lang-benches` full-suite run of 2026-07-03,
committed in that repo as `b4b9a77` (`run-all.sh`, 5 runs, same machine,
previous day's compiler build). These are **not** the E2 reference
numbers; the table above is.

| Benchmark | C | Rust | Zig | Go | OCaml | Zap (ARC) | Zap (Arena) |
|---|---:|---:|---:|---:|---:|---:|---:|
| n-body | 0.162 | 0.166 | 0.164 | 0.294 | 0.182 | **0.107** | **0.106** |
| mandelbrot | 2.033 | 2.210 | 2.574 | 2.443 | 4.466 | 2.121 | 2.113 |
| binary-trees | 9.453 | 14.691 | 3.677 | 9.646 | 1.790 | 6.205 | 2.955 |
| fannkuch-redux | 1.579 | 1.454 | 1.571 | 1.623 | 1.817 | 2.766 | 2.584 |
| spectral-norm | 0.196 | **0.159** | 0.161 | 0.230 | 0.484 | 0.171 | **0.159** |
| k-nucleotide | 0.062 | 0.081 | 0.079 | 0.109 | 0.331 | 0.407 | 0.314 |

(Medians in seconds; bold marks where Zap leads or ties the field.)

## E1 — spawn/ping-pong (S0.2, 2026-07-04)

Fork `std.Io` backend micro-benchmarks: `Io.Evented` (resolves to the
Dispatch/GCD backend on macOS) vs `Io.Threaded`. Re-measured in Phases 1
and 4; spawn cost is manager-dependent, so later phases report per-manager.

### Methodology

- **Date:** 2026-07-04. Same machine as the S0.1 baseline above (Apple M4,
  10 cores, 32 GB, macOS 26.2).
- **Benchmark:** `spike/concurrency-e1/bench.zig` (throwaway spike; see its
  README), compiled with the asdf Zig 0.16.0 binary against the fork's std
  (`~/projects/zig` working tree of this date):

  ```sh
  zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast bench.zig
  ```

  *Fork pin (recorded post hoc):* best-known state is
  `b8fc76ac3f7cc11580a6801d3ccaa2d520f0af06` (the SHA the same-day S0.1 and
  E9 jobs recorded for a clean fork tree). Honesty note: the exact fork tree
  state for these pre-fix rows was **not recorded at measurement time**; the
  rows are superseded-as-history by the post-clobber-fix re-measurement below
  (fork @ `74c0b87fe5`), which is fully pinned.

- **Protocol:** one measurement at a time, foreground; unrecorded warmup pass
  (workload/10, min 1000 ops) then 5 timed repetitions; median + min of
  per-op ns reported. Timing via `CLOCK_UPTIME_RAW` directly, never through
  the `Io` vtable under test. `uptime` recorded immediately before every
  timed run; other agent sessions were active — 1-minute load average ranged
  **3.8–5.2** across the timed runs, so minima are the load-robust floor
  (same caveat as S0.1).
- **Workloads:** spawn benches = 100,000 trivial tasks (`spawn` = `Io.async`
  with ≤64 futures in flight; `spawn-serial` = spawn then await immediately;
  `spawn-group` = `Io.Group.async` batch, awaited once). `pingpong` =
  100,000 round trips of a `u64` token through two capacity-1
  `Io.Queue(u64)`s between two `Io.concurrent` actors. `queue` = 1,000,000
  non-blocking putOne/getOne pairs on one task (floor reference).
- The ≤64-future window exists because each Dispatch fiber reserves ~60 MB
  of lazily-committed address space (`Io/Dispatch.zig` `Fiber.min_stack_size`
  = 60 MiB); 100k in-flight fibers is not addressable. This is itself an E1
  finding: Dispatch fibers are far too heavy for BEAM-style process counts.
- `Io.Threaded` defaults: worker pool = cpu_count − 1 = 9 threads;
  `Io.async` runs tasks **inline** when the pool is saturated (the `eager`
  fraction below), so its spawn number mixes queued and inline completions.

### Results (ReleaseFast, median / min per-op ns, 5 reps each)

| Metric | `Io.Evented` (Dispatch) | `Io.Threaded` | Load (1-min) |
|---|---:|---:|---|
| spawn, windowed ≤64 (`Io.async`+await, ns/task) | 30,149 / 26,744 | 2,219 / 1,441 | 3.8 / 4.7 |
| spawn, serial (spawn→await round trip, ns/task) | 7,896 / 4,126 | 4,316 / 2,660 | 5.0 / 4.7 |
| spawn, `Io.Group.async` batch (ns/task) | **SIGSEGV** (crash 1 below) | 451 / 63 | — / 4.4 |
| ping-pong RTT (ns/round-trip) | **SIGSEGV** (crash 2 below) | 3,430 / 2,879 | — / 4.2 |
| queue floor (ns per put+get pair, non-blocking) | 13.1 / 13.1 | 16.4 / 16.3 | 4.3 / 4.1 |

`Io.Threaded` spawn eager-inline fraction ranged 3.6–23% across windowed
reps (0% for serial/pingpong). Threaded ping-pong is a genuine cross-thread
wakeup: each `Io.concurrent` actor gets a dedicated pool thread.

Debug-build characterization (because Evented crashes at ReleaseFast):
Evented ping-pong at `-ODebug` completes at **37,289 / 37,161 ns/RTT**
(2,000 round trips, 5 reps), while Threaded ping-pong at `-ODebug` is
2,243 / 2,201 ns/RTT — i.e. Debug overhead on this bench is negligible, so
~37 µs/RTT is representative of Dispatch's blocking-queue suspend/wakeup
cost even before the crash is fixed. Evented `spawn-group` at `-ODebug`
runs but pathologically: ~32–45 **ms** per trivial task (likely interacting
with the backend's 10 ms timer leeway).

### Backend failures found (exact reproductions)

All against `spike/concurrency-e1/bench.zig` compiled as above.

1. **Dispatch `Group.async` segfault (ReleaseFast).**
   `./bench evented spawn-group 2000 2 200` → SIGSEGV (exit 139), before any
   rep completes. Works at `-ODebug` (but see pathology above).
2. **Dispatch blocking-queue fiber suspend/resume segfault (ReleaseFast and
   ReleaseSafe).** `./bench evented pingpong 1 1 0` — a *single* round trip —
   dies deterministically with SIGSEGV; ReleaseSafe prints a garbage fault
   address (e.g. `0xa907a3e0910043e8`, PAC-looking), and the crash handler
   cannot unwind (corrupted fiber context). Identical logic completes at
   `-ODebug`. Non-blocking fiber paths (spawn/await, non-blocking queue ops)
   work at ReleaseFast, so the break is specific to fibers suspending on a
   `Io.Queue` condition and being resumed from another fiber/thread under
   optimized codegen.
3. **`Io.Evented.deinit` does not compile.** `Io/Dispatch.zig:584` passes
   `ev.main_loop_stack[0..main_loop_stack_size]` — comptime-known length, so
   type `*[8192]u8` (pointer-to-array, not a slice) — to `Allocator.free`,
   whose comptime assert (`slice_info.size == .slice`) fails whenever
   `deinit` is referenced. The spike skips `deinit` on the evented path.

*Update (E9, 2026-07-04):* the S0.3 spike found the likely root cause of
crashes 1–2: the aarch64 `~{x30}` clobber on `fiber.contextSwitch` is
silently dropped in Zig→LLVM constraint emission, so optimized builds keep
live pointers in x30 across fiber switches. See the E9 section's FORK BUG
finding below.

### Verdict vs plan targets and yardstick

**Fail on both backends; escalate per the plan's kill criterion.** Targets
were sub-µs–3 µs spawn and same-scheduler RTT within 2–3× BEAM/Go (BEAM:
sub-µs spawn, sub-µs same-scheduler send). `Io.Threaded` is the better
substrate but sits at the edge or outside the band: windowed spawn
2.2 µs median (1.4 µs min) is inside 3 µs only via inline-execution mixing,
serial spawn is 4.3 µs, and ping-pong RTT of 3.4 µs median / 2.9 µs min is
**>3× BEAM's sub-µs send** and well above Tokio's low-ns mpsc.
`Io.Evented` (Dispatch) fails outright: ~30 µs per windowed spawn (60 MB
address-space reservation + mmap/munmap + GCD enqueue per fiber), ~37 µs/RTT
even in the Debug-only configuration that survives, two distinct optimized-
build segfaults on exactly the paths a message-passing runtime hammers
(blocking queue suspend/resume, group spawn), and a deinit that does not
compile — it is not a viable scheduler substrate in its current state. The
13–16 ns non-blocking queue floor shows the queue data structure itself is
fine; the cost lives in task/fiber suspension and wakeup. Per the E1 kill
criterion (≥1–3 µs spawn or RTT >3× BEAM/Go), the S0.5 memo should
**escalate to the bespoke run-queue scheduler on `fiber.zig`** rather than
driving processes through `Io.async`/`Io.Queue` as-is; the Dispatch fiber
fixes (crashes, 60 MB stacks, deinit) are needed regardless for the fork's
I/O story, but even a fixed Dispatch backend's cost structure (GCD enqueue
µs-scale, per the yardstick table) cannot reach BEAM-class spawn/send.

### Post-clobber-fix re-measurement (S0.5, 2026-07-04)

The table above was measured with the aarch64 clobber-emission bug present
(E9's FORK BUG finding: `~{x29}`/`~{x30}` silently dropped, so **every
optimized build of fiber code was miscompiled**, including all Evented rows).
After the fork fix (`74c0b87fe5`), the Evented cases were re-run to complete
the E1 record. **The post-fix rows below supersede the pre-fix Evented rows
as the E1 record**; the pre-fix Evented numbers were produced under
miscompilation and are kept only as history.

- **Build:** same `bench.zig` (unchanged, sha as committed), compiled with
  the **fixed fork compiler binary itself** —
  `~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib
  -OReleaseFast bench.zig` (fork @ `74c0b87fe5`, clean tree) — not the asdf
  0.16.0 binary used pre-fix. Two Threaded rows were re-run with the same
  compiler as an apples-to-apples cross-check.
- **Protocol:** unchanged (one measurement at a time, foreground, warmup then
  5 timed reps, `CLOCK_UPTIME_RAW`, `uptime` before every run). 1-minute
  load average ranged **1.5–2.2** across all runs — the quietest E1 session
  (pre-fix was 3.8–5.2), so part of any improvement is load, not the fix.
- **Crash-repro confirmation:** both former deterministic segfaults are gone
  on this exact binary — `./bench evented pingpong 1 1 0` completes
  (228 µs first-op, includes actor startup) and
  `./bench evented spawn-group 2000 2 200` completes (24,962/24,521
  ns/task). E9's root-cause is confirmed on the E1 workload itself.

| Metric (median / min per-op ns, 5 reps) | Evented pre-fix | Evented **post-fix** | Threaded post-fix (cross-check) |
|---|---:|---:|---:|
| spawn, windowed ≤64 (ns/task) | 30,149 / 26,744 | 19,117 / 16,600 | 1,382 / 1,372 (eager 0.6–1.2%) |
| spawn, serial (ns/task) | 7,896 / 4,126 | 19,840 / 19,625 † | — |
| spawn, `Group.async` batch (ns/task) | SIGSEGV | 24,671 / 24,417 | — |
| ping-pong RTT (ns/round-trip) | SIGSEGV (~37,289 at `-ODebug`) | **1,012 / 947** | 1,792 / 1,770 |
| queue floor (ns per put+get pair) | 13.1 / 13.1 | 8.7 / 8.4 | — |

† **New residual Dispatch bug (intermittent, race-like).** `evented
spawn-serial` at the default workload (100k ops × 5 reps) SIGSEGV'd mid-run
in **3 of 5** attempts (twice after rep 1, once after rep 3); it also
crashed once at `2000 3 200` (2 of 3 attempts at that invocation passed).
Single-rep probes at 100/500/1,000/1,500/2,000/4,000/10,000 ops (multiple
attempts each) all passed. The signature is distinct from the fixed clobber
crashes, which were deterministic on the *first* op; this one needs volume
and is probabilistic — consistent with upstream's "explicitly experimental"
label on these backends. The † medians are from the 2 completed full runs
(19,840.3/19,624.7 and 19,851.7/19,727.2 — <0.1% apart). The
`Io.Evented.deinit` compile error (crash 3) is unchanged.

**Triaged 2026-07-05 (job G2) — classification: Dispatch-specific
fiber-lifetime race in `lib/std/Io/Dispatch.zig`; not the shared
`Io/fiber.zig` context-switch machinery; not libdispatch.** Six lldb crash
captures out of 7 ReleaseFast attempts (fork @ `6a425dbaeb`, full raw
captures in `spike/concurrency-e1/triage/`), all on GCD worker threads in
fiber context switches consuming freed/recycled fiber memory: (i) read
fault on unmapped fiber-allocation memory inside `Io.fiber.contextSwitch`;
(ii) wild jump to `pc=0` with all callee-saved registers zeroed (resumed
into a munmapped-then-re-mmapped, zero-filled fiber region); (iii) execute
fault jumping to per-worker `Thread.main_context`-consistent wq-stack
addresses. Register-level smoking gun (cap-06): the awaiter thread is
inside `Dispatch.await` → `Fiber.destroy(fiber=0x104a84000)` → `munmap`
at the very instant the crashing worker holds x21 = `0x104a84000`.
Mechanism candidate: `AsyncClosure.call` publishes `Fiber.finished` and
only *then* leaves the fiber's stack via `yield(.nothing)`, while `await`'s
fast path destroys the 60 MB allocation immediately on seeing `finished` —
predicting exactly the observed distribution (serial await races the
just-finishing task every op and crashes; windowed `spawn` with await
distance 64 and `pingpong` with zero per-op fiber churn ran crash-free as
same-binary controls, pingpong pushing millions of switches through the
same shared asm). ReleaseSafe: 4/4 attempts passed with no safety panic
(perturbs the race, classifies nothing). libdispatch frames were parked/idle
in every capture. Not a Phase 1 blocker — the bespoke scheduler owns its
own fiber lifecycle; see implementation-plan Appendix A.4.4 and
`spike/concurrency-e1/triage/README.md`.

**Does this change the E1 verdict?** One sub-verdict changes materially;
the overall verdict does not.

- **RTT sub-verdict corrected.** Post-fix Dispatch ping-pong is
  **1.01 µs median / 0.95 µs min per RTT** — inside the 2–3×-BEAM target
  band and *better than Threaded* (1.79 µs) on the same session. The
  pre-fix characterization (~37 µs from the Debug-only run) reflected the
  Debug pathology, not the optimized fiber handoff; the earlier claim that
  "even a fixed Dispatch backend's cost structure cannot reach BEAM-class
  send" is **withdrawn for send/RTT**.
- **Spawn verdict stands, and it is architectural.** All three spawn shapes
  sit at **17–25 µs/task** post-fix — 6–25× outside the sub-µs–3 µs target
  — because the costs are structural, not bugs: ~60 MiB address-space
  reservation per fiber (`Io/Dispatch.zig` `Fiber.min_stack_size`), a fresh
  stack mmap per spawn (E9 measured that alone at 1.65 µs), and a GCD
  enqueue per task (µs-scale per the yardstick table). None of that is
  touched by the clobber fix.
- **Overall: fail on spawn → the escalation to a bespoke run-queue
  scheduler on `fiber.zig` stands**, now resting on spawn architecture,
  scheduling control (budgets/LIFO slot/determinism — see the S0.5 memo,
  implementation-plan Appendix A), and the residual intermittent crash —
  not on Dispatch's send path, which the fix vindicated.

### Phase 1 kernel re-measurement (P1-J6, 2026-07-06) — GATE: PASS

The Phase 1 exit-gate re-run of E1 on the REAL landed kernel
(`src/runtime/concurrency/`, the bespoke run-queue scheduler the Phase 0
escalation called for), replacing the spike's `Io.async`/`Io.Queue`
shapes with the kernel's real paths: scheduler spawn (pid acquire + PCB
init + pooled stack + fiber init + ready enqueue), envelope send/receive
through the real Vyukov mailboxes, and the futex wake path.

#### Methodology

- **Date:** 2026-07-06. Same machine as the Phase 0 series (MacBook Air
  `Mac16,13`, Apple M4, 10 cores, 32 GB, macOS 26.2 build 25C56).
- **Benchmark:** `bench/concurrency-kernel/bench.zig` (NOT throwaway —
  the Phase 3 per-manager spawn re-measurement and the Phase 4
  cross-scheduler E1 re-run extend it; see its README), compiled with
  the fork compiler (`~/projects/zig` @ `6a425dbaeb`, clean tree) at
  `-OReleaseFast` against the kernel tree at the P1-J6 commit:

  ```sh
  ~/projects/zig/zig-out/bin/zig build-exe -OReleaseFast --name bench \
    --dep concurrency -Mmain=bench.zig \
    -Mconcurrency=../../src/runtime/concurrency/concurrency.zig
  ```

- **Protocol:** unchanged from Phase 0 (one measurement at a time,
  foreground, unrecorded warmup pass = workload/10, then 5 timed reps,
  `CLOCK_UPTIME_RAW` never through code under test, `uptime` recorded
  immediately before every run). Other agent sessions were active —
  1-minute load average ranged **3.2–3.8** across the timed runs
  (comparable to the E9 session, quieter than pre-fix E1), so minima
  are the load-robust floor (standing caveat). Load was *decaying*
  across the session; several spawn runs show monotonically improving
  reps for that reason — medians are quoted, minima bound the floor.
- **Workloads:** `spawn` = timed batches of 256 admissions (pool-hit
  steady state — batch equals the stack pool's cache ceiling, and a
  512-process warmup wave makes the whole ceiling available; the bench
  asserts `pool_miss_batches == 0`), quiescence between batches
  untimed; 102,400 spawns per rep. `spawn-serial` = spawn one trivial
  process and run it to quiescence per op (full
  spawn→run→exit→teardown), 102,400 ops. `spawn-lifecycle` = timed
  (spawn 256 + run all to quiescence), amortized, 102,400 ops.
  `pingpong` = 100,000 round trips between two kernel processes via
  `ProcessContext.send`/`receive` (real lookup + envelope alloc +
  mailbox push + wake seam per hop; 1,020,006 quanta executed, zero
  parks — pure same-scheduler). `wake` = 100,000 parked-wake
  deliveries: a producer THREAD waits for the scheduler's park counter,
  settles 20 µs so the scheduler is inside the futex wait, then pushes;
  latency = push-instant → `receive` returns in the woken process
  (bounds Phase 4 cross-scheduler RTT). 510,005 parks over the run.
- **Manager caveat (honest):** per-process managers are the Phase 1
  TEST manager (arena + byte accounting, as in the kernel's own tests);
  the real per-spawn manager ABI is Phase 3. Spawn rows measure the
  kernel path with a cheap manager init/teardown, not the eventual
  ARC-manager cost — Phase 3 re-measures per manager.

#### Results (ReleaseFast, median / min per-op ns, 5 reps, 2026-07-06)

| Metric | Kernel | Load (1-min) |
|---|---:|---|
| spawn, admission only (ns/spawn) | **11.1 / 10.4** | 3.75 |
| spawn-serial, full lifecycle (ns/op) | **43.0 / 41.7** | 3.56 |
| spawn-lifecycle, amortized batch (ns/op) | **35.1 / 33.4** | 3.36 |
| ping-pong RTT, same-scheduler (ns/round-trip) | **44.4 / 44.2** | 3.33 |
| parked wake → receive returns (ns) | **5,042 median / 1,458 min**, p99 8,500–10,125 across reps | 3.21 |

**RTT run-to-run variance (P1-R3 adjudication, 2026-07-06).** An informal
rebuild during R1 observed ~150–170 ns/RTT under session load, so the
44.4 ns figure was re-adjudicated by measurement: two fresh back-to-back
ReleaseFast rebuild+runs of `pingpong` on the same kernel (foreground,
`uptime` recorded; 1-min load 2.55 and 3.66) gave medians **90.0 and
49.8 ns** with minima **68.4 and 45.0 ns**, reps improving monotonically
within every run. The minimum reproduces the recorded floor (45.0 vs
44.2, within 2%); the median is load- and warmth-sensitive — ~50–90 ns
across fresh runs, individual cold reps to 136 ns, ~150–170 ns in the R1
informal observation. Read the table's 44.4/44.2 row as the quiet-run
converged best case; under session load expect same-scheduler RTT
medians of ~50–90 ns — still ≥20× inside the 2–3 µs band, verdict
unaffected. This confirms the standing "minima are the load-robust
floor" caveat for RTT specifically.

#### Comparison vs targets, floors, and the Phase 0 backends

| Metric | Kernel (median) | Plan target | E9 substrate floor | `Io.Threaded` | `Io.Evented` post-fix |
|---|---:|---:|---:|---:|---:|
| spawn (admission) | 11.1 ns | sub-µs | 8.99 ns (pooled fiber spawn) | 1,382 ns (windowed, post-fix) | 19,117 ns |
| spawn (full lifecycle, serial) | 43.0 ns | sub-µs–3 µs | — | 4,316 ns (serial, pre-fix) | 19,840 ns |
| ping-pong RTT | 44.4 ns | ≤2–3 µs (2–3× BEAM) | 6.4 ns (switch pair) + 8.7–16 ns (queue floor) | 1,792 ns (post-fix) | 1,012 ns |
| parked wake → running | 5.0 µs (min 1.46 µs) | — (Phase 4 x-sched budget) | 917 ns median / 250 ns min (raw futex wake, thread awake) | — | — |

- **Spawn: PASS with ~2 orders of magnitude of headroom.** Admission is
  11.1 ns — 2.1 ns over the E9 raw pooled-fiber floor buys the pid slot,
  PCB init, envelope-handle init, ready enqueue, and the admission wake
  edge. Even the full serial lifecycle (43 ns) sits ~23× under the
  1 µs low end of the target band and ~100× under Threaded's serial
  spawn. The pool-only claim held: `pool_miss_batches=0` on every run.
- **RTT: PASS with ~23–40× margin.** 44.4 ns/RTT against the 2–3 µs
  band; the scheduler+mailbox budget consumed over the raw substrate
  floor is ≈38 ns/RTT (two sends with pid lookup + envelope alloc, two
  receives, two wake-seam drains, two switch pairs ≈ 12.8 ns of it) —
  22.8× better than post-fix Threaded and within a factor of ~7 of the
  bare switch-pair+queue floor. BEAM's sub-µs same-scheduler send is
  beaten by ~20×.
- **Wake path (informational; no Phase 1 target).** Wake-to-running
  min 1.46 µs ≈ the E9 parked-wake floor (~0.9–1 µs) plus the
  unpark→drain→schedule→switch-in path; the 5.0 µs median and 8.5–10 µs
  p99 carry this session's background load (19 sessions, load ~3.2) —
  consistent with E9's observation that parked-wake p99s of 3–11 µs are
  the number to design against. Phase 4's cross-scheduler RTT bound of
  two parked wakes therefore budgets ~3 µs floor, ~10 µs median under
  load — the LIFO-slot/spin-then-park design (Appendix A) exists
  precisely to keep the hot path off this cost.
- **Verdict: E1 gate PASS** (kill criterion "≥1–3 µs spawn or RTT >3×
  BEAM/Go" — spawn is 43 ns full-lifecycle, RTT is 44 ns; both are
  orders of magnitude inside). The Phase 1 numbers validate the S0.5
  escalation decision on its own terms: the bespoke kernel beats the
  best `std.Io` backend rows by 20–450× per metric with the test
  manager, and the remaining Phase 3 risk is manager cost, not kernel
  structure.

## E9 — fiber-switch floor + Darwin wakeup mechanism (S0.3, 2026-07-04)

Reframed after E1: both fork `std.Io` backends failed the E1 targets, so the
campaign builds a bespoke scheduler on raw `fiber.zig` context switching.
E9 measures the substrate floor (raw fiber switch/spawn/stack costs) and
compares the Darwin mechanisms our scheduler could use to wake a parked
scheduler thread.

### Methodology

- **Date:** 2026-07-04. Same machine as S0.1/E1 (MacBook Air `Mac16,13`,
  Apple M4, 10 cores, 32 GB, macOS 26.2 build 25C56).
- **Benchmarks:** `spike/concurrency-e9/{fiber_switch,wakeup}.zig`
  (throwaway spike; see its README), compiled with the asdf Zig 0.16.0
  binary against the fork's std (`~/projects/zig` @
  `b8fc76ac3f7cc11580a6801d3ccaa2d520f0af06`, clean tree):

  ```sh
  zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast fiber_switch.zig
  zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast wakeup.zig
  ```

- **Protocol:** one measurement at a time, foreground; unrecorded warmup
  (workload/10) then 5 timed repetitions; timing via `CLOCK_UPTIME_RAW`
  (~41.7 ns granularity on Apple Silicon — sub-100 ns numbers quantize to
  ~42 ns ticks). `uptime` recorded immediately before every run; other
  agent sessions were active — 1-minute load average ranged **3.4–3.8**
  across all runs (lighter and steadier than E1's 3.8–5.2).
- **Fiber workloads:** `pingpong` = 1,000,000 round trips of control between
  two fibers on one thread (per-op = one one-way switch; timed region holds
  exactly `2·N + 2` switches); `spawn` = 1,000,000 × (init context on a
  pooled stack → switch in → body immediately switches back); `stack` =
  100,000 × (mmap 256 KiB stack + PROT_NONE guard page + fault in top page +
  munmap). Fiber layout mirrors `Io/Dispatch.zig` (argument block at stack
  top, naked entry trampoline, fp = 0); a `wake_count` counter asserts all
  switches really executed.
- **Wakeup workloads:** 100,000 timed wakeups/rep. Main records t0, signals
  the worker's channel, parks on its own; the parked worker wakes, records
  t1, echoes back. Only main→worker is timed (t1 − t0, same clock). Main
  busy-waits 20 µs between iterations so the worker is reliably parked
  before each timed wake. All blocking waits carry 5 s panic timeouts.
  Default QoS, no pinning (macOS has no affinity API on Apple Silicon).

### FORK BUG (blocking finding): aarch64 `~{x30}` asm clobber silently dropped

Building the spike surfaced a miscompilation that makes the fork's
`std.Io.fiber.contextSwitch` **unusable in optimized builds as-is**:

- `contextSwitch` declares `.x30 = true` in its clobber set, but the Zig
  LLVM backend (`src/codegen/llvm/FuncGen.zig` clobber emission) writes the
  Zig field name into the constraint string — `~{x30}` — while LLVM's
  AArch64 link register is named `lr`. Clang translates user clobber
  `"x30"` → `"lr"`; Zig does not, and LLVM silently ignores unknown clobber
  names. Net effect: **LLVM believes x30 survives the switch** and at
  ReleaseFast allocates live pointers into it across the asm.
- Symptom in this spike (before the workaround): `fiberMain` kept its args
  pointer in x30; a resumed fiber saw the *other* fiber's x30. A 10 M-round-
  trip ping-pong "finished" in 0.01 s real with `total_ns=0`. Minimal repro:
  `-femit-llvm-ir` shows `~{x30}` in the IR while the disassembly carries a
  live pointer in x30 across the switch (`mov x30, x1` before, `ldr x8,
  [x30]` after).
- Debug builds are unaffected — matching E1's "works at `-ODebug`, dies at
  ReleaseFast/ReleaseSafe" Dispatch signature. This is the most plausible
  root cause of **E1 crashes 1–2** (Dispatch `Group.async` and blocking-
  queue suspend/resume segfaults; the PAC-looking ReleaseSafe fault address
  is consistent with control state derived from stale x30). The fork fix
  (map `x30` → `lr` in LLVM constraint emission, then re-run the E1 crash
  repros) is queued for the scheduler work; this measurement job makes no
  fork changes.
- To measure anyway, the spike uses a local copy of the primitive whose only
  change is a fourth `Context` word saving/restoring x30 per-context
  (+1 instruction — correct under either compiler behavior). The numbers
  below include that instruction; the properly fixed fork primitive would be
  marginally cheaper.

**FIXED in the fork (2026-07-04, `74c0b87fe5`):** upstream `codeberg/master`
has no fix (only its pre-existing MIPS clobber-override map), so the fork now
translates Zig clobber names to LLVM's per-target register names in
`appendConstraints` (`src/codegen/llvm/FuncGen.zig`), extending upstream's
MIPS mechanism. A full audit of every `std.builtin.assembly.Clobbers` arch
family against the LLVM 21 register defs found the same silent-drop bug
beyond aarch64 `x29/x30 → fp/lr`: arm `r13/r14 → sp/lr`, aarch64 SME tiles
`za{N}{q,d,s,h,b} → za{q,d,s,h,b}{N}`, avr `flags → sreg`, msp430
`r0/r1/r2 → pc/sp/sr`, riscv `vcsr → vxrm+vxsat`, sparc `ccr/xcc → icc`, ve
`s0–s63 → sx0–sx63`, `vixr → vix` — all now mapped (unmodeled-in-LLVM names
are left verbatim and are harmless; named register *constraints* fail loudly
in LLVM, so only clobbers had a silent path). Re-validation with the fixed
compiler: the x30 repro now emits `~{fp},~{lr}` (was `~{x29},~{x30}`),
`fiber.contextSwitch` IR carries `~{lr}`, and **both deterministic E1
segfaults are gone** — `bench evented pingpong 1 1 0` completes at
ReleaseFast *and* ReleaseSafe, `bench evented spawn-group 2000 2 200`
completes at ReleaseFast (plus a 2000-op × 3-rep evented ping-pong stress at
~784 ns/op, no crash; at that time no second bug had surfaced — the fuller
E1 re-measurement above later found an *intermittent* `spawn-serial`
SIGSEGV at higher volumes). This spike's `fiber_switch`
still passes with matching floor numbers (3.30 ns median one-way, 8.46 ns
spawn). `libzap_compiler.a` was rebuilt with the fix. The E1 `Io.Evented`
*performance* verdict and the `deinit` compile error (crash 3) are
unaffected.

**Erratum (round 2, 2026-07-04, fork `6a425dbaeb`):** the round-1 "full
audit" above used the wrong resolution criterion (it compared against
LLVM's register *names* generally, not against what
`TargetLowering::getRegForInlineAsmConstraint` actually resolves: the
TableGen *def* name of registers that are members of register classes with
target-legal value types, case-insensitive, plus per-target overrides).
Re-auditing against LLVM 21 sources with the correct criterion found:
(1) x86 `cc` and `rflags` were still silently dropped — the flags state
*is* modeled (EFLAGS ∈ CCR; the spelling `flags` resolves via X86's
override), so round 1's "unmodeled/harmless" classification was false;
both now translate to `flags`, and `std.Io.fiber.contextSwitch`'s
`.rflags` clobber verifiably reaches LLVM as `~{flags}` on x86_64. In
practice the drop was masked by the Clang-compat `~{dirflag},~{fpsr},
~{flags}` trailer Zig appends to every x86 asm (round 1's claim that "Zig
appends nothing" was also wrong), so no x86_64 fiber miscompile was live —
but correctness no longer depends on that trailer. (2) Round 1's aarch64
SME tile maps (`za{N}{s} → za{s}{N}`), riscv `vcsr → vxrm+vxsat`, and
sparc `ccr/xcc → icc` were all *no-ops* (targets of the translations
resolve nowhere: untyped register classes / no class membership); tiles
now widen to the resolvable `~{za}` (sound over-approximation), and the
dead riscv/sparc translations were removed with corrected rationale
(sparc condition codes are modeled but unreachable by any clobber
spelling — a Clang-shared upstream limitation, not "unmodeled"). (3) New:
lanai `sw → sr` (status word is modeled; round 1 called it unmodeled).
aarch64 x29/x30 → fp/lr and the arm/avr/msp430/ve/mips maps re-verified
effective under the correct criterion. New `test-llvm-ir` end-to-end cases
pin the emitted constraint strings (x86_64 `rflags`/`cc` → `~{flags}`,
fiber `contextSwitch` on x86_64, aarch64 `~{fp},~{lr}`, tile → `~{za}`).
Compiler + `libzap_compiler.a` rebuilt; aarch64 unaffected — E9
`fiber_switch` floors reproduce (2.98–3.32 ns one-way, spawn min 8.46 ns).

### Fiber-switch floor (ReleaseFast, median / min per-op ns, 5 reps)

| Metric | Median | Min | Load (1-min) |
|---|---:|---:|---|
| one-way context switch (ns) | 3.20 | 3.19 | 3.45 |
| control round trip, 2 switches (ns) | 6.39 | 6.38 | 3.45 |
| spawn floor, pooled stack (init + switch in + switch out, ns) | 8.99 | 8.99 | 3.45 |
| fresh stack (mmap + guard mprotect + first-page fault + munmap, ns) | 1,646 | 1,629 | 3.45 |

Rep-to-rep spread was <0.5% on the switch/spawn rows — these are stable
numbers despite background load (single-threaded, cache-resident).

### Cross-thread wakeup latency, parked thread (Darwin, ns, 100k wakeups × 5 reps)

Median = median of rep medians; min = min across all reps; p99 range = the
per-rep p99 spread. Load (1-min) at run start in parentheses.

| Mechanism | Median | Min | p99 range | Notes |
|---|---:|---:|---|---|
| spin (atomic flag, no syscall) | 83 | 0 | 84–209 | floor for an *awake* scheduler; ~2 clock ticks |
| `gcd-sem` (dispatch_semaphore) (3.43) | 792 | 708 | 5,333–7,333 | cheapest GCD wake |
| `ulock` (`__ulock_wait2`/`wake`, what fork `Io.Threaded` futex uses) (3.74) | 917 | 250 | 3,292–11,167 | fork has **no** `std.Thread.Futex`; this is its internal pair |
| `os-sync` (`os_sync_wait_on_address` public API, macOS 14.4+) (3.78) | 917 | 250 | 5,292–7,084 | identical cost to `ulock` (thin wrapper) |
| `kqueue` (EVFILT_USER trigger → kevent return) (3.53) | 958 | 833 | 6,208–10,166 | same wait point as I/O readiness |

Per-rep maxima ranged 68 µs–5.3 ms on all mechanisms (scheduler
preemption tails under load) — parked-wakeup p99s of 3–11 µs are the
number to design against, not the maxima.

### DECISION — Darwin wake mechanism and spin-then-park threshold

**Use the Darwin futex (`os_sync_wait_on_address` / `os_sync_wake_by_
address_any`, with `__ulock_wait2`/`__ulock_wake` as the pre-14.4 fallback
exactly as the fork's `Io.Threaded` already gates it) as the bespoke
scheduler's park/wake primitive for run-queue parking, and EVFILT_USER only
for threads parked inside the kqueue I/O poller.** Rationale: all four
kernel mechanisms land within ~20% (792–958 ns median), so semantics —
not latency — decide. The futex compare-and-wait is the only primitive that
atomically couples "park" with a run-queue generation/state word, giving
race-free sleep with no per-thread kernel object and a cheap no-op wake
(`ENOENT`) when nobody is parked; it is also the substrate the fork std
already uses, and the public `os_sync` API is stable ABI. GCD semaphores'
~120 ns median edge does not offset dragging libdispatch into a bespoke
runtime and decoupling the wake from scheduler state; kqueue's unified
wait point matters only for the poller thread, where its +40 ns (~1 clock
tick) premium over futex is irrelevant.

**Spin-then-park:** a parked wake costs ~900 ns (median) end-to-end while a
spinning thread observes a handoff in ~83 ns, so the crossover sits near
one park cost: spin ~1–2 µs (a few hundred `spinLoopHint` iterations on M4)
before parking. Piggybacking on the E1 finding that same-thread queue ops
floor at 13–16 ns, a scheduler that spins briefly before parking keeps
same-scheduler message RTT in the tens of ns and pays ~0.9 µs only on a
genuinely idle wake.

**Targets check (feeds S0.5):** the substrate comfortably supports the
campaign targets. Spawn floor is 9 ns with pooled stacks (sub-µs spawn has
~two orders of magnitude of headroom for allocator + run-queue + safepoint
bookkeeping); a same-scheduler RTT built on 6.4 ns switch pairs plus
13–16 ns queue ops sits far under BEAM's sub-µs send; cross-scheduler RTT
bounded by two parked wakes ≈ 1.8 µs median (within the ≤2–3 µs band), and
spin-then-park pulls the busy case toward ~166 ns. The 1.65 µs fresh-stack
cost rules out per-spawn mmap — **stack pooling (or segmented/virtual-memory
tricks) is mandatory** for BEAM-class spawn rates. Caveat: all of this is
contingent on fixing the dropped-x30-clobber fork bug above, which currently
breaks *any* optimized build of fiber-based code, including the E1 Dispatch
backend.

## E10 — vtable vs monomorphized alloc (S0.4, 2026-07-04)

Hot-path cost of allocation *dispatch*, validating the manager-
monomorphization hybrid (`zap-concurrency-research.md` §2.3): the same
few-instruction bump allocation function (limit check + bump over a
pre-reserved 1 MiB buffer, reset on exhaustion, never grown during timing)
reached through three call mechanisms — **inlined** (comptime-known
allocator, today's-Zap monomorphized shape), **direct** (same function
`noinline`, direct call), **vtable** (threadlocal `current_process` →
`Process.manager_vtable` → fn pointer → indirect call, the §2.3 cold-path
dispatch shape).

### Methodology

- **Date:** 2026-07-04. Same machine as S0.1/E1/E9 (MacBook Air `Mac16,13`,
  Apple M4, 10 cores, 32 GB, macOS 26.2 build 25C56).
- **Benchmark:** `spike/concurrency-e10/dispatch.zig` (throwaway spike; see
  its README), compiled with the **fixed fork compiler** from S0.3
  (`~/projects/zig` @ `74c0b87fe5f2191cef674be63222d90689881648`, the
  clobber-translation fix, clean tree):

  ```sh
  ~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib \
      -OReleaseFast -femit-asm=dispatch.s dispatch.zig
  ```

- **Protocol:** one measurement at a time, foreground; unrecorded warmup
  pass (ops/10) then 5 timed reps of 100,000,000 allocations each;
  median + min per-alloc ns. Timing via `CLOCK_UPTIME_RAW` (E1/E9
  convention). `uptime` recorded immediately before each run; 1-minute load
  average was **2.31** for the Shape A runs and **2.03–2.04** for Shape B —
  the quietest session of the Phase 0 series, and rep-to-rep spread was
  <2% on every row.
- **Shapes:** **A `pure`** = tight loop of 16-byte allocations, each
  returned pointer sunk through an empty register-constraint asm (worst
  case, maximally dispatch-sensitive). **B `mix`** = allocate 32-byte
  nodes, write 3 fields each, build 8-node lists, traverse into a checksum
  (sunk via `doNotOptimizeAway`), discard (dispatch diluted by real work).
  1 MiB buffer keeps the working set L2-resident so the measurement is
  about dispatch, not memory bandwidth; each rep asserts (outside the timed
  region) that the buffer wrapped — ~1,526 (A) / ~3,052 (B) resets per rep,
  so reset cost is amortized to noise and allocations provably executed.
- **Anti-elision/devirtualization:** a decoy second manager behind a second
  vtable, selectable only at runtime via argv (never selected in recorded
  runs; `decoy_allocs=0` printed as proof), keeps the vtable and fn-pointer
  loads non-constant.
- **Asm verification (evidence in the spike README):** each shape × variant
  loop sits under its own `noinline` symbol in `dispatch.s`. Confirmed: the
  inlined loops contain **no call instructions** (≈10-instruction body);
  the direct loops contain the direct `bl _dispatch.bumpAllocOutlined`
  (8× unrolled in Shape B); the vtable loops perform the full double
  indirection **per allocation** — load `Process` pointer from the TLS
  slot, `ldp` context+vtable, load fn pointer, `blr` — and are not
  devirtualized. Darwin wrinkle: the `current_process` threadlocal read is
  a call through the TLV thunk; in Shape A that thunk call executes per
  allocation (two `blr`s per alloc), in Shape B LLVM hoisted it to once per
  8-alloc list while still reloading process/vtable/fn-pointer per alloc.

### Results (ReleaseFast, per-alloc ns, 100 M allocs × 5 reps)

| Shape | Variant | Median | Min | vs inlined (median) | vs inlined (min) |
|---|---|---:|---:|---:|---:|
| A pure-alloc | inlined | 1.604 | 1.600 | — | — |
| A pure-alloc | direct (noinline) | 1.704 | 1.690 | **+6.2%** | +5.6% |
| A pure-alloc | vtable-indirect | 1.826 | 1.808 | **+13.8%** | +13.0% |
| B node-mix | inlined | 1.892 | 1.873 | — | — |
| B node-mix | direct (noinline) | 1.943 | 1.918 | **+2.7%** | +2.4% |
| B node-mix | vtable-indirect | 1.980 | 1.977 | **+4.7%** | +5.6% |

Absolute vtable-vs-inlined delta: **+0.22 ns/alloc** (A), **+0.09 ns/alloc**
(B) — the M4's out-of-order core overlaps most of the dispatch chain with
surrounding work, and its indirect-branch predictor is perfect here because
the call target is monomorphic at runtime (a real multi-manager binary's
cold paths would add occasional indirect-branch mispredicts on top).

### DECISION — hybrid split confirmed

**The data confirms the §2.3 hybrid: monomorphize hot allocating paths;
vtable-dispatch is tolerable for cold ones.** On the pure-alloc worst case,
vtable dispatch costs **+13.8% median (+13.0% min)** over the monomorphized
shape — nearly 5× the E2 kill criterion (2–3% CLBG regression) and
~1.8× Go's 7.8%-geomean yardstick for a single extra back-edge instruction,
on top of an allocator that is *already* memory-bound on its own state.
No dispatch of any kind belongs on the alloc hot path. The direct-call
variant sharpens the point: merely losing inlining costs **+6.2%** in the
pure shape — roughly half the total vtable penalty — so the hot-path rule
must be *monomorphized and inlined*, not "direct call into a per-model
function"; per-model specialization only pays if the alloc fast path is
inlined into the hot loop, which is exactly what the plan's
monomorphization arm does. For cold paths the verdict flips: the absolute
cost is +0.09–0.22 ns per allocation, and with even the minimal real work
of Shape B (three field writes + an 8-node traversal per node) the relative
overhead collapses to **+4.7%** of an already tiny per-alloc figure; any
genuinely cold, rarely-allocating function amortizes that to nothing (a
single L2 miss costs two orders of magnitude more). "Resolve once at spawn,
then indirect-call through the PCB's manager vtable" is therefore
empirically sound as the cold-path arm, matching the plan's reasoning.
One design note for Phase 1: on Darwin the `current_process()` threadlocal
lookup is itself a call (TLV thunk) and is part of the measured cost —
scheduler code should load the process pointer once per scheduling quantum
(or keep it in a reserved register) rather than re-resolving the
threadlocal at every dispatch site, since LLVM cannot always hoist it (it
did per-list in Shape B, per-alloc in Shape A).

## E4 — manager-monomorphization code size (P3-J2, 2026-07-07) — GATE: PASS

The companion to E10. E10 measured the *runtime* cost of NOT monomorphizing
(vtable dispatch = +13.8% pure / +4.7% mix); E4 measures the *code-size* cost
of monomorphizing — the price the hybrid pays to avoid that dispatch. Kill
criterion (plan §6): post-ICF text growth exceeds the CLBG binary-size budget
→ shift more paths to vtable dispatch.

**What a model specialization is, in codegen terms.** J2 lowers a spawn-
reachable function per reclamation model by installing that model's caps as the
function's active `declared_caps` for its emission (`ZirDriver.effectiveDeclaredCaps`
→ `elision.canonicalCaps`). The HIR/IR body is IDENTICAL across a source
function's model specializations — only the header-emission ops (retain /
release / free) are emitted or elided, per model. So the *exact* code a
REFCOUNTED specialization emits vs a BULK_OR_NEVER one is what you get by
compiling the SAME source under `-Dmemory=Memory.ARC` vs `-Dmemory=Memory.Arena`.
That is the measurement below (real binaries, existing single-model machinery —
the multi-model driver that puts both in ONE binary is J3, item 3.1/3.3).

**Probe.** `tmp/e4_mm_codesize.zap` (kept as `bench/mm-codesize/e4_mm_codesize.zap`):
a spawn-reachable-shaped allocating subgraph — `driver → build_list →
build_list_from` (cons cells in a loop) `→ sum_list → sum_from` (fold) — five
functions, the shape of a per-process worker hot path. Compiled aarch64-macos.

**Whole-binary `__TEXT,__text` (ReleaseFast), `size -m`:**

| build | reclamation model | `__text` bytes | refcount syms (`nm`) |
|---|---|---|---|
| `-Dmemory=Memory.ARC`   | REFCOUNTED    | 227,160 | 16 |
| `-Dmemory=Memory.Arena` | BULK_OR_NEVER | 223,468 |  2 |
| **delta** | | **+3,692 (+1.65%)** | |

The whole-binary delta (3.7 KB) is an UPPER bound on one specialization's cost:
it includes the one-time ARC runtime machinery (`ArcRuntime.retain/release/…`)
that is present under ARC and folds away under Arena. In a real multi-model
binary that machinery is present ONCE (shared), so the per-specialization
*user-code* cost is smaller — isolated next.

**Per-function user-code sizes (Debug, so functions stay distinct; sizes via
`nm -n` address deltas):**

| function | ARC (REFCOUNTED) | Arena (BULK_OR_NEVER) | delta |
|---|---|---|---|
| `build_list_from` (cons/alloc) | 148 | 148 | **0** |
| `build_list`                    |  56 |  56 | **0** |
| `sum_from`  (fold/consume)      | 508 | 240 | 268 |
| `driver_from`                   | 292 | 152 | 140 |
| `sum_list`                      | 168 |  40 | 128 |
| **spawn-reachable subgraph**    | **1,172** | **636** | **536** |

The two allocating functions (`build_list_from`, `build_list`) have **zero**
delta — their specializations are BYTE-IDENTICAL across models (a freshly-owned
cons needs no retain, and the moved `acc` needs no release). This is the
empirical confirmation of the ICF claim: a spawn-reachable function that does
not emit differing header ops produces identical specializations that linker
ICF folds to ×1. Only the list-*consuming* functions (`sum_from`, `driver_from`,
`sum_list`) carry a per-model delta (the elided releases), totalling 536 bytes.

**Projection to 1 / 2 / 4 models (post-ICF).** ICF folds byte-identical
functions; the J2 foldability verifier guarantees each specialization is
structurally identical to its source modulo header ops, so the ONLY thing that
can keep two specializations of a function from folding is a genuine header-op
difference:

| models in use | user-code text (subgraph) | growth over 1-model |
|---|---|---|
| 1 (manifest = ARC) | 1,172 (baseline) | — |
| 2 (ARC + Arena)    | 204 folded + 968 (ARC-differing) + 432 (Arena-differing) = **1,604** | **+432 B** |
| 4 (ARC + Arena + Tracking + GC) | ≈ **1,604** | **≈ +432 B** |

The 4-model row is ≈ the 2-model row, and this is the load-bearing result: the
three non-refcounted models (BULK_OR_NEVER, TRACED, and INDIVIDUAL_NO_REFCOUNT
absent a deep-walk) emit IDENTICAL header ops for these functions — they all
elide retain/release — so their specializations are byte-identical and ICF
folds all three into ONE copy. Worst-case post-ICF growth is bounded by
(**≤2 distinct emission shapes** — refcounted vs not — for a typical function,
NOT ×4) × (spawn-reachable subgraph text), on top of one shared runtime. For
this subgraph that is +432 bytes; scaled to a realistic worker it stays low-KB.

**Verdict: PASS.** Post-ICF growth is a small, bounded multiple (≤ the number of
distinct header-emission shapes ≤ 2 for refcount-splitting functions) of the
spawn-reachable text, far under any reasonable CLBG binary-size budget (whole-
program `__text` here is 227 KB; the projected growth is sub-KB). The kill
criterion is not tripped. The designed caps hold: the §2.3 vtable-dispatch arm
keeps the *specialized* set confined to genuinely-hot allocating functions
(Callable-existential cold paths are never cloned — `saw_cold_edge`), and ICF
folds both the memory-op-free functions and the same-emission models. Calibrates
with **Nim arc→orc** (orc "produces more machine code than arc" — a modest
single-digit-% delta; ours is comparable in spirit and *sub-linear in model
count* thanks to same-emission folding) and with **E10** (the code-size cost we
accept to avoid E10's +13.8% dispatch tax is bounded and small).

**Two honest caveats, both J-scoped, neither affecting the verdict:**

1. **Darwin has no linker ICF today.** aarch64-macos links through the fork's
   self-hosted Mach-O linker (`~/projects/zig/src/link/MachO.zig`), which
   implements dead-strip but not identical-code folding (lld is not used for
   Mach-O). So the post-ICF numbers above are the *structural* projection —
   validated by the measured zero-delta functions (byte-identical → foldable)
   and by J2's compile-time foldability verifier — not a linker-applied fold.
   On an ICF-capable target (ELF via lld `--icf=all`) the folds are realized by
   the linker. Enabling Mach-O ICF (a new `MachO/icf.zig` in the fork, analogous
   to `MachO/dead_strip.zig`) is a decoupled fork task; until it lands, an actual
   Darwin multi-model binary would carry the *pre*-ICF size (Σ per-model), which
   for this subgraph is 1,808 B vs the 1,604 B post-ICF — a 204 B difference,
   still far under budget. The J2 **red-flag verifier** is the target-independent
   substitute for "did ICF fold?": it flags at COMPILE time any specialization
   that is not structurally foldable (would not fold even with ICF), which is the
   early kill signal the research names.

2. **Single-binary multi-model measurement is J3.** The per-model deltas above
   are measured across two single-model binaries because the driver that
   resolves multiple managers and rewires spawn sites into ONE binary is J3
   (item 3.1/3.3). J2 delivers + unit-tests the specialization mechanism
   (`monomorphize.specializeSpawnManagers`: ≤4 model specializations of the
   spawn-reachable subgraph, correctly tagged, calls redirected, cold edges
   excluded) and the per-function emit/elide codegen
   (`ZirDriver.effectiveDeclaredCaps`); the end-to-end multi-model binary that
   exercises all specializations at once lands with J3's wiring, at which point
   this projection becomes a direct measurement.

## OQ1 — current-process resolution on the alloc hot path (A.4 OQ1, P3-J1, 2026-07-07) — RESOLVED

Appendix A.4 open question 1 — "register vs parameter for the
current-process pointer" — re-pointed to Phase 3 by P2-R1/D3 because the
cost it must beat, the alloc-path current-process lookup, does not exist
until per-process managers make the lookup hot. P3-J1 lands those managers
(each process owns its own ARC context; `src/runtime.zig`
`currentManagerContext`), so the lookup is now measurable. This is the E10
question reframed from "how to DISPATCH the alloc" to "how to RESOLVE the
context the alloc needs".

### Methodology

- **Date:** 2026-07-07. Same machine as S0.1/E1/E9/E10 (MacBook Air
  `Mac16,13`, Apple M4, 10 cores, 32 GB, macOS 26.2).
- **Benchmark:** `spike/concurrency-oq1/resolve.zig` (throwaway spike;
  E10 methodology verbatim — same `CLOCK_UPTIME_RAW` clock, 1 MiB
  L2-resident bump buffer pre-faulted and never grown, unrecorded warmup
  then 5 timed reps of 100 M allocations, median + min per-alloc ns,
  post-region reset assertion proving the buffer wrapped, and a
  runtime-selectable decoy context (`decoy_allocs=0` printed as proof)
  keeping the real path non-constant). Built with the fork compiler at
  ReleaseFast. The **allocation body is byte-identical and inlined in all
  three variants** — only the CONTEXT RESOLUTION differs, isolating the
  number this decision turns on.
- **Variants:** **`register`** = the context resolved ONCE and carried in a
  local/register across the loop (the ceiling the J2 monomorphization /
  parameter-threading arm targets; A.4 rules out a globally reserved
  register on aarch64 — x18 is Darwin-reserved — so this stands in for
  "resolved once per quantum, threaded as a parameter"). **`published`** =
  the P3-J1 SHIP: the context read from the scheduler-published global
  `zap_proc_active_arc_context` on every allocation (modelled as an
  atomic-monotonic load = aarch64 `LDR`, non-hoisted, matching the real
  cross-TU extern var reloaded across the opaque manager call). **`ambient`**
  = the Phase-2 shape: a `zap_proc_current()`-style out-of-line C-ABI call
  per allocation. **Asm-verified** (`resolve.s`): the published loop does a
  per-iteration `ldr` of the published global; the ambient loop does a
  per-iteration `bl _ambientCurrentContext`; the register loop hoists the
  resolve entirely.
- **Load:** 1-minute average **3.2** (busier than the E10 session), so the
  ABSOLUTE ns run a touch high; the RELATIVE deltas (what the decision
  turns on) held with <2% rep-to-rep spread, and the register ceiling
  (1.615 ns) matches E10's inlined pure floor (1.604 ns) — confirming the
  session is comparable.

### Results (ReleaseFast, per-alloc ns, 100 M allocs × 5 reps)

| Shape | Variant | Median | Min | vs register (median) | vs register (min) |
|---|---|---:|---:|---:|---:|
| A pure-alloc | register (ceiling) | 1.615 | 1.605 | — | — |
| A pure-alloc | **published (P3-J1)** | 1.651 | 1.632 | **+2.2%** | +1.7% |
| A pure-alloc | ambient (Phase-2) | 1.757 | 1.734 | **+8.8%** | +8.0% |
| B node-mix | register (ceiling) | 2.004 | 1.957 | — | — |
| B node-mix | **published (P3-J1)** | 2.019 | 1.984 | **+0.7%** | +1.4% |
| B node-mix | ambient (Phase-2) | 2.067 | 2.050 | **+3.1%** | +4.8% |

Published-vs-ambient head-to-head: ambient is **+6.4% (pure) / +2.4% (mix)**
slower than published.

### DECISION — published-per-quantum global; ambient rejected; register is the J2 ceiling

**A.4 OQ1 resolves to the PUBLISHED-PER-QUANTUM GLOBAL.** The runtime reaches
each process's private context by reading the scheduler-published
`zap_proc_active_arc_context` (one `LDR`) — NOT the Phase-2 ambient
`zap_proc_current()` per-allocation call. The data is decisive and consistent
with the E10 yardstick (a call cost +6.2% direct / +13.8% vtable there):
- **published costs only +2.2% median on the pure-alloc worst case (+0.7% on
  the realistic mix)** over the register/parameter ceiling — INSIDE the E2
  kill criterion (2–3% CLBG regression), and near-free once diluted by real
  work;
- **ambient costs +8.8% pure / +3.1% mix** — ~4× the published cost on the
  worst case and over the E2 budget on its own; the extern call is the
  expensive part (a load beats a call, exactly as E10 predicted);
- so among the mechanisms realizable in Phase-3 emitted code (no compiler
  frame-threading), **published wins outright**, and it is what P3-J1 ships.

**The register/parameter ceiling (resolved once per quantum, carried in a
register) remains the target of the J2 monomorphization arm** — it buys back
the residual +2.2%, which only matters on a pure-alloc tight loop and is worth
the specialization there. Full frame-threading of the context through emitted
Zap code needs the monomorphization pass (plan item 3.2, J2); until then
published is the ship. This realizes the feasible half of the standing
"resolve once per quantum, parameter-thread" lean now, and hands the last
2.2% to J2. (The Phase-1 kernel is already fully parameter-threaded
internally — A.4 OQ1's amendment — so J2 extends that discipline into the
compiled surface.)

## E3 — same-model race validation (Phase 1 half, P1-J6, 2026-07-06) — GATE: PASS

The Phase 1 half of gate E3 (gate table: "E3 TSan copy matrix +
sender-dies", phases 1 same-model / 3 full). **Scope honesty:** Phase 1
payloads are opaque (the ARC deep-copy walker is plan item 2.4), so
"ARC→ARC copy under TSan" cannot exist yet; the Phase 1 same-model scope
is ZERO races in the kernel's shared machinery under adversarial
concurrency — mailbox links, envelope page ownership/abandon/reclaim,
pid-table slot transitions, scheduler wake/park — with the
payload-refcount rule (no refcount ever touched cross-thread;
`mailbox.zig`) preserved by construction and asserted where expressible
(payloads are stamped opaque words; nothing dereferences them
cross-thread). The reachable-pair copy matrix re-runs as E3's full half
in Phase 3.

### ThreadSanitizer availability (resolved: AVAILABLE)

The fork compiler supports `-fsanitize-thread` for aarch64-macos test
builds end-to-end (fork @ `6a425dbaeb`). Positive control: a
deliberately racy two-thread counter program compiled at ReleaseFast
reports `WARNING: ThreadSanitizer: data race` with correct stacks.
Finding-fatality control: TSan's default exit code did NOT propagate
through the test runner in this setup, so every gate run sets
`TSAN_OPTIONS="halt_on_error=1 abort_on_error=1"` (verified: findings
then SIGABRT, exit 134) AND the captured output is grepped for
`ThreadSanitizer|WARNING|data race`.

### Method and volumes

1. **Kernel test suite under TSan** — all 98 tests
   (`src/runtime/concurrency/concurrency.zig`), strict options:
   * Debug: 98/98 pass, **zero findings**.
   * ReleaseFast: 96/96 pass (+2 Debug-only skips), **zero findings**.
2. **Dedicated adversarial stress**
   (`src/runtime/concurrency/adversarial_stress.zig`, committed as part
   of the kernel suite; `ZAP_ADVERSARIAL_STRESS_ROUNDS` scales it).
   Six producer THREADS against the scheduler thread, per round: a
   stale-pid dead-letter storm racing the current round's slot
   acquisitions in LIFO-reused slots (every stale lookup must miss —
   a resolve is a §2.4 generation-reuse bug; reasons tallied and only
   `generation_mismatch`/`slot_not_occupied` permitted); mid-flight
   sender death (ephemeral envelope handles abandoned immediately after
   each push + the round handle abandoned while receivers still free
   from its pages); sinks killed `.runnable` with populated mailboxes
   while producers are still pushing to the round's consumers (teardown
   drain + abandoned-page reclaim overlapping live cross-thread
   pushes); victims killed at the non-cooperative `.waiting` point;
   futex park/wake pressure (consumers block mid-round; producers spray
   spurious `wake()`/`requestWatchdogPreemption()` and walk the
   lock-free live iterator without PCB dereference). Every round ends
   with a full barrier and EXACT accounting: consumer receipts with
   per-producer pairwise-FIFO order, sink budgets, kill outcomes by
   state, crash-report mailbox depths at death (sinks die with exactly
   their leftovers, everyone else empty), dead-letter counter delta ==
   producers' locally observed miss count, and zero live/abandoned
   pages, zero live stacks, zero live processes. Contract discipline:
   every push targets a process provably alive across the lookup→push
   window (the out-of-contract foreign-push-vs-teardown race is the
   documented Phase 4 PCB-lifetime caveat and is not exercisable in
   Phase 1); stale-pid traffic is the in-contract shape of "sending to
   exiting/dead processes".
3. **TSan-monitored adversarial volume** (strict options, all clean):
   2×1,000-round standalone runs (Debug 12.4 s, ReleaseFast 9.5 s) +
   **15×1,000-round ReleaseFast chunks + 3×1,000-round Debug chunks run
   back-to-back** (~5 minutes of sustained TSan-monitored adversarial
   concurrency; fresh TSan state per chunk — see the limitation below)
   ≈ **20,000 rounds ≈ 220,000 process lifecycles, ~4 M cross-thread
   envelopes, ~4 M racing stale lookups under TSan. ZERO findings.**
4. **Uninstrumented soak (exact accounting as the oracle):**
   ReleaseFast at **100,000 rounds** — 1.1 M process lifecycles,
   ~19.8 M cross-thread envelopes, ~19.8 M stale-pid probes racing slot
   transitions, ~880 k abandoned-page reclaims, 22.7 s wall — **zero
   invariant violations**; Debug at 10,000 rounds likewise clean.
   Committed CI default: 120 rounds (seconds-scale), in `zig build
   test` / `test-kernel` at Debug + ReleaseFast.

### TSan-runtime limitation found (documented, not a kernel finding)

Single-process adversarial runs ≥ ~4,000 rounds at ReleaseFast crash
INSIDE ThreadSanitizer's runtime — verbatim head of the report
(`handle_segv=0` run, full log in the P1-J6 job record):

```
==94194==ERROR: ThreadSanitizer: BUS on unknown address (pc … T31821900)
==94194==The signal is caused by a WRITE memory access.
    #0 __tsan::TraceSwitchPartImpl(__tsan::ThreadState*) tsan_rtl.cpp:1052
    #1 __tsan::TraceRestartMemoryAccess(…) tsan_rtl_access.cpp:416
    #2 __tsan_atomic64_fetch_add tsan_interface_atomic.cpp:631
    #3 Thread.PosixThreadImpl.spawn….Instance.entryFn Thread.zig:752
```

The fault is a wild WRITE inside TSan's own trace-part allocator while
servicing an ordinary `fetchAdd` from a producer thread — trace-capacity
exhaustion of TSan v3's per-thread event history on Darwin/arm64 at
extreme event volume (`history_size=2` and `flush_memory_ms=1000` do not
avoid it; Debug+TSan additionally degrades superlinearly near the
threshold). Kernel exoneration: the fault frames are entirely within
`tsan_rtl`; the identical binary logic runs **clean at 25× that volume
uninstrumented** (100 k rounds, exact accounting); and TSan itself is
clean across 20 k+ rounds when chunked below the trace-capacity
threshold. Mitigation for future gates: chunk long TSan soaks at ≤1,000
rounds per process (as above). The Phase 4 Linux CI leg of E3 (full
matrix, per the plan's gate table) should re-probe the threshold there,
where TSan's trace allocator behaves differently.

### Verdict

**PASS.** Zero ThreadSanitizer findings across the full kernel suite and
~20,000 adversarial rounds at both optimize modes; zero invariant
violations across 111 k+ uninstrumented rounds (≈1.3 M lifecycles); no
kernel change of any kind was needed (the one-line-ordering-fix budget
went unused). The payload-refcount rule is untestable-by-TSan until the
Phase 2 copy walker exists — preserved by construction (opaque stamped
payloads; the only cross-thread atomics are the mailbox links and pool
page words, per the `mailbox.zig`/`envelope_pool.zig` inventories) and
scheduled for direct TSan coverage in E3's full half (Phase 3).

## E3 — cross-thread refcount race validation (full half, P3-J1, 2026-07-07) — GATE: PASS

The Phase-3 full half of gate E3 (gate table: "any cross-scheduler
refcount race → stop-ship"), unblocked by P3-J1's per-process manager
INSTANCES: the payload-refcount rule (Constraint 3 — no refcount is ever
touched by two threads), preserved by construction in the Phase-1 half
(opaque payloads, no real per-process manager), is now proven under
ThreadSanitizer against REAL per-process ARC contexts and REAL atomic
refcounts.

### Harness

`src/memory/arc/cross_thread_stress.zig` drives the REAL production ARC
manager (`src/memory/arc/manager.zig`) — imported directly, since multiple
independent ARC instances exist only off the real manager, not the host
runtime's single `test_only_arc` context. **N=4 producer THREADS, each
owning its OWN private ARC context**, concurrently: `allocate_refcounted`
a 32-byte cell (rc=1) in their private slab pool, exercise the ATOMIC
`retain_sized`/`release_sized` on that own cell, read its data into a FLAT
message (zero live refcount in flight — the item-3.1 design), release the
cell (rc→0, freed back into that producer's pool), and hand the flat
message across threads. **The consumer thread owns a SEPARATE private ARC
context and ADOPTS** each message by allocating a fresh rc=1 cell in its
own pool, verifying end-to-end data integrity, then releasing it. Every
context is thread-exclusive; the cross-thread payload is flat, never a
refcounted cell — so no two threads ever touch the same slab pool or the
same cell's side-table refcount.

### Method, volumes, result

TSan with `TSAN_OPTIONS="halt_on_error=1 abort_on_error=1"`, output grepped
for `ThreadSanitizer|WARNING|data race` (P1-J6 §E3 discipline):

- default (8,000 cross-thread ARC messages): **zero findings**, 10/10 tests
  pass under TSan, exit 0;
- soak `ZAP_ARC_XTHREAD_ROUNDS=25000` (**100,000 cross-thread ARC
  messages** = 100 k `allocate_refcounted` + retain/release + adopt +
  release across five private contexts): **zero findings**, exit 0;
- Debug + ReleaseFast (via `zig build test` aggregation, uninstrumented):
  leak-exact — every slab any context mapped during the run is unmapped at
  that context's `deinit` (`test_slab_mmap_total` delta == unmap delta),
  and every adopted message's checksum verifies.

### Verdict

**PASS.** Zero ThreadSanitizer findings across 100 k concurrent
cross-thread ARC messages over real per-process manager instances; the
scheduler-local-refcount invariant is now proven by MEASUREMENT (not just
the by-construction argument the Phase-1 half rested on). No manager change
was needed. **Concurrency shape tested:** N sender threads (each a private
manager) + a single adopting consumer — the Phase-3 single-scheduler shape
(the mailbox push side is any-thread; the adopt runs on the one scheduler
thread). **Remaining for Phase 4:** the M:N axis — multiple SCHEDULER
threads each running receivers that adopt into their own per-process
contexts concurrently — which the Phase-4 Linux CI leg of E3 covers once
processes migrate across scheduler threads; the invariant is unchanged
(per-process contexts ⇒ no shared refcount), Phase 4 only widens the set of
threads that can run the adopt.

## E2 — safepoint overhead

**VERDICT: PASS (P2-J6, 2026-07-07).** Kill criterion (>2–3% on
nbody/spectral-norm gate-ON vs gate-OFF) NOT tripped. The three-layer
cooperative safepoints (comptime-gated on `runtime_concurrency`) clear the
gate with a wide margin on the CLBG "wins".

Method: quiet-machine INTERLEAVED PAIRED re-baseline (plan item 2.9). For
each benchmark a gate-OFF and a gate-ON-concurrency-compiled binary were
built with the SAME fork compiler (`-Doptimize=ReleaseFast`, gate-ON adds
`-Druntime-concurrency=on`), then run alternately (off, on, off, on, …) in
one session; paired medians. Load avg during the runs 2.3–3.1 (recorded per
run); the paired-interleaved discipline cancels shared load. 15 and 25 reps,
two sessions — deltas stable to ≤1 pt between sessions.

| Benchmark (args)        | gate-OFF | gate-ON | Δ | shape |
|-------------------------|----------|---------|-----|-------|
| **nbody** (5,000,000)   | 0.1058 s | 0.1032 s | **−2%** | alloc-free loopified — register poll |
| **spectral-norm** (2500)| 0.1658 s | 0.1617 s | **−2%** | alloc-free loopified — register poll |
| mandelbrot (4000)       | 0.5223 s | 0.5425 s | +3% | musttail — global-counter poll |
| fannkuch-redux (10)     | 0.2355 s | 0.2604 s | +10–11% | very tight loopified — register poll |
| binarytrees (16)        | 0.1312 s | 0.1335 s | +1% | allocating loopified |

**The kill-criterion loops (nbody, spectral-norm) are within measurement
noise (±2%) — the loop-local register poll (`subs`/`cbz`, no per-iteration
memory) is hidden in their FP-heavy loop bodies. This beats Go's 7.8%
geomean back-edge figure by a wide margin (effectively 0 on these shapes).**
Verified inline: the emitted nbody `step_loop` poll is `sub xN, xN, #1` +
`cbz xN, <slow>` with the counter register-promoted; the slow-path
`bl zap_proc_safepoint_slow` is taken only once per reduction budget.

Non-kill-criterion regressions (honestly reported, NOT gating): fannkuch's
`reverse_range`/`count_flips` are extremely tight integer/list loops where
the 2-instruction register poll is a larger fraction of the body (+10–11%);
mandelbrot's `iter`/`row_loop` are TCO-safe (trivial params) → musttail →
the poll rides the global reduction counter, whose per-iteration load/store
costs +3%. Both are the inherent cost of cooperative safepoints on tight
non-FP loops (the same class of cost Go measured). Gate-OFF these benchmarks
are unchanged (proven durable at HEAD: the gate-OFF binary carries zero
`zap_proc_*`/`safepoint` symbols and zero poll call sites — see the
Zero-cost-OFF proof below, which also records a point-in-time byte-identical
`__text` checkpoint), and the CLBG suite is normally run gate-OFF — the gate-ON
figure is the "compiled a CLBG kernel WITH preemptive concurrency" scenario.

Documented mitigation for the tight-loop regressions (NOT required — the
kill criterion passed): loop unrolling to amortize the poll over K
iterations (Go's mitigation), and forcing loopification of musttail loops
gate-ON so mandelbrot's poll becomes register-local too. Deferred as a
follow-up optimization pass; noted in the ledger for whoever picks it up.

Zero-cost-OFF proof (the whole point of the comptime gate). The **durable,
HEAD-stable** evidence is symbol- and instruction-level and does NOT depend on
cross-commit byte-stability: a gate-OFF nbody compiled at **HEAD `ecb9113`**
(aarch64-macos, `-OReleaseFast`, fork compiler) carries **zero
`zap_proc_*`/`reductions`/`safepoint` symbols** — verified `nm`: 0 matches of
`zap_proc_`, `reduction`, or `safepoint` across all 801 symbols (the only
`proc`-substring hits are unrelated OS-process symbols, `_Io.Threaded.process*`
/ `abortProcess`, never the concurrency kernel) — and its `__TEXT,__text`
disassembly (58 085 lines via `otool -tV`) contains **zero
`safepoint`/`zap_proc`/`reduction` references**, i.e. no `bl
zap_proc_safepoint_slow` call site and no reductions-counter access anywhere in
gate-OFF code. This is the property that matters (the gate emits no concurrency
machinery), and no amount of always-linked driver churn can invalidate it.

Point-in-time byte anchors (a stronger check *when it reproduces*, but fragile
across commits because the `__text` bytes fold in every always-linked object):
the fresh HEAD-`ecb9113` gate-OFF nbody `__TEXT,__text` SHA-256 is
`d81ead45…d8e8a49` (extracted via `segedit -extract __TEXT __text | shasum -a
256`). The earlier **J6 checkpoint `5075af40…dbb5ecd`** — a `__text` byte-identical
between the pre-J6 and post-J6 compilers — **no longer reproduces at HEAD**: it
drifted because J7's concurrency-verifier registration and J9's `runtime.zig`
`resetAllocator` fix are now always linked into the driver, shifting `__text`
bytes *without adding any gate-ON concurrency code*. That drift is precisely why
the durable proof above is stated at the symbol/instruction level. The CLBG wins
are untouched with the gate off.

## E5 — region detach/adopt (P3-J5, 2026-07-07) — the same-model O(1) region-move

**VERDICT: the same-model region MOVE is O(1) — detach+adopt is 1–2 ns,
INDEPENDENT of payload size (measured 4 KiB … 1 MiB), with pointer identity
preserved (zero relocation) and leak-exact reclamation — vs the copy send's
O(size) cost (a bare `memcpy` alone is 48 µs at 1 MB, and E6's `Map` reconstruct
is 2.19 ms). The move eliminates the O(size) copy entirely for the value shapes
where it is sound.** This is the E5 gate the plan (item 6.1, exit-gate row E5)
requires: "truly O(1) and leak-free, else copy-on-move stays, documented."

### The R4 resolution (the honest mechanism)

R4 (plan item 2.4/3.3) asked whether an O(1) re-parent is achievable given that
a live ARC `List`/`Map` cell is a single contiguous allocation. The P2-J5
finding was "single `c_allocator` block per cell → no relocatable region." **P3-J1
sharpened this**: under the concurrency gate a `List`/`String` container buffer
routes through the running process's OWN ARC manager core, landing in one of two
disciplines, and the answer differs per discipline:

- **SLAB-backed (≤ `MAX_SLAB_CLASS_SIZE` = 4096 B):** the buffer is one slot
  interleaved with UNRELATED cells in a shared 64 KiB slab whose free/partial
  bookkeeping is per-context. A single slot cannot be re-parented to another
  context without dragging its co-tenants (and would race the sender's own slab
  mutation). **NOT O(1)-relocatable — degrades to copy** (small, so copy is on
  the cheap side of the E6 crossover).
- **LARGE (> 4096 B → `page_allocator` mmap):** a standalone block tracked ONLY
  by intrusive membership in the owning context's `large_head` list
  (`LargeHeader.prev/next`); `munmap` is process-global. **This is the one
  discipline that supports a sound O(1) cross-process re-parent:** `detachRegion`
  unlinks the `LargeHeader` from the sender's `large_head`, `adoptRegion` relinks
  it into the receiver's — both scheduler-local (each touched only in its owner's
  quantum, no atomics), the refcount left untouched (rc == 1 ⇒ sole reference, so
  no cross-thread refcount touch — the sacred scheduler-local invariant holds by
  construction). An undelivered move's orphan is reclaimed context-free by
  `freeDetachedRegion` (`munmap`, no list surgery).

The mechanism is delivered as ABI **v1.2** on the REFCOUNT_V1 capability
(`detach_region` / `adopt_region` / `free_detached_region`; only ARC/ORC
implement it — Arena/NoOp/Leak/Tracking are untouched). The `Process.send_move`
surface consumes its message; the region-closure verifier
(`src/concurrency_verifier.zig`) proves MOVE-ELIGIBILITY (rc == 1 + region-closed
over the escape+ownership lattice), and the runtime attempts the O(1) move for a
flat `List(scalar)` large cell sent to a same-model receiver, degrading to copy
otherwise.

**R4 residual (documented, honest):** `Map` cells are still allocated through
`c_allocator` directly (un-migrated even under the gate), so a `Map` is NOT on
the large path and its send DEGRADES TO COPY today — the E6 `Map` catastrophe is
addressed IN-MECHANISM (the O(1) move fixes it the moment a large `Map` cell
routes through `largeAlloc`) but not yet applied to `Map`. Making the map-send
O(1) is the one-call-site follow-up of migrating `Map.bufferAlloc`/
`bufferFreeShallow` to `containerBufferAlloc`/`Free` (the exact gate-branch
`List` already carries), after which `movableFlatListCell` extends to
`movableFlatMapCell`. Nested graphs (a `List`/`Map` of `String`/`List`/`Map`)
have interior ARC children in separate cells and also copy.

### Measurement

- **Date:** 2026-07-07. Same machine as the series (Apple M4).
- **Manager-level (the O(1) claim lives here):** `detachRegion` + `adoptRegion`
  on real ARC large cells, ping-ponged between two contexts, per-op time
  (`-OReleaseFast`, fork compiler):

  | payload | move (detach+adopt) | copy (`memcpy` only) |
  |---|---|---|
  | 4 KiB   | **1–2 ns** | ~0 (sub-resolution) |
  | 16 KiB  | **1–2 ns** | small |
  | 256 KiB | **1–2 ns** | ~11 µs |
  | 1 MiB   | **1–2 ns** | ~48 µs |

  The move is FLAT (constant ~4 pointer writes — one intrusive unlink + one
  relink — regardless of size); the copy is linear. At 1 MB the move is ~24,000×
  a bare `memcpy` and ~1,000,000× the E6 `Map` reconstruct (2.19 ms).
- **Structural O(1) proof (in the test suite):** `src/memory/arc/manager.zig`
  test "detach/adopt is O(1) — cost is independent of buffer size" asserts
  POINTER IDENTITY across 4 KiB…1 MiB (zero relocation), and the leak-exactness
  tests assert the sender's teardown skips the moved block, the receiver reclaims
  it, and an un-adopted orphan is reclaimed exactly once (`test_large_free_total`
  deltas).

**Leak-exactness:** proven at three points — delivered (receiver adopts, its
release reclaims), dead-lettered (sender re-owns: re-adopt + release), and
receiver-teardown-drain (the kernel drain invokes the fragment's
`moved_reclaim`, `munmap`ing the orphan). Every path frees the moved backing
exactly once.

### Gate-ON end-to-end + ThreadSanitizer (P3-J5-VERIFY, 2026-07-08)

The E5 mechanism above is proven at the manager level; this closes the two
end-to-end links the P3-J5 job left un-run.

- **Language-surface behavioral proof (gate-ON `:test_concurrency`).** After
  rebuilding the zap CLI (`zig build -Dzap-compiler-lib=… -Dllvm-lib-path=…`),
  `./zig-out/bin/zap run test_concurrency` — the `build.zap` `:test_concurrency`
  manifest target (`runtime_concurrency: true`, root
  `TestConcurrency.TestRunner`, glob `test_concurrency/**/*_test.zap`) — reports
  **59 tests, 0 failures; 117 assertions, 0 failures** (process exit 0) at HEAD
  (**56 tests / 110 assertions** as of P3-J5; the suite grew by P3-J6 and P3-R1a —
  see the suite-growth line below). The gate is baked into the manifest target
  (no `-Druntime-concurrency=on` needed). These include
  `test_concurrency/move_send_test.zap`'s 3 `Process.send_move` cases
  (confirmed present by name in the `--timings` per-test list): a LARGE
  uniquely-owned `List` move-sends and the receiver gets the whole value; a SMALL
  slab-backed `List` transparently degrades to copy and still delivers; a moved
  `List` is a fresh value the receiver solely owns. Use-after-move stays a
  compile error (pinned in `src/zir_integration_tests.zig`). Suite growth:
  50/0 (P3-J3) → 53/0 (P3-J4) → 56/0 (P3-J5) → 57/0 (P3-J6, `orc_test.zap`) →
  **59/0 (P3-R1a, per-process retain/release dispatch tests)**.

- **Scheduler-local-refcount invariant across the move — now by MEASUREMENT.**
  The manager-level claim rests the cross-thread safety of detach/adopt on
  "rc == 1 ⇒ no cross-thread refcount touch, by construction." A dedicated
  ThreadSanitizer harness now proves it by measurement, mirroring E3's full-half
  method: `src/memory/arc/cross_thread_stress.zig`'s new `runMoveSendArcStress` —
  N=4 ARC sender threads, each on its OWN private ARC context, allocate a LARGE
  (8 KiB) refcounted cell, `detachRegion` it, and hand it BY POINTER to a single
  consumer that `adoptRegion`s it into its own context, verifies the physical
  bytes crossed intact (`seq` + checksum + tail sentinel), and releases it
  (rc 1 → 0, `munmap`). This is the ONE send shape where a real heap cell crosses
  the thread boundary — the copy harnesses (P3-J1 / P3-J4) hand only flat data.
  `TSAN_OPTIONS="halt_on_error=1 abort_on_error=1"
  zig test -fsanitize-thread src/memory/arc/cross_thread_stress.zig`: **zero
  findings** at the 8,000-cell default AND a 20,000-cell soak
  (`ZAP_ARC_XTHREAD_ROUNDS=5000`), leak-exact (`test_large_alloc_total` delta ==
  `test_large_free_total` delta), exit 0 — grep for `ThreadSanitizer|WARNING|data
  race` empty. Scope note: Phase-3's scheduler is single-threaded, so a *real*
  move runs detach and adopt on the same OS thread; the harness deliberately
  models the more-conservative cross-thread shape (the mailbox push side is
  any-thread by design), forward-looking to Phase 4's M:N scheduler — the
  invariant is unchanged (per-process contexts ⇒ no shared refcount).

## E6 — copy crossover (P2-J9, 2026-07-07) — first crossover measurement

**VERDICT: crossover is LATE for flat scalar payloads (~1 KB) and IMMEDIATE +
catastrophic for `Map` payloads (~256 B, hash-rebuild reconstruct).** The
plan's two-copy serialize-to-blob send (P2-J5 walker; the R4 note at plan item
2.4) is *free relative to the ~44 ns same-scheduler RTT floor for messages up
to ~1 KB of flat scalars* — the common BEAM small-message actor pattern pays
essentially nothing — but the **receiver-side reconstruct (Copy C) dominates**
and, for `Map`, rebuilds the hash table entry-by-entry, making a 1 MB map send
cost **2.19 ms** (150× a bare 1 MB `memcpy`). That split is the Phase-3
prioritization signal: the O(1) region-move / bulk-adopt path (R4/R5) is
*deferrable for small flat messages* but *urgent for maps and large payloads*,
and the win lives in eliminating the reconstruct, not the serialize.

This is the Phase-2 measurement of item **2.8** (moved from S0.1 because it
needs the 2.4 walker) and quantifies the 2-copy cost the **P2-J5 R4 note**
flagged (plan item 2.4, "serialize-to-blob (2 copies)…the 2-copy cost is
exactly what item 2.8's copy-p99-vs-size harness feeds into the E6 crossover
measurement"; the R4/R5 fallback at item 3.3). Re-run in Phase 6 after the
Blob/move path lands (gate table row E6).

### Methodology

- **Date:** 2026-07-07. Same machine as the whole series (MacBook Air
  `Mac16,13`, Apple M4, 10 cores, 32 GB, macOS 26.2 build 25C56).
- **Harness:** `bench/concurrency-copy/bench.zig` (NOT throwaway — re-runs in
  Phase 6), compiled with the fork compiler (`~/projects/zig` @
  `6a425dbaeb`, clean tree) at `-OReleaseFast`. It links the REAL runtime
  (`src/runtime.zig`) against the REAL production **ARC manager**
  (`src/memory/arc/manager.zig`, whose `zap_memory_section` the runtime's weak
  extern binds), so the copied values are real refcounted `List`/`Map`/`String`
  ARC cells (`refcount_v1_active == true`) and the two timed copies are the
  exact walker passes `Process.send`/`receive` run — `serializeMessage`
  (**Copy A**, sender: walk graph → `c_allocator` blob, the allocator
  `send_message` uses) and `deserializeMessage` (**Copy C**, receiver: allocate
  FRESH rc=1 ARC cells → copy bytes out). Exact module-graph build command in
  the bench README. This is NOT a synthetic memcpy — it is the real 2-copy
  walker on real ARC cells.
- **Protocol (E1/E9/E10 conventions):** one measurement at a time, foreground,
  `uptime` recorded before each mode (`run-copy-bench.sh`). Timing via
  `CLOCK_UPTIME_RAW` directly in the harness, never through the walker. Per
  size: unrecorded warmup, then **7 reps** (≥5 per the ledger) each collecting
  a per-op latency sample; samples **pooled across reps** → median / min / p99.
  A separate **clock-overhead-free floor** (`rt_floor`) times the round trip in
  small sub-batches and keeps the MIN per-op across every group and rep — the
  un-preempted group, so neither the ~42 ns per-op clock tick (E9) nor load is
  in it; it is the number the sub-tick small sizes need. **Load** 1-min ranged
  **2.4–3.7** across the run (moderate; other agent sessions active) — medians
  carry that load, **the min and `rt_floor` are the load-robust floor** (the
  standing caveat), and the tight `rt_repmed` spreads show the medians are
  nonetheless stable. Anti-elision: every reconstructed value's element count
  is asserted (forces the copy) + a touched-byte checksum is
  `doNotOptimizeAway`n.
- **Message shapes + sizing (documented in the bench README):** blob byte
  targets 64 B → 1 MB; the row's actual blob is sized to the target by the
  grammar and printed. `list` = `List(i64)`, blob `= 4 + 8n` (flat scalars,
  cheapest — pure memcpy). `map` = `Map(i64,i64)`, blob `= 4 + 16n` (reconstruct
  rebuilds the hash table via `put_owned_unchecked`). `string` = `List(String)`
  of 16-byte strings, blob `= 4 + n·(4+16)` (reconstruct does one
  `runtime_arena` allocation per element). `list`/`map` sweep the full range;
  `string` is capped at 64 KB (bounded arena growth — the scalar/map sweeps
  carry the crossover).
- **Substrate honesty:** Phase-2 reality — ONE binary-wide ARC instance (plan
  item 3.1 makes managers per-process); reconstruct allocates through the
  production ARC slab pool (representative cell-allocation cost). A latent
  compile error in `runtime.zig`'s never-before-analyzed `pub fn
  resetAllocator` (ignored the `bool` from `ArenaAllocator.reset`) was surfaced
  and fixed by this job (the bench is its first caller).
- **The floor to beat:** the E1/P1-J6 same-scheduler RTT — **44 ns** median /
  44 ns min (quiet-run converged; ~50–90 ns median under session load). A copy
  cheaper than this is hidden inside the message-passing mechanism itself.

### `List(i64)` — primary scalar sweep (median / min / p99 per-op ns, 7 reps)

| Blob (B) | elems | round-trip median | min | p99 | floor | serialize (A) | reconstruct (C) | RT ÷ 44 ns |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 60 | 7 | 0 | 0 | 42 | 35 | 0 | 0 | ≈1× |
| 252 | 31 | 41 | 0 | 42 | 47 | 0 | 0 | ≈1× |
| 1 020 | 127 | 83 | 0 | 84 | 96 | 41 | 42 | **~2×** |
| 4 092 | 511 | 208 | 125 | 209 | 217 | 42 | 166 | ~5× |
| 16 380 | 2 047 | 708 | 625 | 792 | 737 | 167 | 542 | ~16× |
| 65 532 | 8 191 | 3 458 | 3 208 | 4 000 | 4 047 | 1 167 | 2 250 | ~79× |
| 262 140 | 32 767 | 12 208 | 11 958 | 14 791 | 13 602 | 3 292 | 8 333 | ~278× |
| 1 048 572 | 131 071 | 45 834 | 45 542 | 52 500 | 49 756 | 12 542 | 32 709 | ~1 042× |

### `Map(i64,i64)` sweep (median / min per-op ns, 7 reps)

| Blob (B) | entries | round-trip median | min | p99 | serialize (A) | reconstruct (C) | RT ÷ 44 ns |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 52 | 3 | 42 | 0 | 84 | 0 | 42 | ≈1× |
| 244 | 15 | 375 | 208 | 625 | 0 | 375 | **~8.5×** |
| 1 012 | 63 | 1 792 | 1 250 | 2 917 | 41 | 1 791 | ~41× |
| 4 084 | 255 | 7 375 | 6 000 | 8 833 | 83 | 7 292 | ~168× |
| 16 372 | 1 023 | 30 958 | 27 208 | 35 584 | 333 | 30 500 | ~704× |
| 65 524 | 4 095 | 124 791 | 116 208 | 136 333 | 1 542 | 122 750 | ~2 836× |
| 262 132 | 16 383 | 515 000 | 493 834 | 549 166 | 5 875 | 511 167 | ~11 705× |
| 1 048 564 | 65 535 | 2 189 917 | 2 119 750 | 2 291 042 | 22 750 | 2 165 583 | ~49 771× |

### `List(String)` (16-byte elements) sweep (median / min per-op ns, 7 reps)

| Blob (B) | elems | round-trip median | min | p99 | serialize (A) | reconstruct (C) |
|---:|---:|---:|---:|---:|---:|---:|
| 64 | 3 | 41 | 0 | 42 | 0 | 41 |
| 244 | 12 | 83 | 0 | 125 | 41 | 42 |
| 1 024 | 51 | 333 | 250 | 417 | 125 | 208 |
| 4 084 | 204 | 1 250 | 1 208 | 1 375 | 500 | 833 |
| 16 384 | 819 | 5 083 | 5 000 | 6 417 | 2 041 | 3 250 |
| 65 524 | 3 276 | 21 333 | 20 667 | 25 625 | 8 292 | 13 541 |

### Calibration — clock floor + transport copy (Copy B proxy)

Per-op `CLOCK_UPTIME_RAW` read cost **12.8 ns** (the per-op-sampling floor;
the tick quantizes to ~42 ns, so sub-tick sizes are read off `rt_floor`). Bare
`@memcpy` of a blob-sized buffer — the kernel transport copy (**Copy B**: the
size-proportional `@memcpy` `zap_proc_send` does into the mailbox ledger,
`src/runtime/concurrency/abi.zig`), the third size-dependent memcpy a full
send→receive adds on top of the two walker copies and the payload-independent
~44 ns mailbox RTT:

| Blob (B) | 64 | 256 | 1 024 | 4 096 | 16 384 | 65 536 | 262 144 | 1 048 576 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| memcpy ns | 1.5 | 2.6 | 9.4 | 37 | 136 | 741 | 3 409 | 14 162 |

### Crossover verdict

"Significant" is defined concretely as **round-trip copy ≥ 2× the 44 ns
same-scheduler RTT floor (≥ ~88 ns)** — the point where the copy is no longer
hidden inside the message-passing mechanism; "dominant" as **≥ 10× the floor
(≥ 440 ns)**.

- **`List(i64)` (flat scalars): crossover ≈ 1 KB.** At ≤ 256 B the round trip
  is 0–41 ns — at or below the RTT floor, i.e. the two copies are *free*
  relative to sending the message at all. It reaches ~2× the floor at ~1 KB
  (127 elems, 83 ns / floor 96 ns), ~5× at 4 KB, and becomes **dominant
  (~16×) at ~16 KB**. Even 1 MB is only ~46 µs.
- **`Map(i64,i64)`: crossover is IMMEDIATE (~256 B) and the cost is
  catastrophic.** 15 entries (244 B) already cost 375 ns (~8.5× the floor);
  the round trip is ~168× the floor by 4 KB and reaches **2.19 ms at 1 MB —
  150× the 14 µs bare `memcpy` of the same bytes** — because the reconstruct
  rebuilds the hash table one `put_owned_unchecked` at a time (hash + probe +
  incremental-growth rehash), work the flat memcpy never does.
- **`List(String)`: intermediate, crossover ~256 B–1 KB** (2× floor at ~256 B,
  7.5× at ~1 KB) — the per-element `runtime_arena` allocation on reconstruct
  costs more than a flat list but far less than a map's hash rebuild.

**Against the research anchors.** Erlang's **64-byte** refc-binary threshold
(copy ≤ 64 B, zero-copy refc-share above) is *conservative* for Zap's flat
scalars: our copy stays ≤ the RTT floor to ~256 B and only crosses at ~1 KB —
flat data can be copied ~16× longer than Erlang's binary cutoff before it
matters. But the `Map` result argues the *opposite* for structured data: the
reconstruct's hash rebuild makes maps cross ~4× earlier than Erlang's byte
cutoff would suggest, at ~256 B. The protobuf/`bytes` precedent (serialize/parse
cost ∝ payload, µs/MB for flat data) matches the `list`/`string` rows; the map
rows are the parse-side hash-build outlier those precedents also see.

### Two-copy attribution (serialize vs reconstruct)

The receiver-side **reconstruct (Copy C) is the dominant half everywhere**, and
`serialize (A) + reconstruct (C)` reconciles with the round trip (e.g. `Map`
1 MB: 22 750 + 2 165 583 = 2 188 333 ≈ 2 189 917 round-trip):

| Shape (1 MB / 64 KB) | serialize A | reconstruct C | C ÷ A |
|---|---:|---:|---:|
| `List(i64)` @ 1 MB | 12 542 ns | 32 709 ns | **2.6×** |
| `List(String)` @ 64 KB | 8 292 ns | 13 541 ns | 1.6× |
| `Map(i64,i64)` @ 1 MB | 22 750 ns | 2 165 583 ns | **95×** |

Serialize is a linear walk + one `c_allocator` blob (`writeValue` is memcpy-
class); reconstruct additionally *allocates* — fresh rc=1 ARC cells (`list`),
per-element arena strings (`string`), or a from-scratch hash table (`map`).
The full send→receive adds Copy B (the transport `memcpy` above, e.g. 14 µs at
1 MB) and the ~44 ns mailbox RTT, so a real 1 MB `List(i64)` message ≈ 12.5 µs
(A) + 14 µs (B) + 32.7 µs (C) ≈ **~59 µs end-to-end**; a 1 MB `Map` ≈ **~2.2 ms**,
almost entirely Copy C.

### Phase-3 implication — feeds R4/R5 prioritization

The crossover is **late for flat scalars, early and catastrophic for maps**,
and the cost is **concentrated in the reconstruct** — which is exactly the copy
the O(1) region-move / refcounted-adopt path (research.md §6.4, risk **R4** at
research.md:237; the R4/R5 fallback at plan item 3.3) eliminates. Therefore:

1. **Flat small messages (< 1 KB): defer.** Copy ≤ the RTT floor; the
   O(1)-move/`Blob` machinery buys nothing for the common BEAM actor pattern.
   The verifier + docs may keep serialize-to-blob as the flat-scalar path
   indefinitely for these sizes.
2. **`Map` payloads: prioritize.** The hash-rebuild reconstruct crosses at
   ~256 B and reaches milliseconds — the strongest case in this measurement for
   a Phase-3 intervention. It specifically justifies the plan item 3.3
   **`BULK_OR_NEVER` page-splice / bulk-adopt** reconstruct (move the entry
   region wholesale instead of re-hashing), and it means the R4 degradation the
   P2-J5 note recorded (cross-process move falls back to the 2-copy serialize
   because ARC `List`/`Map` cells are single `c_allocator` blocks) is *most
   expensive for exactly the container that most needs relocatable/arena-backed
   buffers* (R4 remediation option (a)).
3. **Large flat/string payloads: valuable, not blocking.** Tens of µs at
   1 MB — an O(1)-move is a throughput win for bulk-data pipelines, secondary
   to the map case.
4. **`Blob` tier (§6.2/6.3): mild.** `String` is the least-penalized shape here;
   zero-copy immutable `Blob` share helps large-string traffic but is not the
   Phase-3 urgency the map reconstruct is.

Net: **an early crossover for maps pulls the R4 bulk-adopt/move path forward
for structured containers; a late crossover for flat scalars lets it be
deferred there.** Re-run E6 in Phase 6 with the move path on and compare the
`Map` row against the 2.19 ms/MB serialize-to-blob baseline recorded here.

## E8 — conservative fiber-stack scan (P3-J6, 2026-07-08) — GATE: PASS (mark-sweep ships as TRACED)

E8 decides the **tracing-GC roster**: can the conservative mark-sweep collector
(`src/memory/gc/manager.zig`, `Memory.GC`, TRACED) run PER-PROCESS, which
requires conservatively scanning a suspended fiber's saved register context +
private guard-paged stack for pointers into a private heap? Kill criterion (plan
§6): unbounded scan cost or false-retention keeping demonstrably-dead cyclic
graphs alive → mark-sweep out of v1, ORC-over-ARC the sole cyclic model.

**ORC-over-ARC ships regardless of this verdict** (`src/memory/orc/manager.zig`):
it works on the refcount graph and needs NO stack scan. E8 decides only whether
conservative mark-sweep ALSO ships.

### Structural finding — the scan is complete on Darwin/aarch64

The fork fiber `Context` on aarch64 saves only `{sp, fp, pc}`; the context-switch
asm (`~/projects/zig` `lib/std/Io/fiber.zig`) clobbers `x19–x28`/`x30`, forcing
the compiler to spill every live callee-saved register onto the fiber's OWN stack
around the yield. So a single sweep of the live span `[savedRegisters.stack_pointer,
stack.top())` already covers the saved callee-saved registers — there is no
separate register save area a conservative scan could miss. This is the property
that makes a per-fiber conservative scan well-defined here; the Boehm-with-green-
threads register-root fragility the research flags (Q4) does not bite on
Darwin/aarch64. Reused primitives: `fiber_context.savedRegisters` (pub) +
`Stack.top()`/`Stack.usable()` (pub); the containment predicate mirrors the GC's
`findOwningRecord` (`src/memory/gc/manager.zig`).

### Methodology

`src/runtime/concurrency/e8_fiber_scan.zig` (wired into the kernel suite). Build
512 tracked objects (48 B each) at page-allocator addresses; suspend a real fiber
holding genuine pointers to 32 of them plus 8192 words (64 KiB) of realistic +
adversarial (full-range PRNG) non-pointer stack data; conservatively sweep the
fiber's live span word-by-word (binary-search interval containment); best-of-5.

### Results (median span ≈ 66 KiB, aarch64)

| build | scan cost | ns/KiB | genuine pointers found | false-retentions | false-retention rate |
|---|---|---|---|---|---|
| ReleaseFast (fork zig) | 67 µs / 66 KiB | **1,036 ns/KiB** | 32 / 32 | 0 / 480 | **0.00000%** |
| Debug (stock zig) | 335–595 µs / 66 KiB | 5,120–9,095 ns/KiB | 32 / 32 | 0 / 480 | **0.00000%** |

* **Scan cost is BOUNDED** — ~1 µs/KiB (ReleaseFast), linear in stack size with a
  low constant. A typical few-KB live fiber stack scans in microseconds; a full
  256 KiB stack in ~0.25 ms. Not unbounded.
* **Coincidental false-retention is NEGLIGIBLE** — 0 of 480 non-referenced
  objects retained, even with adversarial full-range stack words. The 48-bit
  address space makes the tracked heap a vanishing fraction (512 × 48 B ≈ 24 KB
  of 2⁴⁸), so a non-pointer word almost never lands interior to an object.
* **Scan is COMPLETE over the stack span** — all 32 genuine pointers found,
  confirming the `[sp, top())` sweep covers the entire live stack. Note the 32
  planted pointers live in an on-stack buffer, so this result measures *stack*
  completeness directly; it does not by itself exercise a pointer held only in a
  callee-saved register. Register coverage is argued **structurally** (the file
  header's Darwin/aarch64 finding): the context-switch asm clobbers `x19–x28`/
  `x30`, forcing the compiler to spill every live callee-saved register onto the
  fiber's own stack around the yield, so any register-resident pointer is already
  within the swept `[sp, top())` span — there is no separate register save area
  the sweep could miss. The 32/32 measurement confirms the span is swept
  completely; the asm-clobber argument is what makes that span sufficient.

### Verdict: PASS — `Memory.GC` (TRACED) ships as a per-process spawn option

The kill criterion is not tripped (bounded cost, negligible coincidental
false-retention, complete root coverage). Conservative per-fiber mark-sweep is
VIABLE on Darwin/aarch64, so `Memory.GC` ships as the TRACED per-process model
alongside ORC. **ORC-over-ARC remains the *recommended* cyclic model**, because
conservative scanning carries a hazard E8's coincidental measurement does not
remove: **stale-pointer false-retention** — a live stack slot still holding a
pointer to a semantically-dead object (a dropped local not yet overwritten) keeps
that object, or a dead cycle it anchors, alive for a cycle. That imprecision is
inherent to conservative stack scanning and bounded only by live stack depth; ORC
(precise refcount graph, no stack scan, deterministic, no stop-the-world) has no
such hazard. `Memory.GC` is therefore positioned for FFI-heavy / opaque heaps
where precise refcounting is impossible; ORC is the default cyclic recommendation.

### Companion — the ORC-shares-REFCOUNTED-specialization hypothesis (CONFIRMED)

E8's counterpart verifies the P3-J6 key hypothesis (zap-concurrency-research.md
§2.5). `Memory.ORC` declares `declared_caps == 0x1`, byte-identical to `Memory.ARC`
→ `elision.reclamationModel` = `.refcounted` → `src/monomorphize.zig` keys it onto
ARC's `.refcounted` specialization (the key is the 4-value `hir.ReclamationModel`
enum; there is no separate ORC specialization). The Bacon–Rajan cycle-root
buffering lives entirely inside the ORC manager's `release`/`release_sized`
(`noteDecrement` → `possibleRoot`) — a runtime black box behind the `retain`/
`release` ABI vtable slots, so an ARC process and an ORC process emit and run the
IDENTICAL retain/release code. Proven at three layers: (1) `src/memory/elision.zig`
— caps `0x1` ⇒ `.refcounted`, indistinguishable from ARC to every codegen gate;
(2) `src/builder.zig` stdlib-manager matrix — the ORC adapter resolves to
`expected_caps = 0x1`, `expected_model = .refcounted`, same row shape as ARC;
(3) end-to-end — `test_concurrency/orc_test.zap` spawns an ARC child and an ORC
child in ONE binary, both carrying the `refcounted` pid model bits (0), each on
its own heap. Cycle collection is manager-internal (one new `CYCL` capability
descriptor, never a new Axis-A model), proven exhaustively in
`src/memory/orc/manager.zig`'s unit tests: a self-referential cycle and a
three-node cycle are built through the ORC ABI, dropped, and reclaimed
(leak-exact via the backing allocator's leak check — a negative control with the
collector disabled reports the cycle leaked); acyclic data is reclaimed promptly
by the ARC base with no regression; an externally-reachable cycle is NOT wrongly
collected. These are **manager-unit-level** proofs (cycles built in Zig through
the ABI); a **surface-level** Zap-builds-a-cycle test is infeasible today because
Zap is immutable (no `A → B → A` back-edge is expressible) and `CYCL`'s per-type
`register_cell_type` auto-registration is not yet wired to the runtime container
types — so ORC-as-a-correct-manager is done while its user-visible cycle
collection is **dormant-until-mutation** (see plan item 3.4). **Hypothesis:
CONFIRMED — ORC shares the REFCOUNTED specialization exactly, zero additional
monomorphized code.**

## Baseline comparison yardstick

External systems' spawn/RTT numbers (from `research-round-2.md` Q10) — the
judging yardstick for E1 and the scheduler decision memo (S0.5):

| System | Spawn/task creation | Message/channel RTT | Source basis |
|---|---|---|---|
| Tokio task | ~10 ns overhead (below measurability at 10 ms tasks) | mpsc low-ns | InfluxData measurement; Tokio budget blog |
| Go goroutine | low-hundreds ns | channel low-µs | Go runtime literature |
| BEAM process | sub-µs spawn | same-scheduler send sub-µs; cross-scheduler higher | Erlang benchmarking docs; NVLang ping-pong |
| GCD `dispatch_async` | ~µs-scale enqueue | — | Darwin Dispatch (tier-1 backend) |
| kqueue/io_uring wakeup | µs-scale RTT | — | OS event backends |
