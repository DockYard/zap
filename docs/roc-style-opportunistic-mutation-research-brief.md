# Roc-Style Opportunistic Mutation in Zap — Research Brief

**Audience:** A research agent with zero prior context on Zap, the Zap Zig fork, or the work that has already been done. This document is a self-contained briefing. After reading it, the agent should be able to (a) understand the problem space, (b) survey the prior art, (c) propose concrete designs, and (d) reason about the trade-offs without needing to ask clarifying questions about Zap itself.

**The question to research:** How should Zap implement *Roc-style opportunistic in-place mutation* — pure functional surface semantics for `Map`, `List`, and `Vector`, with the compiler/runtime silently mutating in place when a value's reference count is unique, and falling back to persistent (structural-sharing) updates otherwise — and once that capability exists, eliminate the existing imperative escape-hatch types `MArrayI64` and `MArrayF64` from the language. Survey the design space, identify the hardest sub-problems, and return concrete implementation strategies with trade-offs.

---

## 1. What Zap Is

Zap is an early-stage statically-typed functional programming language. It is heavily inspired by Elixir at the surface level (modules, pattern matching, multi-clause functions, pipe operator, sigils, Erlang-style atoms), but unlike Elixir it is:

- **Statically typed** with a Hindley–Milner-derived type system extended for protocols/typeclasses.
- **Compiled to native code** via LLVM. There is no VM and no interpreter.
- **Macro-driven** — macros are written in Zap itself and run at compile time.
- **No top-level functions.** Every `def`/`fn` lives inside a `defmodule`/`pub struct` (a hard rule the user has reiterated multiple times).
- **Functional-first**, with immutable persistent data structures (`List`, `Vector`, `Map`) as the default.

**Surface examples (illustrative, language is in flux):**

```zap
defmodule Counter {
  pub fn count_words(text :: String) -> Map(String, Integer) {
    text
    |> String.split(" ")
    |> Enumerable.reduce(Map.new(), fn(word, acc) ->
      Map.update(acc, word, 1, fn(n) -> n + 1 end)
    end)
  }
}
```

The semantics are pure: `Map.update` returns a new map; `acc` in the previous iteration is unchanged. A persistent HAMT (Hash Array Mapped Trie) provides structural sharing so this isn't catastrophically slow, but in tight write loops it's still 30–50× slower than a C hash table.

### Files relevant to language definition

- `lib/*.zap` — the standard library, written in Zap. Includes `kernel.zap` (macros: `if`, `unless`, `\|>`, etc.), `map.zap`, `list.zap`, `string.zap`, `marray_i64.zap`, `marray_f64.zap`, etc.
- `src/lexer.zig`, `src/parser.zig`, `src/ast.zig`, `src/macro.zig`, `src/types.zig` — front end.
- `src/hir.zig`, `src/ir.zig` — High-level IR and (lower) IR. **`src/ir.zig` is ~9,300 lines**, the largest single source file in the project. It is the central site of ownership/ARC reasoning.
- `src/zir_backend.zig` — emits Zig's ZIR (a typed intermediate representation) by calling C-ABI functions exposed by the Zap Zig fork.
- `src/runtime.zig` — the Zig-side runtime (~8,600 lines). Contains the implementations of `List(T)`, `Map(K, V)`, `Vector(T)`, `MArrayOf(T)`, `String`, atoms, ARC headers, per-type memory pools, etc.

---

## 2. Compilation Pipeline

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
  ▼ src/ir.zig    ← ARC ownership inference happens here
IR (ownership-typed)
  │
  ▼ src/zir_backend.zig
Zig ZIR (via C-ABI calls into the Zig fork)
  │
  ▼ ~/projects/zig/  (the Zap Zig fork)
LLVM IR
  │
  ▼ Zig-fork build system
Native binary (linked against `libzap_compiler.a` from the fork
              and `src/runtime.zig` compiled as part of the program)
