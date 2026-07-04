# Concurrency Campaign — Benchmark Results

Results ledger for the concurrency implementation campaign
(`docs/concurrency-implementation-plan.md`). Job **S0.1** (Phase 0) recorded the
CLBG performance baseline below on pre-concurrency `main` so that every later
phase — especially the **E2** safepoint-overhead gate — has an apples-to-apples
reference. Zap's CLBG standing (n-body, spectral-norm wins) is a hard
requirement of the campaign; any run that regresses these numbers by more than
the E2 kill criterion (>2–3% on n-body/spectral-norm) triggers the unrolling
mitigation before concurrency-on ships.

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

For scale only — from the committed `lang-benches` full-suite run of
2026-07-03 (`run-all.sh`, 5 runs, same machine, previous day's compiler
build). These are **not** the E2 reference numbers; the table above is.

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

## E9 — Dispatch vs Kqueue (Darwin)

*Reserved — filled by the Phase 0 S0.3 spike. Fiber-switch + wakeup latency on
each backend; picks the tier-1 Darwin default.*

## E10 — vtable vs monomorphized alloc

*Reserved — filled by the Phase 0 S0.4 spike. Confirms the manager
monomorphization hybrid's hot/cold split empirically.*

## E2 — safepoint overhead

*Reserved — filled in Phase 2. CLBG suite re-run with concurrency compiled ON,
against the S0.1 baseline table above. Kill criterion: >2–3% regression on
n-body/spectral-norm → unrolling mitigation first. Alloc-piggyback must be
≈ 0 on allocating loops; the bare back-edge poll is the number to watch
(Go's back-edge figure to beat: 7.8% geomean).*

## E6 — copy crossover

*Reserved — filled in Phase 2 (re-run in Phase 6). Copy p99 vs message size,
64 B–1 MB; the crossover point drives the steal-vs-copy (Blob/move) decision.*

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
