# Implementation Plan — List Unification (Roc-style) + Performance Phases

**Reference docs (read these first if context is needed):**
- `docs/list-vector-tuple-friction-research-brief.md` — design space and four options.
- `docs/dense-map-implementation-plan.md` — sister implementation plan for the dense-Map work, voice + format mirror.
- `docs/opportunistic-mutation-milestone.md` — close-out of the uniqueness / opportunistic-mutation work that this plan builds on.
- `docs/roc-style-opportunistic-mutation-research-brief.md` — broader rationale for the rc-1 mutation model.
- `docs/zap-map-representation-research-brief.md` — Map-specific design discussion.

**Goal in one sentence.** Unify Zap's three first-class collections (`Map(K,V)`, `List(T)` as cons-cell, `Vector(T)` as flat buffer) into two (`Map(K,V)`, `List(T)` as flat buffer), formalize Tuple as a first-class type, then close the deferred Phase 2.7+ perf work and ship SIMD codegen for numeric inner loops.

**Decisions locked in by the user (do not re-litigate):**
1. **Option B from `list-vector-tuple-friction-research-brief.md` is chosen.** `Vector(T)` is eliminated as a separate concept; the canonical sequence type becomes a flat-buffer `List(T)` (Roc design). The cons-cell list goes away entirely.
2. Tuple is promoted to a first-class generic fixed-arity heterogeneous product type. Compile-time indexing only (`t.0`, `t.1`); no runtime indexing.
3. After unification, the deferred Phase 2.7 work (extending `arc_liveness.ArcOwnership` to track non-ARC aggregates with ARC components) is done, then SIMD codegen for `List(T : Numeric)` over uniquely-owned buffers is added.
4. The `@Vector` SIMD primitive in the Zig fork (`~/projects/zig/`) is the codegen target — it is internal to the compiler, never user-facing. The word "Vector" disappears from the Zap surface.

---

## 1. What Zap Is

Zap is an early-stage statically-typed functional programming language. The surface is heavily inspired by Elixir (modules, pattern matching, multi-clause functions, atoms, pipe operator `|>`, sigils, persistent collections). The runtime is native: there is no VM, no interpreter, no tracing GC.

- **Statically typed** with a Hindley–Milner-derived type system extended for protocols/typeclasses.
- **Compiled to native code** through LLVM via Zig's intermediate representation (ZIR).
- **No top-level functions.** Every `def`/`fn` lives inside a `defmodule`/`pub struct`.
- **Macro-driven.** Macros are written in Zap itself and run at compile time.
- **Functional-first** with pure surface semantics — every operation returns a new value; mutation is purely an under-the-hood optimization invisible to users.
- **Single-threaded today.** Multi-threading is not in scope but should not be foreclosed.

A short example to anchor vocabulary:

```zap
defmodule Counter {
  pub fn count_words(text :: String) -> Map(String, i64) {
    text
    |> String.split(" ")
    |> Enumerable.reduce(Map.new(), fn(word, acc) ->
      Map.put(acc, word, Map.get(acc, word, 0) + 1)
    end)
  }
}
```

`Map.put` returns a new map semantically; under the hood the rc-1 fast path mutates in place when the uniqueness verifier proves uniqueness. The user does not see this distinction.

### Compilation pipeline

```
Zap source (lib/*.zap, user code)
  │
  ▼ src/lexer.zig + src/parser.zig
AST
  │
  ▼ src/macro_eval.zig + src/desugar.zig
Expanded AST
  │
  ▼ src/types.zig + src/resolver.zig
Typed AST
  │
  ▼ src/hir.zig
HIR (high-level IR)
  │
  ▼ src/ir.zig    ← ARC ownership inference + uniqueness inference happen here
IR (ownership-typed)
  │
  ▼ src/zir_builder.zig
Zig ZIR (via C-ABI calls into the forked Zig compiler)
  │
  ▼ ~/projects/zig/  (the forked Zig compiler)
LLVM IR
  │
  ▼ Zig-fork build system
Native binary (linked against libzap_compiler.a + src/runtime.zig)
```

**Hard invariant:** Zap *only* lowers through ZIR. There is no Zig-source-text codegen path. `src/codegen.zig` is dead legacy; `src/zir_builder.zig` is the only supported lowering. If a feature requires a new lowering, the correct fix is to add a C-ABI to the fork. The fork at `~/projects/zig/` exposes `libzap_compiler.a`. Modifications to the fork are allowed when needed.

### Memory model — ARC + per-type pools

- Every heap-allocated value carries an inline `ArcHeader { strong_count, weak_count, type_id }` at the head of the cell. `retain` increments; `release` decrements and runs the type's drop function on the zero-transition.
- There is no GC. There is no cycle collector. All lifetimes are managed by ARC.
- Each ARC-managed type allocates out of a thread-local `std.heap.MemoryPool(T)`, giving O(1) alloc/free with no `malloc` overhead in hot loops.
- Pure functional surface semantics — every collection operation returns a new value semantically. The runtime may reuse storage when uniqueness is provable, but the user-visible shape is purely value-semantic.

The classification of "ARC-managed" lives in `src/ir.zig::isArcManagedTypeId` (line 1166):

```zig
return switch (type_store.getType(type_id)) {
    .opaque_type, .map, .list, .vector_type => true,
    else => false,
};
```

Plain integers/floats/bools/atoms are *trivial* — no retain/release. `Map`, `List`, `Vector`, and opaque types (`String`, `Atom`, etc.) are ARC-managed.

### Source map — where to read code

- **Runtime collections + ARC headers + `*_owned_unchecked` variants:** `src/runtime.zig` (~10,580 lines).
- **IR + type registry + ARC classification:** `src/ir.zig` (~9,735 lines).
- **Type system primitives:** `src/types.zig`.
- **Native type registry (NativeTypeKind):** `src/scope.zig` line 479.
- **ZIR emission (the only codegen path):** `src/zir_builder.zig`, `src/zir_backend.zig`.
- **Ownership pipeline:** `src/arc_ownership.zig`, `src/arc_param_convention.zig`, `src/arc_liveness.zig`, `src/arc_drop_insertion.zig`, `src/arc_verifier.zig`, `src/arc_optimizer.zig`.
- **uniqueness inference:** `src/uniqueness.zig`, `src/uniqueness_signature.zig`, `src/uniqueness_fixpoint.zig`, `src/uniqueness_interprocedural.zig`.
- **Zap standard library:** `lib/*.zap` — `kernel.zap`, `map.zap`, `list.zap`, `vector_i64.zap`, `vector_f64.zap`, etc.
- **Forked Zig compiler:** `~/projects/zig/` — `src/zir_api.zig` exposes the C-ABI; `@Vector` SIMD primitive is at `src/zir_builder.zig:3320` in the fork.
- **CLBG benchmark suite (separate repo):** `~/projects/lang-benches/`.
- **Map workload instrumentation (still in repo, behind `-Dinstrument-map=true`):** `bench/map-workloads/`.

---

## 2. Current State

The user has been through a multi-month effort building toward this point. The codebase right now reflects all of that work.

### 2.1 Existing collection types

- **`Map(K, V)`** (`src/runtime.zig:4772`): dense `ankerl::unordered_dense`-style hash table. Robin Hood probing with `(dist << 8) | fingerprint` packed metric, swap-remove on delete, wyhash with random per-process seed. Generic over K and V. Well-known TypeId. Surface in `lib/map.zap`. Replaced an earlier HAMT in commit `7d3bbfd`.
- **`List(T)`** (`src/runtime.zig:5726`): cons-cell persistent linked list. Each cell `{ ArcHeader, head: T, tail: ?*const Cell }`, allocated through a thread-local `MemoryPool(Cell)`. ARC-managed (per Phase H.4 in commit `bd4a5e4`). Generic. Surface in `lib/list.zap`. **This is what Option B replaces.**
- **`Vector(T)`** (`src/runtime.zig:1678`): flat-buffer mutable contiguous array `{ ArcHeader, len: u32, cap: u32 }` followed by `[cap]T`. Generic at the runtime level (`pub fn Vector(comptime T: type) type`). Currently exposed at the language level only as concrete aliases `VectorI64` (`src/runtime.zig:1671`) / `VectorF64` (`src/runtime.zig:1676`) in `lib/vector_i64.zap` / `lib/vector_f64.zap`. **This is what Option B unifies into List.**
- **Tuple syntax `{a, b, c}`**: structural anonymous shapes with `tuple_init` (`src/ir.zig:308`) and `index_get` (`src/ir.zig:317`) IR opcodes. Used heavily for `{:error, "reason"}` patterns and multi-return shapes like `{VectorI64, Bool}`. Compile-time indexing only. **Not first-class as a type yet — Stage 7 of this plan addresses that.**

