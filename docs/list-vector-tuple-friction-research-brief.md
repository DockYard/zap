# Zap `List` / `Vector` / `Tuple` Friction — Research Brief

**Audience.** A research agent with **zero prior context on Zap**, the Zap fork of the Zig compiler, the lang-benches harness, or the work that has already been done on opportunistic mutation. This document is fully self-contained — after reading it the agent should be able to (a) understand the language and the three collection types in scope, (b) reason about the design space, (c) evaluate the four concrete options laid out in §6, and (d) return a recommendation without needing clarifying questions about what Zap is.

**The question to research.** Should Zap have a separate `Vector(T)` type at all, or can `List(T)` plus a first-class `Tuple` together cover every real use case? The current state has `Map(K, V)`, `List(T)`, `Vector(T)`, and an informal tuple syntax — that's three first-class collections plus one informal one, and the surface for `Vector(T)` is wrong (concrete `VectorI64`/`VectorF64` aliases instead of generic `Vector(T)`). Decide whether the right end-state is three types, two, or two-with-a-different-shape.

This is a **language design** question, not an algorithm question. The brief lays out the design space neutrally; the agent is expected to pick a side, with reasoning.

---

## 1. What Zap Is

Zap is an early-stage statically-typed functional programming language. The surface is heavily inspired by Elixir (modules, pattern matching, multi-clause functions, pipe operator `|>`, Erlang-style atoms, sigils, persistent collections). The runtime is native: there is no VM, no interpreter, no tracing GC.

- **Statically typed** with a Hindley–Milner-derived type system extended for protocols/typeclasses.
- **Compiled to native code** through LLVM via Zig's intermediate representation (ZIR).
- **No top-level functions.** Every `def`/`fn` lives inside a `defmodule`/`pub struct`.
- **Macro-driven.** Macros are written in Zap itself and run at compile time.
- **Functional-first** with pure surface semantics — every operation returns a new value; mutation is purely an under-the-hood optimization invisible to users.
- **Single-threaded today.** Multi-threading is not in scope but should not be foreclosed.

A tiny example to anchor the vocabulary:

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

`Map.put`, `Map.get`, the pipe operator, and the lambda closure are all standard. The `Map.put` returns a new map semantically; under the hood the rc-1 fast path mutates in place when uniqueness is provable. The user does not see this distinction.

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
  ▼ src/ir.zig    ← ARC ownership inference + V8 uniqueness inference happen here
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

**Key invariant:** Zap *only* lowers through ZIR. There is no Zig-source-text codegen path. Anything the language does must be expressible as a ZIR-builder C-ABI call into the fork. If a feature requires a new lowering, the correct fix is to add the C-ABI to the fork. The fork at `~/projects/zig/` exposes `libzap_compiler.a`. **The user has full latitude to modify the fork** — no proposal is rejected because it would require fork changes.

### Memory model — ARC + per-type pools

- Every heap-allocated value carries an inline `ArcHeader { strong_count, weak_count, type_id }` at the head of the cell. `retain` increments; `release` decrements and runs the type's drop function on the zero-transition.
- There is no GC. There is no cycle collector. All lifetimes are managed by ARC.
- Each ARC-managed type allocates out of a thread-local `std.heap.MemoryPool(T)`, giving O(1) alloc/free with no `malloc` overhead in hot loops.
- Pure functional surface semantics — `Map.put(m, k, v)` always returns a new map *semantically*. The runtime may reuse storage when uniqueness is provable, but the user-visible shape is purely value-semantic.

The classification of "ARC-managed" lives in `src/ir.zig::isArcManagedTypeId` (line ~1166):

```zig
return switch (type_store.getType(type_id)) {
    .opaque_type, .map, .list, .vector_type => true,
    else => false,
};
```

Plain integers/floats/bools/atoms are *trivial* — no retain/release. `Map`, `List`, `Vector`, and opaque types (`String`, `Atom`, etc.) are ARC-managed.

---

## 2. The Collection Types As They Exist Today

Zap currently exposes three first-class generic collections plus an informal tuple shape. Each is described below — internal representation, asymptotics, layout, and where it lives in source.

### 2.1 `Map(K, V)` — dense Robin-Hood hash table

**Runtime:** `src/runtime.zig` ~line 4772 (`pub fn Map(comptime K: type, comptime V: type) type`).

**Layout (single contiguous allocation):**

```
[ Self    (header, len, capacity, entry_cap, hash_seed) ]
[ buckets[capacity]  of DenseMapBucket                   ]
[ entries[entry_cap] of MapEntry { hash, key, value }    ]
```

Robin-Hood probing with a `(dist << 8) | fingerprint` packed metric drives insertion and lookup. Delete is swap-remove on entries plus backshift on buckets. wyhash with a random per-process seed gives DoS resistance. The previous HAMT (Hash Array Mapped Trie) was deleted entirely — `Map` is now `ankerl::unordered_dense`-style throughout.

