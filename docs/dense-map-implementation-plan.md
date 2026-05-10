# Unified Implementation Plan — Dense Map / Flat Vector / Opportunistic Mutation

**Status note:** this plan predates list unification. The dense Map and
opportunistic-mutation substrate remain relevant, but the flat-buffer sequence
surface is now `List(T)`, not `Vector(T)`, and the `VectorI64`/`VectorF64`
aliases have been removed. Treat Vector references below as historical names
for the flat-buffer sequence work unless the text explicitly discusses Zig's
internal SIMD `@Vector` primitive.

**Reference briefs:**
- `docs/roc-style-opportunistic-mutation-research-brief.md` — broad direction
- `docs/zap-map-representation-research-brief.md` — narrow Map question
- `docs/map-workload-findings.md` — empirical evidence (recommendation: Dense COW)
- `docs/map-workload-instrumentation-plan.md` — Phase 0 substrate

**Goal:** replace the HAMT-backed `Map(K, V)` with a dense, insertion-ordered, open-addressed table; replace the ARC-managed `List(T)`-backed `Vector` (where it exists) with a flat-buffer Vector(T); add V8/V9 verifier invariants for opportunistic mutation; teach the codegen to emit refcount-aware in-place updates; delete `MArrayI64`/`MArrayF64`.

**Decisions locked in by the user:**
1. `MArrayI64`/`MArrayF64` are deleted.
2. Map delete is Roc-style **swap-remove** (O(1), insertion order disturbed only by the deletion itself).
3. **Hash function: wyhash** (latest production version). Layout: `ankerl::unordered_dense`-style.

---

## 1. Technical Decisions

### 1.1 Dense Map layout

Single-allocation buffer holding header, bucket array, and entries array contiguously. The `Map(K, V)` cell is a thin handle pointing to the buffer.

```
Buffer layout:
  [ ArcHeader ]
  [ Header { len: u32, capacity: u32, entry_cap: u32, hash_seed: u64 } ]
  [ buckets: [capacity]Bucket ]    // power-of-2, populated by Robin Hood probing
  [ entries: [entry_cap]Entry ]    // dense, insertion order

Bucket = packed struct {
  dist_and_fingerprint: u32,  // (dist << 8) | fingerprint
                              //   dist=0xFFFFFF means empty
                              //   fingerprint = high 8 bits of the hash
  entry_idx: u32,             // index into entries[]
}

Entry(K, V) = struct {
  hash: u64,    // cached for resize and probe
  key: K,
  value: V,
}
```

**Probe strategy:** Robin Hood with backshift on delete (per `ankerl::unordered_dense`). On insert, walk forward from the ideal bucket; if the existing bucket has smaller `dist_and_fingerprint`, swap into that slot and continue with the displaced bucket. On lookup, walk until either a match (hash + key equal) or a bucket with smaller `dist_and_fingerprint` (means the key is not present). On delete: backshift adjacent buckets until an empty or already-ideal bucket is reached.

**Load factor:** max 0.875 (7/8). Resize doubles capacity, rehashes everything. Initial capacity 8.

**Capacity is always a power of 2.** `bucket_mask = capacity - 1`. Slot index = `hash & bucket_mask`.

**Delete (swap-remove):**
1. Look up bucket holding the deleted key. Get `entry_idx`.
2. If `entry_idx != len - 1`, swap `entries[entry_idx]` with `entries[len - 1]`. Find the bucket that pointed to `len - 1` and update its `entry_idx` to `entry_idx`.
3. Decrement `len`.
4. Backshift buckets after the deleted bucket.

**Iteration order:** entries are walked `0..len` directly. This is the insertion order modulo the swap-remove on delete — consistent with Roc's `Dict.

**Empty map:** `len = 0`, `capacity = 0`, `entry_cap = 0`. No allocation. The cell pointer is null. `?*const Map(K,V) == null` is the empty map.