```

**Key invariant:** Zap *only* lowers through ZIR. There is no Zig-source-text codegen path. Anything the language can do must be expressible as a ZIR-builder C-ABI call into the fork. If a feature requires a new lowering, the correct fix is to add the C-ABI to the fork — not to fall back to text generation. (`src/codegen.zig` exists but is dead legacy code.)

### The Zap Zig Fork

Zap is built on a **fork of Zig 0.16.0** that lives at `~/projects/zig/`. The fork adds:

- A C-ABI surface (`libzap_compiler.a` / `libzir_builder.a`) exposing ZIR construction, semantic analysis, and codegen as library calls.
- Hooks for Zap-specific runtime needs (e.g., type registration for ARC dispatch).
- The user has full latitude to modify the fork. *No fix is rejected because "it would require fork changes."*
- The fork tracks Zig 0.16.0 conventions (in particular the `usingnamespace`-removed, declaration-literals-default world). Anything researched should be valid against Zig 0.16.0, not 0.13/0.14.

When the fork must be rebuilt, follow the README in both repos. Building the fork is slow (10–20 minutes); avoid unnecessary rebuilds.

---

## 3. Memory Model — ARC and Per-Type Pools

### ARC headers

Every heap-allocated value managed by Zap carries an inline `ArcHeader { strong_count: u32, weak_count: u32, type_id: u32 }` (or an equivalent layout) at the head of the cell. `retain` increments `strong_count`; `release` decrements and, on transition to zero, runs the type's drop function, which recursively releases child fields and returns the cell to its pool.

There is no GC. There is no cycle collector. All lifetimes are managed by ARC, with optional borrowing.

### Per-type MemoryPool

`runtime.zig` allocates each ARC-managed type out of a thread-local `std.heap.MemoryPool(T)`. This avoids `malloc` overhead in hot loops and gives O(1) allocate/free. Notable pools:

- `Map(K, V).Cell` and `Map(K, V).HamtNode`
- `List(T).Cell`
- `Vector(T)` cells
- `MArrayOf(T).Inner`

### ARC-managed types

The ownership pipeline only inserts retain/release calls for types it knows are ARC-managed. The classification lives in `src/ir.zig::isArcManagedTypeId` (line ~1166). The currently ARC-managed kinds include:
- `.opaque_type` (anything wrapping a Zig pointer behind an opaque handle, e.g., `String`, `Atom`, `MArrayI64`)
- `.map` (flipped in **Phase F** of the recent leak-fix work)
- `.list` (flipped in **Phase H.4** — most recent milestone)

Plain integers/floats/bools/atoms (interned) are *trivial* — no retain/release.

### Persistent data structures

- `Map(K, V)` (`runtime.zig` ~line 3258): a HAMT with two physical layouts: a flat sorted vector for small maps and a trie node for larger maps. Both are persistent: any `put` returns a new top-level cell; existing cells are never mutated.
- `List(T)` (`runtime.zig` ~line 4414): a singly-linked persistent cons-list. `next` / `prepend` share tail structure.
- `Vector(T)`: a persistent indexed sequence (HAMT-based bit-partitioned vector trie, similar to Clojure's `PersistentVector`).

### MArrayI64 and MArrayF64 — the imperative escape hatch

`lib/marray_i64.zap` and `lib/marray_f64.zap` expose a directly-mutable, contiguous, fixed-size `i64` / `f64` array. Backed by `runtime.zig::MArrayOf(T)`:
- `Inner` cell goes through the per-type pool, ARC-headered.
- Payload is a `[*]T` allocated through `page_allocator`.
- Operations: `new(size, init)`, `get(arr, i)`, `set(arr, i, v)`, `length(arr)`, `release(arr)`.

**`set` is observably mutating.** Two pieces of code holding the same `MArrayI64` see each other's writes. This is the central tension this brief is asking the researcher to resolve. These types were added by the assistant (during the recent benchmarks work) without explicit user approval — the user does not consider their existence settled, and a clean Roc-style path should make them **deletable**.

Their original motivation was the CLBG benchmarks `fannkuch-redux` (random-access permutation buffer) and `spectral-norm` (vector dot products), where persistent `List`'s O(n) `at` was disqualifying. Once Roc-style opportunistic mutation lands on `Vector(T)`, those benchmarks should be expressible against `Vector(i64)` / `Vector(f64)` with no perf loss.

---

## 4. The Ownership IR (Recent Work)

Over a multi-month effort to fix a 7.36 GiB → 507 MiB RSS leak in the k-nucleotide benchmark, the following infrastructure has been built in `src/`. **This is the substrate the Roc-style path will build on.**

### Files

- `src/arc_ownership.zig` (~2,575 lines) — `OwnershipClass`, `ParamConvention`, `ResultConvention`, `classifyAndNormalize`, per-callee consume-site rewriting.
- `src/arc_param_convention.zig` (~545 lines) — whole-program parameter convention inference (which params are `borrowed` vs `owned`).
- `src/arc_liveness.zig` (~4,221 lines) — last-use analysis, owned-at-return tracking, `owns_effect` per IR instruction.
- `src/arc_drop_insertion.zig` (~1,888 lines) — inserts retain/release at scope exits; respects parameter conventions.
- `src/arc_verifier.zig` (~1,838 lines) — enforces invariants V1–V7 on the ownership-typed IR.
- `src/arc_optimizer.zig` (~493 lines) — peephole-style cleanup (e.g., elide retain immediately followed by release).
- `src/perceus.zig` — Perceus-style reuse-analysis groundwork.

### Ownership classes and conventions

Every IR value has an `OwnershipClass`:
- **owned** — caller transfers a +1 strong ref to this site; receiver is responsible for `release`.
- **borrowed** — caller retains the +1; receiver does not `release`.
- **trivial** — non-ARC value, no bookkeeping.

Function parameters declare a `ParamConvention` (`borrowed` is the default). Return values declare a `ResultConvention`. `arc_param_convention.zig` derives conventions whole-program when not annotated.

### Verifier invariants (V1–V7)

V1–V7 are enforced post-ownership-rewrite by `arc_verifier.zig`. The exact text of each invariant lives in that file's comments, but in spirit:

- **V1**: every `release` corresponds to exactly one matching `retain`/owned-source on every control-flow path (no double-free, no leak).
- **V2**: borrowed values do not escape their lender's lifetime.
- **V3**: parameter convention obeyed at every call site.
- **V4**: return value's `ResultConvention` matches what callees consume.
- **V5**: ownership transfers across `if`/`switch` arms balance (each arm produces the same ownership shape).
- **V6**: drops at scope exit cover exactly the live-but-not-consumed owned set.
- **V7**: `share_value` / `borrow_value` / `copy_value` / `move_value` IR primitives type-check against operand classes.

### IR primitives for ownership

`src/ir.zig` exposes:
- `share_value` — bump strong count and return a fresh +1.
- `borrow_value` — produce a borrow tied to a lender's lifetime.
- `copy_value` — deep copy (allocates new cells).
- `move_value` — transfer ownership without bumping refcount.

The drop-insertion pass uses these to make ownership flow explicit before lowering to ZIR.

### Tail-call rewriter

`if`/`switch` arms get a tail-call rewrite so each arm has matching ARC discipline (necessary for V5 to hold under deeply nested expressions).

---

## 5. The Problem — Why This Brief Exists

### The benchmark gap (motivation)

Latest k-nucleotide numbers (CLBG canonical input):

| Language | Time           | Peak RSS |
| -------- | -------------- | -------- |
| C        | 59.8 ms ± 1.0  | 27 MiB   |
| Rust     | 80.9 ms ± 1.2  | 15 MiB   |
| Zig      | 78.2 ms ± 0.5  | 11 MiB   |
| Go       | 106.3 ms ± 1.4 | 14 MiB   |
| OCaml    | 307.0 ms ± 4.5 | 33 MiB   |
| Elixir   | 3.30 s ± 0.04  | 135 MiB  |
| **Zap**  | **3.77 s ± 0.01** | **507 MiB** |

The catastrophic leak is fixed (was 7.36 GiB). What remains is a **~50× algorithmic gap** versus C/Rust/Zig, driven entirely by `Map.put` being a HAMT update (O(log₃₂ n) allocation per write) instead of an in-place hash-table store (one CPU cache-line write).

### The wrong solution (rejected)

Adding an `MMap` primitive (mutable hash map analogous to `MArrayI64`). The user pushed back: this would compound a precedent (`MArrayI64`, `MArrayF64`) that was set without their approval, and it would fork the language into "real Map" and "fast Map" — exactly the schism a functional language should not have.

### The right solution (this brief)

**Roc-style opportunistic mutation:**

1. The user-visible API has only persistent `Map` / `List` / `Vector`. Pure semantics. No `M*` types.
2. At every mutation site (`Map.put`, `List.append`, `Vector.set`, etc.), the compiled code branches on the runtime refcount of the receiver:
    - `rc == 1` → mutate the existing cell in place. No alloc. Same pointer returned.
    - `rc > 1` → run the persistent path (allocate a new cell with structural sharing).
3. When the ownership IR can statically prove the receiver is uniquely owned (which is most of the time in tight loops, by construction), the runtime branch is *elided* and the in-place store is unconditional.
4. `MArrayI64` and `MArrayF64` are deleted; their callers move back to `Vector(i64)` / `Vector(f64)` and observe no perf regression.

**This is what the research agent should design and survey solutions for.**

---

## 6. Prior Art the Research Agent Must Survey

The agent should produce concrete design proposals for Zap that are informed by — and explicitly compare against — these systems:

### Roc (https://www.roc-lang.org/)

The naming inspiration. Roc is a pure functional language with reference-counted memory. The compiler emits, at every "write" site on a refcounted value, a check like:

```
if (refcount == 1) {
    // unique owner — mutate in place, return same pointer
} else {
    // shared — copy the relevant region with structural sharing
}
```

Key Roc concepts to research:
- **"Opportunistic mutation"** — the term Roc uses.
- **Roc's "boxed" vs "unboxed" representation** and how it interacts with rc-1 detection.
- Roc's compiler implementation (in Rust). The relevant pass is the lowering pass that emits the rc-1 branch on builtins.
- Roc's `List` and `Dict` standard library types — how their internal layouts are designed to support both modes.
- Roc's escape analysis / **"reset/reuse"** optimization (related to Perceus): when a cell is dropped on one branch and a new one allocated on another, the compiler can reuse the storage.

### Perceus (Daan Leijen et al., Microsoft Research)

The academic foundation. **Search terms:** "Perceus precise reference counting", "Perceus reuse analysis", "Koka ownership". Key papers:
- *Perceus: Garbage Free Reference Counting with Reuse* (Reinking, Xie, de Moura, Leijen — PLDI 2021).
- *Functional but in-place* — Koka's approach.
- Koka's `FBIP` (Functional But In-Place) programming model.

Perceus is the closest theoretical relative to what the Zap ownership IR has been heading toward. `src/perceus.zig` exists in the codebase as preliminary scaffolding. The research agent should check whether the existing ARC IR design is already a Perceus-compatible substrate, or whether deviations exist that block adopting Perceus's reuse rules wholesale.

### Clojure transients

Clojure's solution to the same problem in a Lisp context. **Search terms:** "Clojure transients", "Rich Hickey transient persistent". A `transient!` produces a thread-local mutable view of a persistent collection; `persistent!` flips it back. The mutable phase is bounded lexically and enforced dynamically (a transient cannot be used after `persistent!`).

This is *not* the model Zap should adopt (it requires explicit user calls), but it informs the design — the data structures Clojure uses (HAMT for `PersistentHashMap`, bit-partitioned vector trie for `PersistentVector`) are the ones Zap is already using, and Clojure's transient implementation shows what bookkeeping the underlying nodes need to support both modes.

### Haskell `ST` monad and `MutableArray#`

