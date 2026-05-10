# Zap `Map` Representation — Research Brief

**Audience:** A research agent with zero prior context on Zap. This brief is a follow-up to `docs/roc-style-opportunistic-mutation-research-brief.md` — read that document first for full background on Zap, the Zig fork, the ARC ownership IR, the persistent collections, and the Roc-style opportunistic mutation work plan. *This brief is narrower and more analytical.* It assumes the broader direction (pure surface, opportunistic mutation under consuming/owned IR contracts) is settled, and asks one focused architectural question.

**The question to research:** Should Zap's `Map(K, V)` remain a Hash Array Mapped Trie (HAMT) and gain *path-local `make_mut`* semantics for opportunistic mutation, *or* should it be redesigned as a **dense open-addressed hash table** (Swiss-table / Robin Hood / IndexMap-style) with whole-buffer copy-on-write?

This decision affects the rest of the opportunistic-mutation work plan. The current plan (from the first brief) assumes HAMT-plus-make_mut. If a dense representation is meaningfully better for Zap's actual workload mix, the plan should pivot before implementation begins.

---

## 1. Why This Question Exists

The first brief recommended path-local `make_mut` over Zap's existing HAMT-backed `Map`. That recommendation was made *given* the HAMT layout — it's the cleanest opportunistic-mutation strategy if you already have a HAMT. It did not seriously question whether the HAMT itself is the right starting point.

Two facts surfaced in subsequent discussion that make the HAMT assumption worth re-examining:

1. **Roc's `Dict` is not a HAMT.** Roc — the canonical "Roc-style opportunistic mutation" inspiration — uses an insertion-ordered dense hash table internally, similar to Rust's `IndexMap` or `unordered_dense`. The first brief glossed over this and treated Roc as a literal blueprint when it is in fact only a *semantic* one.
2. **The modern industry consensus has shifted to dense open-addressed hash tables.** Google's `absl::flat_hash_map` (Swiss table), Facebook's F14, Rust's `hashbrown` (Swiss table, became `std::collections::HashMap`), Boost's `unordered_flat_map`, etc. The HAMT is the rare bird in production hash-table use; it remains dominant only in *persistent* / *immutable-by-default* languages (Clojure, Scala, Haskell `Data.HashMap.Strict`).

The trade-off is roughly:

- **HAMT** wins on **structural sharing across versions**. If a program holds many versions of "almost the same map" simultaneously (undo stacks, immutable.js-style React props, reducer histories, persistent data-structure-as-database patterns), HAMT is *enormously* more memory-efficient and update-cheap-amortized.
- **Dense hash table** wins on **single-version throughput**. If a program treats `Map` as a working dictionary that gets built up, queried heavily, and eventually discarded — without holding multiple versions — dense is 5-30× faster on real workloads and uses less memory.

For **opportunistic mutation**, the rep choice cascades:

- HAMT + `make_mut` mutates one node per level of the trie path. Even fully unique, that's still O(log₃₂ n) cache lines touched per `put`. Better than allocating those nodes, but not as good as a single store.
- Dense + COW mutates **one slot** under unique ownership. That's the C-class speed Zap is aiming for in `k-nucleotide`. But under sharing, the *whole table* must be copied — which is catastrophic for large maps held by multiple owners.

So: opportunistic mutation might *not* close the k-nucleotide gap to C if `Map` stays HAMT, even with perfect path-local `make_mut`. The 32-way fanout of the HAMT means each level is a pointer chase. The user's `k-nucleotide` numbers will land somewhere between current (3.77 s) and C (60 ms), but probably closer to OCaml's 307 ms than to C's 60 ms.

This brief asks the agent to research and recommend the right answer.

---

## 2. The Two Primary Candidates (and a Third)

### Candidate A: HAMT + path-local `make_mut` (current direction)

**Layout:** the existing `Map(K, V)` from `runtime.zig` ~line 3258 — small flat-vector mode for tiny maps, 32-way bit-partitioned trie for larger maps. ARC-headered cells per node, allocated through per-type memory pools.

**Mutation strategy:**
- Owned `put` walks root → leaf. At each node, if `rc == 1`, mutate the bitmap/array in place and continue. If `rc > 1`, clone the node (Rust `Rc::make_mut` style), then continue.
- Unowned `put` always copies on the modified path (current persistent behavior).

