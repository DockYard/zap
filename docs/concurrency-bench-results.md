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
are byte-for-byte unchanged (proven: nbody `__TEXT,__text` SHA is identical
pre/post-J6), and the CLBG suite is normally run gate-OFF — the gate-ON
figure is the "compiled a CLBG kernel WITH preemptive concurrency" scenario.

Documented mitigation for the tight-loop regressions (NOT required — the
kill criterion passed): loop unrolling to amortize the poll over K
iterations (Go's mitigation), and forcing loopification of musttail loops
gate-ON so mandelbrot's poll becomes register-local too. Deferred as a
follow-up optimization pass; noted in the ledger for whoever picks it up.

Zero-cost-OFF proof (the whole point of the comptime gate): a gate-OFF nbody
compiled with the post-J6 compiler has a `__TEXT,__text` section SHA-256
BYTE-IDENTICAL to one compiled with the pre-J6 compiler
(`5075af40…dbb5ecd`), and carries NO `zap_proc_*`/`reductions`/`safepoint`
symbols. The CLBG wins are untouched with the gate off.

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
