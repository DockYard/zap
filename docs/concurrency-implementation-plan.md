# Zap Concurrency Implementation Plan

**Status: DRAFT — awaiting approval.**

**Lineage:** `research.md` (round-1 survey) → `research-round-2.md` (round-2 evidence) →
`zap-concurrency-research.md` rev 2 (design positions, all resolved). This document turns those
positions into a phased, testable implementation program. Design rationale is *not* repeated
here — each section cites the position it implements.

**Date basis:** 2026-07-03. Zig substrate facts verified against our fork at `~/projects/zig`
(last local commit 2026-06-16) and the upstream devlog (`ziglang.org/devlog/2026`).

---

## 1. Zig substrate assessment (0.16 fork + 2026 upstream)

What our fork already provides (verified):

| Capability | Where | State |
|---|---|---|
| Stackful fibers (context switch asm) | `lib/std/Io/fiber.zig` | aarch64/x86_64/riscv64; **no wasm** (call stack architecturally inaccessible) |
| `Io.Evented` | `lib/std/Io.zig:31` | macOS/iOS→**Dispatch (GCD)**, Linux→**Uring**, BSDs→**Kqueue**; **Windows→void** |
| Typed futures | `Io.Future(Result)` (`Io.zig:1176`) | await/cancel |
| Union-typed select | `Io.Select(comptime U)` (`Io.zig:1367`) | async/concurrent arms, await/awaitMany/cancel — **the natural lowering target for `receive`/`after`** |
| Task groups | `Io.Group` (`Io.zig:1218`) | async/concurrent/await/cancel — substrate for supervisors |
| MPMC queue | `Io.Queue(Elem)` (`Io.zig:2184`) | plus `QueueClosedError` |
| Structured cancellation | `Io.Cancelable` error set, `io.cancel()` | the kill/shutdown signal |
| Clocks/timeouts | `Io.Clock`, `Timeout`, `sleep`, `operateTimeout` | the `after` substrate |
| Batched I/O ops | `Io.operate`/`Batch` | I/O suspension points |

What the 2026 devlog changes about our plan:

1. **Feb 13, 2026 — io_uring + GCD `std.Io` backends landed, fiber-based, explicitly
   experimental** (error handling, perf diagnostics, coverage gaps). Consequence: our fork has
   the right substrate but we must expect churn; upstream fixes (notably the known io_uring perf
   regression) are cherry-picked continuously rather than waiting for releases.
2. **Upstream is now 0.17.0-dev — and our fork is already based on it.** The fork's merge-base
   with upstream master is a commit from ~2026-03-18 (66 Zap commits on top; local upstream ref
   stale since March). Consequence: the campaign **starts with a catch-up rebase onto a pinned
   current master snapshot (Phase −1)** — done while our diff is 66 commits, not after Phases
   0–2 grow it, and so that every experiment measures the substrate we will actually build on
   (including post-February `Io` fixes such as the io_uring perf-regression work). After Phase
   −1: `std.Io` contact stays behind **one seam file** (`runtime_io.zig`, §4); upstream `Io`
   fixes are cherry-picked deliberately; the only later realignment is a small hop when 0.17.0
   tags. No mid-campaign full rebase.
3. **Jan 31, 2026 — zig libc**: libc functions becoming Zig wrappers, with the stated goal of
   letting `read`/`write` participate in an io_uring event loop. Consequence: long-term, even
   libc-using FFI can suspend cooperatively instead of blocking a scheduler. Near-term the
   dirty/blocking pool (Phase 4) is still required; this devlog item is the eventual path to
   shrinking its use.
4. **Incremental compilation maturity** (`zig build test --watch -fincremental`, 200–300 ms
   incremental links): adopt for the campaign's inner loop where our fork supports it.
5. **Windows:** `Io.Evented` is `void` on Windows in 0.16. v1 posture: Windows processes run on
   `Io.Threaded` (real OS threads, 1:1) as an honest capability-matrix fallback — per-process
   heaps and non-atomic ARC still hold (refcounts stay process-local; only envelope handoff is
   atomic). Fiber+IOCP on Windows is fork work, deferred (Phase 7 stretch).