**Pros:**
- Smallest delta from current code. The HAMT is already implemented, tested, and integrated with ARC.
- Preserves cheap "fork the map" semantics. Two callers can hold different versions of an "almost-the-same" map with structural sharing — the persistent-data-structure use case.
- Per-node mutation is cheap when ownership is unique on the path.

**Cons:**
- Per-`put` cost stays O(log₃₂ n) cache lines even under perfect uniqueness. For a `k-nucleotide` map with ~16M entries, that's ~5 levels = 5 cache misses per `put` minimum.
- Iteration is bad: walking a HAMT is pointer-chase-heavy, cache-unfriendly. Real measurements on Clojure / Scala persistent maps show 5-15× slower iteration than dense tables.
- Memory overhead per entry is high: each leaf cell carries an ARC header, plus interior nodes carry bitmap + 32-pointer arrays.

### Candidate B: Dense open-addressed hash table (Swiss / Robin Hood / IndexMap)

**Layout:** a single contiguous buffer of `(key, value)` slots plus a parallel "control" / metadata array. Open addressing for collision resolution. ARC header on the buffer (one header for the whole table, not per slot).

**Mutation strategy:**
- Owned `put` checks `rc == 1`. If unique: mutate one slot in place, possibly resize. If shared: copy the entire buffer first (COW), then mutate the copy.
- Unowned `put` always copies the entire buffer first. *This is the central concern.*

**Pros:**
- Per-`put` is O(1) cache lines under uniqueness. SIMD-accelerated probing (Swiss tables) makes lookups extremely fast.
- 1.5-3× lower memory overhead per entry vs HAMT.
- Iteration is sequential-buffer scan — cache-friendly.
- Maps Zap toward C-class `k-nucleotide` performance.

**Cons:**
- "Persistent versioning" use cases pay catastrophically: any `put` on a shared map copies the whole buffer (potentially MBs).
- Resize cost is amortized O(1) but worst-case O(n) — and resize blocks any structural-sharing optimization on that operation.
- More invasive change. Need to delete the existing HAMT code path, implement and tune a new collision strategy, audit the verifier for the new layout.

**Variants to research:**
- **Swiss table** (`absl::flat_hash_map`, `hashbrown`) — 16-byte SIMD groups, 7-bit hash signature in metadata. Best lookup performance.
- **Robin Hood hashing** — minimizes variance in probe distance. Good for high-load-factor workloads.
- **F14** (Facebook) — 14-way SIMD-grouped chaining.
- **Insertion-ordered (IndexMap, Roc Dict)** — separate insertion-order array + hash table over indices. Keeps stable iteration order. Pays a small overhead for the indirection.

### Candidate C: Hybrid / phase-shifting representation

**Layout:** dense hash table when uniquely owned and within a size bound; transitions to HAMT when the table is shared with another owner OR when size exceeds a threshold OR when held across an operation that requires cheap forking.

**Mutation strategy:**
- "Use the right tool for the right phase." Tight loops that build a map without sharing get dense semantics. Maps that get held by multiple owners or used in persistent-versioning patterns get HAMT semantics.

**Pros:**
- Theoretically best of both worlds.

**Cons:**
- Massive complexity. Two layouts mean two code paths through every operation, plus a transition.
- The transition cost itself is high (rebuild the structure). If transitions happen at the wrong time (e.g., share + put in a loop), the workload thrashes.
- It's not clear how the compiler decides when to transition — ahead-of-time profiling? Runtime heuristics? Per-call ownership info?

Most production systems that have tried hybrid layouts have backed away from them. Rust's `HashMap` is just dense (`hashbrown`); Roc's `Dict` is just dense; Clojure's `PersistentHashMap` is just HAMT. The agent should investigate whether there is any production system that has *successfully* shipped a hybrid representation, and if not, what to learn from the failures.

---

## 3. Sub-Questions the Agent Must Address

### 3.1 Workload analysis: what is `Map` actually used for in Zap?

The agent should analyze (by inspecting `lib/*.zap` and the test suite) how `Map` is actually used today:

- **Working-dict patterns** (build, mutate, query, discard): how prevalent? `k-nucleotide`'s counter-loop is the archetype.
- **Persistent-versioning patterns** (hold multiple versions, share across functions): how prevalent?
- **Read-heavy patterns** (build once, query many): does iteration order matter?
- **Tree-walk-with-accumulator patterns** (each recursive call gets a slightly modified map): how prevalent? This is the strongest argument for HAMT.

The agent should produce a concrete tally. Heuristic: if >70% of `Map` uses are working-dict, dense is the right answer. If versioning is common, HAMT is. The number is unlikely to be 50/50.

### 3.2 The "shared-map COW catastrophe" question

For dense representations: how bad is the worst case? Under what circumstances does a shared `Map` get `put` to it, and what's the size when that happens?

- If shared maps are typically small (e.g., config-style maps with <100 entries), whole-buffer COW is cheap and dense wins outright.
- If shared maps can grow unboundedly (e.g., a global symbol table that gets passed by-borrow into many phases), whole-buffer COW is catastrophic and HAMT wins.

Possible mitigations the agent should evaluate:
- **Chunked dense** — split the buffer into fixed-size chunks (e.g., 4 KiB pages), each with its own ARC header. COW-per-chunk on share. This blends dense's O(1) update with HAMT's structural sharing — a 2-level structure where the top level is a small array of chunk pointers.
- **Snapshot tags** — keep a generation counter on the buffer; on shared `put`, allocate a new buffer at the new generation but share with reads at the old generation. (This is harder than it sounds and rarely a clean win.)

### 3.3 Iteration order and stability

Several real-world API decisions hinge on whether iteration order is:
- Insertion order (`IndexMap`, Roc `Dict`, JavaScript `Map`, Python 3.7+ `dict`) — stable, useful, costs ~1 word per entry.
- Hash order (`hashbrown`, `absl`) — non-deterministic across resizes, fastest.
- Key-sort order (some `BTreeMap`-style) — not the question here.
- Trie-walk order (HAMT) — deterministic but not insertion order; users find this surprising.

Modern languages have largely converged on insertion order. Zap's `Map` currently has trie-walk order. The agent should investigate whether changing this would break existing Zap programs and whether Roc's choice (insertion-order) is the right model.

### 3.4 Memory pool and ARC header interaction

Zap's `runtime.zig` allocates HAMT nodes through `std.heap.MemoryPool(HamtNode)`, which is O(1) alloc/free and avoids fragmentation. Each cell is ARC-headered.

For a dense table:
- The buffer is one allocation, not pool-friendly (variable size).
- ARC is on the buffer, not per slot.
- Resize requires `realloc`-equivalent (allocate-larger, copy, free-old).

The agent should evaluate whether moving away from per-cell pool allocation is acceptable. The pool model is a real perf win for HAMT. For dense, it doesn't apply — but the buffer model has its own efficiency story (one alloc per map, not N).

### 3.5 Opportunistic mutation interaction (the central engineering question)

For HAMT-plus-`make_mut`:
- The runtime branch on `rc == 1` happens at *each level* of the trie walk. That's 5 branches per `put` for a million-entry map.
- Each branch has a chance of being mispredicted, especially in shared-map scenarios where some nodes are unique and others are not.
- Compiler can't always elide these branches even with perfect ownership info, because per-node sharing isn't visible to static analysis.

For dense + COW:
- The runtime branch happens *once* per `put` — at the buffer level.
- When uniqueness is statically provable (most tight loops by construction), the branch elides cleanly to a single store.
- When the map is shared, the COW happens once and *then* subsequent puts in the same scope are unique — so the cost amortizes well.

The agent should compute (or estimate from prior art) the actual per-`put` cost in each model under k-nucleotide-style workload. Specifically:
- Cycles per `put` in the inner loop assuming perfect L1-resident state.
- Cache misses per `put` assuming the map exceeds L2.
- Branch prediction outcomes.

### 3.6 Implementation cost

How much work is each option, given the existing Zap codebase?

- **HAMT-plus-make_mut**: extend existing `Map` with mutation paths. Estimate: 2-4 weeks. Builds on existing tested code.
- **Dense rewrite**: new `Map` implementation from scratch. Estimate: 4-8 weeks for a production-quality SwissTable port + integration with ARC + verifier extensions + porting all callers + benchmark validation. Probably +2 weeks for working through bugs and perf tuning.
- **Hybrid**: 8-16+ weeks, plus high uncertainty on whether it actually pays off.