For contrast. Haskell *does* segregate mutation in the type system (`ST s` / `IO`). The agent should explain why Zap should *not* take this approach — Zap's whole point is that mutation be invisible to the user, not quarantined behind a monad. But Haskell's primitives (`thawArray#`, `freezeArray#`, `unsafeFreezeArray#`) are useful prior art on the *runtime* mechanics of switching between mutable and immutable physical layouts.

### Swift's COW (Copy-on-Write) on `Array`/`Dictionary`/`Set`

Swift's `Array` is value-semantic but heap-backed and refcounted. Mutation goes through `isKnownUniquelyReferenced` to decide whether to mutate the underlying buffer or copy it. **Search terms:** "Swift Array CoW", "isKnownUniquelyReferenced", "Swift exclusivity enforcement".

This is mechanically very close to what Zap needs — but Swift's refcount check is per-buffer, not per-node. For Zap's HAMT-backed `Map`, the agent must reason about whether the refcount check should be on the *root* cell only (cheap, common case) or recurse into nodes (more uniqueness opportunities, more checks).

### OCaml `Hashtbl` / mutable arrays

For comparison only — OCaml does not unify mutable/immutable. It just has both. This is the path Zap has been on (`Map` + `MMap`) and is rejecting. Agent should be aware OCaml is the cautionary tale, not a model.