## 2. Locked design decisions (implemented by this plan)

From `zap-concurrency-research.md` rev 2 §6 — restated as one line each:

1. Manager comptime-resolved at the spawn site (language rule) — **Decision Gate 0, needs
   explicit sign-off with plan approval**.
2. Monomorphization hybrid: hot allocating paths specialized per reclamation model (≤4); cold
   closure/existential paths dispatch via the process's manager vtable; post-ICF kill criterion.
3. Cross-model traffic: same-model O(1) move ▸ Blob/immutable ▸ lazy per-reachable-pair copy
   stubs; cross-model `move` degrades to copy.
4. Pid invariant: model bits are a function of {slot, generation}; dead-letter on mismatch.
5. Model roster: ARC default; ORC-over-ARC recommended cyclic model (shares REFCOUNTED
   specialization — hypothesis verified in Phase 3); conservative mark-sweep contingent on E8.
6. Safepoints: alloc piggyback + mandatory bare back-edge polls in alloc-free/call-free loops +
   flag-only watchdog; documented latency bound.
7. Receive: exhaustive surface form over the per-process message union + internal
   correlation-token skip under `call`/`Future(T)`; dead-letter unexpected runtime messages.
8. Blob-backed strings: copy-out slices, ~15 B SSO, 64 B promotion threshold, rc==1 in-place
   append, opt-in aliasing view.
9. Wasm/feasibility: comptime capability matrix + runtime spawn error; no Asyncify.
10. Fork posture: extend `Io.Evented` in `~/projects/zig`; no vendored scheduler.
11. Testing: seeded deterministic scheduler; verona-rt-style seed sweeps; failing test prints
    its seed.

Explicit non-goals (v1): priority messages, bounded mailboxes by default, ETS-style shared
mutable tables, hot code loading, distribution (design-for only: pid node bits, copy-walker
reusable as serializer), BoC multi-cown scheduling, wasm fibers.

## 3. Architecture overview

**A process is:** a fiber (fixed guard-paged lazy-commit stack reservation) + a manager context
(vtable+state pointer in the process control block) + a Vyukov MPSC mailbox + a preemption
budget + a drop-list of external resources + a pid table slot `{slot, generation, model bits,
node bits}`.

**The scheduler is:** per-core scheduler threads (M:N), per-core run queues with LIFO slot +
global overflow queue + work stealing, parking/wakeup integrated with the `Io.Evented` event
loop, a per-scheduler hierarchical timing wheel, a per-scheduler flag-only watchdog timer, and
a seedable single-threaded deterministic mode. The Zap scheduler **implements the `std.Io`
vtable**, so any Zap-runtime or FFI code doing I/O through `Io` suspends the calling process
correctly instead of blocking the scheduler thread.

**A send is:** copy into a detachable fragment from the shared envelope page pool (owned by the
message system; abandon/reclaim on sender death) → one atomic exchange onto the receiver's
mailbox → wakeup. **A receive is:** `Io.Select` over {mailbox, timer, exit-signal} arms →
adopt fragment into own manager → pattern match (exhaustive over the message union).

**Memory ops** compile against the process's reclamation model: monomorphized on hot paths,
manager-vtable on cold paths. Non-spawning binaries compile exactly as today (no polls, no TLS
current-process, global manager) — the zero-cost gate.

## 4. Division of labor (CLAUDE.md: Zap is a language)

**Zig — genuine primitives only:**

- Runtime kernel: scheduler, fibers, run queues, mailbox queue, envelope pool, pid table,
  timing wheel, watchdog, blocking pool, registry table, copy/adopt machinery, crash teardown.
  Lives as a self-contained runtime source unit (`src/runtime_concurrency.zig` + a thin
  `src/runtime_io.zig` seam over `std.Io`), compiled per target via
  `zap_fork_compile_zig_to_object` exactly like manager sources — never text codegen.