The agent should weigh: is the extra ~3-5 weeks of dense-rewrite work worth ~10× speedup on `k-nucleotide`?

### 3.7 What if dense is right for `Map` but HAMT is right for `Vector`?

Reminder: this brief predates list unification. The broader plan originally involved giving `Vector(T)` a flat-buffer fast path so `MArrayI64` / `MArrayF64` could be deleted. That work is now represented by flat-buffer `List(T)`; the agent should consider whether the `Map` and `List` redesigns share infrastructure (buffer COW, ownership-aware ABI).

The cleanest end state might be: **all three core collections (`Map`, `List`, `Vector`) use dense/contiguous representations as their default, with HAMT-style structural sharing reserved only for very specialized "persistent-versioned" types** (e.g., a separate `PersistentMap` opt-in). The agent should evaluate whether this is the right end-state vision, or whether `Map` specifically should keep HAMT semantics by default for some reason `Vector` doesn't.

### 3.8 Hashing

Zap currently uses FNV-1a (per `runtime.zig` ~line 3200). Modern dense hash tables typically use:
- **SipHash** — DoS-resistant, slower.
- **AHash** — Rust default, fast, not DoS-resistant.
- **FxHash** — used by `rustc`, very fast, predictable.
- **WyHash / xxHash** — fast, good distribution.

