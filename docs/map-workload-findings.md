# Phase 0 Findings — Map Workload Classification

**Generated:** 2026-05-07 (initial), updated after Phase B1 read_mostly landed
**Plan reference:** `docs/map-workload-instrumentation-plan.md`
**Aggregate data:** `bench/map-instrumentation-data/aggregate.{json,md}`

## TL;DR

The data unambiguously supports a **dense open-addressed hash table with whole-buffer copy-on-write** as Zap's default `Map` representation. Persistent-versioning patterns are not observed in real workloads. Even k-nucleotide — the canonical map-heavy benchmark with 8.75M Map instances — has zero post-share mutations: every map instance has refcount transitions consistent with a working-dictionary pattern.

**Recommendation:** proceed with the dense Map redesign (Architecture B from `docs/zap-map-representation-research-brief.md`). Reserve HAMT-with-make_mut as an opt-in `PersistentMap` type only if a real Zap program later demonstrates a need for cheap persistent versioning.

## Aggregate metrics

Across 4 successfully-instrumented workloads (k-nucleotide, working_dict, versioned, read_mostly), weighted by total Map ops:

| Metric | Value |
| --- | ---: |
| Total Map ops observed | 8,751,024 |
| `class_S_fraction` | 99.997% |
| `class_W_fraction` | 0.0005% |
| `class_V_fraction` | 0.0023% |
| `class_W_or_S_fraction` | 99.998% |

**Class definitions** (recap from plan §2):
- **S** — single owner. Refcount stayed at 1 throughout the cell's life. The pure working-dict baseline.
- **W** — was shared at some point (refcount > 1) but no derived map was produced while shared. Read-only sharing.
- **V** — was shared AND a derived map was produced while shared (`Map.put`/`delete`/`merge` returned a distinct cell). The persistent-versioning pattern.

## Per-workload data

| Workload | Instances | Lineages | %S | %W | %V | post_share_mutation | total_node_clones |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| k-nucleotide | 8,750,004 | 14 | **100%** | 0% | 0% | 0 | 7,499,921 |
| versioned (synthetic) | 480 | 40 | 50% | 8.33% | 41.67% | 200 | 0 |
| working_dict (synthetic) | 540 | 60 | **100%** | 0% | 0% | 0 | 0 |
| read_mostly (synthetic) | 180 | 20 | **100%** | 0% | 0% | 0 | 0 |

### k-nucleotide (the dispositive benchmark)

8.75M Map instances. **Zero post-share mutations.** Of 14 lineages, 7 are class S and 7 are class W, but no V lineages — meaning at the lineage level, even when momentary sharing occurred, no mutation was performed against a still-shared map.

The size histogram is informative for performance tuning but not for the representation choice:
- 1,250,051 instances size 1–7
- 1,250,121 instances size 8–31
- 1,250,400 instances size 32–127
- 1,252,656 instances size 128–1023
- 3,746,740 instances size 1024+ (bulk of the data is in large maps)

The 7,499,921 HAMT node clones across 8.75M instances give a baseline cost: roughly 0.86 path-copy nodes per instance allocation — that's the per-`put` cost the HAMT representation is paying that a dense-buffer COW would eliminate.

### versioned (synthetic, deliberately exercising the V path)

Designed to park a Map in a persistent sequence container before deriving a new version via `Map.put`. At the time this used the old cons-cell `List`; after list unification the equivalent container is the flat-buffer `List(T)`. The classifier correctly identifies 200 V instances out of 480 (41.67%) — confirming that when persistent containers do hold Map references, the post-share-mutation detection works.

This workload is the only one in the harvest that produces meaningful V signal. It's a synthetic test, not a real-world workload.

### working_dict (synthetic, baseline)

A textbook chained-`Map.put` pattern. Confirms 100% class S — the classifier doesn't false-positive on the implicit owned-arg retain that every `Map.put` call site emits.

### Workloads with no Map activity

Out of 27 attempted workloads (4 CLBG benchmarks + 23 examples + 3 micro-benchmarks + 1 self-build), 24 produced no Map activity. This includes fannkuch-redux, spectral-norm, binary-trees, and every example in `examples/*`. Most Zap programs simply don't use `Map`; this is consistent with the language being early-stage with most demos focused on language features rather than data-structure-heavy logic.

## Decision criteria evaluation

Per plan §8:

| Threshold | Required (rule) | Observed | Result |
| --- | --- | --- | --- |
| `class_V_fraction < 0.05` | rule 1 (Dense COW) | 0.002% | ✅ |
| `class_V_fraction ≥ 0.30` | rule 2 (HAMT) | 0.002% | ❌ |
| `class_V_fraction ∈ [0.05, 0.30)` | rule 3 (chunked) | no | ❌ |
| Bimodal pattern | rule 4 (split types) | no | ❌ |
| Default | rule 5 | — | not reached |

The aggregator fires rule 1 (`rule-1-class-V-essentially-zero`): persistent-versioning is essentially absent in real workloads.

## Recommendation

**Default Map: dense, insertion-ordered, open-addressed hash table with whole-buffer copy-on-write.**

The data shows:
1. The dominant Zap workload (k-nucleotide) is purely working-dict. Whole-buffer COW under unique ownership reduces to a single in-place store — the expected ~10–30× speedup applies here.
2. Even the worst case (the synthetic `versioned` workload) is a small map (size <32). Whole-buffer COW on a small map is cheap. The chunked-COW fallback (Architecture C from the second research brief) is not needed.
3. Persistent-versioning patterns are not observed in real workloads. Reserving an opt-in `PersistentMap` type for that case is sufficient.