- Compiler: spawn/send/receive/link/monitor lowering in `src/zir_builder.zig`; safepoint
  emission; message-union inference; monomorphization hybrid in `src/monomorphize.zig`;
  verifier passes (`src/concurrency_verifier.zig`, modeled on `src/arc_verifier.zig`); driver
  multi-manager resolution (`src/memory/driver.zig`); capability matrix.
- Fork (`~/projects/zig`): ZIR C-ABI additions for the new intrinsics; `Io.Evented` gap fixes;
  (later) work-stealing/IOCP contributions.

**Zap — everything else (`lib/*.zap`, all with `@doc`):**

- `lib/process.zap` — `Process.spawn/spawn_link/spawn_monitor/self/exit/sleep/send`,
  `trap_exit`, thin wrappers over `:zig` intrinsics.
- `lib/task.zap` — `Task.async`/`Task.await` returning `Future(T)`; the typed-call idiom
  (correlation token internal).
- `lib/supervisor.zap` — strategies `one_for_one`/`rest_for_one`/`one_for_all`, intensity 1 /
  period 5 s defaults, shutdown protocols; built on `Group` semantics via intrinsics.
- `lib/process/dead_letter.zap`, `lib/process/registry.zap` (via-style layer over the runtime
  registry), credit-based flow control (stdlib, later).
- Zest concurrency helpers (`lib/zest/…`): seeded-scheduler test wrappers.

The `receive` construct itself is language surface (parser → HIR → ZIR lowering onto
`Io.Select`); everything above it is Zap code.

## 5. Phases

Effort sizing: S (~days), M (~1–2 weeks), L (~weeks), XL (multi-week+fork work). Every phase:
tests written first (Zest under `test/` for language/stdlib semantics; `zir-test` additions only
for harness concerns — flags, cache layout, cross-target, compile-fail diagnostics); full suite
green before the phase closes; frequent commits.

### Phase −1 — Fork realignment to upstream master (M, infrastructure)

Goal: rebase our 66 fork commits onto a **pinned** current upstream master snapshot and bring
Zap green against it, so all concurrency work builds on the freshest `std.Io` — the fastest-
moving API in std and the one the scheduler will *implement*, not merely consume.

- **P-1.1** Fetch upstream; pin a snapshot commit (never track master continuously); rebase the
  Zap commit stack (zir_api C-ABI layer + targeted std/os fixes) onto it.
- **P-1.2** Bootstrap check: if master has moved past LLVM 21, rebuild the zig-bootstrap +
  supplemental z/zstd prefix (documented gotchas apply — the local build READMEs are
  incomplete; budget real time here).
- **P-1.3** Fork test suite green (re-run the known verification gotchas from the previous
  fork-green campaign).
- **P-1.4** Zap alignment: rebuild `libzap_compiler.a`, refresh `zap-deps` archives, fix std
  churn in `src/runtime.zig` and every manager source, full Zap test suite green.
- **P-1.5** Re-snapshot CLBG baselines on the new base so E2's before/after comparison is
  apples-to-apples.

Exit gate: fork `zig build test` green + Zap full suite green + CLBG baselines re-recorded +
pinned upstream SHA documented in this plan.

### Phase 0 — Substrate spikes + experiment harness (M)

Goal: retire the highest-uncertainty questions with throwaway-marked spikes (`spike/` dirs,
same convention as `spike/manager_v1`) before any production code.

- **S0.1** Benchmark harness: spawn cost, ping-pong RTT (same/cross scheduler), copy p99 vs
  size; CLBG baseline snapshot for E2 comparison. Baselines table from
  `research-round-2.md` Q10.
- **S0.2 (E1)** Fiber spawn + ping-pong on the fork's `Io.Evented` (Dispatch on this machine)
  vs `Io.Threaded`. Targets: sub-µs–3 µs spawn, RTT within 2–3× BEAM/Go.
- **S0.3 (E9)** Dispatch vs Kqueue on Darwin: fiber-switch + wakeup latency → picks the
  tier-1 default backend (note: upstream's Evented switch picks Dispatch for macOS; validate
  or override in-fork).
