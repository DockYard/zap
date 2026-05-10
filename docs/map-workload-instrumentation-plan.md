# Phase 0: Map Workload Instrumentation Plan

**Goal:** Empirically determine how Zap programs actually use `Map(K, V)` — specifically, the ratio of *working-dictionary* patterns to *persistent-versioning* patterns — so we can commit confidently to a representation choice (dense COW vs HAMT-with-make_mut).

**Out of scope:** Implementing the redesign. This plan is purely measurement. No representation changes. No API changes. The instrumentation is a build-flag-gated overlay on the existing HAMT implementation.

**Estimated effort:** 5–7 working days for one engineer.

---

## 1. The Decision Question

After this work completes, we should be able to answer one question with confidence:

> Across realistic Zap workloads, what fraction of `Map` instances are *ever* observed by more than one owner simultaneously, and of those, what fraction have their pre-clone version *mutated again* after sharing?

Specifically:
- **Working-dict map:** allocated, mutated, queried, eventually released. Refcount stays at 1 for its entire lifetime, OR goes above 1 only briefly during transient borrows that don't outlive the next mutation.
- **Persistent-versioned map:** at some point in its life, two or more derived versions exist concurrently AND the program continues to read/use earlier versions after newer derivatives are produced.

If the working-dict ratio is **≥80%**, dense COW is the correct default. If versioning is **≥30%** of map instances, HAMT-plus-make_mut is the safer choice. Anything in between needs nuanced design discussion (e.g., a small-map-dense / large-map-trie hybrid, or shipping both as separate types).

---

## 2. Definitions (Precise)

For the purposes of this measurement:

- **Map instance** = a single `Map.allocMap()` allocation. Each call produces one instance, identified by its allocation pointer.
- **Lineage** = the transitive set of map instances connected by any `put`/`delete`/`merge` operation. When `put(m1, k, v)` returns a new map `m2` (and shares HAMT nodes with `m1`), `m2` is in `m1`'s lineage.
- **Concurrent versions** = at any point in time, the count of map instances within a single lineage that have `strong_count > 0`.
- **Sharing event** = the first `retain` on a Map cell after its initial allocation that brings its refcount from 1 to 2.
- **Post-share mutation** = an operation (`put`/`delete`/`merge`) on a map that has previously had a sharing event, where the *result* of the operation produces a new derived map *and* the original is still live.

A map is classified at release time:
- **Class W (working-dict):** never had a sharing event, OR all sharing events were resolved (refcount returned to 1) before any further mutation.
- **Class V (versioned):** at some point had concurrent versions in its lineage with at least one post-share mutation observed.

---

## 3. What to Measure

### 3.1 Per-instance metrics (recorded on each Map allocation)

| Field | Type | Updated when |
| --- | --- | --- |
| `instance_id` | u64 | At `allocMap` (monotonic counter) |
| `lineage_id` | u64 | Inherited from parent on `put`/`delete`/`merge`; new lineage on initial `Map.new`/empty allocation |
| `parent_instance_id` | u64 (0 if root) | Set when allocation is the result of a `put`/`delete`/`merge` |
| `alloc_size` | u32 | Size at time of allocation (for non-root, the size of the *parent* at the time of mutation) |
| `creation_callsite_hash` | u64 | Hash of the IR call site that triggered this allocation (best-effort — use return address if no IR site available) |
| `puts` | u32 | Incremented on each `put` consuming this as input (whether or not result == this) |
| `deletes` | u32 | Same for `delete` |
| `merges` | u32 | Same for `merge` |
| `gets` | u32 | Same for `get`, `getStr`, `hasKey` |
| `size_at_release` | u32 | Final size when refcount hits 0 |
| `peak_strong_count` | u32 | Max value strong_count ever held |
| `had_share_event` | bool | True if peak_strong_count >= 2 |
| `had_post_share_mutation` | bool | True if any mutation occurred after `peak_strong_count` first reached >= 2 |
| `lifetime_ns` | u64 | Wall time between allocMap and release |
| `class_W_or_V` | enum | Computed at release time from the bools above |

### 3.2 Per-lineage metrics (aggregated at lineage's last-instance release)

| Field | Type | Notes |
| --- | --- | --- |
| `lineage_id` | u64 | |
| `instance_count` | u32 | Total Map instances generated through this lineage |
| `peak_concurrent_versions` | u32 | Max number of instances in this lineage simultaneously alive |
| `total_puts` | u32 | Sum across all instances |
| `total_node_clones` | u64 | Sum of HAMT nodes cloned across all puts (proxy for path-copy cost) |
| `had_branching` | bool | True if `peak_concurrent_versions >= 2` |
| `class` | enum | `W`, `V`, or `S` (single — only one instance ever existed) |

### 3.3 Workload-level rollups (printed on program exit)

- Total instances allocated.
- Distribution of `class_W_or_V` by count and by lifetime-weighted size.
- Distribution of `peak_concurrent_versions` (histogram: 1, 2, 3-5, 6-20, 21+).
- Distribution of `size_at_release` (histogram: 0, 1-7, 8-31, 32-127, 128-1023, 1024+).
- Distribution of `peak_strong_count` (histogram).
- Top 20 creation call sites by instance count.
- Top 20 creation call sites contributing class-V instances.
- Total wall time spent inside `Map` operations (rough — start/end timestamps around put/delete/merge/get).