### 2.2 Existing V1–uniqueness ownership IR

Built incrementally over many phases. `src/arc_verifier.zig` enforces the suite of invariants post-rewrite:

- **V1–V7**: existing ownership invariants (no double-free, balanced retains, parameter conventions obeyed at every call site, return-value conventions match, ownership transfers across `if`/`switch` arms balance, drops at scope exit cover exactly the live-but-not-consumed set).
- **uniqueness**: alias safety on owned update — a mutator may return its receiver's pointer (rc-1 in-place mutation) only if the receiver is provably uniquely owned at the call site. Verifier check in `src/arc_verifier.zig::runUniquenessCheck`.

Static analysis pipeline:
- `src/uniqueness.zig` (~2,272 lines): per-instruction forward dataflow producing `definitely_unique` for every local. Includes `tuple_pending` tracking for per-component uniqueness propagation through `tuple_init` / `index_get` / returns / escapes.
- `src/uniqueness_signature.zig` (~352 lines): per-function uniqueness signatures using a 4-element lattice `{CU, PU, AL, ⊤}` with per-return-component witnesses tracking which input parameter (if any) each component preserves uniqueness from.
- `src/uniqueness_fixpoint.zig` (~2,496 lines): joins per-function signatures to a least fixpoint over a Tarjan SCC of the call graph.
- `src/uniqueness_interprocedural.zig` (~1,554 lines): propagates uniqueness across function boundaries.

Codegen integration: `src/arc_ownership.zig` rewrites `Vector.set` → `Vector.set_owned_unchecked` (and equivalents for Map) at provably-safe sites, eliding the runtime rc-check entirely.

Chain-consistency audit: `src/arc_param_convention.zig::computeLiftSet` (line 293) admits a `.borrowed` slot to the lift set when audit + uniqueness pre-flight both accept.

### 2.3 Recent commit chain (last ~30 commits)

The future agent should read these for context. Each delivered a concrete piece of the substrate this plan builds on.

```
9c8ba1d fix(arc): close two dataflow gaps surfaced by Phase H.4 .list ARC flip
bd4a5e4 feat(ir): flip .list to ARC-managed in isArcManagedTypeId (Phase H.4)
e8dc773 fix(runtime): retain head/tail in List.next, getHead, getTail (Phase H.3)
de47ed5 fix(arc_liveness): scope guard_block body ownership to its execution path
7cc588b fix(ir,arc_verifier): plumb HIR types through list-binding and verifier param lookup
4cf2ba1 feat(runtime): List(T) cells become Arc-headered + pool-allocated (Phase H.1)
57405b5 feat(ir): flag .map as ARC-managed (Phase F milestone)
3fdab5b docs(milestone): mark MArray deletion complete (5693091)
5693091 feat(runtime,lib): delete MArrayI64/MArrayF64 — replaced by VectorI64/VectorF64 (Phase 6)
af2f3da docs: opportunistic-mutation milestone close-out
d833233 feat(v8,arc): Phase 2.6 infrastructure for SCC tuple-pending promotions
72cb556 feat(uniqueness): tuple_pending tracking for per-component uniqueness propagation (Phase 2.5)
9ac58eb feat(arc): uniqueness-uniqueness pre-flight check in chain-consistency audit (Phase 2.4)
c73f9f1 fix(arc_param_convention): path-sensitive chain-consistency + cross-module-aware anchor (Phase 2.3)
d64a1ad feat(arc_ownership): path-sensitive aggregate-store move + uniqueness rewriter id-order fix (Phase 2.2)
39bdeb8 feat(uniqueness_fixpoint): tuple-return PU classification (Phase 2.1)
eb88c7b feat(uniqueness_fixpoint): borrow-passthrough short-circuit on top-signature .borrowed callees (Phase 1.8 #5)
c18eb54 feat(arc): bounded-borrow refinement in paramSlotIsRefetchedAfter (Phase 1.8 #4)
694804b fix(compiler): dedupe merged-IR functions when struct is processed both as module and entry-point
0f60bf3 fix(arc): correct ARC discipline for borrow-then-consume sequences
9cef28d fix(arc): close k-nucleotide uniqueness gaps via path-sensitive last-use + cross-struct convention fallback
2d3d174 fix(ir): retain ARC values extracted from non-ARC tuples and structs
1919e98 test(arc_param_convention): add LiftSet packing/lookup unit tests
fa0dd0e feat(arc): chain-consistency audit before lifting borrowed-source veto
e7aac3e fix(arc_verifier): make convention name lookup last-wins to match rewriter and inference passes
0c5d5b0 docs(uniqueness_signature): document deferred Phase 1.3 integration with soundness notes
d0983c8 feat(arc): per-function uniqueness signatures + SCC fixpoint (Phase 1.1+1.2)
5c53d7b feat(arc): make Vector(T) ARC-managed in IR (A2)
7bc783c fix(hir): assignment bindings shadow parameters per Elixir scope rules
7021d9d feat(arc): interprocedural uniqueness uniqueness fixpoint (A1)
```

### 2.4 Current benchmark numbers (lang-benches)

Trust these. Don't re-run benchmarks to verify them.

| Benchmark | Current Zap | Best baseline | Status |
| --- | --- | --- | --- |
| **k-nucleotide** | 1.5s, byte-exact | C ~60ms | 100% uniqueness firing on `Map.put` (8.75M unchecked / 8.75M total) |
| **nbody** | 103ms | (fastest of 7 tested) | No collections used |
| **mandelbrot** | 2.044s | Competitive with C/Rust | No collections used |
| **binarytrees** | 5.49s | Beats C/Rust/Go | No collections used |
| **fannkuch-redux n=10** | 2.6s, byte-exact | — | Was 154s+ pre-Phase-1 (60× improvement) |
| **fannkuch-redux n=11** | 36.4s, byte-exact | C 1.55s | Over 30s gate. `vector_unchecked_total = 0` — uniqueness doesn't fire. Documented gap. |
| **spectral-norm** | 1.86s, byte-exact | Rust 156ms | Was NaN through ~10 phases |

### 2.5 Stashed WIP from deferred work

`git stash list` shows:

```
stash@{0}: On main: Phase 2.7 WIP from killed agent
```

The diff stats:
```
src/arc_liveness.zig         | 255 ++++++++++++++++++++++++++++
src/arc_param_convention.zig | 390 +++++--------------------------------------
src/compiler.zig             |  43 +++--
3 files changed, 317 insertions(+), 371 deletions(-)
```

This is ~1,018 lines of work-in-progress from a previous agent that was killed mid-task. It is **research material, not necessarily safe to recover wholesale**. When Stage 8 begins, inspect with `git stash show -p stash@{0}` and decide whether to recover or restart based on quality of the WIP. Do not blindly apply it.

The Phase 2.6.2 / 2.6.3 work that this stash was attempting to ungate is currently behind an env-var feature flag at `src/arc_param_convention.zig:643`:

```zig
// Set ZAP_ENABLE_PHASE_2_6_2=1 to reactivate the new behaviour
const phase_2_6_2_enabled = std.c.getenv("ZAP_ENABLE_PHASE_2_6_2") != null;
```

### 2.6 Hard rules (project-wide constraints)

- **Never run `zig build zir-test`.** This is forbidden across the project. zir-test takes 6+ minutes per invocation and previous agents have been killed for running it. Verification uses only: `zig build`, `zig build test`, `zig build test -Dinstrument-map=true`, `bench/map-workloads/run-differential-tests.sh`, and direct CLBG benchmark invocation.
- **No special-casing.** No hardcoded function names, no benchmark-specific heuristics in compiler logic. Zap is a general-purpose language; the compiler is a general-purpose tool.
- **No hardcoded Zap struct names in the compiler.** If you find yourself writing a Zap struct name as a string literal in Zig source, you are doing it wrong. Find the Zap-level solution.
- **Soundness over speed.** The uniqueness verifier is the post-rewrite safety net. Wrong inference produces compilation failure, never miscompilation.
- **No workarounds, no hacks.** Production-grade fixes only. If a proper fix requires deep architectural changes across multiple files, that is the fix. If it requires changes to the Zig fork, make those changes.
- **TDD.** Failing test first, then implementation. Run `zig build test` and confirm green before committing.
- **Frequent commits.** Don't allow projects to run on with work uncommitted. One commit per sub-deliverable where reasonable.
- **No top-level functions in Zap.** Every `def`/`fn` must live inside `defmodule`/`pub struct`.
- **All public Zap functions need `@fndoc`.** Heredoc strings. Blank line after every closing `"""`.
- **Functional surface semantics.** Whatever the implementation, every collection operation returns a new value semantically. Mutation is invisible to the user. The opportunistic-mutation pattern (uniqueness) is the safety substrate for any "in-place" optimization.

