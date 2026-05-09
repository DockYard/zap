# Opportunistic Mutation Milestone

**Status:** shipped (with one documented perf gap on fannkuch n=11).
**Period:** Phase 0 instrumentation through Phase 2.6 (~50 commits).
**Reference plans:** `docs/dense-map-implementation-plan.md`, `docs/escape-analysis-research-brief.md`, `research1.md`, `research2.md`.

This document captures what was built, what works, what's documented as a gap, and the architectural foundation it leaves in place. It's the close-out for the dense-Map / flat-Vector / opportunistic-mutation project.

---

## What was built

A complete redesign of Zap's primary collections plus a static-uniqueness inference + verifier system that powers in-place mutation under value-semantic surface APIs.

### Core data structures

- **Dense `Map(K, V)`** (`src/runtime.zig` + `src/wyhash.zig`) — `ankerl::unordered_dense`-style: single-allocation buffer with header + Robin-Hood-probed bucket array + insertion-order entries array. Roc-style swap-remove on delete. wyhash with random per-process seed. Replaces the previous HAMT entirely.
- **Flat `Vector(T)`** (`src/runtime.zig`) — single-allocation buffer with header + contiguous data. Specialized as `VectorI64`/`VectorF64` aliases mirroring the prior `MArrayI64`/`MArrayF64` pattern.
- **rc-1 fast path** on every mutating operation (`put`, `delete`, `merge`, `set`, `push`, `pop`, `append`): when `header.count() == 1`, mutate in place; otherwise clone-then-mutate.
- **`*_owned_unchecked` runtime variants** for every owned-mutating operation: skip the rc-check entirely, mutate directly. Emitted by codegen only at sites the V8 verifier proves uniquely owned.

### Ownership IR pipeline

Built on the existing V1–V7 ownership invariants (no double-free, balanced retains, parameter conventions obeyed, etc.). Adds:

- **V8 invariant** (`src/arc_verifier.zig`) — alias safety on owned update. A `*_owned_unchecked` call site is accepted only if its receiver is provably uniquely owned per the static analysis. This is a post-rewrite check; if inference is wrong, the verifier rejects → compilation failure, never miscompilation.
- **Per-function uniqueness signatures** (`src/v8_signature.zig`, `src/v8_fixpoint.zig`) — 4-element lattice `{CU, PU, AL, ⊤}` with per-return-component witnesses tracking which input parameter (if any) each component preserves uniqueness from. Computed by intraprocedural classification, joined to a least fixpoint over a Tarjan SCC of the call graph.
- **Chain-consistency audit** (`src/arc_param_convention.zig`) — admits a borrowed-convention parameter slot to the lift set only when all caller chains pass uniqueness AND the V8 verifier-equivalent pre-flight check accepts the resulting promoted state. Phase 2.4's pre-flight makes the audit and verifier agree by construction.
- **V8 static-uniqueness dataflow** (`src/v8_uniqueness.zig`, `src/v8_interprocedural.zig`) — per-instruction forward dataflow producing `definitely_unique` for every local. Includes tuple_pending tracking for per-component uniqueness propagation through `tuple_init` / `index_get` / returns / escapes.
- **Codegen integration** — the call-site emission rewriter swaps `Vector.set` to `Vector.set_owned_unchecked` (and equivalents for Map) when V8 holds. Fall-through to the rc-checked path is sound; only the unchecked path gets the perf gain.

### Phase 0 instrumentation (preserved)

Behind `-Dinstrument-map=true`: per-instance per-lineage records, S/W/V classifier, atexit JSON output, aggregator script with rule-based recommendation engine. Used to validate that the dense-Map redesign was the right choice.

---

## What works

### Performance

| Benchmark | Result | vs target |
| --- | --- | --- |
| **k-nucleotide** | **1.5s wall**, byte-exact | 100% V8 firing on `Map.put` (8,749,968 unchecked sites out of 8,749,968 total) |
| **fannkuch n=10** | **2.5s wall**, byte-exact | Was 154s+ pre-Phase-1 (60× improvement) |
| **vector_rc1 example** | 100/100 unchecked | Confirms V8 + codegen end-to-end on Vector |
| Differential test suite (`bench/map-workloads/`) | 3/3 PASS | working_dict / versioned / read_mostly classifier signal correct |
| `zig build test` | 917+/917+ green | All host-side regression tests pass |

