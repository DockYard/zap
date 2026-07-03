# Zap Concurrency: Per-Spawn Memory Managers — Findings and Design Amendments

**Status:** companion to `research.md`. That document is the state-of-the-art survey; this one
records what was verified against the actual Zap codebase and Zig fork (2026-07-03), and amends
the survey where it conflicts with decisions already made — above all the decision that **a Zap
process is spawned with its own memory manager, chosen by the developer at the spawn site.**

## TL;DR

- **`research.md`'s §6.6 recommendation is rejected.** It keeps the reclamation model
  comptime-global (one model per binary, ARC default) and says "no per-process tracing GC in v1."
  That contradicts the standing decision (2026-05-30): developers pick the memory manager
  **per process at spawn time** — an ARC process, an arena process, and a GC process must be able
  to coexist in one binary. The survey only weighed comptime-global vs. dynamic-dispatch-per-
  allocation; it never evaluated the option that fits Zap: **manager-monomorphization** of the
  spawn-reachable call graph, reusing the same per-call-path specialization machinery Zap already
  uses for raising/pure and owned/borrowed splits.
- **Per-spawn managers make every cross-process message a cross-*model* copy.** Heap-object
  layout differs by reclamation model (ARC cells carry a refcount header; arena/no-op cells do
  not), so the sender-writes-fragment/receiver-adopts discipline from `research.md` §6.4 needs a
  layout decision: canonical fragment layout vs. model-tagged pids with per-model-pair copy
  stubs. This is new work the survey does not itemize.
- **The survey understates what already exists.** Our Zig fork already ships `std.Io.Evented`
  with fiber support on aarch64/x86_64/riscv64 and Dispatch (GCD), Kqueue, Uring, and Threaded
  backends — Darwin works in-fork today, so "Linux-first, vendor `zio` as fallback" is the wrong
  posture; extend the fork directly. And `src/region_solver.zig` already implements the
  MLKit-style region/multiplicity/storage-mode inference that the survey schedules as new
  Stage-3 work for the O(1) move path and arena auto-reset.

## 1. Verified premises (checked 2026-07-03)

Everything `research.md` assumes about Zap's infrastructure was verified to exist:

| Claim in `research.md` | Verified against |
|---|---|
| Uniqueness/ownership prover | `src/arc_ownership.zig`, `src/perceus.zig` |
| `.borrowed` parameter convention (needed by the "no borrowed value reaches a send" verifier) | `src/arc_param_convention.zig` |
| Verifier-pass precedent for new concurrency passes | `src/arc_verifier.zig` |
| Region machinery for the move path | `src/region_solver.zig` (see §4) |
| Escape analysis for region closure | `src/escape_lattice.zig`, `src/generalized_escape.zig` |
| Context-based, multi-instance-capable manager ABI | `src/memory/abi.zig`, `docs/memory-manager-abi.md`, backends under `src/memory/{arc,arena,gc,no_op,tracking,leak}/` |
| `runtime_os` portability seam (deterministic-scheduler seam) | `src/runtime_os/`, `src/runtime_os_portability_gate.zig` |
| Zig fork green-thread substrate | `~/projects/zig/lib/std/Io.zig:31` (`Io.Evented`), `lib/std/Io/fiber.zig` |

## 2. The central decision: a process owns its manager, chosen at spawn

### 2.1 The standing decision

Recorded 2026-05-30 and reaffirmed here as the design anchor:

> Developers pick the memory manager per process when they `spawn` it — more flexible than stock
> BEAM (which uses one GC shape for all processes).

Two consequences were established with the decision:

1. **Cross-compile requirement.** Every manager backend must be present and linkable in every
   target binary, because any process might spawn with any of them. Managers cannot be
   compile-time-gated out of a target. Genuinely impossible manager×target combinations (e.g.
   `Memory.GC` on wasm32 — conservative stack scanning needs a native stack) become **runtime
   spawn errors**, not compile-time exclusions.