- **S0.4 (E10)** Vtable-dispatch vs monomorphized alloc call microbenchmark → confirms the
  hybrid's hot/cold split empirically.
- **S0.5** Scheduler architecture decision memo: drive processes through `Io.async`/
  `concurrent`/`Select` as-is vs own run-queue scheduler on `fiber.zig` implementing the `Io`
  vtable. E1/E9 numbers decide; the plan assumes the latter (full control over budgets, LIFO
  slot, stealing, determinism) unless the spike shows Evented-as-is suffices for Phase 1–2.

Exit gate: E1/E9/E10 numbers recorded in the plan doc; scheduler decision made.

### Phase 1 — Runtime kernel, single scheduler, single model (L)

Goal: processes exist; ARC-only (manifest manager); no language surface yet — kernel exercised
from Zig tests and a minimal intrinsic set.

- **1.1** Process control block: fiber + stack reservation (guard page, lazy commit) + manager
  context (per-process instance of the manifest manager) + mailbox + budget + drop-list.
- **1.2** Pid table: generational indices; model/node bit fields reserved and validated
  (dead-letter path stubbed); scalable iteration (OTP-28-style) from day one.
- **1.3** Vyukov MPSC mailbox (envelope-intrusive; null-next-nonempty case handled); envelope
  page pool with abandon/reclaim (mimalloc-style) for sender-death.
- **1.4** Spawn/exit/teardown: pool-only hot path (pid slot + manager init + lazy stack +
  enqueue); wholesale arena/slab free on exit; drop-list destructor run; `io.cancel()` wiring.
- **1.5** Deterministic mode: single-threaded seeded scheduler; all nondeterminism (scheduling,
  timers, sender interleaving) funneled through the seam; seed printed on failure.
- **1.6** Observability skeleton (non-negotiable): process list iterator, mailbox depth, heap
  bytes, state, crash reports with native stack traces.
- **1.7** Darwin teardown test (mimalloc-#164 class): thousands of spawn/die cycles under
  Tracking/Leak managers, clean teardown asserted.

Exit gate: E3's same-model half (ARC→ARC copy under TSan, adversarial send/receive, zero
refcount races); E1 re-measured on the real kernel.

### Phase 2 — Language surface + copy-path send/receive (XL)

Goal: `spawn`/`send`/`receive`/`after` work in Zap programs; single model; safepoints in.

- **2.1** Typed pids: `Pid(M)` as the primary handle (Gleam-`Subject` analogue); `send`
  type-checks against `M`; untyped `Pid` exists for registry/dynamic use behind a
  `catch_all`-required receive.
- **2.2** Message-union: explicit annotation first (`process … receives M`), inference from
  receive patterns second; exhaustiveness verifier; out-of-union send = send-site compile
  error.
- **2.3** `receive`/`after` lowering onto `Io.Select` (mailbox arm, timer-wheel arm,
  exit-signal arm); `after 0` = poll; suspension at arbitrary call depth (stackful fibers).
- **2.4** Deep-copy send: sender copies into detachable fragment (closures: share code pointer,
  deep-copy environment); receiver adopts (rc=1 init). ZIR-emitted copy walker written for
  reuse as a serializer later.
- **2.5** Safepoints, all three layers, comptime-gated (`runtime_concurrency` off → zero
  emission): alloc piggyback; bare back-edge polls only in alloc-free/call-free loops;
  per-scheduler flag-only watchdog.
- **2.6** Verifier passes v1: no-borrowed-at-send, no-shared-at-send, use-after-move-across-
  send (extends the existing move checker). Compile-fail diagnostics via `zir-test` until Zest
  supports compile-fail.
- **2.7** Zap stdlib: `lib/process.zap` minimal surface; Zest concurrent tests (seeded) —
  ping-pong, ordering (pairwise FIFO), crash-teardown, timeout semantics.

Exit gates: **E2** (CLBG with concurrency ON: alloc-piggyback ≈ 0 on allocating loops;
back-edge poll ≤2–3% on nbody/spectral-norm, else loop-unroll mitigation before proceeding);
**E6** first crossover measurement.