---

## 3. Why Option B (Roc-style List unification) Is the Answer

The user has chosen Option B from `docs/list-vector-tuple-friction-research-brief.md`. This section captures the rationale so a future agent doesn't second-guess it.

**Roc is the closest precedent to Zap.** Roc, like Zap, is ARC-managed, native-compiled, statically-typed, and functional-first. Roc has only `List T` — flat-buffer, no separate cons-cell list. Roc handles `[head, ..rest]` pattern syntax over the flat-buffer representation through specific lowering rules: head is a slot read, rest is a slice or clone (depending on uniqueness).

**ARC + Perceus-style reuse analysis closes the persistence gap.** The most-cited drawback of flat-buffer-only is "you lose persistent suffix-sharing across versions." But under ARC + the uniqueness substrate that Zap already has, the compiler reuses the same buffer across versions when there is exactly one live reference; allocates a new buffer only when there is fanout. Lean 4's `Array α` proves this works in practice for the workloads where it matters.

**The Elixir surface is preserved — it's destructuring, not representation.** `[h | t]` and `[a, b, c | rest]` are pattern-match syntax. They lower to head-extract + tail-slice. The user code reads the same; the underlying representation is flat. Roc's experience is that this is invisible to nearly all client code.

**Cons-cell suffix-sharing is the genuine loss.** Workloads that hold many near-identical versions of the same list (undo stacks, reducer histories, persistent-data-structures-as-database) lose their O(1) cons + structural sharing. This is a real cost. Mitigation: when a real production user hits this, library types (`LazyList`, `Zipper`) can be added on top of `List(T)` without touching the representation.

**Most FP languages have both List and Vector for Lisp-legacy reasons.** OCaml, Haskell, Standard ML, Scala, Clojure, Lean 4, Idris 2 all maintain both. The historical cause is that cons-cell list was THE list before flat-buffer mutable arrays were the default in functional languages. The dual-collection design has stuck around as accumulated convention. It is not actively right.

**The friction in §5 of the friction brief is concentrated entirely on Vector.** Every Zap benchmark that does NOT use `Vector` is competitive with C/Rust. Both benchmarks that DO use Vector (fannkuch, spectral-norm) are the worst-case Zap performers. Vector's theoretical advantage (cache-friendly contiguous storage, O(1) indexed access) hasn't translated to delivered perf because the hot-loop uniqueness firing requires non-ARC-aggregate-with-ARC-component last-use tracking (Phase 2.7) that's still unfinished. Option B does not eliminate this work — it relocates it to the unified `List(T)`. But the unification removes a duplicate type in the surface and aligns the language identity with Roc.

**The user has zero production users.** This is the right time to make breaking surface changes. The agent should not constrain the recommendation by fear of breakage.

Option A (keep three) preserves the status quo's design errors. Option C (Elixir-style cons-only) closes the door on numerical workloads entirely. Option D (hybrid) tends to trap — Rust's `HashMap` is just dense; Roc's `List` is just flat-buffer; production systems that have tried hybrids have backed away. **Option B is the answer.**

---

## 4. Stage-by-Stage Implementation Plan

Ten stages, sequenced. Stages 1–6 are the List unification (Option B) proper. Stage 7 (Tuple) is independent and can interleave. Stages 8–9 are perf work that depends on Stage 6 being done. Stage 10 is independent cleanup.

Each stage has: **Goal**, **Files**, **Deliverables**, **Verification gates**, **Done criteria**.

### Stage 1: Foundation — flat-buffer `List(T)` alongside cons-cell `List`

**Goal:** introduce the flat-buffer List(T) without breaking existing cons-cell List code. Both coexist briefly so migration can be staged without regressions.

**Files modified:**
- `src/runtime.zig` — rename current `Vector(T)` body to a temporary internal name (`FlatList(T)` is suggested). Keep its existing implementation: single-allocation buffer with `[ArcHeader][header: len, capacity][data: [cap]T]`, rc-1 fast path on set/push/pop/append, `*_owned_unchecked` variants exposed at the runtime level. **Do not touch `Vector(T)` callers yet.**
- Keep current `runtime.zig::List(T)` (cons-cell) untouched. It will be renamed in Stage 2.
- Keep `VectorI64` and `VectorF64` aliases pointing at the renamed type body (so existing surface continues to compile).

**Deliverables:**
- 1.1 Internal type body renamed to `FlatList(T)` (or final long-term name). Surface aliases `VectorI64`/`VectorF64` continue to point at it.
- 1.2 `runtime.zig::FlatList` exposes the same operations Vector currently does: `new_filled`, `new_empty`, `length`, `get`, `set`, `set_owned_unchecked`, `push`, `push_owned_unchecked`, `pop`, `pop_owned_unchecked`, `append`, `append_owned_unchecked`, `retain`, `release`. No new operations; this is a pure rename.
- 1.3 Unit-test block in `src/runtime.zig` confirms FlatList round-trips on `i64`, `f64`, ARC-managed `String`, and a generic struct type T with non-trivial drop. Existing Vector tests get updated to reference the new internal name.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- All CLBG benchmarks byte-exact (k-nucleotide, fannkuch n=10, fannkuch n=11, spectral-norm, nbody, mandelbrot, binarytrees).

**Done criteria:**
- Single commit: "refactor(runtime): rename Vector(T) body to FlatList(T) (Stage 1)".
- No surface change visible to Zap-level code.
- All gates green.

### Stage 2: Surface migration — replace `Vector` with `List` semantically

**Goal:** rename `Vector` everywhere in the IR + scope + types layers so all references align with the long-term `List` name. Existing cons-cell List temporarily renamed to `ConsList` for clarity during migration.

**Files modified:**
- `src/runtime.zig`:
  - Rename current `pub fn List(comptime T: type) type` (cons-cell) → `pub fn ConsList(comptime T: type) type`. This is temporary; deleted in Stage 6.
  - Promote `pub fn FlatList(comptime T: type) type` from Stage 1 to be the canonical `pub fn List(comptime T: type) type`. The old cons-cell List name is now bound to the flat-buffer type body.
  - Delete the `VectorI64` and `VectorF64` aliases. Replace `pub const VectorI64 = Vector(i64);` with nothing; `lib/vector_i64.zap` is rewritten in Stage 3.
- `src/ir.zig`:
  - In `isArcManagedTypeId` (line 1166): the `.vector_type` arm goes away. Currently:
    ```zig
    return switch (type_store.getType(type_id)) {
        .opaque_type, .map, .list, .vector_type => true,
        else => false,
    };
    ```
    Becomes:
    ```zig
    return switch (type_store.getType(type_id)) {
        .opaque_type, .map, .list => true,
        else => false,
    };
    ```
    The same change applies to the duplicate switch ~line 5621 and the comment block ~line 1189. Search for every `.vector_type` reference and either delete it or fold it into the `.list` arm.
- `src/types.zig`:
  - Delete the `vector_type: VectorElementKind` variant from the `ZigType` union (currently line 76).
  - Delete `VectorElementKind` enum (currently line 117): `pub const VectorElementKind = enum { i64, f64 };`.
  - The `list: ListType` variant (line 80) absorbs everything Vector was used for — `ListType` keeps its same structure, and the runtime type body is now flat-buffer.
- `src/scope.zig`:
  - Delete `vector_i64` and `vector_f64` variants from `NativeTypeKind` enum (currently lines 484–485).
  - Delete the corresponding `fromName` cases (lines 492–493).
  - Add the `list` variant if not already present, and wire it through.
- `src/zir_builder.zig` and `src/zir_backend.zig`:
  - Any `vector_*` emit functions get renamed `list_*` and routed through the unified path.
  - Search for every `.vector_type` and `.vector_i64`/`.vector_f64` reference; route through `.list`.
- `lib/vector_i64.zap` and `lib/vector_f64.zap`:
  - Delete both files. Their content is replaced in Stage 3 by a generic `lib/list.zap`.
- `lib/list.zap`:
  - Move current contents (cons-cell-shaped surface) to a temporary `lib/cons_list.zap` and update its `@native_type` and `pub struct ConsList` accordingly. This file is deleted in Stage 6.

**Deliverables:**
- 2.1 All `vector_*` references renamed to `list_*` in IR/scope/types layers. `grep -rn "vector_type\|vector_i64\|vector_f64" src/` returns zero matches outside historical comments.
- 2.2 Cons-cell List is now named `ConsList` everywhere. `grep -rn "fn List(" src/runtime.zig` returns one match: the new flat-buffer body.
- 2.3 Existing `lib/vector_i64.zap` / `lib/vector_f64.zap` deleted; `lib/list.zap` is empty or replaced with a stub.
- 2.4 All compiler tests pass without surface API existing yet — Stage 3 fills in the surface.