**Asymptotics:**
- `get`, `has_key?`: O(1) amortized.
- `put`, `delete`: O(1) amortized.
- `size`, `empty?`: O(1).
- `keys`, `values`: O(n).
- `merge`: O(|map_b|).

**Memory:** single buffer per map. ARC header at offset 0; one header per map.

**Generic:** yes — `pub fn Map(comptime K: type, comptime V: type) type`. The user-visible surface is `Map.put(m, k, v)`, `Map.get(m, k, default)`, etc. (`lib/map.zap`).

**Iteration order:** insertion order modulo the swap-remove on delete (matches Roc, JavaScript `Map`, Python 3.7+ dict).

**Status:** first-class. Heterogeneous in the type-class sense (any `K` or `V`); homogeneous within a single instance.

### 2.2 `List(T)` — persistent cons-cell linked list

**Runtime:** `src/runtime.zig` ~line 5726 (`pub fn List(comptime T: type) type`).

**Layout (per cell, allocated through a thread-local `MemoryPool(Cell)`):**

```
struct Cell {
    header: ArcHeader,  // refcount, type id
    head:   T,
    tail:   ?*const Cell,
}
```

Each cell has its own ARC refcount. Tails are shared between lists — `cons(x, list)` produces a new cell pointing at the same tail.

**Asymptotics:**
- `prepend` (cons): O(1).
- `head`, `tail`: O(1).
- `at(i)` (random access): **O(n)** — walk `i` cells.
- `length`: O(n) — walks the spine.
- `append(list, value)`: O(n) — copies the spine.
- `reverse`: O(n).
- `concat`: O(|first|).

**Memory:** one ARC header per cell, one pool allocation per cell. Persistent — sharing tails is the whole point.

**Generic:** yes — `pub fn List(comptime T: type) type`. The user-visible surface is `List.prepend(l, v)`, `List.head(l)`, `List.at(l, i)`, etc. (`lib/list.zap`).

**Status:** first-class. Homogeneous — every element is `T`.

### 2.3 `Vector(T)` — flat-buffer mutable contiguous array

**Runtime:** `src/runtime.zig` ~line 1678 (`pub fn Vector(comptime T: type) type`).

**Layout (single contiguous allocation):**

```
[ Self  { header: ArcHeader, len: u32, cap: u32 } ]
[ data: [cap]T                                     ]
```

ARC header at offset 0. The cell pointer IS the buffer pointer — same shape as `Map(K, V)` and `List(T)` cells. Allocated through `c_allocator` (libc malloc, which has size classes that pack small allocations efficiently — same choice the dense Map made).

**Asymptotics:**
- `get(i)`: O(1).
- `set(v, i, x)`: O(1) on the rc-1 fast path; O(n) on the rc-clone path.
- `push`: amortized O(1) on the rc-1 fast path; O(n) on the rc-clone path. Capacity doubles on growth.
- `pop`: O(1) on the rc-1 fast path; O(n) on the rc-clone path.
- `length`, `capacity`: O(1).
- `append(a, b)`: amortized O(|b|) on the rc-1 fast path.

**Generic at the runtime level:** yes — `pub fn Vector(comptime T: type) type`.

**Generic at the language surface:** **no.** Currently exposed only as concrete aliases:

```zig
// src/runtime.zig:1671
pub const VectorI64 = Vector(i64);
pub const VectorF64 = Vector(f64);
```

Surfaced as `lib/vector_i64.zap` (`pub struct VectorI64`) and `lib/vector_f64.zap` (`pub struct VectorF64`). The compiler has `vector_i64` and `vector_f64` as separate `NativeTypeKind` enum variants in `src/scope.zig:479`. This is a design error — copied from the now-deleted `MArrayI64`/`MArrayF64` imperative escape hatches. The runtime is already generic; only the surface is specialized.

**Status:** first-class at the runtime level, surface-broken. Homogeneous — every element is `T`.

### 2.4 Tuples — informal heterogeneous fixed-arity values

**Type system:** `src/types.zig:79` (`tuple: TupleType` with `elements: []const TypeId`).

**IR opcodes:** `src/ir.zig:308` (`tuple_init: AggregateInit`) and `src/ir.zig:317` (`index_get: IndexGet`).

**Surface:** `{a, b, c}` syntax. Used heavily for `{:error, "reason"}` patterns, multi-return shapes like `{VectorI64, Bool}`, and pattern matches. There is no `lib/tuple.zap` standard library struct.

**Asymptotics:**
- Construction: O(n) where n is the arity (compile-time fixed).
- Indexed access: O(1) — but the index is **compile-time only**. `t.0` returns the first slot at the slot's static type; `t.[i]` for runtime `i` is not well-typed because slots have different types.

**Layout:** depends on lowering. The IR's `tuple_init` builds a heterogeneous aggregate; in some lowering paths it is non-ARC (the wrapper aggregate is trivial even when its components are ARC-managed), which is a known source of friction (see §3 below).

**Generic:** structurally so. Each `(T1, T2, ..., Tn)` is a distinct anonymous type. Heterogeneous. Length is fixed at the type level (`{i64, Bool}` is a different type from `{i64, Bool, String}`).