### Correctness

- **Heap corruption fix** (`2d3d174`) — the long-standing bug where ARC values extracted from non-ARC aggregates double-freed. Found and fixed during Phase 1 iteration.
- **Borrow-then-consume bug fix** (`0f60bf3`) — multiple `param_get` aliases of the same `.owned` slot now correctly share one +1 instead of double-releasing.
- **HIR shadowing fix** (`7bc783c`) — assignment bindings now correctly shadow parameters per Elixir scope rules. Was a latent bug exposed by Vector ARC.
- **V8 verifier as safety net** — every `*_owned_unchecked` site is post-hoc validated. The verifier has rejected unsound experiments multiple times during development; the rejection becomes a compile error, never a runtime crash.

### Architectural foundation

- The ownership IR with V1–V8 invariants is the substrate that Phase 3 (higher-order) will build on.
- The signature-based interprocedural fixpoint and the chain-consistency audit together provide the standard "uniqueness-with-verifier-safety" architecture used by Roc, Koka, and Lean 4.
- The dense Map and flat Vector are production-quality replacements for the HAMT and `MArray*` types.

---

## What's documented as a gap

### fannkuch-redux n=11 is 17% over its perf gate

- Current: 36.4s wall, byte-exact.
- Target: ≤ 30s wall (within 5% of MArrayI64 baseline 1.64s — note this gate was overoptimistic given fannkuch's pathological 2.15B Vector.set calls).
- Pre-Phase-1 with HAMT: did not terminate in reasonable time.
- Pre-Phase-1 with MArrayI64 (the imperative escape hatch we deleted): 1.64s.

**Root cause:** `vector_unchecked_total = 0` on fannkuch — V8 doesn't fire on Vector mutation sites in fannkuch's hot loops. The architectural diagnosis chain converged on this:

1. `arc_liveness.ArcOwnership` doesn't track last-use of non-ARC aggregates (tuples) whose components are ARC-managed. Phase 2.5's `tuple_pending` machinery in `v8_uniqueness` queries `isLastUseAt(parent_tuple, ...)` which always returns false for these aggregates, so the destructure-promotion idiom never fires on the canonical fannkuch shape.
2. With (1) fixed, Phase 2.6.2 (`TentativeAnalyzer` tuple_pending support) and Phase 2.6.3 (`arc_drop_insertion` tuple-component releases) need to come online together. They're committed but gated off behind `ZAP_ENABLE_PHASE_2_6_2`.
3. The full convergence requires uniqueness propagation through every IR shape — multi-clause control flow with tuple returns, non-ARC aggregates with ARC components, mutually-recursive PU chains. Each shape has been a separate fix; the cumulative engineering surface is large.

**Why we stopped:** the architectural chain has been narrowing across phases but the perf number on n=11 has been stuck at 36.4s through 6+ sub-phases. The remaining work is real and tractable but each round identifies the next layer. We're shipping the milestone with the n=11 gap documented because the core infrastructure is sound and the gap is on one specific worst-case benchmark.

**Phase 2.7 was started and stashed.** A future session can resume by recovering the stash (`git stash list` shows the WIP) and continuing the ArcOwnership extension work.

### Higher-order callsites (Phase 3) — not started

The plan called for lambda-set defunctionalization à la Roc (Brandon et al. PLDI 2023) to extend V8 propagation through closures and protocol dispatch. This wasn't reached. Current behavior: closure / dynamic-dispatch callees conservatively return `⊤` (unknown), which prevents V8 promotion through them but is sound.

For the workloads we have today, this is not blocking — k-nucleotide doesn't use higher-order in its hot path; fannkuch's gap is upstream of this. Phase 3 stays as future work.

### Opt-in `@unique`/`@borrow` annotations — not added

Per the research recommendation, these were planned as Phase 3 escape hatches: opt-in checked assertions on parameters (Lean 4's `@&` style — never load-bearing types). Not reached because Phase 1.x and Phase 2.x consumed all the available iteration. Future work.

---

## Architectural integrity

The most important property of this milestone is that **a wrong inference produces a compilation failure, never a miscompilation**. The V8 verifier runs post-rewrite as an independent post-hoc validator. During development, the verifier rejected unsound experiments multiple times (Phase 1.3 first-attempt veto lift, Phase 2.4 optimistic seed without pre-flight check, Phase 2.6 items 2+3 without item 3). Each rejection became a compile error, never wrong runtime output.

This safety property is what made the iterative architecture work possible. We could try aggressive optimizations and trust the verifier to catch mistakes.

---

## File inventory (commits in the project)

Phase 0 (instrumentation):
- `f8088aa`, `076e5ba`, `7c6890c`, `5a32419`, `c06697c`, `ac3e2b0`, `17252af`, `ecf8721`, `3b91d78`, `b0483bb`

Foundation (dense Map, Vector, V8 verifier, codegen):
- `bb8e5a8` (wyhash), `84b9ea2`, `927ce33`, `4d7ad62`, `14caf68`, `9bc560d` (dense Map alongside HAMT)
- `7d3bbfd` (dense Map swap; HAMT deleted)
- `8eda49f`, `ab506ac`, `0d0b298`, `6105f72` (Vector(T))
- `88c7c11`, `81c591a`, `59b8ff3`, `f3468eb` (V8 verifier + unchecked variants + codegen)
- `7021d9d` (interprocedural V8 — A1)
- `5c53d7b`, `7bc783c`, `5961043`, `8422d92` (Vector ARC-managed in IR — A2)

Phase 1 corrections:
- `2d3d174` (heap corruption fix), `d81a275`, `9cef28d` (codegen wiring + path-sensitive last-use)
- `0f60bf3` (borrow-then-consume fix)

Phase 1.7+ structural:
- `694804b` (merged-IR dedup)
- `c18eb54`, `eb88c7b` (Phase 1.8 items #4 + #5)

Phase 1 V8 signature pipeline:
- `d0983c8` (signature ADT + SCC fixpoint), `0c5d5b0` (Phase 1.3 docs)
- `e7aac3e` (verifier name-lookup), `fa0dd0e` (chain-consistency audit), `1919e98` (LiftSet tests)

Phase 2 V8 propagation work:
- `39bdeb8` (tuple-return PU classification), `d64a1ad` (path-sensitive aggregate-store)
- `c73f9f1` (cross-module signature propagation), `9ac58eb` (V8 pre-flight check)
- `72cb556` (V8 dataflow tuple_pending), `d833233` (Phase 2.6 infrastructure, items 2+3 gated off)

Documentation:
- `1d238ca` (zir-test prohibition), `b0483bb` (implementation plan)

Plus benchmark ports in `~/projects/lang-benches/` (separate repo).

---

## What changed about Zap as a language

- `Map`, `List`, and `Vector` are the canonical collections. `MArrayI64` and `MArrayF64` are deletable (gated on spectral-norm correctness fix).
- The functional surface (pure value semantics) is preserved end-to-end. `Vector.set(v, i, x)` returns a new vector; the rc-1 fast path (and unchecked variant when V8 holds) is purely an implementation optimization invisible to the user.
- Iteration order on `Map` is insertion order modulo the swap-remove on delete (matches Roc).
- The hash function is wyhash with random per-process seed, providing DoS resistance by default.

---

## Future work

**Highest priority** (closes fannkuch n=11 gap):
1. Resume Phase 2.7: extend `arc_liveness.ArcOwnership` to track last-use of non-ARC aggregates with ARC components.
2. Ungate Phase 2.6.2 + 2.6.3 (`TentativeAnalyzer` tuple_pending + `arc_drop_insertion` tuple-component releases).
3. Verify fannkuch n=11 hits 30s gate.

**Medium priority:**
4. Phase 3 — higher-order V8 propagation via lambda-set defunctionalization. Likely needed for production-scale workloads with closures and protocol dispatch.
5. Opt-in `@unique`/`@borrow` annotations as checked assertions for performance-critical hot paths.

**Cleanup:**
6. Rename "V8" everywhere — the name collides with the JavaScript engine. Internal terminology shift from "V8" to "uniqueness" or "alias-safety" or similar. (See `~/.claude/projects/-Users-bcardarella-projects-zap/memory/project_v8_rename_pending.md`.)
7. Delete the unused stashed WIP (`stash@{0}`, `stash@{1}`) once Phase 2.7 lands.