**Verification gates:**
- `zig build` (compiler builds, even if no Zap programs use the new List surface yet).
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- Benchmarks that previously used `VectorI64` / `VectorF64` will not yet build — this is expected; Stage 3 adds the new surface and Stage 5 ports the benchmarks.

**Done criteria:**
- Mechanical rename done across IR, types, scope, zir_builder.
- `grep -rn "Vector\|vector_" src/ lib/` returns matches only in: `.zap-cache` (ignored), historical comments, the `@Vector` LLVM SIMD primitive in `~/projects/zig/` (out of scope).
- One commit per logical unit (IR rename, types rename, scope rename, runtime rename, lib delete).

### Stage 3: Generic `List(T)` Zap surface

**Goal:** a single generic `List(T)` Zap-level type that maps to the flat-buffer runtime. Mirrors `Map(K, V)`'s shape exactly.

**Files created:**
- `lib/list.zap` — new file, replaces the deleted cons-cell list surface AND the deleted `vector_i64.zap` / `vector_f64.zap` aliases. Generic `pub struct List` with `@native_type = "list"`.

**Files modified:**
- `src/zir_builder.zig` — emit the generic `List` type for arbitrary T. Mirror how `Map(K, V)` is emitted today.
- `src/types.zig` — `ListType` already exists; verify it is generic over its element type and not specialized to a `VectorElementKind`.

**Surface API (representative — all functions need `@fndoc` heredocs):**

```zap
@native_type = "list"

@structdoc = """
A flat-buffer sequence of elements of type T.

Backed by `List(T)` in the runtime — single-allocation contiguous
buffer with ARC-managed lifetime, opportunistic in-place mutation
under uniqueness, and O(1) indexed access.
"""

pub struct List {
  @fndoc = """
  Allocate a new list of `size` elements, each initialized to `init`.
  ...
  """

  pub fn new_filled(size :: i64, init :: t) -> List(t) {
    :zig.List.new_filled(size, init)
  }

  pub fn new_empty(initial_capacity :: i64) -> List(t) { ... }

  pub fn length(list :: List(t)) -> i64 { ... }

  pub fn get(list :: List(t), index :: i64) -> t { ... }

  pub fn set(list :: List(t), index :: i64, value :: t) -> List(t) { ... }

  pub fn push(list :: List(t), value :: t) -> List(t) { ... }

  pub fn pop(list :: List(t)) -> {List(t), t} { ... }

  pub fn append(a :: List(t), b :: List(t)) -> List(t) { ... }

  pub fn map(list :: List(t), f :: fn(t) -> u) -> List(u) { ... }

  pub fn filter(list :: List(t), pred :: fn(t) -> Bool) -> List(t) { ... }

  pub fn reduce(list :: List(t), init :: u, f :: fn(t, u) -> u) -> u { ... }

  # Cons-cell-style destructuring still works (lowered to slice ops):
  #
  #   match list {
  #     [head | rest] -> ...
  #     [] -> ...
  #   }
}
```

**Deliverables:**
- 3.1 `lib/list.zap` exposes the canonical generic API with `@fndoc` heredocs on every public function.
- 3.2 ZIR emit for `List(t)` works for arbitrary `t`: `i64`, `f64`, ARC-managed (`String`), generic struct, nested `List(List(i64))`.
- 3.3 Test programs in `test/` cover: `let l = List.new_filled(10, 0 :: i64)`, `List.set(l, 5, 99)`, `List.length(l)`, `List.append`, `List.map`, `List.filter`, `List.reduce`, `List.push`, `List.pop`.
- 3.4 The uniqueness unchecked rewrite continues to fire on `List.set` exactly as it fired on `Vector.set` pre-rename. Confirm by inspecting `vector_unchecked_total` (which should be renamed to `list_unchecked_total` as part of this stage — search-replace in `src/runtime.zig`).

**Verification gates:**
- `zig build test` green with the new test programs.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- A small Zap program using `List(i64)` end-to-end produces correct output.

**Done criteria:**
- `lib/list.zap` exists with full generic `List(T)` surface, `@fndoc` on every public function, blank line after each closing `"""`.
- Zap-level user code can write `List(i64)`, `List(f64)`, `List(String)`, `List(MyStruct)` and have the compiler emit correct ZIR.
- Commit: "feat(runtime,lib): generic List(T) Zap surface (Stage 3)".

### Stage 4: Migrate `[h | t]` syntax to flat-buffer destructure

**Goal:** make the existing pattern-match syntax `[h | t]` and `[a, b, c | rest]` work over the flat-buffer `List`, like Roc's `[first, ..rest]`. The user-visible pattern-match shape is unchanged; only the lowering changes.