---

## 4. Hook Sites in `runtime.zig`

All sites are inside `pub fn Map(comptime K: type, comptime V: type) type` (~line 3258).

| Hook | File:Line | Action |
| --- | --- | --- |
| Allocate instance + assign instance_id, lineage_id | `runtime.zig:3404` (`fn allocMap`) | Insert a per-instance record into the instrumentation table. |
| Cell retain → check share event | wherever `Map` cell ARC retain is emitted (search for `retain` call sites on `*const Self`) | Increment peak_strong_count; if transition 1→2 set `had_share_event=true` and stamp share-time |
| Cell release → finalize record | wherever `Map` cell ARC release/drop runs | Compute final size, classify W/V, emit instance record to ring buffer |
| `put` | `runtime.zig:4062` | Bump `puts` on input map; tag output with parent_instance_id and inherited lineage_id; if input had_share_event → mark output and `had_post_share_mutation` on input |
| `delete` | `runtime.zig:4139` | Same as `put` |
| `merge` | `runtime.zig:4263` | Same; both inputs get bumped; output's lineage = input_a's lineage |
| `get` / `getStr` / `hasKey` / `size` | `runtime.zig:4003+` | Increment `gets` |
| HAMT node clone (proxy for path-copy cost) | inside `put`/`delete` paths where new HamtNodes are allocated | Increment `total_node_clones` on the lineage |

**Implementation notes:**
- Counters are written from instrumentation hooks only; the existing fast paths read nothing from the instrumentation state.
- Use a thread-local instrumentation record stored beside the Map cell (Zap is single-threaded today — no atomics needed). Simplest layout: when `instrument-map=true` at build time, append the instrumentation fields to the cell header. When false, the Map struct layout is unchanged.
- The instrumentation table itself **must not use `Map`** to avoid recursive instrumentation. Use a `std.AutoHashMap` (Zig stdlib) or a plain `ArrayList` keyed by instance_id.

---

## 5. Build Integration

Add a `-Dinstrument-map=bool` build option in `build.zig` (default false):

```
const instrument_map = b.option(bool, "instrument-map",
    "Emit Map workload instrumentation data") orelse false;
```

When enabled:
- Define a build-time constant `pub const instrument_map = true;` available in `runtime.zig`.
- All hook code is gated by `if (instrument_map)` blocks (or `comptime` blocks where applicable). When false, the compiler eliminates all instrumentation.

**Verify zero-overhead when disabled** by running the existing benchmark suite with and without the flag at build time and confirming no measurable difference in `k-nucleotide` wall time between the two builds (with `-Dinstrument-map=false` and the default build). Difference should be <1% — if it's larger, something leaked into the hot path.

---

## 6. Output Format

On program exit (atexit handler or end-of-main), if instrumentation is enabled, write to `$ZAP_INSTRUMENT_OUT` (default `./map-instrumentation.json`):

```json
{
  "workload": "k-nucleotide",
  "binary": "/path/to/binary",
  "duration_ns": 3770000000,
  "summary": {
    "total_instances": 2891234,
    "total_lineages": 14723,
    "by_class": {
      "S": {"count": 1023849, "frac": 0.354},
      "W": {"count": 1782345, "frac": 0.617},
      "V": {"count": 85040, "frac": 0.029}
    },
    "by_lineage_class": {
      "S": 8123,
      "W": 6201,
      "V": 399
    },
    "size_histogram": {
      "0": 1023849,
      "1-7": 891234,
      "8-31": 723451,
      "32-127": 198345,
      "128-1023": 45782,
      "1024+": 8573
    },
    "peak_concurrent_versions_histogram": {
      "1": 14324,
      "2": 312,
      "3-5": 67,
      "6-20": 18,
      "21+": 2
    },
    "post_share_mutation_count": 85040,
    "total_node_clones": 18923451,
    "top_callsites_by_instance_count": [
      {"site": "lib/map.zap:put@3", "count": 1923451},
      ...
    ]
  }
}
```

The full per-instance log can be emitted as JSON-lines to a separate file (`./map-instrumentation.jsonl`) for offline analysis if needed; the summary above is what gets read by the decision script.

---

## 7. Workloads to Measure

Run the instrumented build against:

| Workload | Why | Command |
| --- | --- | --- |
| k-nucleotide | The motivating benchmark; tight `Map.put` loop | `~/projects/lang-benches/.../k-nucleotide.zap` |
| fannkuch-redux | Map-light; sanity baseline | (existing CLBG runner) |
| spectral-norm | Map-light; sanity baseline | (existing CLBG runner) |
| binary-trees | Allocator-heavy; mostly persistent trees, not maps | (existing CLBG runner) |
| Zap test suite | Realistic compiler / language workload | `zig build test` |
| zir-test integration suite | Macro-emitted code; possible doc-runner edge cases | filtered subset |
| doc-runner | Generates docs from `lib/*.zap` — uses Map for symbol tables | (existing tooling) |
| Self-build of stdlib | Zap compiling itself; symbol tables, env maps, scope chains | the build pipeline |
| Each `examples/*/` program | Smaller real-world flavor checks | `for d in examples/*/; do (cd $d && run); done` |