### 1.2 Hash function

**wyhash** (current production version, the same one `ankerl::unordered_dense` uses by default).

- Variable-length key path: full wyhash on the key bytes.
- Specializations:
  - `u64` / `i64` keys: single round of wyhash mixing on the 64-bit value.
  - `Atom` (interned u32): single round on the 32-bit atom id.
  - `String` ([]const u8): full wyhash on the bytes.
  - Other types: derive from key shape via `comptime` switch.
- **Random per-process seed.** A `Map` instantiation reads the seed once at init from a process-global threadlocal seed (set on first use, cryptographically-random source if available, fallback to time + PID). This gives DoS-resistance-by-default for adversarial-input scenarios without the user having to opt in. Each `Map` instance stores its seed in the buffer header so resize can rehash deterministically.

**Bucket fingerprint** = top 8 bits of the 64-bit hash. Stored in `dist_and_fingerprint`. Empty bucket sentinel = `dist_and_fingerprint == 0xFFFFFFFF`.

### 1.3 Flat Vector(T)

Same single-allocation pattern.

```
Buffer layout:
  [ ArcHeader ]
  [ Header { len: u32, capacity: u32 } ]
  [ data: [capacity]T ]
```

Operations:
- `Vector.new(initial_capacity, element)` — allocate, fill with `element`.
- `Vector.length(v) -> i64` — read `len`.
- `Vector.get(v, i) -> T` — bounds-check, read `data[i]`.
- `Vector.set(v, i, x) -> Vector(T)` — refcount-aware:
  - `rc == 1`: mutate `data[i] = x` in place, return same pointer.
  - `rc > 1`: clone whole buffer, mutate clone, return new pointer.
- `Vector.push(v, x)`, `Vector.pop(v)` — same refcount-aware pattern.
- `Vector.append(a, b)` — concatenate two vectors. Result reuses `a` if `rc(a) == 1` and `cap(a) >= len(a) + len(b)`.

### 1.4 Refcount-aware mutation (the rc-1 fast path)

Every mutating operation has the same shape:

```zig
fn mutate(buf: *Buffer, ...) *Buffer {
    if (buf.header.count() == 1) {
        // Unique owner: mutate in place, return same pointer
        return buf;  // possibly resized in place
    } else {
        // Shared: clone + mutate clone
        const clone = cloneBuffer(buf);
        // ... mutate clone ...
        return clone;
    }
}
```

This applies to: Map.put, Map.delete, Map.merge, Vector.set, Vector.push, Vector.pop, Vector.append.

The check is one load + compare + branch. Well-predicted in tight loops because in working-dict patterns the receiver is always uniquely owned.

### 1.5 V8 / V9 verifier invariants

Added to `src/arc_verifier.zig`'s invariant suite. Same enforcement style as V1–V7.

- **V8 (alias safety on owned update):** an instruction `result = mutate(receiver, ...)` may return the same pointer as `receiver` (i.e. `result == receiver`) only if `receiver` has `OwnershipClass.owned` and is dead on every successor path of the call site. Verified by running the existing liveness analysis; if `receiver` has any live use after the mutation site, the verifier rejects identity-return.

- **V9 (alias safety on borrowed update):** an instruction whose receiver is `OwnershipClass.borrowed` may not perform mutating side effects on storage reachable from `receiver`. Verified by checking that borrowed-receiver intrinsics are tagged `pure` or `read-only` in the IR opcode metadata; the dense-Map intrinsics that take owned receivers are tagged `owned-mutating` and may only appear on owned values.

V8 and V9 are checked on every IR function during `arc_verifier.run()`. Integrate alongside V1–V7's pass.

### 1.6 Codegen integration

The IR's `arc_param_convention.zig` already infers owned vs borrowed for every callee. The dense-Map intrinsics expose two variants for each mutator:

- `Map.put_owned(m, k, v)` — owned receiver, returns owned result. Applied at call sites where `m`'s last-use is the put.
- `Map.put_borrowed(m, k, v)` — borrowed receiver, returns owned result. Always allocates (no rc-1 fast path).

The IR rewriter chooses the variant per call site based on liveness. The runtime's owned variant has the rc-1 fast path; the borrowed variant always allocates.

Same split for delete, merge, Vector.set/push/pop/append.

---

## 2. Phasing

Six phases. Each phase has TDD (failing tests first), CLBG benchmark byte-exact validation, clean commit boundary.

### Phase 1: Dense Map runtime

**Files:**
- `src/runtime.zig` — replace `pub fn Map(K, V) type` body. Keep the public API (`new`, `put`, `delete`, `merge`, `get`, `getStr`, `hasKey`, `size`, `keys`, `values`, `next`, `retain`, `release`, etc.) so callers don't break.
- New `src/wyhash.zig` (or inlined into runtime.zig if small) — wyhash implementation.

**Sub-deliverables:**
- 1.1 wyhash implementation, with `u64`/`Atom`/`[]const u8` specializations. Tested with the wyhash reference test vectors.
- 1.2 Buffer layout and helpers: `bufferAlloc`, `bufferClone`, `bufferRelease`, `bucketAt`, `entryAt`. Tested with hand-constructed small maps.
- 1.3 Insert (Robin Hood with backshift), get, has_key. Tested via existing `lib/map.zap` tests.
- 1.4 Delete with swap-remove. Tested.
- 1.5 Resize on load-factor breach. Tested.
- 1.6 Refcount-aware put/delete/merge with rc-1 fast path. Tested.
- 1.7 Iteration via `keys`, `values`, `next` — walk entries directly. Tested.
- 1.8 ARC integration: `retain`, `release`, deep-release of K and V children when refcount hits zero. Tested via the existing `instrument_map=true` instrumentation hooks (which can stay — they still apply to the new layout).