2. **Tension with comptime elision.** The capability-driven memory model
   (`src/memory/abi.zig`, `src/memory/elision.zig`) bakes one reclamation model per binary at
   comptime and shapes memory-op codegen to match: ARC emits retain/release; Arena/NoOp/Leak
   elide all individual frees; Tracking uses static free-at-last-use. Per-process runtime manager
   choice breaks the "one model per binary" premise.

### 2.2 Where `research.md` went wrong

Survey §6.6 ("Can different processes use different allocation strategies?") framed three options:

- **(a)** one reclamation model binary-wide, only allocation *strategy* (bump/arena/GPA
  parameters) varying per process — **its recommendation**;
- **(b)** compile the runtime multi-model and dispatch dynamically on every allocation —
  rejected, correctly, as a direct regression to Zap's few-instruction alloc path;
- **(c)** restrict per-process choice to parameters — the conservative fallback.

Option (a) contradicts the spawn-time decision outright. Option (b) is rightly dead. The survey
never considered the option Zap's architecture makes natural:

- **(d) Manager-monomorphization.** Specialize the spawn-reachable call graph per chosen
  reclamation model, exactly like the existing raising/pure and owned/borrowed per-call-path
  splits. Each specialization's memory-op codegen is gated by that manager's `declared_caps`
  (the existing `src/memory/elision.zig` decode — `reclamationModel` /
  `shouldEmitRefcountOps` — applied per specialization instead of once per binary). Comptime
  elision survives *per copy*; the cost is code size, not per-allocation dispatch.

**Recommendation: adopt (d).** It is the only option that honors the spawn-time decision without
giving up the few-instruction allocation path. Zap's monomorphizer (`src/monomorphize.zig`)
already performs exactly this kind of call-graph splitting for other axes.

### 2.3 What manager-monomorphization requires

1. **The manager must be statically known at the spawn site.** `spawn(f, .{ .manager =
   Memory.Arena, ... })` with a comptime-resolvable manager binding selects which
   specialization of `f`'s call graph the new process enters. This should be a language rule,
   not an optimization heuristic: a fully-runtime manager value would force fallback to option
   (b) dispatch for that spawn, reintroducing the overhead the design exists to avoid. (A
   runtime-chosen manager can be revisited later as an explicit opt-in with documented cost.)
2. **Specialization is by reclamation *model*, not by manager identity.** There are four models
   (REFCOUNTED, BULK_OR_NEVER, INDIVIDUAL_NO_REFCOUNT, TRACED — `declared_caps` Axis A,
   `src/memory/abi.zig`), so the worst case is 4 specializations of the spawn-reachable graph,
   not one per manager. Managers sharing a model (Arena/NoOp/Leak are all BULK_OR_NEVER) share
   code and differ only in the vtable/context they are handed. This bounds code-size growth and
   matches the ABI's own principle: *the compiler reads capability axes, never the manager's
   name*.
3. **Code-size discipline.** Only the spawn-reachable subgraph is split, and only for models
   actually used by some spawn site in the program. A binary that only ever spawns ARC processes
   carries one specialization — identical to today. A binary with no spawns at all compiles
   exactly as today (the zero-cost guarantee, Constraint 4 of `research.md`).
4. **Driver/runtime changes.** Today `src/memory/driver.zig` resolves **one** manifest-selected
   manager and registers its backend source as the singleton `zap_active_manager` symbol set
   (see also `src/zap_active_manager_stub.zig`). Per-spawn managers need: (i) the driver to
   resolve and validate *every* manager referenced by any spawn site (plus the manifest default),
   (ii) a per-manager symbol family or registration table in the runtime instead of the
   singleton, and (iii) each process's green-thread control block carrying its manager context
   pointer (survey §6.6's TLS-load design is unchanged — it already assumed per-process
   contexts; what changes is that the *vtable* is also per-process, selected once at spawn).
5. **The reserved Axis-A `0b11` encoding stays reserved.** Spawn-time validation of
   manager×target feasibility (consequence 1 above) happens in the runtime spawn path, keyed by
   the manager's declared capabilities and the compile-target — a new runtime check, not an ABI
   change.