**Status:** **not a first-class collection type.** Tuples are anonymous structural shapes. There is no `Tuple.size`, no `Tuple.first`, no tuple-iterating protocol. They are used as a low-overhead anonymous record / multi-return shape, not as a sequence.

---

## 3. The Opportunistic-Mutation Infrastructure

The collection types above didn't always behave the way they do. Over the past several months, an extensive ownership-IR + verifier system was built so the runtime can mutate in place when refcount is unique while preserving pure value-semantic surface. Reading this section is necessary background for reasoning about what changing the collection set would cost.

The full retrospective is in `docs/opportunistic-mutation-milestone.md` and the design rationale is in `docs/roc-style-opportunistic-mutation-research-brief.md`.

### V1–V7 ownership invariants

`src/arc_ownership.zig`, `src/arc_param_convention.zig`, `src/arc_liveness.zig`, `src/arc_drop_insertion.zig`, `src/arc_verifier.zig`, `src/arc_optimizer.zig` together implement:

- **Ownership classes** per IR value: `owned` (caller transfers a +1 strong ref), `borrowed` (caller retains the +1), `trivial` (non-ARC).
- **Parameter conventions** per function param: `owned` / `borrowed` / `trivial`.
- **V1–V7 invariants** post-ownership-rewrite, enforced by `arc_verifier.zig`. Spirit: balanced retains and releases, no double-free, parameter conventions obeyed at every call site, return-value conventions match, ownership transfers across `if`/`switch` arms balance, drops at scope exit cover exactly the live-but-not-consumed set.

### V8 — alias safety on owned update

`src/arc_verifier.zig` adds a V8 invariant: a mutator may return its receiver's pointer (rc-1 in-place mutation) **only if** the receiver is provably uniquely owned at the call site. The codegen rewrites `Vector.set` → `Vector.set_owned_unchecked` (and equivalents for Map) at provably-safe sites, eliding the runtime rc-check entirely.

Static analysis lives in:
- `src/v8_uniqueness.zig` — per-instruction forward dataflow producing `definitely_unique` for every local.
- `src/v8_signature.zig` — per-function uniqueness signatures using a 4-element lattice `{CU, PU, AL, ⊤}`.
- `src/v8_fixpoint.zig` — joins per-function signatures to a least fixpoint over a Tarjan SCC of the call graph.
- `src/v8_interprocedural.zig` — propagates uniqueness across function boundaries.

If inference is wrong, the verifier rejects → compilation failure, never miscompilation. The architectural property is: **a wrong inference produces a compilation failure, never a runtime crash**.

### Why this matters for the current question

The infrastructure was built primarily because `Vector(T)` is the only collection where in-place indexed mutation is the perf-critical path. `Map(K, V)` benefits too (k-nucleotide hits 100% V8 firing on `Map.put`), but the engineering surface — chain-consistency audit, tuple_pending tracking, cross-module signature propagation, ~16 sub-phases — was driven by trying to make `Vector.set` in tight loops match imperative-array perf.

If `Vector(T)` goes away, a meaningful slice of this infrastructure is still useful (V8 fires on Map all the time), but the most ornery cases — non-ARC aggregates with ARC components, the still-deferred Phase 2.7+ work — exist mostly to serve `Vector(T)` callers. If `Vector` is replaced, the agent should consider how much of the deferred work is still load-bearing.

---

## 4. What Benchmarks Use Each Type

Concrete grounding is essential — the design space here is large only because perf claims have to be checked against the actual workload set. Zap is early-stage and has no production users. The benchmark suite is the de facto representative workload.

| Benchmark        | Primary collection      | Current Zap result | Best baseline | Notes |
| ---------------- | ----------------------- | ------------------ | ------------- | ----- |
| **k-nucleotide** | `Map(K, V)` (heavy)     | 1.39s, byte-exact  | C ~60ms       | 100% V8 firing on `Map.put` (8.75M unchecked sites out of 8.75M total). |
| **fannkuch-redux** | `VectorI64` (perm buf) | n=11: 37.3s wall, **15.8 GB peak RSS** | C 1.55s, 1.3 MB | V8 doesn't fire (`vector_unchecked_total = 0`). Catastrophic. |
| **spectral-norm** | `VectorF64` (u/v vecs)  | n=2500: 1.86s, 2.2 GB peak RSS | Rust 156ms, 1.6 MB | V8 doesn't fire on the hot loops. |
| **nbody**        | struct fields (no Vector) | 103ms             | (fastest of 7 langs tested) | No collection used. |
| **mandelbrot**   | none                    | competitive with C/Rust | — | No collection used. |
| **binarytrees**  | recursive Tree struct (no Vector) | 5.49s | beats C/Rust/Go | No collection used. |

Two findings drop out of this table:

**(a)** Vector is exclusively used by 2 benchmarks (fannkuch, spectral-norm), and **both are the worst-case Zap performers** in the entire suite. Vector's theoretical advantage — cache-friendly contiguous storage, O(1) indexed access — hasn't translated to delivered perf. The architectural diagnosis (documented in `docs/opportunistic-mutation-milestone.md`) is that closing fannkuch n=11 to a 30s gate requires extending `arc_liveness.ArcOwnership` to track non-ARC aggregates with ARC components, then ungating Phase 2.6.2/2.6.3 work currently behind a feature flag. Future work, not done.

**(b)** Every benchmark that does NOT use `Vector` is competitive with C/Rust. Map, List, struct fields, and recursive trees all deliver. The friction is concentrated entirely on the one collection that exists to serve numerical/indexed workloads.

This concentration is what makes the design question worth asking now. If Vector is hard to make fast and is only used by benchmarks Zap may not care about, the question of whether to keep it at all is genuine.

---

## 5. The Friction

This is the central section. It captures the six concrete frictions between the three current collection types, in the order that makes the design space easiest to navigate.

### 5.1 Friction 1 — Vector exists for a use case Zap may not actually care about

`Vector(T)` exists to provide O(1) random access via integer indexing. That is the only thing it provides over `List(T)`. The use case is numerical / indexed workloads — linear algebra, scientific computing, fannkuch's permutation buffer, spectral-norm's vector dot products.

But:
- The only current consumers are 2 CLBG benchmarks (fannkuch, spectral-norm).
- No production Zap code uses Vector. (Zap has zero production users; the language is early-stage.)
- The benchmarks were ported from imperative reference implementations. Functional rewrites might not need indexed mutation at all.
- If Zap doesn't aim to compete on numerical kernel benchmarks, Vector earns nothing.

The agent should weigh whether numerical/indexed workloads are part of Zap's stated identity. The user has not committed publicly to numerical performance as a language goal. Elixir does not compete on these benchmarks and is not embarrassed by it. Zap's surface is Elixir-flavored, and one defensible position is "Zap doesn't do numerical kernels — write those in Zig if you need them."

### 5.2 Friction 2 — Vector's perf doesn't deliver on its promise

The architectural complexity built to make Vector match imperative-array perf has been substantial:
- V8 verifier (`src/arc_verifier.zig`)
- Interprocedural uniqueness fixpoint (`src/v8_fixpoint.zig`, `src/v8_interprocedural.zig`)
- Chain-consistency audit (`src/arc_param_convention.zig`)
- `tuple_pending` tracking in V8 dataflow (`src/v8_uniqueness.zig`)
- Cross-module signature propagation
- ~16 sub-phases of incremental work

After all that:
- **fannkuch n=11**: 37s vs C's 1.55s (24× slower), 15.8 GB RSS vs C's 1.3 MB.
- **spectral-norm**: 1.86s vs Rust's 156ms (12× slower), 2.2 GB RSS vs Rust's 1.6 MB.
- `vector_unchecked_total = 0` on fannkuch — the V8 fast path **never fires** in fannkuch's hot loops.

The documented gap: closing fannkuch n=11 to a 30s gate requires extending `arc_liveness.ArcOwnership` to track non-ARC aggregates whose components are ARC-managed (so the destructure-promotion idiom can fire on the canonical fannkuch shape), then ungating Phase 2.6.2/2.6.3 work that's currently behind a feature flag. This is real, tractable, and explicitly deferred.

The architectural shape: each phase identifies the next layer; the cumulative engineering surface is large; on n=11 specifically the perf number has been stuck at ~36s through 6+ sub-phases. The milestone shipped with the gap documented because the core infrastructure is sound, but the ROI on closing the last 17% on n=11 is unclear when the workload's reason for existing is "match an imperative C benchmark by porting it line-for-line."

### 5.3 Friction 3 — `List(T)` cannot substitute for `Vector(T)` in numerical workloads

For sequential iteration, List is fine. But for random-access patterns Vector exists to serve, List's O(n) `at(i)` is asymptotically disqualifying:

- **fannkuch n=11** does ~2.15 billion `Vector.set(v, i, x)` calls. Each set with List = O(n). Total = O(n²) per pass × millions of passes = O(n³) overall. Catastrophic.
- **spectral-norm dot product**: O(n²) iterations × O(n) per List read = O(n³) per dot product.

So *if* we keep these benchmarks and care about their perf, we genuinely need Vector or its equivalent. List by itself is not a substitute.

The escape clause: a different physical representation for "List" — flat-buffer instead of cons-cell — would make List a plausible substitute. That's Option B in §6 below (the Roc design).

### 5.4 Friction 4 — Vector's surface is wrong (concrete aliases instead of generic)

Currently:
- `lib/vector_i64.zap` exposes `pub struct VectorI64`.
- `lib/vector_f64.zap` exposes `pub struct VectorF64`.
- `vector_i64` and `vector_f64` are separate `NativeTypeKind` variants in `src/scope.zig:479`.
- The type system has `VectorElementKind = enum { i64, f64 }` as a discriminator (`src/types.zig:117`).

The runtime is already generic: `pub fn Vector(comptime T: type) type` at `src/runtime.zig:1678`. Only the surface is specialized.