**Verification gates:**
- `zig build test` green.
- All `test/zap/map_test.zap` test cases pass (Map's existing public API contract).
- k-nucleotide produces byte-exact output vs current main.
- The Phase 0 instrumentation, when run on the new Map, still reports class S for working-dict patterns (confirming the dense layout integrates cleanly with the classifier).

### Phase 2: Flat Vector(T)

**Files:**
- `src/runtime.zig` — `pub fn Vector(T) type` (currently a HAMT-backed persistent vector). Replace with the flat buffer.
- `lib/vector.zap` (if it exists) — verify public API still correct.

**Sub-deliverables:**
- 2.1 Buffer layout, alloc, clone, release.
- 2.2 `new`, `length`, `get` with bounds check.
- 2.3 `set` with rc-1 fast path.
- 2.4 `push`, `pop`, `append` with rc-1 fast path.
- 2.5 ARC integration with deep-release of T children.
- 2.6 Iteration.

**Verification gates:**
- `zig build test` green.
- fannkuch-redux and spectral-norm produce byte-exact output AND match current `MArray*` performance within 5%. (This is the gating measurement for the deletion in Phase 6.)

### Phase 3: V8 / V9 verifier extensions

**Files:**
- `src/arc_verifier.zig` — add V8 and V9 checks. Existing V1–V7 stay.
- `src/ir.zig` — add opcode metadata: `pure`, `read-only`, `owned-mutating` tags on the dense-Map and Vector intrinsics added in Phases 1–2.
- `src/arc_liveness.zig` — extend liveness analysis if needed to support V8's "dead on every successor path" check (the existing analysis likely already provides this).

**Sub-deliverables:**
- 3.1 IR opcode metadata.
- 3.2 V8 check: per-call-site liveness query, rejection on identity-return of live receiver.
- 3.3 V9 check: pure/read-only verification of borrowed-receiver intrinsics.
- 3.4 Tests in `src/arc_verifier.zig`'s test block: positive and negative cases for V8 and V9.

**Verification gates:**
- `zig build test` green.
- The verifier flags any incorrect lowering produced by Phase 4's codegen rewrites (so Phase 4 lands on a verified substrate).

### Phase 4: Codegen integration

**Files:**
- `src/zir_builder.zig` — emit owned vs borrowed variants of Map/List intrinsics based on call-site convention (already inferred by `arc_param_convention.zig`).
- `src/runtime.zig` — split each mutator into `_owned` and `_borrowed` variants where the IR consumes them.
- `lib/map.zap`, `lib/list.zap` — surface API stays the same; the user calls `Map.put` / `List.set` and the compiler picks the variant.

**Sub-deliverables:**
- 4.1 IR rewriter wiring: at every Map/List mutation call, emit the owned variant when receiver is dead-on-all-successors per liveness, else emit the borrowed variant.
- 4.2 Runtime owned/borrowed implementations exposed and named per the IR's intrinsic table.
- 4.3 Verifier (V8/V9) clears the rewritten code on every existing test program.

**Verification gates:**
- `zig build test` green.
- k-nucleotide hits the C-class performance target (<200 ms wall, <50 MiB RSS).
- **Do NOT run `zig build zir-test`. Ever. The user will run it themselves when ready.**

### Phase 5: List FBIP traversals

**Files:**
- `src/runtime.zig` — `List(T).map`, `List(T).filter`, `List(T).reverse`, and related traversal helpers build or reuse flat buffers when uniqueness makes that sound.
- `lib/list/enumerable.zap`, `lib/list.zap` — surface API unchanged.

**Sub-deliverables:**
- 5.1 `List.map` reuse: if input refcount is 1 and the result element type permits reuse, update the existing flat buffer in place. Else allocate a fresh buffer.
- 5.2 Same shape of analysis for `filter` and `reverse`, with fresh allocation when the output length or element type makes in-place reuse unsound.

**Verification gates:**
- `zig build test` green.
- No CLBG benchmarks regress (List operations may not be on the hot path of any current benchmark, so this is mostly a quality improvement).

### Phase 6: MArray deletion

**Files:**
- Deleted: `lib/marray_i64.zap`, `lib/marray_f64.zap`, `runtime.zig::MArrayOf` and aliases.
- Modified: fannkuch-redux and spectral-norm sources in `~/projects/lang-benches/zap/{fannkuch-redux,spectral-norm}/` — port to `Vector(i64)` / `Vector(f64)`.
- Modified: `src/ir.zig::isArcManagedTypeId` — drop the `marray_*` registrations.

**Sub-deliverables:**
- 6.1 Port fannkuch-redux to Vector(i64), verify byte-exact output.
- 6.2 Port spectral-norm to Vector(f64), verify byte-exact output.
- 6.3 Confirm performance parity (within 5% of current `MArray*` numbers).
- 6.4 Delete the `MArray*` types and their registrations.
- 6.5 Update any docs that reference `MArray*` (README, CLAUDE.md if applicable).

**Verification gates:**
- `zig build test` green.
- fannkuch-redux byte-exact output vs current main.
- spectral-norm byte-exact output vs current main.
- Both within 5% of current `MArray*` perf numbers.
- `grep -r "MArray" .` returns nothing in `src/`, `lib/`, `examples/`, `test/`.
- **Do NOT run `zig build zir-test`. Ever. The user will run it themselves when ready.**

---

## 3. Cross-Phase Invariants

These hold at every commit boundary, not just at the end:

- **`zig build test` green.** Default and `-Dinstrument-map=true` builds.
- **No new file size regressions** in user binaries beyond what's intrinsic to the redesign.
- **No new IR verifier rejections** in any existing test program.
- **No regression** in the Phase 0 instrumentation classifier output for existing workloads (working_dict stays 100% S, versioned stays >40% V).
- **CLBG benchmarks byte-exact** at every gate (k-nucleotide, fannkuch-redux, spectral-norm, binary-trees).
- **Commit hygiene**: one commit per sub-deliverable where reasonable; no half-finished states; commit messages explain why, not just what.

---

## 4. Iteration Discipline — NEVER Run zir-test

**HARD RULE: Claude and any subagent MUST NEVER run `zig build zir-test`.** Ever. Period.

Reason: zir-test takes 6+ minutes per invocation. Agents that run it iteratively (or even once "to be thorough") burn 20+ minutes per session. The user has explicitly forbidden it after multiple repeat offenses.

Verification within a phase uses ONLY:
- `zig build test` (fast — ~10 seconds)
- `bench/map-workloads/run-differential-tests.sh` (fast — ~30 seconds)
- Direct CLBG benchmark invocation: `~/projects/lang-benches/zap/k-nucleotide/zap-out/bin/k_nucleotide`, etc. (fast)

If a verification step seems to require `zig build zir-test`, the answer is: skip it. The user will run zir-test themselves when they're ready.

---

## 5. Risk Inventory

- **Risk**: dense Map breaks an existing test that relies on HAMT iteration order. **Mitigation**: review `test/zap/map_test.zap` and any other test that depends on iteration order; update assertions to expect insertion-order iteration (which is the new contract anyway, matching Roc).
- **Risk**: wyhash quality on Atom keys (interned u32) is bad for some adversarial inputs. **Mitigation**: per-process random seed eliminates this.
- **Risk**: rc-1 fast path is buggy and corrupts data when a mutation should have COW'd. **Mitigation**: V8/V9 verifier extensions catch the codegen-side mistakes; runtime asserts check `header.count()` is non-zero on every operation.
- **Risk**: Vector flat-buffer doesn't match `MArray*` perf on fannkuch-redux due to bounds-check overhead. **Mitigation**: bounds-checks are debug-only; in ReleaseFast they elide.
- **Risk**: V9 verification rejects existing legitimate IR patterns. **Mitigation**: V9 only fires on borrowed-receiver intrinsics that are tagged `owned-mutating`; existing non-Zap intrinsics are unaffected.

---

## 6. Approximate Scope

| Phase | Files modified | Lines of new code (rough) | Estimated effort |
| --- | --- | ---: | --- |
| 1: Dense Map | runtime.zig, wyhash.zig | ~1500 | 3 weeks |
| 2: Flat Vector | runtime.zig | ~500 | 1.5 weeks |
| 3: V8/V9 verifier | arc_verifier.zig, ir.zig, arc_liveness.zig | ~400 | 1.5 weeks |
| 4: Codegen | zir_builder.zig, runtime.zig | ~600 | 2 weeks |
| 5: List FBIP | runtime.zig | ~300 | 1.5 weeks |
| 6: MArray deletion | runtime.zig, lib/, lang-benches | ~50 (deletion + ports) | 1 week |
| **Total** | | ~3350 | ~10–11 weeks |

Less calendar time with stream parallelism: Phases 1+2 can run in parallel; Phase 5 is independent and can run any time; Phase 3 depends on 1+2; Phase 4 depends on 3; Phase 6 depends on 2.

---

## 7. Done Criteria for the Whole Plan

1. `zig build test` green with default and `-Dinstrument-map=true` flags.
2. CLBG benchmarks byte-exact:
   - k-nucleotide: <200 ms wall, <50 MiB RSS (C-class).
   - fannkuch-redux: within 5% of current `MArray*` perf.
   - spectral-norm: within 5% of current `MArray*` perf.
   - binary-trees: no regression.
3. No `MArrayI64` / `MArrayF64` references anywhere in the tree.
4. The Phase 0 instrumentation infrastructure still works on the new dense Map.
5. README and CLAUDE.md updated to reflect the new state if needed.

**zir-test is NOT a done criterion.** The user runs zir-test themselves on their own schedule. Subagents must never invoke it.