### Phase 3 — Per-spawn managers (XL; the centerpiece)

Goal: `spawn(f, .{ .manager = … })` with comptime-resolved manager binding (Decision Gate 0).

- **3.1** Driver: resolve/validate every spawn-site manager + manifest default; per-manager
  symbol families replacing the `zap_active_manager` singleton; runtime manager registry.
- **3.2** Monomorphization hybrid in `src/monomorphize.zig`: specialize spawn-reachable hot
  paths per model (elision decisions per specialization via `src/memory/elision.zig`); cold
  closure/existential paths through the control-block vtable; ICF-unfoldable specializations
  surfaced as verifier red flags.
- **3.3** Model-tagged pids live; per-reachable-pair copy stubs (lazy generation); adoption
  semantics per model (rc=1 / bulk splice / range registration / free-at-last-use) — **manager
  ABI minor bump** (detach/adopt entry points + envelope-domain semantics) per spec §2.3,
  spec doc updated in the same commits.
- **3.4** ORC manager: `src/memory/orc/manager.zig` + stdlib adapter; verify the
  shares-REFCOUNTED-specialization hypothesis (cycle-root buffering entirely inside `release`);
  cycle-collection at yield points only.
- **3.5** Capability matrix (comptime table + runtime spawn error); wasm32 and Windows entries;
  compile-time warnings for statically-known-impossible combos.

Exit gates: **E4** (post-ICF text growth at 1/2/4 models on an existential-heavy program);
**E3** full matrix (reachable pairs, TSan, sender-dies abandon/reclaim); **E8** (fiber-stack
conservative scan cost + false retention → mark-sweep ships or slips per rev 2 §2.5).

### Phase 4 — Multicore + blocking (L)

- **4.1** M:N work-stealing scheduler (schedulers = cores), per-core queues + LIFO slot +
  global overflow; parking via Evented wakeups (userspace flag when awake; eventfd/`MSG_RING`/
  kqueue-user/GCD source when parked — measure, R7).
- **4.2** Hierarchical timing wheel per scheduler, feeding the `after` Select arm.
- **4.3** Blocking pool (dirty-scheduler equivalent): `Process.blocking` intrinsic; documented
  FFI contract; zig-libc devlog path noted as the long-term shrink.
- **4.4** Deterministic mode extended: seeded multi-scheduler interleaving sweeps
  (verona-rt-style `--seed`/seed-range).

Exit gates: **E7** (fiber blocking inside a manager call — GC pause in `allocate`, lazy-commit
fault — co-scheduled fibers not delayed beyond watchdog tick, else mandatory handoff for
blockable manager calls); E1 cross-scheduler numbers.

### Phase 5 — Signals, supervision, typed calls (L)

- **5.1** Links (bidirectional, one-per-pair), monitors (unidirectional, stackable, `DOWN`
  with `noproc`), `trap_exit`, exit-signal ordering merged with pairwise FIFO; `kill`
  untrappable → `killed`. Exit signals as a distinct Select arm.
- **5.2** Runtime local registry (atomic register/lookup, register-then-crash race handled).
- **5.3** Pure-Zap stdlib: `lib/supervisor.zap` (strategies, defaults, shutdown protocols,
  start left→right/terminate right→left), `lib/task.zap` (`Task.async` → `Future(T)`,
  `call` with internal correlation-token skip — the ref-trick receive mark lands here),
  dead-letter sink + telemetry.
- **5.4** `spawn_link`/`spawn_monitor`; `Process` module completed; `@doc` everywhere.

Exit gate: supervision-tree Zest suite (restart intensity, rest_for_one ordering, brutal_kill
timing) under seeded determinism; R8 selective-receive benchmark (10⁶-deep mailbox, O(1)
correlated replies).

### Phase 6 — Performance tier (L)

- **6.1** Same-model O(1) region move: region-closure verifier constraint over
  `src/region_solver.zig` + escape lattice + uniqueness facts; slab detach/adopt (**E5**:
  truly O(1) and leak-free, else copy-on-move stays, documented).