**Files modified:**
- `src/parser.zig` — verify the parser already produces a list-pattern AST node for `[h | t]`. No changes expected; if changes are needed, the AST node should encode head + rest as separate slots.
- `src/hir.zig` — the HIR-side lowering of list-pattern: previously emitted `list_head` / `list_tail` IR ops that traversed a cons-cell. Retarget these (or introduce new HIR ops) to emit a head extract + tail slice over the flat-buffer.
- `src/ir.zig` — replace the cons-cell-shaped `list_head` / `list_tail` opcodes with flat-buffer-shaped `list_head` (head element), `list_slice` (rest as a `List(T)` view starting at index 1, length-1). Or introduce new opcodes if cleaner. Cite the existing cons-cell `list:` type opcodes at lines 610, 626, 636.
- `src/runtime.zig` — provide `List.head(l) -> t` (returns `l[0]` with bounds check), `List.tail(l) -> List(t)` (returns the rest, allocating a new buffer that shares no storage; OR returns a slice view if the compiler can prove the slice doesn't outlive the parent). The choice between "always copy" and "slice-on-uniqueness" is a perf decision documented below.
- `lib/list.zap` — expose `List.head` and `List.tail` as user-callable functions.

**Lowering semantics:**

The pattern `[h | t]` lowers to:

```zir
%h = List.head(%list)            # bounds-checked read of l[0]
%t = List.tail(%list)            # rest of the list as a new List(T)
```

Under uniqueness inference, `List.tail` becomes `List.tail_owned_unchecked` and reuses the parent buffer in place by shifting elements down. Under non-uniqueness, it allocates a fresh buffer.

For richer patterns like `[a, b, c | rest]`, the lowering is:

```zir
%a = List.get(%list, 0)
%b = List.get(%list, 1)
%c = List.get(%list, 2)
%rest = List.slice(%list, 3, length(%list) - 3)
```

For tail-only patterns like `[]` (empty match), the lowering is `length(%list) == 0`.

**Deliverables:**
- 4.1 New / repurposed IR opcodes for flat-buffer head/tail/slice. Existing `list_head` / `list_tail` opcodes either repurposed or replaced with new opcodes that take a flat-buffer `List(T)` and produce a `T` (head) or `List(T)` (slice).
- 4.2 Runtime support: `List.head_owned_unchecked`, `List.tail_owned_unchecked`, `List.slice_owned_unchecked` variants exposed on the rc-1 fast path.
- 4.3 uniqueness verifier extension: the slice/tail operations participate in the uniqueness lattice. A slice-from-uniquely-owned-list returns a uniquely-owned list slot (aliasing analysis must understand that the slice IS the original buffer, just with a shifted base pointer + new len).
- 4.4 All existing `lib/*.zap` code that uses `[h | t]` patterns continues to work.
- 4.5 Test programs cover: list pattern matching, recursive functions over lists (`def length(list)` matching `[_ | rest]`), Erlang-style `def reverse(list)` accumulator pattern.

**Verification gates:**
- `zig build test` green.
- All Zap-level tests that use `[h | t]` patterns continue to pass.
- A recursive function over a List(T) produces correct output (e.g., `def sum([]) = 0; def sum([h | t]) = h + sum(t)` returns the right sum).

**Done criteria:**
- `[h | t]` pattern matching works over flat-buffer `List(T)`.
- The IR opcodes for list pattern matching are aligned with the flat-buffer representation.
- Commit: "feat(parser,ir,runtime): list pattern matching over flat-buffer List(T) (Stage 4)".

### Stage 5: Migrate stdlib and benchmark code

**Goal:** remove all uses of the cons-cell `ConsList` from `lib/`. After this stage, `ConsList` is unreferenced and ready to delete. Migrate fannkuch and spectral-norm benchmark sources to the new `List(T)` API.

**Files modified:**
- All `lib/*.zap` files: search for any references to `ConsList` (renamed cons-cell list from Stage 2). Convert each to the new flat-buffer `List(T)` API. Most existing code should "just work" since the flat-buffer List exposes the same operations as cons-cell List (`length`, `prepend`, `head`, `tail`, `map`, `filter`, `reduce`, etc.) — only the implementation differs.
- `lib/list/concatenable.zap`, `lib/list/enumerable.zap`, `lib/list/membership.zap` — protocol implementations may need their `@native_type` updates and any cons-cell-specific implementation details ripped out.
- `~/projects/lang-benches/fannkuch-redux/` — benchmark source uses `VectorI64` today. Replace with `List(i64)`.
- `~/projects/lang-benches/spectral-norm/` — benchmark source uses `VectorF64`. Replace with `List(f64)`.

**Audit checklist:**
- Every `lib/*.zap` reviewed for `ConsList` references → converted to `List`.
- Every `lib/*.zap` reviewed for `VectorI64` / `VectorF64` references → converted to `List(i64)` / `List(f64)`.
- Both benchmark sources updated.

**Deliverables:**
- 5.1 `grep -rn "ConsList\|VectorI64\|VectorF64\|Vector(" lib/` returns zero matches.
- 5.2 Both benchmarks (`fannkuch-redux`, `spectral-norm`) compile under the new API.
- 5.3 Both benchmarks produce byte-exact output vs current main (the renamed-but-equivalent flat-buffer should give identical results).
- 5.4 All other CLBG benchmarks (k-nucleotide, nbody, mandelbrot, binarytrees) unchanged.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- All CLBG benchmarks byte-exact.
- Wall-time numbers preserved within noise (no expected change at this stage; Stage 8+ delivers the perf improvements).

**Done criteria:**
- `lib/` is fully migrated to the new `List(T)`.
- Benchmarks produce byte-exact output and are within noise of current wall-time.
- Commits: one per `lib/*.zap` migration unit, plus one per benchmark.

### Stage 6: Delete cons-cell `ConsList` and Vector remnants

**Goal:** simplify. One sequence type. No vestigial code.

**Files deleted:**
- `runtime.zig::ConsList(T)` — the entire renamed cons-cell type body.
- `lib/cons_list.zap` (created in Stage 2 as a temporary holding place) if still present.
- Any cons-cell-specific opcodes in `src/ir.zig` that were not retargeted in Stage 4.
- The `MemoryPool(Cell)` allocator for cons-cell list cells.

**Files modified:**
- `src/runtime.zig` — remove `ConsList` body, imports, and helper functions.
- `src/ir.zig` — remove cons-cell opcodes; ensure `list:` type entry points only at the flat-buffer body.
- `src/scope.zig` — clean up any `cons_list` native type references (none expected, but verify).
- Any related test fixtures.

**Deliverables:**
- 6.1 `grep -rn "ConsList\|cons_list\|cons_cell\|cons-cell" src/ lib/ test/ examples/` returns zero matches (excluding `.zap-cache` and historical doc references).
- 6.2 `grep -rn "Vector\|vector_" src/ lib/ test/ examples/` returns matches only in: historical doc references in `docs/`, the `@Vector` LLVM SIMD primitive references in `~/projects/zig/` (out of scope), and the `vector_unchecked_total` runtime counter (which should already have been renamed to `list_unchecked_total` in Stage 3 — verify).
- 6.3 All tests still green.
- 6.4 All benchmarks still byte-exact.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- All CLBG benchmarks byte-exact.

**Done criteria:**
- One sequence type (`List(T)`) in the surface and runtime. No vestigial cons-cell code anywhere.
- Final commit: "feat(runtime,lib): unify List(T) on flat-buffer; cons-cell List deleted (Roc-style design) (Stage 6)".

### Stage 7: Tuple formalization (independent, can interleave with Stages 1–6)

**Goal:** promote Tuple to a first-class generic fixed-arity heterogeneous product type. Compile-time indexing only — no runtime indexing (that would re-create homogeneous-vector confusion). Pattern matching continues to work.

This stage can interleave with Stages 1–6; it touches mostly different files (`src/types.zig`, `lib/tuple.zap`). Sequence with the other stages based on agent throughput.

**Files modified:**
- `src/types.zig` — `tuple: TupleType` (line 79) already exists. Verify it's generic over the slot type list. Make sure `TupleType { elements: []const TypeId }` has the right shape.
- `src/ir.zig` — `tuple_init` (line 308) and `index_get` (line 317) opcodes already exist. Confirm they handle arbitrary arity.
- `src/scope.zig` — add a `tuple` `NativeTypeKind` variant if not present (so user code can write `Tuple.size`).

**Files created:**
- `lib/tuple.zap` — new file. `pub struct Tuple` with operations like:

```zap
@native_type = "tuple"

@structdoc = """
Heterogeneous fixed-arity product type. Tuples are anonymous
structural shapes — `{i64, String, Bool}` is a distinct type from
`{i64, String, Bool, Atom}`. Indexing is compile-time only:
`t.0`, `t.1`. There is no runtime `t.[i]` because slot types
differ.

Compiles to record-equivalent layout. `(a, b, c)` and the literal
`{a, b, c}` produce the same shape.
"""

pub struct Tuple {
  @fndoc = """
  Number of slots in the tuple. Compile-time constant.
  ...
  """

  pub fn size(t :: Tuple) -> i64 { :zig.Tuple.size(t) }

  # ... compile-time-indexed accessors per slot
}
```

**Surface semantics (locked in by user):**
- Tuples are heterogeneous: `{i64, String, Bool}` is a real type.
- Fixed-arity at the type level: `{i64, Bool}` ≠ `{i64, Bool, String}`.
- **Compile-time indexing only.** `t.0` returns the first slot at the slot's static type. `t.[i]` for runtime `i` is not well-typed — slot types differ. **Do not add a "runtime indexing for homogeneous tuples" exception** — that's the trap that re-creates homogeneous-vector confusion.
- Pattern matching: `(a, b, c) = my_tuple` continues to work. Multi-return shapes like `def f() -> (i64, Bool)` continue to work.
- ABI: tuples compile to record-equivalent layout. `(a, b, c)` and `{0: a, 1: b, 2: c}` are ABI-identical (both are a flat heterogeneous aggregate).

**Deliverables:**
- 7.1 `lib/tuple.zap` with `Tuple.size` and any other operations that make sense at compile-time (e.g., `Tuple.first`, `Tuple.last`, where these are compile-time-resolved per-arity).
- 7.2 `@structdoc` describes the heterogeneous + fixed-arity + compile-time-indexing constraints.
- 7.3 Existing tuple syntax (`{a, b, c}`) and pattern matching (`(a, b, c) = expr`) continue to work unchanged.
- 7.4 Tests cover: tuple construction, pattern destructuring, multi-return functions returning tuples, nested tuples (`{i64, {String, Bool}}`).

**Verification gates:**
- `zig build test` green.
- All existing tuple-using code in `lib/` continues to work.
- Tuple is now visible as a first-class type in error messages and type system output.

**Done criteria:**
- Tuple is a real type with a real surface. The friction in §5.5 of the friction brief is closed.
- Commit: "feat(types,lib): formalize Tuple as a first-class type (Stage 7)".

### Stage 8: Phase 2.7 — close fannkuch n=11 perf gate

**Goal:** extend `arc_liveness.ArcOwnership` to track last-use of non-ARC aggregates whose components are ARC-managed. This is the upstream prerequisite for ungating Phase 2.6.2 / 2.6.3 (currently behind `ZAP_ENABLE_PHASE_2_6_2` env var), which together close the fannkuch n=11 perf gate.

**Background.** From `docs/opportunistic-mutation-milestone.md` §"What's documented as a gap":

> `arc_liveness.ArcOwnership` doesn't track last-use of non-ARC aggregates (tuples) whose components are ARC-managed. Phase 2.5's `tuple_pending` machinery in `uniqueness` queries `isLastUseAt(parent_tuple, ...)` which always returns false for these aggregates, so the destructure-promotion idiom never fires on the canonical fannkuch shape.

> With (1) fixed, Phase 2.6.2 (`TentativeAnalyzer` tuple_pending support) and Phase 2.6.3 (`arc_drop_insertion` tuple-component releases) need to come online together. They're committed but gated off behind `ZAP_ENABLE_PHASE_2_6_2`.

After Stage 6, `Vector` is gone — so the canonical fannkuch shape is now `(List(i64), Bool)` or similar tuple-with-ARC-component-and-non-ARC-component. The same Phase 2.7 work is needed; the type names are different but the structure is identical.

**Files modified:**
- `src/arc_liveness.zig` (~4,972 lines) — extend `ArcOwnership` to track last-use of non-ARC aggregates. The aggregate's last use is the final program point where it (or any of its component projections) is referenced. Cite the existing `ArcOwnership` analysis and add aggregate-tracking as a parallel structure.
- `src/uniqueness.zig` — verify that `tuple_pending` queries to `isLastUseAt(parent_tuple, ...)` now return correct results for the canonical fannkuch shape. The previous machinery (commit `72cb556`) is in place; it just wasn't getting useful answers because the upstream tracking was missing.
- `src/arc_param_convention.zig` — remove the `ZAP_ENABLE_PHASE_2_6_2` env var gate at line 643:
  ```zig
  // Set ZAP_ENABLE_PHASE_2_6_2=1 to reactivate the new behaviour
  const phase_2_6_2_enabled = std.c.getenv("ZAP_ENABLE_PHASE_2_6_2") != null;
  ```
  Once Phase 2.7 is complete, the gate flips on permanently. Delete the gate and any conditional code paths.
- `src/arc_drop_insertion.zig` (~2,632 lines) — if Phase 2.6.3's tuple-component release insertion needs adjustment given the upstream changes, do it here.

**Stash recovery decision.** Before starting, run `git stash show -p stash@{0}` and inspect the WIP. The stash contains ~317 lines of new additions to `arc_liveness.zig` that were aimed at this exact problem. Decide:
- If the WIP is high quality and aligned with the new flat-buffer-only world, recover it and continue.
- If the WIP made design choices that don't fit anymore (cons-cell-shape assumptions, etc.), restart from scratch.
- Either way, commit the decision rationale into the next commit message.

**Deliverables:**
- 8.1 `arc_liveness.ArcOwnership` extended to track last-use of non-ARC aggregates with ARC-managed components.
- 8.2 The `ZAP_ENABLE_PHASE_2_6_2` gate at `src/arc_param_convention.zig:643` is removed; Phase 2.6.2 and Phase 2.6.3 are unconditionally enabled.
- 8.3 uniqueness firing on `List.set` in fannkuch's hot loops: `list_unchecked_total > 0` (renamed from `vector_unchecked_total` in Stage 3).
- 8.4 Verifier still rejects unsound experiments — uniqueness is the post-rewrite safety net.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- **fannkuch n=11 byte-exact + ≤ 30s wall.** This is the gate.
- fannkuch n=10 still byte-exact and within noise of 2.6s.
- spectral-norm still byte-exact.
- k-nucleotide still 100% uniqueness firing on `Map.put`.
- No regressions on other benchmarks.

**Done criteria:**
- fannkuch n=11 closes its 17% perf gap.
- The Phase 2.6.2/2.6.3 feature flag is gone from the codebase.
- Commits: one per Phase 2.7 sub-deliverable (extension + ungate + verification).

### Stage 9: SIMD codegen for `List(T : Numeric)` over uniquely-owned buffers

**Goal:** when the compiler can prove a `List(T)` is uniquely owned AND `T` is a primitive numeric type AND the operation is map / fold / zipWith / dot / scale, lower to Zig's `@Vector(N, T)` SIMD primitive. This is where "Vector" actually lives in Zap — as an internal codegen concept, never as a user-surface type.

**Background.** The Zig fork at `~/projects/zig/` already supports `@Vector(N, T)`. The C-ABI is already exposed:
- `~/projects/zig/src/zir_api.zig:3200` — `pub fn zap_vector_type(...)` "Emit `@Vector(len, elem_type)`".
- `~/projects/zig/src/zir_builder.zig:3320` — internal Zig builder support.

The work in this stage is recognizing the IR pattern (`List.map`, `List.reduce`, etc. over uniquely-owned numeric buffers) and emitting the right C-ABI calls.

**Files modified:**
- `src/zir_builder.zig` — add a SIMD lowering path. When the IR opcode is a List traversal AND the element type is primitive numeric (`i8/i16/i32/i64/f32/f64`) AND uniqueness proves the receiver uniquely owned AND the operation is closed over a primitive operation (add, mul, etc.), emit:
  ```
  %vec_ty = @Vector(N, T)        # via zap_vector_type C-ABI
  %loaded = load %vec_ty from buffer
  %op_result = vector_op(%loaded, ...)
  store %op_result to buffer
  ```
  with `N = optimal_simd_width / sizeof(T)` (the Zig fork picks N based on the target's native SIMD width — see how Zig itself chooses N for `@Vector` builtins).
- `src/ir.zig` — recognize the SIMD-eligible patterns. Add IR-level metadata (or a verifier pass) that flags traversal opcodes with eligibility hints.
- `src/runtime.zig` — internal helpers if the SIMD codegen needs runtime support (e.g., aligned-load helpers, SIMD-friendly buffer allocation if alignment becomes load-bearing).
- Possibly `~/projects/zig/src/zir_api.zig` — if any SIMD operation needs a new C-ABI entry (e.g., `zap_vector_add`, `zap_vector_fma`), add it to the fork.

**Eligibility conditions (compile-time checks):**
1. Receiver is `List(T)`.
2. `T` is one of: `i8`, `i16`, `i32`, `i64`, `f32`, `f64`. (Bool, Atom, String, struct types, ARC-managed types are NOT eligible.)
3. uniqueness verifier proves the receiver is uniquely owned at the call site (the existing `set_owned_unchecked` rewrite condition).
4. The operation is a known SIMD-friendly traversal: `map(fn(x) -> x + k)`, `map(fn(x) -> x * k)`, `reduce(0, fn(a, x) -> a + x)`, `zipWith(other, fn(a, b) -> a + b)`, `zipWith(other, fn(a, b) -> a * b)`, dot product, scaled add (FMA), etc. The closure body must be a single primitive operation; complex closures fall back to scalar codegen.

**Critical guardrails:**
- This is internal codegen, not surface API. The Zap user writes `List.map` and the compiler picks SIMD or scalar based on the conditions above.
- The unification of `Vector` into `List` (Stages 1–6) means there is no "Vector" surface anywhere. The SIMD lowering is entirely a compiler-internal concept.
- The user must not be able to detect the difference between scalar and SIMD codegen except as a wall-time delta.
- If the eligibility check fails (non-numeric T, non-unique receiver, complex closure), fall back to scalar codegen with no error.

**Deliverables:**
- 9.1 ZIR builder emits `@Vector(N, T)` operations for eligible patterns. `~/projects/zig/`'s C-ABI is invoked correctly.
- 9.2 Eligibility verifier: a compile-time check that filters call sites to those that meet all four conditions. Sites that fail any condition fall through to scalar codegen.
- 9.3 Both fannkuch-redux and spectral-norm benchmarks show measurable speedups vs Stage 8 baseline.
- 9.4 Byte-exact output preserved on all benchmarks.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- All CLBG benchmarks byte-exact.
- fannkuch-redux n=11 wall-time improves vs Stage 8 baseline (target: ≤ 15s, but no specific gate — the win is whatever the SIMD width on the test machine permits).
- spectral-norm wall-time improves vs Stage 8 baseline (target: ≤ 1s, but again no specific gate).
- k-nucleotide perf unchanged (it doesn't traverse numeric `List`s in its hot path; SIMD shouldn't fire there).

**Done criteria:**
- SIMD codegen fires on numeric `List(T)` traversals over uniquely-owned buffers.
- Both perf-gap benchmarks (fannkuch, spectral-norm) hit competitive wall-times.
- The word "Vector" appears in the codebase only inside `src/zir_builder.zig` (as a reference to the LLVM SIMD primitive) and in `~/projects/zig/` (as the Zig builder).
- Commit chain: one commit per SIMD-friendly operation pattern enabled.

### Stage 10: Legacy uniqueness-analysis terminology cleanup (done)

**Goal:** finish the terminology cleanup for the uniqueness analysis. Pure cleanup; no behavior change.

**Background.** From the legacy uniqueness-analysis rename memory and `docs/opportunistic-mutation-milestone.md` §"Future work" #6.

**Files renamed:**
- `src/uniqueness.zig` is the per-instruction uniqueness analysis module.
- `src/uniqueness_signature.zig` is the per-function uniqueness signature module.
- `src/uniqueness_fixpoint.zig` is the SCC fixpoint module.
- `src/uniqueness_interprocedural.zig` is the cross-function propagation module.

**Symbols renamed:**
- All internal types, functions, and variables use consistent uniqueness naming.
- Public-facing IR opcode names (e.g., `set_owned_unchecked`) stay — they describe semantics, not the analysis.
- `vector_unchecked_total` was renamed `list_unchecked_total` in Stage 3; no further change here.
- Verifier check name is `runUniquenessCheck`.

**Documentation:**
- Historical references keep the old name; don't rewrite history. This includes `docs/opportunistic-mutation-milestone.md`, `docs/list-vector-tuple-friction-research-brief.md`, `docs/dense-map-implementation-plan.md`, `docs/map-workload-findings.md`, `docs/map-workload-instrumentation-plan.md`, and `docs/zap-map-representation-research-brief.md`.
- Live planning text uses the new terminology after the rename. Today this means this list-unification plan and any new public docs generated after Stage 10.
- Existing commit messages keep their historical references; don't rewrite git history.

**Current scan after implementation:**
- `rg -n 'legacy-name-pattern' src` returns zero matches.
- The renamed modules are `src/uniqueness.zig`, `src/uniqueness_signature.zig`, `src/uniqueness_fixpoint.zig`, and `src/uniqueness_interprocedural.zig`.
- Zap library, Zap tests, examples, scripts, `README.md`, `CLAUDE.md`, and `AGENTS.md` have no legacy uniqueness-analysis name hits.
- Historical docs listed above are excluded from the cleanup gate.

**Naming options (author's choice; document in commit message):**
- `AliasSafety` — emphasizes the safety property.
- `UniquenessInvariant` — emphasizes the invariant.
- `Linearity` — emphasizes the linear-typing connection.

**Deliverables:**
- 10.1 All legacy uniqueness-analysis module filenames renamed.
- 10.2 All internal symbols renamed.
- 10.3 Source has no legacy uniqueness-analysis name hits.
- 10.4 Documentation updated.

**Verification gates:**
- `zig build test` green.
- `bench/map-workloads/run-differential-tests.sh` 3/3 PASS.
- All CLBG benchmarks byte-exact and within noise of pre-rename wall-times.

**Done criteria:**
- Legacy uniqueness-analysis terminology is gone from live source and non-historical planning prose. Historical research/plan docs and preserved commit-message references may keep it intentionally.
- Commit: "refactor: rename legacy uniqueness terminology".

This stage is pure cleanup with no behavior change.

---

## 5. Cross-Stage Invariants

These hold at every commit boundary, not just at the end of each stage:

- **`zig build test` green.** Default and `-Dinstrument-map=true` builds.
- **`bench/map-workloads/run-differential-tests.sh` 3/3 PASS.**
- **All CLBG benchmarks byte-exact.** k-nucleotide, fannkuch n=10, fannkuch n=11, spectral-norm, nbody, mandelbrot, binarytrees.
- **No regressions on benchmarks already passing.** Wall-time within noise of the pre-stage baseline.
- **No `zig build zir-test` invocations.** Ever. Period. The user runs zir-test themselves.
- **No verifier rejections of correct programs.** uniqueness (or its renamed successor) remains the post-rewrite safety net. Wrong inference produces compilation failure, never miscompilation.
- **No partially-finished states across commits.** Every commit must build and pass tests. If a stage requires cross-file changes that don't compile partway, the changes go in a single commit.
- **Commit hygiene.** One commit per logical unit of work. Commit messages explain why, not just what. Use the project's commit message style (lower-case `feat(scope):` / `fix(scope):` / `refactor(scope):` / `docs:` prefixes).

---

## 6. File Pointers (for Future Agents)

Where to read code when context is needed:

### Runtime
- `src/runtime.zig` (~10,580 lines) — collection types (`Map(K,V)` ~line 4772, `List(T)` ~line 5726 cons-cell currently, `Vector(T)` ~line 1678 flat-buffer currently), ARC headers, `*_owned_unchecked` variants, instrumentation counters (`vector_unchecked_total` line 381 — to be renamed `list_unchecked_total` in Stage 3).

### IR + types + scope
- `src/ir.zig` (~9,735 lines) — `isArcManagedTypeId` line 1166, IR opcodes including `tuple_init` line 308 and `index_get` line 317, list-related opcodes lines 610/626/636.
- `src/types.zig` — `tuple: TupleType` line 79, `vector_type: VectorElementKind` line 76, `VectorElementKind = enum { i64, f64 }` line 117.
- `src/scope.zig` — `NativeTypeKind` enum line 479 with variants `vector_i64` / `vector_f64`.

### Ownership pipeline
- `src/arc_ownership.zig` (~4,986 lines) — call-site rewriter that swaps `Vector.set` → `Vector.set_owned_unchecked`.
- `src/arc_param_convention.zig` (~4,962 lines) — chain-consistency audit; `computeLiftSet` line 293; Phase 2.6.2 gate line 643.
- `src/arc_liveness.zig` (~4,972 lines) — `ArcOwnership` analysis; the target of Stage 8's extension.
- `src/arc_drop_insertion.zig` (~2,632 lines) — drop-insertion pass.
- `src/arc_verifier.zig` (~2,580 lines) — V1–uniqueness invariant enforcement; runs post-rewrite as the safety net.
- `src/arc_optimizer.zig` (~493 lines) — additional ownership optimizations.

### uniqueness inference
- `src/uniqueness.zig` (~2,272 lines) — per-instruction forward dataflow with `tuple_pending` tracking.
- `src/uniqueness_signature.zig` (~352 lines) — 4-element lattice `{CU, PU, AL, ⊤}`.
- `src/uniqueness_fixpoint.zig` (~2,496 lines) — Tarjan SCC + worklist join.
- `src/uniqueness_interprocedural.zig` (~1,554 lines) — cross-function uniqueness propagation.

### Codegen
- `src/zir_builder.zig` — emits ZIR via C-ABI calls into the Zig fork. The only codegen path. SIMD codegen in Stage 9 lives here.
- `src/zir_backend.zig` — supporting ZIR-side glue.
- `~/projects/zig/src/zir_api.zig` — C-ABI exposed by the Zig fork. `zap_vector_type` at line 3200 (the SIMD primitive entry point for Stage 9).

### Surface library
- `lib/list.zap` — current cons-cell list surface; replaced in Stage 3.
- `lib/map.zap` — Map surface (mirror for Stage 3's List surface).
- `lib/vector_i64.zap`, `lib/vector_f64.zap` — concrete Vector aliases; deleted in Stage 2.
- `lib/list/concatenable.zap`, `lib/list/enumerable.zap`, `lib/list/membership.zap` — protocol implementations to revisit in Stage 5.
- `lib/kernel.zap` — macros and core language constructs.

### Benchmarks
- `~/projects/lang-benches/k-nucleotide/` — Map-heavy. Untouched by this plan.
- `~/projects/lang-benches/fannkuch-redux/` — uses `VectorI64` today; migrated in Stage 5.
- `~/projects/lang-benches/spectral-norm/` — uses `VectorF64` today; migrated in Stage 5.
- `~/projects/lang-benches/nbody/`, `mandelbrot/`, `binarytrees/` — no collections used; untouched.

### Test infrastructure
- `bench/map-workloads/` — Phase 0 instrumentation (still in repo, behind `-Dinstrument-map=true`). `bench/map-workloads/run-differential-tests.sh` is the differential test runner.
- `test/zap/` — Zap-level tests.
- Inline test blocks in `src/*.zig` — Zig-level unit tests.

### Existing research and milestone docs
- `docs/dense-map-implementation-plan.md` — voice/format mirror for this plan.
- `docs/list-vector-tuple-friction-research-brief.md` — full design space; Option B is what this plan implements.
- `docs/opportunistic-mutation-milestone.md` — close-out summary of work-to-date; Phase 2.7 is the open gap.
- `docs/roc-style-opportunistic-mutation-research-brief.md` — broader rationale for rc-1 mutation model.
- `docs/zap-map-representation-research-brief.md` — Map-specific design discussion.
- `docs/map-workload-findings.md`, `docs/map-workload-instrumentation-plan.md` — Phase 0 substrate.

### Forked Zig compiler
- `~/projects/zig/` — the forked Zig compiler. `libzap_compiler.a` exposes the C-ABI. Modifications allowed when needed (e.g., new SIMD operation entry points in Stage 9).
- `~/projects/zig/README.md` — fork-specific build instructions.

---

## 7. Sequencing Summary

```
Stage 1 (FlatList rename)
   │
Stage 2 (IR/scope/types rename — Vector → List, List → ConsList)
   │
Stage 3 (Generic List(T) Zap surface)
   │
Stage 4 (List pattern matching over flat-buffer)
   │
Stage 5 (Migrate stdlib + benchmarks)
   │
Stage 6 (Delete ConsList + Vector remnants)         ← Option B (List unification) DONE
   │
   ├── Stage 7 (Tuple formalization) — INDEPENDENT, can start anytime,
   │   touches mostly different files (types.zig, lib/tuple.zap)
   │
Stage 8 (Phase 2.7 — close fannkuch n=11 gate)      ← Depends on Stage 6 (uses unified List(T))
   │
Stage 9 (SIMD codegen for List(T : Numeric))         ← Depends on Stage 8 (uniqueness firing)
   │
Stage 10 (uniqueness terminology cleanup)           ← DONE
```

| Stage | Goal | Depends on | Files touched (rough) | Estimated effort |
| ----: | --- | --- | --- | --- |
| 1 | FlatList rename in runtime | — | `src/runtime.zig` | 0.5 weeks |
| 2 | Vector→List rename in IR/scope/types | 1 | `src/ir.zig`, `src/types.zig`, `src/scope.zig`, `src/zir_builder.zig`, `src/zir_backend.zig`, `lib/vector_*.zap`, `lib/list.zap` | 1.5 weeks |
| 3 | Generic List(T) Zap surface | 2 | `lib/list.zap`, `src/zir_builder.zig` | 1 week |
| 4 | `[h \| t]` pattern → flat-buffer | 3 | `src/parser.zig`, `src/hir.zig`, `src/ir.zig`, `src/runtime.zig`, `lib/list.zap` | 1.5 weeks |
| 5 | Migrate stdlib + benchmarks | 4 | `lib/*.zap`, `~/projects/lang-benches/{fannkuch,spectral-norm}/` | 1 week |
| 6 | Delete ConsList + Vector remnants | 5 | `src/runtime.zig`, `src/ir.zig`, cleanup | 0.5 weeks |
| 7 | Tuple formalization | independent | `src/types.zig`, `lib/tuple.zap` | 1 week |
| 8 | Phase 2.7 (close fannkuch n=11) | 6 | `src/arc_liveness.zig`, `src/arc_param_convention.zig`, `src/arc_drop_insertion.zig`, `src/uniqueness.zig` | 2–3 weeks (this is the hard one) |
| 9 | SIMD codegen | 8 | `src/zir_builder.zig`, possibly `~/projects/zig/src/zir_api.zig` | 2 weeks |
| 10 | uniqueness terminology cleanup | independent | `src/uniqueness*.zig` and all callers | done |
| **Total** | | | | ~12 weeks calendar; less with parallelism |

**Parallelism opportunities.** Stage 7 can run alongside Stages 1–6 as long as the agent coordinates file ownership (Stage 7 touches `lib/tuple.zap` and `src/types.zig`'s tuple-related code; Stages 1–6 touch List/Vector code). Stage 10 can run after Stage 6 in parallel with Stages 8–9. Stages 1–6 are strictly sequential. Stages 8 and 9 are strictly sequential.

---

## 8. Done Criteria for the Whole Plan

1. **One sequence type.** `Map(K, V)` for associative; `List(T)` (flat-buffer) for sequences. No cons-cell list. No `Vector(T)` surface. No `MArray*` (already gone). No `VectorI64` / `VectorF64` aliases.
2. **`Tuple` is first-class.** Heterogeneous fixed-arity, compile-time indexing only, surface in `lib/tuple.zap` with `@fndoc` on all public functions.
3. **`zig build test` green** with default and `-Dinstrument-map=true` flags.
4. **CLBG benchmarks byte-exact** at every gate:
   - k-nucleotide: 100% uniqueness firing on `Map.put`, byte-exact, ≤ current wall-time.
   - fannkuch-redux n=10: byte-exact, ≤ 3s.
   - fannkuch-redux n=11: byte-exact, ≤ 30s (closes the 17% gap).
   - spectral-norm: byte-exact, ≤ 1s with SIMD (Stage 9).
   - nbody, mandelbrot, binarytrees: byte-exact, no regression.
5. **No `Vector\|vector_` references** in `src/`, `lib/`, `test/`, `examples/` outside historical doc comments and the `@Vector` LLVM SIMD primitive references inside `src/zir_builder.zig` (Stage 9 codegen) and `~/projects/zig/`.
6. **No `ConsList\|cons_list\|cons_cell` references** in `src/`, `lib/`, `test/`, `examples/`.
7. **The `ZAP_ENABLE_PHASE_2_6_2` env-var gate is gone** from `src/arc_param_convention.zig`.
8. **SIMD codegen fires** on numeric `List(T)` traversals over uniquely-owned buffers, measurably improving fannkuch and spectral-norm wall-times.
9. **(Optional, deferrable indefinitely)** "uniqueness" terminology renamed (Stage 10).
10. **Phase 0 instrumentation infrastructure still works** on the unified `List(T)`.

**zir-test is NOT a done criterion.** The user runs zir-test themselves on their own schedule. Subagents must never invoke it.

---

## 9. Iteration Discipline — Verification Quick Reference

Allowed verification commands (fast):
- `zig build` — compiler builds (~30 seconds).
- `zig build test` — all tests pass (~10 seconds).
- `zig build test -Dinstrument-map=true` — instrumentation build green.
- `bench/map-workloads/run-differential-tests.sh` — differential test runner (~30 seconds).
- Direct CLBG benchmark invocation:
  - `~/projects/lang-benches/k-nucleotide/zap-out/bin/k_nucleotide`
  - `~/projects/lang-benches/fannkuch-redux/zap-out/bin/fannkuch_redux 10`
  - `~/projects/lang-benches/fannkuch-redux/zap-out/bin/fannkuch_redux 11`
  - `~/projects/lang-benches/spectral-norm/zap-out/bin/spectral_norm 2500`
  - etc.

**Forbidden verification commands:**
- `zig build zir-test` — takes 6+ minutes; agents have been killed for running it. **Never invoke.**

---

## 10. Risk Inventory

- **Risk:** Stage 4's flat-buffer `[h | t]` lowering produces a slow recursive function pattern (each recursive `tail` allocates) under non-uniqueness. **Mitigation:** under uniqueness inference, `tail` becomes `tail_owned_unchecked` and reuses the parent buffer. The cost falls on workloads that hold many versions of nearly-identical lists; those workloads were always going to pay this cost under Option B (this is the documented trade-off in §3).
- **Risk:** Stage 8's `arc_liveness.ArcOwnership` extension introduces verifier rejections of correct programs. **Mitigation:** TDD discipline. Add failing tests first; the uniqueness verifier is the post-rewrite safety net and will catch incorrect inferences as compile errors, never as miscompilation.
- **Risk:** Stage 9's SIMD codegen produces incorrect output on edge cases (length-not-divisible-by-N, alignment, etc.). **Mitigation:** byte-exact CLBG benchmark output is the gating signal; eligibility check is conservative. The fallback to scalar codegen is always sound.
- **Risk:** Stage 5 stdlib migration breaks a `lib/*.zap` file in a way that causes user-code tests to fail. **Mitigation:** TDD per file; `zig build test` green at every commit boundary.
- **Risk:** Stage 7 tuple formalization conflicts with assumptions in the uniqueness pipeline (which already has `tuple_pending` tracking). **Mitigation:** the formalization should not change tuple semantics — it adds a surface library and a real type registration. The IR side already has `tuple_init` and `index_get`; those don't change.
- **Risk:** stash@{0} contains unsalvageable WIP for Stage 8 and the agent burns time trying to recover it. **Mitigation:** explicit decision point at the start of Stage 8 — inspect with `git stash show -p stash@{0}`, make a clean recover-or-restart call, document the decision in the next commit message.
- **Risk:** SIMD eligibility check is too conservative or too aggressive. **Mitigation:** gate Stage 9 sub-deliverables one operation pattern at a time. Each operation pattern (`map`, `reduce`, `zipWith`, etc.) gets its own commit with byte-exact verification before the next pattern is enabled.

---

## 11. Final Notes for the Implementing Agent

This plan describes WHAT to do; you implement HOW. When in doubt, prefer:

- **Specific over generic.** Stage 5 says "audit `lib/*.zap` for List uses" — actually walk the directory, file by file, audit by audit. Don't sweep.
- **TDD.** Failing tests first, then implementation. The project rule (`CLAUDE.md`) is unambiguous on this.
- **Soundness over speed.** If the verifier rejects, find the right inference; do not weaken the verifier.
- **No workarounds.** If a fix requires deep architectural changes across multiple files, that is the fix. If it requires changes to the Zig fork, make them.
- **Frequent commits.** One commit per logical unit. Commit messages explain why, not just what.
- **No `zig build zir-test`.** Ever.

If a stage proves harder than the plan estimates, surface the difficulty as documented progress + clear handoff for the next agent. Do not paper over a stuck stage with hacks; document and pause.

If a stage uncovers a deeper architectural issue not anticipated by this plan, document it in a follow-up brief in `docs/` and pause. The user reads docs/ between sessions; an unanticipated finding gets the user's attention.

The plan is comprehensive but not omniscient. Treat it as a forward-looking sketch, not a contract. The specific decisions (Option B chosen, Tuple compile-time-indexed-only, SIMD as internal codegen) are locked in. The order of stages, the file paths, the eligibility conditions, the verification gates — all of these are right at the time of writing but may need adjustment as implementation reality lands. When that happens, document the adjustment and continue.
