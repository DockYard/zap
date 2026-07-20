# Phase B — Per-Test Hard-Failure Isolation for Zest

## Problem

Phase A made **recoverable** raises catchable: a `raise` reaching an
unhandled frame is threaded through error unions and caught by the Zest
per-test landing pad (`lib/zest/case.zap`, `try { test() } rescue { … }`),
recorded as a failure, and the run continues. That covers *soft* failures.

**Hard** failures are still fatal to the whole run:

1. **`@panic` / fatal abort** — the kernel's panics abort the OS process
   (`src/runtime/concurrency/panic_guards.zig`: "A panic cannot be observed
   in-process"). One `@panic` in any test kills the entire suite.
2. **Hardware faults** — SEGV/BUS/FPE/ILL/TRAP. `runtime.installCrashHandlers`
   prints a crash report, but the process still dies.
3. **Timeout / infinite loop** — a non-yielding test hangs the run forever.

A lightweight `spawn_monitor` child *cannot* contain these — they abort the
OS process, not a fiber. True isolation requires an **OS-process boundary**.

## Non-goal: one OS process per test

Spawning a fresh OS process (+ runtime init + reloading the compiled test
binary) for each of ~1500 tests is prohibitively slow and is NOT how this is
built. Isolation must be **pay-for-what-you-use**: the common (no-hard-failure)
path runs the whole suite in ONE process, exactly as today.

## Design: run-normally, resume-on-crash (supervisor in the `zap test` command)

The **supervisor lives in the `zap test` command** (`src/main.zig`, Zig),
which already owns `std.process.Child` and runs the compiled test binary as a
subprocess. Zest itself gains only a *checkpoint* and a *resume* mode — no new
Zap-visible OS-process primitives are required.

### Protocol

1. **Supervisor** spawns the test binary as a child process, capturing its
   stdout/stderr, with a per-run wall-clock **timeout**.
2. **Zest child**, before running each test, writes a one-line **checkpoint**
   to a fd/file the supervisor watches (or emits a structured `##ZEST-BEGIN <n>`
   / `##ZEST-END <n>` marker on stdout): the *global test ordinal* about to run.
   Zest already assigns a stable per-run ordering (seeded shuffle) and can run
   a single case by index (`zest_run_selected_case`, `enter_selected_suite`,
   `should_run_selected_case`).
3. **Child exits 0** → every test ran; supervisor parses the normal Zest
   summary and is done.
4. **Child dies abnormally** (non-zero exit, or a fault/panic signal) → the
   supervisor reads the last `##ZEST-BEGIN <n>` with no matching `##ZEST-END`:
   test *n* is the culprit. It records test *n* as a **hard failure**
   (`crashed: <signal/exit + captured stderr tail>`) and **re-spawns** the
   binary with `ZAP_ZEST_RESUME_AFTER=<n>` so Zest skips ordinals ≤ n and
   continues from n+1 (same seed → same ordering).
5. **Timeout** → supervisor `kill`s the child, records the in-progress test as
   a **timeout failure**, and re-spawns with resume, same as (4).
6. Loop until a child exits normally (0 remaining) or the whole ordering is
   exhausted. Aggregate all per-shard summaries + injected hard failures into
   one final report + exit code.

### Why this shape

- **Fast common case:** no hard failure ⇒ exactly one process, one summary.
- **Correct isolation:** a `@panic`/fault/hang loses at most the *one*
  in-progress test; the supervisor attributes it precisely (checkpoint) and
  every subsequent test still runs.
- **Reuses existing machinery:** seeded ordering + single-case selection in
  Zest; `std.process.Child` + signal/exit inspection in `main.zig`; the crash
  handlers already print a diagnostic before death.
- **No new Zap OS-process primitives** (which would otherwise need
  posix/windows/wasi backends through the `runtime_os` seam).

## Concrete changes

### `src/runtime.zig` (Zest runtime seam)
- Emit `##ZEST-BEGIN <ordinal>` / `##ZEST-END <ordinal>` markers around each
  case (behind a flag so normal runs are unaffected in human output — markers
  go to a dedicated fd or are filtered by the supervisor).
- Honor `ZAP_ZEST_RESUME_AFTER=<n>`: skip global ordinals ≤ n (map ordinal →
  (suite, case) via the existing selection path).

### `lib/zest/*.zap`
- Thread the resume/ordinal through the discovered-cases loop
  (`zest_run_discovered_cases`, `zest_run_selected_case`) — mostly reuse of the
  `enter_selected_suite`/`should_run_selected_case` selection already present.

### `src/main.zig` (supervisor)
- Wrap the test-binary run in a supervise loop: spawn child (timeout, capture),
  classify exit (0 / signal / non-zero / timeout), parse markers, on hard
  failure inject a synthetic failure + re-spawn with `ZAP_ZEST_RESUME_AFTER`,
  aggregate, and produce the final summary + exit code.
- Gate behind concurrency/target capability (the supervisor needs child-process
  spawn; on targets without it, fall back to today's single-run behavior).

## Test plan (TDD)

- `test/` (or a dedicated isolation fixture, gated so it does not abort normal
  CI): a suite containing (a) a passing test, (b) a `@panic` test, (c) a
  segfault test, (d) an infinite-loop test, (e) a passing test *after* each —
  assert the supervisor reports the passing tests as passed, the hard ones as
  crashed/timeout, and the run exits with a failure code but does NOT abort.
- `zir-test` harness assertions for exit-code/stderr classification and the
  resume env var, since these are process/CLI concerns not expressible from
  Zap.

## Open questions to resolve during implementation

- Marker transport: dedicated inherited fd vs. stdout sentinel filtered by the
  supervisor (leaning fd to keep human output clean).
- Timeout granularity: whole-suite deadline vs. per-test deadline (per-test is
  more precise but needs the supervisor to reset the timer on each `##ZEST-END`).
- Interaction with `-Druntime-concurrency` and the traced test target.