- **6.2** `Blob` (atomically-refcounted immutable byte buffer; naming folds into the pending
  V8→dense rename sweep): the one sanctioned share tier; global immutable registry
  (`persistent_term` analogue).
- **6.3** Blob-backed String per rev 2 §5.4: copy-out slices, SSO, 64 B promotion (tuned by
  measurement), rc==1 in-place append via the uniqueness prover, opt-in aliasing view.
- **6.4** Arena auto-reset at the receive back-edge for solver-proven loop-closed processes;
  `hibernate` intrinsic (arena reset + stack shrink).
- **6.5** Full observability: send/receive trace points (compile-time-optional), scheduler
  utilization, run-queue depth, deadlock ("all waiting, none runnable") and starvation
  detection.

Exit gate: E6 re-run — crossover documented; ping-pong within target with move path on.

### Phase 7 — Hardening + portability (M)

- **7.1** Wasm: capability-matrix entries verified (spawn error clean, Threaded fallback where
  host threads exist); cross-compile smoke per the existing `runtime_os` gate.
- **7.2** Windows: Threaded-backend 1:1 fallback validated end-to-end; IOCP+fiber fork work
  scoped as a follow-on (stretch).
- **7.3** Docs: user-facing concurrency guide; FFI safety contract; message-versioning posture
  (never crash on unknown dynamic message); latency bound documentation incl. the one
  unbounded case.
- **7.4** README/CHANGELOG; benchmark suite results published in-repo.

## 6. Experiment gates → phases

| Gate | Phase | Kill criterion / decision |
|---|---|---|
| E1 spawn/ping-pong | 0, re-run 1, 4 | ≥1–3 µs spawn or RTT >3× BEAM/Go → escalate scheduler design |
| E9 Dispatch vs Kqueue | 0 | picks Darwin default backend |
| E10 dispatch vs mono alloc | 0 | confirms hybrid hot/cold split |
| E2 CLBG safepoints | 2 | >2–3% on nbody/spectral-norm → unrolling mitigation first |
| E6 copy crossover | 2, re-run 6 | early crossover → pull Blob/move forward |
| E3 TSan copy matrix + sender-dies | 1 (same-model), 3 (full) | any cross-scheduler refcount race → stop-ship |
| E4 post-ICF code size | 3 | exceeds CLBG size budget → shift more paths to vtable dispatch |
| E8 fiber-stack scan | 3 | unbounded cost / high false retention → mark-sweep out of v1, ORC only |
| E7 manager-call blocking | 4 | stalls beyond watchdog tick → mandatory handoff |

## 7. Risks (top 5; full list in rev 2 §8)

1. Fiber-stack conservative scan (E8) — mark-sweep may slip; ORC is the designed fallback.
2. Existential reachability inflating monomorphization (E4) — vtable arm + ICF are the designed
   caps; red-flag verifier catches semantic leaks.
3. Safepoint cost on CLBG wins (E2) — highest-visibility perf risk; unrolling mitigation
   staged before concurrency-on ships.
4. Upstream 0.17 `std.Io` churn — contained by the Phase −1 catch-up rebase (pinned snapshot),
   the `runtime_io.zig` seam, deliberate cherry-picks, and one small hop when 0.17.0 tags.
   Secondary risk inside Phase −1 itself: an LLVM version bump forcing a bootstrap rebuild.
5. Darwin teardown ordering — dedicated Phase-1 test, not discovered in production.

## 8. What approval covers

Approving this plan locks in: the **rebase-first sequencing** (Phase −1 before any concurrency
code); the phase ordering and exit gates above; **Decision Gate 0** (a
spawn site's manager binding is comptime-resolvable — the language rule everything in Phase 3
stands on); the scheduler-owns-`Io`-vtable architecture (pending only S0.5's confirmation); the
Windows-Threaded and wasm-capability-error v1 postures; and the division of labor in §4.
Anything the experiment gates overturn comes back as a plan amendment, not a silent change.