This was a design error inherited from the deleted `MArrayI64`/`MArrayF64` imperative escape hatches. The correct surface would mirror `Map(K, V)` and `List(T)`:

```zap
@native_type = "vector"

pub struct Vector {
  pub fn new_filled(size :: i64, init :: t) -> Vector(t) { ... }
  pub fn get(vec :: Vector(t), index :: i64) -> t { ... }
  pub fn set(vec :: Vector(t), index :: i64, value :: t) -> Vector(t) { ... }
  ...
}
```

Cleanup work pending. This is uncontroversial; the question is whether to do this cleanup *before* deciding the larger Vector-vs-no-Vector question, or whether deciding to delete Vector entirely makes the cleanup moot.

### 5.5 Friction 5 — Tuples aren't a first-class type

- Tuple literals `{a, b, c}` work syntactically.
- The IR has `tuple_init` and `index_get` opcodes (`src/ir.zig:308`, `src/ir.zig:317`).
- They're used heavily for `{:error, reason}` patterns and multi-return shapes (e.g., `{VectorI64, Bool}` for pop-with-status).
- But there is **no formalized `Tuple` type** in the standard library. They're structural anonymous shapes.
- A first-class `Tuple` type with operations like `Tuple.size`, `Tuple.first`, etc. would parallel how `Map`, `List`, `Vector` work.