### 2.4 New consequence: cross-model message copies

`research.md` §6.4's copy discipline — sender deep-copies into a detachable fragment from a
shared page pool; receiver adopts the fragment; refcounts stay scheduler-local — was designed
assuming both heaps share one reclamation model. Per-spawn managers break that assumption:

- An ARC process's heap cells carry refcount headers (`allocate_refcounted`, ABI v1.1); an
  arena or tracking process's cells do not (INDIVIDUAL_NO_REFCOUNT is explicitly "no refcount
  header").
- The sender writes the fragment, but the **receiver's** model determines what layout the
  adopted cells must have. An ARC→Arena send must not leave refcount headers the arena model
  will never maintain; an Arena→ARC send must *add* headers the sender's own heap lacks.

Three resolutions, in descending order of preference:

1. **Model-tagged pids + per-model-pair copy stubs (recommended).** The pid (already
   `{slot, generation}` with reserved node bits) reserves 2 bits for the target's reclamation
   model. `send` selects a monomorphized copy routine for (sender-model → receiver-model). With
   4 models that is at most 16 stubs, most of which share code (the graph walk is identical;
   only per-cell header emission differs). No per-object dispatch — one branch per send.
2. **Canonical fragment layout.** All fragments use a refcount-headered layout regardless of
   endpoint models; non-ARC receivers ignore the headers. Simpler, but permanently wastes a
   header word per object in every non-ARC process's adopted messages and pollutes the arena
   model's "no individual metadata" invariant. Acceptable as a Stage-1 stepping stone only.
3. **Neutral wire form + receiver-side second pass.** Serialize to a model-free encoding and
   materialize on receive. Strictly worse: two walks per message. Reject (though note §6.10
   distribution will need a wire form eventually — the copy-stub graph walker should be written
   so a serializing backend can reuse it).