Dense tables are more sensitive to hash quality than HAMTs (HAMT's wide fanout dilutes bad hashes; dense linear-probing amplifies them). The agent should research whether FNV-1a is good enough for a dense table and recommend a replacement if not.

---

## 4. Prior Art the Agent Must Survey

### Production hash tables to study

- **Google `absl::flat_hash_map`** — the original Swiss table. C++. Read the design doc and the source.
- **Rust `hashbrown`** — port of Swiss table to Rust. *In particular*, study how it handles refcounting in the `Rc::make_mut` pattern.
- **Facebook F14** — alternative SIMD-grouped chaining. Compare layout choices.
- **Boost `unordered_flat_map`** — recent (2022) addition, well-documented internals.
- **Rust `IndexMap`** — insertion-ordered dense table. Direct analog to Roc's `Dict`.
- **Roc `Dict`** — the closest semantic prior art. Investigate its source code if available; if not, infer from documentation and benchmarks.
- **Python `dict`** — open-addressed, insertion-ordered (since 3.7). The mass-deployment benchmark.

### Persistent hash maps to compare against

- **Clojure `PersistentHashMap`** — HAMT, the canonical reference. Well-documented.
- **Scala `immutable.HashMap`** — HAMT variant (CHAMP). Some interesting compaction wins over the basic HAMT.
- **Haskell `Data.HashMap.Strict`** — another HAMT. Performance characteristics published.
- **`im-rs`** (Rust) — HAMT in Rust, with some uniqueness optimizations applied. Direct prior art for what Zap is contemplating.

### Specifically for the make_mut / opportunistic mutation question

- **`Rc::make_mut` / `Arc::make_mut`** in the Rust stdlib — the canonical "clone-on-write under refcount" pattern.
- **`im-rs`'s mutability strategy** — how does it apply make_mut over an HAMT? What's its measured speedup on unique workloads?
- **Roc's reference-counting-with-reuse implementation** — the 2023 thesis cited in the first brief. Does Roc's dense `Dict` use any HAMT-style sharing, or is it pure COW?
- **Clojure transients on `PersistentHashMap`** — the edit-token model. Per-node bookkeeping. What does this teach about HAMT mutation?

### Key papers

- *Optimizing Hash-Array Mapped Tries for Fast and Lean Immutable JVM Collections* (Steindorfer, Vinju, OOPSLA 2015) — CHAMP, Scala's improved HAMT.
- *Designing a Fast, Efficient, Cache-friendly Hash Table, Step by Step* (Matt Kulukundis CppCon 2017) — Swiss table design talk.
- *F14: A 14-way Probing Hash Table* — Facebook engineering blog post.
- *Perceus: Garbage Free Reference Counting with Reuse* — already cited; relevant because reuse interacts with both layouts.

### Benchmarks to look for in the literature

- **k-nucleotide** is one of CLBG's classic hash-heavy benchmarks. Compare implementations across languages: C uses dense, Rust uses dense, Java uses HashMap (closed addressing), Clojure uses HAMT, Scala uses HAMT.
- **Microbench suites:** rust-hashbrown's bench suite, F14's bench suite, dotnet's hash benchmarks. These compare in-language hash table implementations head-to-head.

---

## 5. The Decision Criteria

The agent should produce a recommendation organized around these criteria:

1. **Expected k-nucleotide speedup.** Quantitative estimate per option.
2. **Worst-case behavior under sharing.** Specifically: what happens when a 1M-entry `Map` is `put` from a borrowed call site?
3. **Memory overhead.** Bytes per entry under each option, ignoring keys and values.
4. **Iteration cost and order.** Sequential scan vs trie walk; insertion order vs hash order vs trie order.
5. **Implementation effort.** Engineer-weeks for the production-quality implementation.
6. **Ecosystem ergonomics.** Is the iteration order surprising? Are there benchmarks where the design will look bad?
7. **Risk.** Probability of needing to redo the work. HAMT-plus-make_mut is lower risk; dense is higher upside.

The recommendation should pick *one* option as the primary recommendation, with explicit reasoning. It should *not* be "it depends" — if the workload analysis (sub-question 3.1) shows working-dict dominance, recommend dense; if persistent-versioning is significant, recommend HAMT-plus-make_mut.

---

## 6. Constraints From Zap's Design

These are non-negotiable. The recommendation must respect them.

- **Pure functional surface semantics.** Whichever representation wins, `Map.put(m, k, v)` must remain semantically pure: returns a new map; `m` is unchanged.
- **ARC-managed.** The `Map` cell carries an ARC header. Mutation under uniqueness is handled by the ownership IR and runtime, not by user code.
- **Single-threaded today.** Atomic refcounts not required. But the design should *not* preclude future cross-thread sharing — flag any choices that would.
- **No top-level types in Zap source.** All Zap-level definitions live inside `defmodule`/`pub struct`.
- **The Zig fork can be modified** but is not the default. Most of this work lives in `src/runtime.zig`, `src/ir.zig`, and the ownership passes.
- **The verifier's V1–V7 invariants (and the proposed V8/V9) must continue to hold.** Whichever representation wins must respect alias safety in the verifier.
- **Existing tests must pass.** Byte-exact output on benchmarks must be preserved.
- **`MArrayI64` / `MArrayF64` will be deleted regardless.** That requires `Vector` flat-buffer support, which is independent of the `Map` decision but related infrastructure-wise.

---

## 7. Deliverable Shape

The agent should produce a document organized as:

1. **Recommendation** — one option, picked clearly, with the reasoning.
2. **Workload analysis** — concrete tally of how `Map` is used in Zap source today (`lib/*.zap` and tests).
3. **Per-option deep dive** — for each of the three candidates:
   - Layout description.
   - Mutation strategy under owned/borrowed conventions.
   - Cycles/cache-misses per `put` estimate (rough numerical ranges from prior art).
   - Bytes-per-entry estimate.
   - Iteration cost.
   - Worst-case under sharing.
   - Implementation effort estimate.
4. **Prior art comparison table** — Roc Dict, Clojure PersistentHashMap, Rust hashbrown, im-rs, Swiss table, F14, IndexMap. Columns: representation, persistent semantics, mutation strategy, performance characteristics.
5. **Implementation plan for the recommended option** — replacing or enhancing the relevant section of the first brief's plan.
6. **Open questions for the user** — anything the agent cannot decide without product input.

---

## 8. Final Note

The first brief's recommendation (HAMT-plus-make_mut) is the *conservative* answer — it minimizes change. The dense answer is the *upside* answer — bigger speedup, bigger redesign. The hybrid answer is probably a trap.

The user is willing to commit to the more invasive option *if* the research shows the gains are real and the worst-case behavior under sharing is manageable. The user is *not* interested in a recommendation that hedges or recommends "implement both and switch dynamically" without a strong reason.

The agent should pick a side. The agent should also be willing to recommend the hybrid path *if* there is genuinely strong production prior art for it succeeding — but the assumption going in is that hybrid is a trap.

Be concrete. Cite production hash table sources. Include numbers (cycles, cache misses, memory) wherever possible — even rough estimates from published benchmarks are more useful than handwaving.