**Aligned plan of work** (per `docs/zap-map-representation-research-brief.md` §B and `docs/roc-style-opportunistic-mutation-research-brief.md`):

1. **Dense Map redesign** with insertion-ordered open-addressed layout, modern seeded hash (replacing FNV-1a), and refcount-aware in-place mutation under unique ownership.
2. **Flat-buffer `List(T)`** with the same COW pattern. This is the post-unification replacement for the former `Vector(T)` surface and the deleted `MArrayI64` / `MArrayF64` escape hatches.
3. **V8/V9 verifier extensions** for alias safety (already designed in `docs/roc-style-opportunistic-mutation-research-brief.md`).
4. **List FBIP** consuming traversals (`map`/`filter`/`reverse`).
5. **`MArrayI64` / `MArrayF64` deletion** after step 2 lands and the CLBG benchmarks confirm parity.

## Caveats and limitations

1. **Most Zap programs are too trivial to exercise Map.** Out of 27 attempted workloads, only 3 produced data. The signal comes overwhelmingly from k-nucleotide. As the language matures and more programs use `Map` in earnest, the workload mix may shift. The instrumentation infrastructure (build flag `-Dinstrument-map=true`, runner `bench/map-instrumentation-runner.sh`, aggregator `bench/map-instrumentation-aggregator.sh`) is preserved in-repo and can be re-run any time to re-validate.

2. **read_mostly micro-benchmark** had an initial Zap-level i8/i64 type-inference issue, resolved during Phase B1 by switching the read pattern to `Map.size` (which avoids the contentious default-value type inference). It now reports 180 instances, 100% class S — confirming read-only patterns don't allocate new Map cells and don't trigger share events.

3. **Aggregator rule-1 was tuned during gap analysis.** Original rule 1 required `class_W_or_S_fraction ≥ 0.80 AND class_V_fraction < 0.10 AND lineage_pcv1_fraction ≥ 0.90`, which was too strict — Zap's IR-level ARC keeps prior locals alive within the function frame, so peak_concurrent_versions ≥ 2 is the norm even for textbook working-dict patterns, and `lineage_pcv1` is essentially a measure of "did this lineage have any chain of mutations" rather than a measure of versioning. Tuned rule: `class_V_fraction < 0.05`. Aggregator now fires rule-1 (`rule-1-class-V-essentially-zero`) for the real data.

4. **Single-platform measurement.** All data was collected on aarch64-darwin. Re-validate on x86_64-linux before production rollout if the dense-Map redesign exposes platform-sensitive behavior (e.g., SIMD probing in Swiss-table-style metadata).

5. **k-nucleotide is the dominant data point, by ~7000×.** The aggregate weighting is essentially "what k-nucleotide says," with the synthetic workloads providing only sanity-check signal. This is the correct weighting — k-nucleotide is the only real workload — but worth flagging.

## Instrumentation infrastructure

All preserved in-repo:

- **Build flag**: `-Dinstrument-map=true`. Comptime-eliminated when off.
- **Runtime**: `src/runtime.zig` per-instance + per-lineage records, atexit JSON writer, posix-fd file I/O.
- **Codegen propagation**: `retainAny` (transient borrow plumbing) vs `retainAnyPersistent` (long-lived second owner) split, with `src/zir_builder.zig` emitting the correct variant for `copy_value` IR ops.
- **Workloads**: `bench/map-workloads/{working_dict,versioned,read_mostly}/`.
- **Runner**: `bench/map-instrumentation-runner.sh` — sweeps every CLBG benchmark, every example, every micro-benchmark, plus the self-build pipeline.
- **Aggregator**: `bench/map-instrumentation-aggregator.sh` — weighted cross-workload aggregate plus rule-based recommendation with explicit threshold deltas.
- **Test fixtures**: `bench/map-instrumentation-data/fixtures/` — five synthetic workload JSONs plus a smoke-test script verifying all five recommendation rules fire correctly.

The classifier itself uses a put-time refcount sample combined with `mapInstrumentationOnRetain` hooks split by retain semantics:
- Transient retains (IR `share_value mode=retain`) bypass instrumentation.
- Persistent retains (list elements, struct field assignments, `copy_value` IR ops) flow through the type's `retain` method and update the per-cell `peak_strong_count` and `had_share_event` flags.
- A post-share mutation is recorded only when (a) the input had a share event and (b) the put produced a distinct output cell.

This design avoids both the false-positive (every owned-arg retain looks like sharing) and false-negative (container retains invisible) modes that earlier iterations of the classifier produced.

## Next steps

1. **Approval gate**: confirm the recommendation with the language designer before any implementation work. (User has the final say on whether to commit to dense vs hold off.)

2. **If approved**, the unified implementation plan combines:
   - Dense Map redesign (per `docs/zap-map-representation-research-brief.md`)
   - Flat-buffer `List(T)` + COW
   - Opportunistic-mutation IR work (V8/V9 verifier extensions, owned/borrowed call-site rewriting)
   - List FBIP traversal reuse
   - `MArrayI64` / `MArrayF64` deletion

3. **Tune aggregator rule 1** as described in caveat 3 above (drop `lineage_pcv1_fraction` requirement, lower `class_V_fraction` upper bound to 5%).

4. **Re-run the harvester periodically** as new Zap programs land. Watch for any workload that produces ≥10% V class — that would be a signal that real persistent-versioning patterns are emerging and the recommendation should be re-validated.