The **move path** (Stage 3 region re-parenting) has a sharper version of this: an O(1)
re-parent is only possible between processes of the *same* reclamation model (the adopted slabs
must be maintainable by the receiver's model). Cross-model `move` degrades to copy — the
verifier and the docs must say so explicitly. Likewise **arena processes and `receive`**: a
BULK_OR_NEVER process adopting fragments can only reclaim them at bulk-reset/death, which is
exactly the semantics an arena process signed up for, but the docs must flag that a long-lived
arena server accumulating message fragments grows until its auto-reset point (survey §6.5's
loop-closure reset becomes *more* important, not less, under per-spawn arenas).

### 2.5 What this changes in the staged plan

Amendments to `research.md`'s Stage 1 (everything else in the plan stands):

- Stage 1 gains: manager-monomorphization of spawn-reachable call graphs (bounded to models in
  use); driver multi-manager resolution + runtime manager registry; model bits in the pid;
  copy stubs (or the canonical-layout stopgap with an explicit follow-up); spawn-time
  manager×target feasibility check.
- Stage 1 spawn options become `spawn(f, .{ .manager = ..., .initial_heap = ..., .max_heap =
  ... })` — the survey's Open Decision #4 answer (configurable per spawn) extends naturally
  from "strategy parameters" to "manager binding".
- Survey Open Decision #6 is re-answered: **not** "no tracing GC in v1" but "GC is one of the
  four models a process may spawn with; the existing single-threaded conservative mark-sweep
  collector (`src/memory/gc/manager.zig`) is already the correct per-process shape — one
  collector instance over one private heap, no cross-thread scanning, no stop-the-world beyond
  the owning process." Per-process isolation is precisely what makes per-process tracing GC
  cheap to offer.

## 3. The Zig fork substrate is further along than the survey says

Verified in `~/projects/zig` (our 0.16 fork):

- `lib/std/Io.zig:31` — `pub const Evented = if (fiber.supported) switch (builtin.os.tag) ...`
- `lib/std/Io/fiber.zig` — stackful-coroutine context switching with hand-written assembly for
  **aarch64, x86_64, riscv64** (`fiber.supported` is arch-gated; wasm is excluded, consistent
  with the survey's WASI caveat).
- Backends present: `Dispatch.zig` (GCD — Darwin), `Kqueue.zig`, `Uring.zig`, `Threaded.zig`.
- The `Io` vtable already carries async/concurrent/await/cancel, `Group`
  (`groupWait`/`groupCancel`), `Queue`, and `netLookup`.

Consequences:

- **Darwin is tier-1 from Stage 0.** Development and the test suite run on Apple Silicon macOS;
  the substrate for it exists in-fork today. The survey's "Linux-first, kqueue staged" framing
  is stale for our fork.
- **Do not vendor `zio`.** The survey hedged toward vendoring a third-party scheduler. We own
  the fork and have standing permission to change it; the correct posture under the no-fallbacks
  rule is to **extend `Io.Evented` in the fork** (work-stealing M:N, wakeup integration,
  stack-reservation policy) using `zio` purely as a design reference. Gaps found during Stage 0
  are fixed in `~/projects/zig`, not papered over with a parallel runtime.

## 4. The Stage-3 move path is mostly already built

`src/region_solver.zig` ("Region-Based Lifetime Solver, Research Plan Phase 4") already
implements: dominator-tree CFG construction, constraint generation from IR, non-lexical
lifetime solving via LCA, MLKit-inspired multiplicity inference, MLKit-inspired storage-mode
analysis, and region→allocation-strategy mapping.

- The survey's Stage-3 **region-closure verifier** (SE-0414 / Pony-`iso` style: no external
  in-pointers, no escaping out-pointers, refcount == 1) is a new *constraint* layered on this
  existing solver plus `src/escape_lattice.zig` / `src/generalized_escape.zig` and the
  uniqueness facts from `src/arc_ownership.zig` — not a from-scratch analysis.
- The survey's **arena auto-reset** for proven loop-closed server loops (§6.5, its single most
  promising Zap-specific optimization) is essentially the solver's storage-mode/multiplicity
  analysis applied at the `receive` back-edge.
- Planning consequence: the move path's cost estimate shrinks, and it can be pulled forward if
  the R5 experiment (copy p99 vs message size) disappoints. Under per-spawn managers it also
  gains the same-model restriction from §2.4.

## 5. Other amendments to the survey

### 5.1 Safepoint gating: drop "reachable from a spawned process"

The survey proposes emitting yield checks "only in functions reachable from a spawned process."
With first-class closures as `Callable` existentials (the in-flight closures work) and protocol
dispatch, the spawn-reachable set degenerates to nearly everything, and any unsound narrowing
starves schedulers. Replace with:

- **Binary-wide comptime gate:** concurrency off → zero safepoints (CLBG wins intact);
  concurrency on → safepoints everywhere, made cheap.
- **Piggyback on the allocation path:** every allocating loop already calls the manager; the
  budget decrement rides that call for free. Bare back-edge polls are emitted only in
  allocation-free, call-free loops — exactly nbody's shape, which is where the R1 experiment
  should concentrate its measurement.

### 5.2 Selective receive vs. typed exhaustive unions: an unresolved language decision

Survey §6.8 wants `receive` exhaustive over a per-process message union; §6.2 wants Erlang
selective receive. These conflict: exhaustiveness means no message is left in the mailbox;
selective receive exists to defer non-matching messages (gen_server `call` depends on it).
Likely resolution: two receive forms — the steady-state exhaustive `receive`, and a
correlation-token receive (the ref-trick O(1) path) that may skip. Must be settled before
`receive` lowering is designed; it also interacts with the typed-`Future(T)` reply path, which
may make token-receives rare enough that skipping stays an internal mechanism rather than
surface syntax.

### 5.3 Copy-path ABI work items (now larger under per-spawn managers)

The detachable-fragment discipline requires, concretely:

- a third allocation domain (in-flight envelopes owned by neither manager, from a shared page
  pool) — a runtime-owned pool, not a manager;