Record results separately per workload. Then aggregate, weighted by *total Map operations per workload* (so the test suite, which runs many small programs, doesn't dominate the signal).

---

## 8. Decision Criteria

After collecting and aggregating the data:

| Pattern in aggregated data | Recommended representation |
| --- | --- |
| Class W ≥ 80% AND Class V < 10% AND `peak_concurrent_versions=1` for ≥90% of lineages | **Dense COW.** Commit to it. |
| Class V ≥ 30% OR significant post-share mutation in long-lived lineages | **HAMT-plus-make_mut.** The current direction. |
| 10–30% Class V, dominated by *small* shared maps (<32 entries) | **Dense COW + chunked-COW fallback for large maps.** Compose Architecture B + C from the second research brief. |
| Bimodal: many tiny W maps + a few very large V maps | **Dense COW for default; opt-in `PersistentMap` type for the V cases.** Two types, deliberate choice at the library level. |

If the data is genuinely ambiguous, **default to dense COW.** The industrial signal (Roc, hashbrown, Abseil, F14, Boost, Go 1.24) is strong enough that the burden of proof falls on choosing HAMT, not on choosing dense.

---

## 9. Sequenced Steps

| Step | Description | Effort |
| --- | --- | --- |
| 0.1 | Add `-Dinstrument-map` build option + `comptime` flag in `runtime.zig` | 0.5 day |
| 0.2 | Append instrumentation fields to Map cell header (gated) + thread-local instrumentation table | 1 day |
| 0.3 | Add hooks: allocMap, retain/release, put, delete, merge, get | 1 day |
| 0.4 | Add lineage tracking (lineage_id propagation + per-lineage table) | 0.5 day |
| 0.5 | Add JSON exit-handler output | 0.5 day |
| 0.6 | Verify zero overhead when flag is false (benchmark with/without) | 0.5 day |
| 0.7 | Run all workloads, collect data files | 1 day |
| 0.8 | Write aggregator/analyzer script (Zap or shell+jq) | 0.5 day |
| 0.9 | Produce `docs/map-workload-findings.md` with the data, classification, and the recommended representation | 1 day |
| 0.10 | Remove or revert the instrumentation (keep behind the build flag — no need to delete code; just leave it dormant) | 0.5 day |

**Total: ~7 days.**

---

## 10. Done Criteria

- `-Dinstrument-map=true` produces a working build that emits a valid `map-instrumentation.json` for every workload run.
- `-Dinstrument-map=false` (default) produces a build with verified zero overhead vs current main.
- All workloads in §7 have been measured, with raw JSON files committed under `bench/map-instrumentation-data/`.
- `docs/map-workload-findings.md` exists, summarizes the data, classifies the workload, and recommends a specific representation with reasoning grounded in the numbers.
- The recommendation in `map-workload-findings.md` is precise enough to commit to without further research.

---

## 11. Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Instrumentation distorts behavior (timing, allocation patterns), making the workload numbers unrepresentative | Verify zero overhead at build flag false. For build-flag-true, focus on *ratios* and *call-site fingerprints*, which are robust to constant-factor slowdown |
| Test suite dominates the signal with tiny synthetic maps | Weight aggregation by total ops, not by instance count. Report per-workload separately before aggregating |
| Lineage tracking has bugs that misclassify W as V | Differential test: build a known-pure working-dict micro-benchmark and verify it reports 100% W. Build a known-versioned micro-benchmark and verify it reports V. |
| Recursive instrumentation if the analyzer uses Map | Use Zig's `std.AutoHashMap` for the instrumentation table — never `runtime.zig::Map` |
| Some workloads use Map indirectly through stdlib functions whose hot paths we don't see | The hooks are at the runtime level (allocMap, retain, release, put, delete, merge), so all uses go through them regardless of Zap-level call site |
| Real Zap programs are different from current programs because the language is young | Acknowledged. Use this measurement as the strongest evidence available *now*; commit to a representation but design the rollout (feature flag, side-by-side) so we can revisit if production patterns diverge |

---

## 12. After This Phase

Whichever representation the data points to, the next document is `docs/map-redesign-implementation-plan.md` — the unified plan combining:

1. The chosen `Map` representation (from this Phase 0 result).
2. Flat-buffer `List(T)` (the post-unification replacement for the former `Vector(T)` surface and the deleted `MArrayI64`/`MArrayF64` escape hatches).
3. Opportunistic-mutation IR work — V8 + V9 verifier extensions, owned/borrowed call-site rewriting, runtime rc-1 fast path.
4. List FBIP traversal reuse for stdlib `map`/`filter`/`reverse`.
5. `MArrayI64` / `MArrayF64` deletion and benchmark migration.

Phase 0 unblocks #1; #2-5 follow regardless of which representation #1 picks, though their phasing depends on the choice.