### Lean 4 / Idris 2 — uniqueness types and FBIP

**Search terms:** "Lean 4 reference counting", "Idris 2 linear types in-place update", "Sébastien Hinderer mutation under linearity". Lean 4 in particular uses Perceus and is a working production system.

### Rust's interior mutability and `Rc::make_mut`

`Rc::make_mut` in Rust's stdlib: if `rc == 1`, return `&mut T`; otherwise clone first then return `&mut T`. Same pattern as the rc-1 branch, exposed as a library function. Agent should explain the parallel.

---

## 7. Sub-problems the Research Must Address

The agent should treat these as the design-decision checklist. Each one needs a recommended answer with trade-offs explained.

### 7.1 Where is the rc-1 check emitted?

Options:
- **At every persistent-collection builtin call site** (Map.put, List.append, Vector.set, …). Compiler emits the branch as part of the inlined builtin. Pros: simple, predictable. Cons: branch overhead in shared cases.
- **Only when the ownership IR cannot statically prove uniqueness.** When it can, emit the unconditional in-place path. When it cannot, emit the runtime branch. Pros: elides branch in most hot loops by construction. Cons: more complex codegen, requires ownership info to flow to lowering.
- **Hybrid** — runtime check at all sites by default, with a static-uniqueness analysis upgrade pass that elides checks when provable.