This friction is independent of the Vector question — formalizing Tuple is desirable regardless. But it interacts with the Vector question: if a formalized Tuple could subsume Vector for some use cases, that affects the design space. (Spoiler: it can't, see Friction 6.)

### 5.6 Friction 6 — Tuple can't substitute for Vector

Even if Tuple were formalized:
- Tuples are **compile-time-fixed in arity**. `{i64, Bool}` is a different type from `{i64, Bool, String}`. There is no single tuple type that grows or shrinks at runtime.
- **Indexing is compile-time-only.** `t.0` returns `i64`; `t.1` returns `Bool`; `t.[i]` for variable runtime `i` isn't well-typed because slot types differ.
- For homogeneous tuples (`{i64, i64, i64}`), runtime indexing IS well-typed in principle (every slot has type `i64`), but Zap's tuples don't currently support this. Adding it would mean special-casing the homogeneous case in the type system, which is a meaningful surface change.

So Tuple is heterogeneous + fixed-arity by design. Even with formalization, it does not subsume Vector for the workloads Vector exists to serve (fannkuch's permutation buffer, spectral-norm's u/v vectors — both varying-length and indexed at runtime).

A "homogeneous Tuple with runtime indexing" is a possible compromise (Option D in §6) but it stretches the tuple concept past its natural shape.

---

## 6. The Design Question — Four Options

Given the frictions above, the open question is:

> **Should Zap have a separate `Vector(T)` type, or can `List(T)` + `Tuple` together cover all the real use cases?**

Four concrete options the research agent should evaluate:

### Option A — Keep three types (status quo, with cleanups)

- Tuple becomes first-class: a `Tuple` standard library struct with `Tuple.size`, etc. Stays heterogeneous + compile-time-arity, but gains a real surface.
- Vector stays. Its surface is fixed: generic `Vector(T)` instead of concrete `VectorI64`/`VectorF64` aliases. The runtime is already generic; only the language-side wiring needs work.
- All three coexist. The Vector perf gap on fannkuch n=11 is closed via the deferred Phase 2.7+ work (extend `arc_liveness.ArcOwnership` to track non-ARC aggregates with ARC components, ungate Phase 2.6.2/2.6.3).
- This is the **OCaml/Haskell/Standard ML/Scala/Clojure/Lean 4** design — most production functional languages have both List and Vector.

**Pros:**
- Smallest delta from current code. The runtime, IR, and verifier already support everything; just clean up the surface.
- Preserves Zap's ability to compete on numerical / indexed-mutation benchmarks once the deferred work lands.
- No migration cost for existing code.

**Cons:**
- Inherits the 6 frictions in §5. Tuple is still less expressive than the other two; Vector still needs deferred work to deliver on its promise.
- Three first-class collections is more surface area than two. More to teach, more to test, more to document.
- The Vector perf delivery is contingent on phase-2.7-and-beyond work, which has been stuck across multiple sub-phases.

### Option B — Eliminate Vector, replace with List flat-buffer (Roc design)

- `List(T)` becomes flat-buffer-backed instead of cons-cell.
- O(1) random access by default.
- O(1) indexed mutation under uniqueness (the V8 path that already exists for Vector).
- O(1) `length`.
- The persistent-cons-cell list as a separate concept goes away. Iteration is by walking a flat buffer, not by structural recursion on `cons`.
- Tuple becomes first-class (same as Option A).
- This is **Roc's choice**: their `List T` IS a flat buffer; they have no cons-cell list. Roc treats `List` as the fundamental sequence type.

**Pros:**
- Two first-class collections instead of three. Smaller surface.
- The fast path for indexed mutation already exists (V8 + unchecked variants). Reuses the substrate.
- O(1) indexed access is now uniform — no more "List `at` is O(n)" gotcha for users.
- Aligns with the most recent functional-language design (Roc — published 2023+).

**Cons:**
- **Cons-cell idioms break.** Pattern matching on `[head | tail]` either lowers to a flat-buffer head/slice operation (O(1) head, O(?) slice) or stops being efficient. Pattern matching on `[a, b, c | rest]` is a fundamental Elixir-flavored pattern; preserving it efficiently requires careful design.
- **Persistent sharing across versions** is lost. Two near-identical lists no longer share structure. For workloads that hold many versions (undo stacks, reducer histories, persistent-data-structure-as-database patterns), memory blows up.
- **Tail-recursion on lists** changes shape. `def loop(list)` matching `[head | rest]` and recursing on `rest` is currently O(1) per step under cons-cell sharing. Under flat-buffer with COW, each recursive call's `rest` is either a slice (cheap, but requires slice support) or a new allocation (expensive).
- Migration cost: every cons-cell-shaped algorithm in `lib/*.zap` and user code needs review.

The agent should research how Roc handles cons-cell-style patterns (`[head | tail]` destructuring) given a flat-buffer List. Roc may have specific lowering rules that preserve the pattern semantics without paying allocation cost.

### Option C — Eliminate Vector, accept O(n) random access (Elixir design)

- `List(T)` stays cons-cell.
- No flat-buffer collection at all.
- Numerical / indexed-mutation workloads (fannkuch, spectral-norm) are slow by design. Zap doesn't compete on those benchmarks.
- Tuple becomes first-class (same as Option A and B).
- This is **Elixir's choice**: it has cons-cell `[a]` and tuple `{a, b}` and that's it for sequences. There's no Vector. Elixir's CLBG performance on numerical kernels is poor and Elixir does not aim to fix this.

**Pros:**
- Smallest possible surface — two collection types, both with clean shapes.
- No deferred work, no V8 vector-related frictions.
- Aligns with Elixir's identity, which is Zap's stated surface inspiration.
- Frees up architectural capacity. The non-ARC-aggregate-with-ARC-components work can be ignored or simplified.

**Cons:**
- Zap explicitly *cannot* compete on numerical / indexed-mutation benchmarks. Fannkuch and spectral-norm get rewritten in idiomatic Zap (which means they are slow) or get deleted from the benchmark suite.
- Users who *do* need an indexed mutable buffer have nothing in the language. They have to write Zig (`@zig` interop) or accept O(n) per access.
- Closes the door on Zap being used for any workload where indexed mutation is structural — ML training loops, simulation, image processing, etc.

The agent should research whether Elixir's identity-without-Vector has hurt Elixir's adoption. The answer (from public reception) appears to be "no" — Elixir's adoption is in domains where Vector-perf isn't the bottleneck.

### Option D — Hybrid

The agent may propose a hybrid the user hasn't anticipated. Two examples:

- **List as cons-cell by default + a separate "indexed" wrapper.** Users who need O(1) indexed access opt into `IndexedList` (flat-buffer) explicitly. Persistent `List` stays cons-cell. This is the OCaml design (`'a list` vs `'a array`) but renamed.
- **Tuple extended with homogeneous-element runtime indexing.** When a tuple's slot types are all the same (`{i64, i64, i64}`), the type system grants `t.[i]` for runtime `i`. Tuples remain compile-time-fixed in arity. This is a tighter version of Option C — fixed-arity tuples cover small cases; users handle larger cases differently.
- **Vector becomes a non-ARC builtin (no V8 needed).** The runtime exposes Vector as a "transient" with explicit lifetime — closer to Clojure transients. Persistent surface lives elsewhere, or is dropped entirely. This is a step *back* from the Roc-style direction Zap has committed to and would require unwinding the V8 work.

The agent should evaluate hybrid options against the cost-of-complexity / benefit-vs-options-A-B-C tradeoff. Hybrid options tend to be traps — Rust's `HashMap` is just dense; Roc's `List` is just dense; Clojure's `PersistentVector` is just HAMT. Most production systems that have tried hybrids have backed away.

### How to evaluate

The agent should evaluate each option against:

1. **Real Zap workloads** (the benchmark set in §4 + any proxy for "production code" — note the language is early-stage, no real production users).
2. **Other functional languages' choices** (the survey table in §7).
3. **Zap's stated language identity** — functional-first, statically-typed, native-compiled, ARC-managed, Elixir-flavored surface.
4. **Implementation cost** of each option (engineer-weeks, deletions vs additions).
5. **Migration cost** — porting fannkuch + spectral-norm benchmark sources, deleting Vector-related code, formalizing Tuple, etc.
6. **Future-proofing** — does the choice foreclose use cases? Numerical workloads, multi-threading, persistent-versioning, large-state programs.

---

## 7. Survey of FP Language Choices

The dominant pattern across functional languages: **most have both List and Vector (or Array).** A few omit one or the other. The table below is accurate as of recent research; the agent should treat it as a starting point and verify any line they want to lean on.

| Language     | List-like                  | Vector-like                                | Notes                                  |
| ------------ | -------------------------- | ------------------------------------------ | -------------------------------------- |
| Haskell      | `[a]` (cons, lazy)         | `Data.Vector` (library, not Prelude)       | Both available; `[a]` is the default.  |
| OCaml        | `'a list` (cons)           | `'a array` (built-in, mutable)             | Both built-in.                         |
| F#           | `'a list` (cons)           | `'a array`, `ResizeArray`                  | Both built-in.                         |
| Scala        | `List` (cons)              | `Vector` (HAMT-trie, persistent)           | First-class; both common idiomatic.    |
| Clojure      | `(list)` (cons)            | `[1 2 3]` (PersistentVector, HAMT-trie)    | First-class; vector is more idiomatic. |
| Standard ML  | `'a list` (cons)           | `'a vector` (immutable) + `'a array` (mut) | Both built-in.                         |
| Racket       | `list` (cons)              | `vector` (mutable by default)              | First-class.                           |
| Koka         | `list<a>` (cons)           | `vector<a>` (flat-buffer)                  | Closest precedent to Zap's V8 work.    |
| Lean 4       | `List α` (cons)            | `Array α` (flat-buffer + rc-1 mutation)    | Same model as Zap.                     |
| Idris 2      | `List a` (cons)            | `Vect n a` (length-indexed)                | Length-as-type.                        |
| **Roc**      | —                          | `List T` (flat-buffer, unified)            | **No separate cons-cell list.**        |
| **Elixir**   | `[a]` (cons)               | — (tuples for fixed-arity O(1))            | **No flat-buffer Vector.**             |
| Erlang       | same as Elixir             | —                                          | Same as Elixir.                        |

**Two outliers from the dominant pattern:**

- **Roc** unified them — `List T` is the only sequence type, and it's flat-buffer. This is Option B above.
- **Elixir / Erlang** omit the Vector concept entirely — `[a]` is the only sequence type, and it's cons-cell. This is Option C above.

Lean 4 and Koka are the closest precedents for what Zap is currently doing (Option A): both have a persistent List + a flat-buffer Array/Vector with rc-1 mutation. Both are working production systems.

The agent should investigate:
- How Roc's `List` handles cons-cell-style patterns (`[head | tail]`) given its flat-buffer representation.
- How Lean 4 markets the List/Array distinction to its users — when to use which, what the perf story is.
- How Elixir users handle indexed-mutation workloads in practice (the answer appears to be "Erlang `:array` library" and "rewrite in C/Rust/Zig via NIFs").
- Whether any production language has shipped a hybrid (Option D) and either succeeded or learned a clean lesson.

---

## 8. Constraints and Hard Rules

The following are non-negotiable. Whatever the agent recommends must respect them.

- **Zap is a general-purpose language.** Solutions must not special-case specific use cases or benchmarks. Whatever's chosen must work for any user code, not just for the workloads listed in §4.
- **Functional surface semantics.** Whatever the implementation, every collection operation returns a new value semantically. Mutation is invisible to the user. The opportunistic-mutation pattern (V8) is the safety substrate for any "in-place" optimization.
- **Soundness over speed.** The V8 verifier remains the post-rewrite safety net. Wrong inference produces compilation failure, never miscompilation. Any new collection design must be V8-compatible (or replace V8 with an equivalent safety property).
- **No backwards compatibility constraint.** Zap has zero production users. This is the right time to make breaking surface changes. The agent should not constrain the recommendation by fear of breakage.
- **The Zig fork can be modified** but is not the default. Most of this work will be in `src/runtime.zig`, `src/ir.zig`, `src/types.zig`, `src/scope.zig`, and `lib/*.zap`. Fork changes are allowed when needed.
- **No top-level functions in Zap.** Every `def`/`fn` must be inside `defmodule`/`pub struct`. Standard library code follows this rigorously.
- **No GC, no cycle collector.** Memory model is ARC. Cycles must be impossible by construction or broken by weak refs.
- **The IR-to-ZIR pipeline is the only codegen path.** No Zig source text generation. `src/codegen.zig` is dead legacy code; `src/zir_builder.zig` is the only supported lowering.
- **`@fndoc` on every `pub fn`/`pub macro` in `lib/*.zap`.** Documentation discipline is enforced.
- **Single-threaded today.** Atomic refcounts not required. Design should not foreclose future cross-thread sharing — flag any choices that would.

---

## 9. What the Research Agent Should Produce

The deliverable should mirror the structure of `docs/roc-style-opportunistic-mutation-research-brief.md`'s "deliverable shape" — direct, specific, named choices.

1. **Recommendation.** Pick one of Options A / B / C / D (or a specific variant the agent constructs). State the choice clearly. Justify it.
2. **Alternative options considered and rejected.** For each of the other three options not chosen, explain why the agent rejected it.
3. **Per-option deep dive.** For each of A, B, C, D:
   - Surface description (what the user sees — `List(T)` API, `Vector(T)` API or its absence, `Tuple` shape).
   - Runtime representation.
   - Mutation strategy under V8 (or its equivalent) — does the rc-1 fast path apply, where, with what surface signature.
   - Asymptotic table — `get`, `set`, `length`, `prepend`, `append`, random access — for each collection in the option.
   - Migration cost — what breaks, what gets rewritten, what gets deleted.
   - Implementation cost (engineer-weeks rough estimate, citing the most ornery sub-problems).
4. **Prior art comparison.** Cite specific language designs that informed the recommendation. The table in §7 is a starting point; expand with concrete references — Roc's `List` source, Lean 4's `Array` paper, Elixir's stance on numerical workloads.
5. **Sub-problem answers.** At minimum:
   - How does pattern matching on `[head | tail]` work under each option?
   - How does Tuple formalization interact with each option?
   - For Option B (Roc-style `List` flat-buffer): how is persistent-versioning handled (or sacrificed)? Does Roc's `List` use any structural sharing under the hood?
   - For Option C (Elixir-style, no Vector): what do users do for the few workloads that genuinely need indexed mutation? Where is the escape hatch?
   - How much of the current V8 / opportunistic-mutation infrastructure remains useful under each option, and how much becomes orphaned?
6. **Implementation phasing.** A sequenced plan of work items with byte-exact benchmark output preserved at each step. Reference the existing pattern from `docs/opportunistic-mutation-milestone.md`. The plan should include:
   - Substrate work (runtime layout changes if any).
   - IR + verifier changes.
   - Surface cleanup (`lib/*.zap`, `NativeTypeKind`, `VectorElementKind`).
   - Migration of fannkuch + spectral-norm benchmark sources.
   - Deletion of Vector-related code (if Option B or C).
   - Formalization of Tuple (regardless of option, if recommended).
7. **Open questions for the language designer.** Anything the agent cannot decide without product input — the cleanest example is "does Zap want to compete on numerical-kernel benchmarks?" If the answer is yes, Vector probably stays; if no, it can go.

---

## 10. Pointers Into the Codebase

When the research agent or follow-up implementer needs to read code:

- **Map runtime:** `src/runtime.zig:4772` (`pub fn Map(K, V)`).
- **List runtime:** `src/runtime.zig:5726` (`pub fn List(T)`).
- **Vector runtime:** `src/runtime.zig:1678` (`pub fn Vector(T)`).
- **Vector concrete aliases:** `src/runtime.zig:1671` (`VectorI64`, `VectorF64`).
- **Tuple type:** `src/types.zig:79` (`tuple: TupleType`), `src/types.zig:119` (`TupleType { elements }`).
- **Tuple IR opcodes:** `src/ir.zig:308` (`tuple_init`), `src/ir.zig:317` (`index_get`).
- **Native type registry:** `src/scope.zig:479` (`NativeTypeKind` enum).
- **Vector element kind discriminator:** `src/types.zig:117` (`VectorElementKind = enum { i64, f64 }`).
- **ARC type classification:** `src/ir.zig:1166` (`isArcManagedTypeId`).
- **V8 verifier:** `src/arc_verifier.zig`.
- **V8 uniqueness inference:** `src/v8_uniqueness.zig`, `src/v8_signature.zig`, `src/v8_fixpoint.zig`, `src/v8_interprocedural.zig`.
- **Liveness:** `src/arc_liveness.zig`.
- **Drop insertion:** `src/arc_drop_insertion.zig`.
- **Map surface:** `lib/map.zap`.
- **List surface:** `lib/list.zap`, `lib/list/`.
- **Vector surface:** `lib/vector_i64.zap`, `lib/vector_f64.zap`.
- **Opportunistic-mutation milestone retrospective:** `docs/opportunistic-mutation-milestone.md`.
- **Opportunistic-mutation design rationale:** `docs/roc-style-opportunistic-mutation-research-brief.md`.
- **Map-specific design discussion:** `docs/zap-map-representation-research-brief.md`.

---

## 11. Final Note to the Research Agent

This brief asks for a **language design recommendation**, not an algorithm choice. The decision space is small (four options) but each option cascades into substantial implementation, migration, and identity consequences. The agent should pick a side.

- The user has not pre-committed to any of A / B / C / D. The current state (Option A in degraded form) is a snapshot, not a destination.
- The benchmark numbers in §4 are accurate. Don't run benchmarks to verify them; trust them.
- The user is willing to commit to a more invasive option (Option B or C) if the research shows the long-term win. The user is *not* interested in a recommendation that hedges or recommends "ship all four and see which the community prefers."
- Roc's design (Option B) and Elixir's design (Option C) are both successful in their own domains. The question is which fits Zap's identity better.
- Implementation cost matters but is not the deciding factor. "Cost and time are not concerns — correctness and quality are" is the project rule (`CLAUDE.md`). If Option B is the right answer and it costs 12 weeks of work, that's the answer.

Be concrete. Cite production language sources, papers, benchmarks. Avoid generalities. If a sub-question needs more research than the agent can do in one pass, surface it as an open question for the language designer rather than guessing.