- detach/adopt entry points on the manager ABI — an ABI **minor** bump per
  `docs/memory-manager-abi.md` §2.3, with the adopt semantics defined *per reclamation model*
  (ARC adopts headered cells; BULK_OR_NEVER splices pages into its bulk set; TRACED registers
  the range as heap);
- the §2.4 copy stubs (or the documented canonical-layout stopgap).

### 5.4 `Zap.Blob` and String will collide

Erlang's >64-byte refc-binary tier exists mostly *for* binaries/strings. If `String` does not
ride the `Zap.Blob` tier, every large-string send deep-copies; if it does, string slicing is
exactly the sub-blob aliasing the survey excludes from v1 (the binary-leak pathology). Leaning:
Blob-backed large strings with slices that copy out rather than alias. Needs its own analysis
when Blob is designed (Stage 3). Note Blob's atomic refcount is model-independent — it works
identically regardless of the owning process's manager, which makes it the one message payload
that is cross-model-free.

### 5.5 Minor platform notes

- Fixed stack reservation + lazy commit behaves well on Darwin (lazy commit on fault; large
  virtual reservations are cheap on 64-bit). The survey's overcommit caveat (R6) applies to
  Linux-no-overcommit deployments, which should be documented, not designed around.
- `fiber.supported` excludes wasm — WASI cannot run green threads in the fork today, consistent
  with the survey; under the cross-compile requirement (§2.1), spawning on wasm32 without a
  threaded fallback is a runtime capability question to resolve alongside the manager×target
  check (one mechanism should answer both).

## 6. Decisions to make (recommended answers)

1. **Is the manager statically known at `spawn`?** → Yes, as a language rule (comptime-resolved
   manager binding at the spawn site). This is the gate for everything in §2.3.
2. **Specialization key** → reclamation model (4 max), not manager identity.
3. **Cross-model copy layout** → model-tagged pids + per-model-pair copy stubs; canonical
   headered layout acceptable only as an explicitly temporary Stage-1 stopgap.
4. **Cross-model `move`** → degrades to copy; verifier says so; docs say so.
5. **Fork posture** → extend `Io.Evented` in `~/projects/zig`; no vendored scheduler.
6. **Safepoint strategy** → binary-wide gate + alloc-path piggyback + back-edge polls only in
   alloc-free/call-free loops.
7. **Survey Open Decision #6 (re-answered)** → tracing GC is a valid per-process model from v1;
   the per-process mark-sweep shape already exists.

## 7. Experiments (amended from the survey's risk list)

- **E1 (was R2):** spawn/ping-pong MVP directly on the fork's `Io.Evented` with the
  Dispatch/Kqueue backends on Apple Silicon. Targets: ~1–3 µs spawn, competitive ping-pong.
  This validates the substrate we actually own, before anything else.
- **E2 (was R1):** comptime-gated safepoint benchmark on the CLBG suite, including the
  alloc-path-piggyback variant; measure nbody/spectral-norm deltas with concurrency on. Kill
  criterion unchanged (>2–3% → back-edge-only or watchdog).
- **E3 (was R3):** detachable-fragment copy path under ThreadSanitizer with adversarial
  send/receive — now run per model pair (at minimum ARC→ARC, ARC→Arena, Arena→ARC) to validate
  the §2.4 stubs keep every refcount scheduler-local.
- **E4 (new):** manager-monomorphization code-size measurement — compile a representative
  program with 1, 2, and 4 reclamation models in use; measure binary growth of the
  spawn-reachable split. Kill criterion: growth wildly out of proportion to the spawn-reachable
  subgraph → revisit specialization granularity (e.g., split only memory-op-containing
  functions).
- **E5 (was R4):** region detach/adopt in the slab allocator, restricted to same-model pairs.
- **E6 (was R5):** copy p99 vs message size (64 B → 1 MB), per model pair — the crossover
  decides when to accelerate `Zap.Blob` and the move path.