Recommended path needs to weigh: how often is the ownership IR's static info sufficient? How costly is the runtime check (a load + compare + branch — typically ~1 cycle when well-predicted)? What does it look like in the generated LLVM IR?

### 7.2 What does "unique" mean for nested structures?

For `Map(K, V)` (HAMT):
- `rc(root) == 1` is necessary but not sufficient — the root might have refcount 1 but a deeply shared HamtNode.
- The persistent `put` walks the trie and creates a copy on the path from root to leaf, sharing siblings. Under uniqueness, the in-place store should mutate the existing node *only if every node on the path has rc == 1*.
- Strategies:
  - **Path-walk uniqueness check** — at each level, check rc == 1 before descending. Cheap if true; degrades gracefully.
  - **Whole-trie ownership flag** — maintain a bit on the root indicating "the entire trie is uniquely owned." Set on construction; cleared on first share. Eliminates per-node checks but requires careful invariant maintenance.
  - **Hybrid**: root flag fast path, fall back to per-node check.

### 7.3 How do we mutate HAMT nodes safely?

The current HAMT layout (`runtime.zig::Map`) has flat-vector and trie-node modes. The agent must reason about:
- Whether the node layouts admit in-place modification without invalidating invariants (sortedness, bitmap consistency).
- Whether the flat-vector (small map) layout needs different mutation rules than the trie-node layout.
- Whether expansion (flat → trie when size threshold crossed) needs special handling.

Same questions for `Vector(T)` (bit-partitioned vector trie) and `List(T)` (cons cells, mostly straightforward — `append` on a unique list is just a tail-pointer write).

### 7.4 Refcount accuracy for the rc-1 fast path

The fast path is correct *only if* the refcount accurately reflects the number of live references. That requires:
- No "phantom retains" (retains the IR inserted but won't be matched by a release).
- No "phantom borrows" (borrows that are accounted for in some other count).
- The current ARC IR's V1–V7 invariants are designed to enforce this, but the agent should verify that the invariants are sufficient for opportunistic-mutation correctness, not just for leak-freedom.

### 7.5 Interaction with the verifier

The verifier (V1–V7) reasons about ownership at the IR level. After the in-place mutation transformation, the IR must still type-check. Specifically:
- If `Map.put(m, k, v)` returns "the same pointer" in the in-place case, but a "new pointer" in the persistent case, the IR must treat the result as having owned-with-uniqueness semantics either way. The simplest model: `Map.put` always *consumes* its `m` parameter (transfers ownership), and *produces* a fresh +1 owned result, regardless of whether the implementation reused the storage. The verifier sees a clean transfer.

### 7.6 Interaction with multi-threading

The ARC pools are currently `threadlocal`. Refcounts are non-atomic. If Zap ever supports cross-thread sharing of these collections, atomic refcounts would be required, and the rc-1 check becomes "rc was 1 *at this instant*" — still correct, but with possible races on subsequent operations.

This is currently moot (Zap is single-threaded), but the agent should flag it as a design constraint that could surface later. Roc handles this via thread-local heaps + message passing; the agent should compare.

### 7.7 What happens to `MArrayI64` / `MArrayF64`?

Once `Vector(T)` supports opportunistic in-place mutation:
- The `M*` types are deletable.
- Their callers (fannkuch-redux, spectral-norm) move back to `Vector(i64)` / `Vector(f64)`.
- The `lib/marray_i64.zap` and `lib/marray_f64.zap` files are removed.
- `runtime.zig::MArrayOf(T)` is removed.
- The `@native_type = "marray_i64"` / `"marray_f64"` registrations are removed from `src/ir.zig::isArcManagedTypeId` (and wherever else they appear).

The agent should produce a migration plan as part of the deliverable, including:
- How to verify byte-exact output preservation on fannkuch-redux and spectral-norm.
- How to verify performance is preserved (no regression on those benchmarks).
- The order of operations: opportunistic Vector ships first; benchmarks port; only then `M*` deletes.

### 7.8 Effect on benchmarks beyond k-nucleotide

- **k-nucleotide** — the motivating benchmark. Tight loop of `Map.put(counts, kmer, count + 1)`. Should hit C-class speed under opportunistic Map.
- **fannkuch-redux** — random-access permutation buffer. Currently uses `MArrayI64`. Will use `Vector(i64)` post-migration; `Vector.set` must be O(log₃₂ n) persistent or O(1) in-place.
- **spectral-norm** — dot products on `f64` vectors. Currently uses `MArrayF64`. Will use `Vector(f64)`. Sequential reads with occasional writes.
- **binary-trees** — allocation-heavy persistent trees. Should be unaffected (already optimal for persistent ARC).

The agent should predict the relative speedup of each benchmark.

### 7.9 Scope: what does NOT change

- The user-visible language. No new keywords. No new types. `Map`, `List`, `Vector` look identical to today.
- The pure functional surface semantics. `Map.put` *always* returns a new value semantically; the in-place reuse is invisible.
- The macro system, the type system, the protocol/typeclass mechanism.
- The IR-to-ZIR boundary. Whatever the agent designs must lower through the existing ZIR-builder C-ABI.

---

## 8. What the Deliverable Should Look Like

The research agent should produce a document organized as follows:

1. **Recommended design** — a single concrete proposal, picked from the design space. Names the specific approach (e.g., "static-uniqueness via ownership IR with runtime rc-1 fallback at builtin call sites"), describes how it works end-to-end.

2. **Alternative designs considered and rejected** — at least two, with the reason each was rejected.

3. **Sub-problem answers** — for each sub-problem in §7, the recommended answer plus alternatives.

4. **Prior art comparison table** — Roc, Perceus/Koka, Clojure transients, Swift CoW, Rust `make_mut`, Lean 4. Columns: how mutation is decided, what user sees, refcount discipline, applicability to Zap.

5. **Implementation phasing** — a sequenced plan of work items. The user has a strong preference for incremental, verifiable steps with byte-exact benchmark output preserved at each step. Reference the existing pattern from `docs/k-nucleotide-rss-gap-phase6-redux-plan.md` (Phases A–H, with §4 iteration discipline that reserves the slow zir-test suite for major-milestone gates). The plan should include:
    - Substrate work (HAMT/Vector node layout changes).
    - Codegen changes (rc-1 branch emission).
    - Static analysis changes (uniqueness flow into lowering).
    - Migration of `M*` callers.
    - Deletion of `M*` types.
    - Benchmark verification steps.

6. **Risks and unknowns** — what could go wrong, what would invalidate the design, what would force a redesign.

7. **Open questions for the user** — anything the agent cannot decide without product input from the language designer.

---

## 9. Constraints, Conventions, and Hard Rules

These are non-negotiable. The agent must respect all of them.

- **No workarounds, no hacks, no shortcuts.** Every solution must be the correct, production-grade, long-term fix. Cost and time are not concerns. (Project rule from `CLAUDE.md`.)
- **Zap is a language — implement features in Zap code where possible.** The compiler is general-purpose; do not hardcode struct/function names of stdlib types in the compiler. Things like `Map.put` lower through general mechanisms (protocols, dispatch, intrinsics), not by the compiler matching on the literal string `"Map"`. (Project rule from `CLAUDE.md`.) This means: where opportunistic mutation logic can live in `lib/*.zap`, it should. The compiler hooks should be general (e.g., "this builtin is rc-1-aware") rather than per-type.
- **No top-level functions in Zap.** Every `def`/`fn` must be inside `defmodule`/`pub struct`. Stdlib code follows this rigorously.
- **TDD: failing test first, then implementation.** Run `zig build test` locally; push only when green. (Project rule.)
- **Zig fork modifications require explicit reasoning.** They are allowed but should not be the default. The fork is at `~/projects/zig/`. Building it is slow.
- **The IR-to-ZIR pipeline is the only codegen path.** No Zig source text generation.
- **Documentation: every `pub fn`/`pub macro` in `lib/*.zap` needs a `@fndoc` heredoc.**
- **Memory model is ARC.** No GC. No cycle collector. Cycles must be impossible by construction or broken by weak refs.
- **Zig 0.16.0 conventions.** No `usingnamespace` (removed). Declaration literals are the default for enum/struct values.
- **`MArrayI64` / `MArrayF64` are slated for deletion.** The end-state design must not preserve them. They were added without user approval and are an active language-identity concern.

---

## 10. Pointers Into the Codebase

When the research agent or follow-up implementer needs to read code:

- **HAMT Map implementation:** `src/runtime.zig` ~line 3258 (`pub fn Map(comptime K: type, comptime V: type) type`), through ~line 4400.
- **Persistent List:** `src/runtime.zig` ~line 4414 (`pub fn List(comptime T: type) type`).
- **MArray:** `src/runtime.zig` ~line 957 (`pub const MArrayI64 = MArrayOf(i64)`); see also `lib/marray_i64.zap` and `lib/marray_f64.zap`.
- **ARC type classification:** `src/ir.zig::isArcManagedTypeId` ~line 1166.
- **Ownership IR core:** `src/ir.zig` (large), `src/arc_ownership.zig`, `src/arc_param_convention.zig`.
- **Verifier:** `src/arc_verifier.zig` — V1–V7 invariants in comments.
- **Drop insertion:** `src/arc_drop_insertion.zig`.
- **Liveness:** `src/arc_liveness.zig`.
- **Perceus scaffolding:** `src/perceus.zig`.
- **ZIR backend:** `src/zir_backend.zig`.
- **Recent leak-fix plan (precedent for phasing):** `docs/k-nucleotide-rss-gap-phase6-redux-plan.md`.
- **Recent leak-fix retrospective:** `docs/k-nucleotide-rss-gap-phase6-struggles.md`.
- **Standard library:** `lib/*.zap`.
- **Build:** `build.zig` and `build.zig.zon` at repo root; the fork at `~/projects/zig/build.zig`.

---

## 11. Definition of Done (for the eventual implementation, not the research)

So the agent understands what the *implementation* phase is aiming for:

1. `Map.put`, `List.append`, `Vector.set`, and equivalent builtins all use opportunistic in-place mutation when the receiver is uniquely owned.
2. Pure-functional semantics are preserved end-to-end. Every existing test in `zig build test` passes. Every existing zir-test passes.
3. k-nucleotide drops to within 2× of C/Rust/Zig (target: ~150–200 ms, RSS under 50 MiB).
4. fannkuch-redux and spectral-norm preserve current performance using only `Vector(T)`.
5. `MArrayI64`, `MArrayF64`, `lib/marray_i64.zap`, `lib/marray_f64.zap`, `runtime.zig::MArrayOf` are deleted.
6. The verifier's V1–V7 invariants are extended (or re-proven sufficient) to cover the new in-place transformation.
7. CHANGELOG and README reflect the new model.

---

## 12. Final Note to the Research Agent

This is not a request to implement. This is a request to *survey, analyze, and propose*.

The user has lived with the surface-level discussion long enough to be confident in the *direction* (Roc-style opportunistic mutation, no `M*` escape hatches). What is missing — and what this brief is asking the agent to provide — is the *engineering depth* to know exactly how to build it: which sub-problems are easy, which are hard, where the academic prior art carries directly over and where Zap's specifics force divergence, and what the phased path of execution should look like.

The agent should be willing to recommend a *different* approach than the user has envisioned, *if* the research surfaces a better one. Roc-style opportunistic mutation is the assumed direction, but the agent should explicitly compare it to alternatives (Perceus reuse, Clojure-transients-with-static-binding, Swift-style CoW on the root only, etc.) and justify the recommendation.

Be concrete. Cite papers, link to code, name specific data structures. Avoid generalities.
