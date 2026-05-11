# Implementation Spec: Slab-Class ArcPool with Per-Slab Refcounting

**Status:** Open implementation task. The two research reports (`arcpool1.md`, `arcpool2.md`) disagree on the recommendation; this spec resolves the disagreement in favor of arcpool1's recommendation (slab allocator) for the reasons given below, and constitutes the contract the implementing agent must meet.

**Read first:** `docs/binarytrees-pool-page-return-research-brief.md` for the problem statement, Zap/Zig fork architecture, ARC runtime mechanics, and benchmark details. This spec assumes that context.

---

## 1. Why the slab allocator, not `collect_unused()`

The benchmark lifecycle for `binarytrees N=21`:

1. **Stretch phase:** allocate 4.2M Arc(Tree) cells, check, free all. `live → 0` momentarily.
2. **Long-lived phase:** allocate 2.1M cells. `live → 2.1M` for the rest of the run.
3. **Bands phase:** for each depth d ∈ {4,6,…,20}, repeatedly build & free a tree of 2^d−1 cells. Peak simultaneous live ≈ 2.1M (long-lived) + ~1M (current band tree at d=20) = ~3.1M.

The two reports agree on the facts. They disagree on Option A's reach:

| Option | Pool capacity peak | Predicted RSS | vs C (129 MB) |
|---|---|---|---|
| Status quo | 4.2M (stretch tree) | 193 MB | +64 MB |
| Option A: `collect_unused()` at stretch→long-lived boundary | 3.1M (band peak) | ~168 MB | +39 MB |
| Slab allocator with per-slab unmap | ~2.1M sustained, brief +1M during bands | ~143 MB | +14 MB |
| Slab allocator + 16-byte Inner (no padding) | ~2.1M sustained | ~135 MB | +6 MB |

The user's stated target is **under 140 MB**. Option A alone misses it by ~28 MB. The slab allocator hits it with margin. The residual ~14 MB is fundamental ARC overhead (4-byte header + alignment padding), not addressable without changing ARC semantics.

arcpool2 underestimated Option A's miss because it didn't model the band phase. arcpool1's analysis (§9, Part 4) is correct: free-list-over-arena pools structurally cannot return pages while any cell is live, and the band phase never has live==0.

mimalloc, snmalloc, SLUB, jemalloc, and TCMalloc all converge on per-slab live counts + eager-or-decayed unmap. This is the industrial consensus design. We adopt it.

---

## 2. Architecture

### 2.1 Slab layout

```
Slab (64 KiB, aligned to 64 KiB):
  ┌────────────────────────────────────────────────────────┐
  │ SlabHeader (≤ alignment(Inner) bytes, padded)          │
  │   - magic: u32           (verification, 0xA8C50A8)     │
  │   - live_count: u32      (live cells in this slab)     │
  │   - free_list_head: u32  (slot index, NULL_SLOT=0xFFFFFFFF)│
  │   - capacity: u32        (total slots in this slab)    │
  │   - prev: ?*Slab         (intrusive partial-slabs list)│
  │   - next: ?*Slab                                       │
  │   - owner: *ArcPoolBackend (back-pointer for free path) │
  │   - allocation_size: usize (for munmap)                │
  │   - allocation_base: [*]u8 (for munmap, pre-trim base) │
  ├────────────────────────────────────────────────────────┤
  │ Slot[0]: Inner OR FreeNode (when free)                 │
  │ Slot[1]: ...                                           │
  │ ...                                                    │
  │ Slot[N-1]                                              │
  └────────────────────────────────────────────────────────┘
```

`FreeNode` overlays the slot when free; it stores the next free slot's index. Slot size = `@max(@sizeOf(Inner), @sizeOf(FreeNode))` with `@alignOf(Inner)` alignment. For Arc(Tree).Inner (24 bytes, 8-aligned): slot=24 bytes; N = (65536 − header) / 24 ≈ 2725 slots.

### 2.2 Pool backend

```
ArcPoolBackend(comptime T):
  threadlocal var backend: Backend(T) = .empty

  Backend(T):
    active: ?*Slab          // current allocation target
    partial: ?*Slab         // intrusive list of slabs with free slots AND live_count > 0
    cached_empty: ?*Slab    // one cached empty slab to avoid mmap/munmap thrash
    live: u32               // total live cells across all slabs
    high_water: u32         // peak total live (for telemetry)
    stats: PoolStats        // existing instrumentation hook
```

### 2.3 Allocation algorithm

```
create() -> *Inner:
  if active != null and active.free_list_head != NULL_SLOT:
    pop slot from active.free_list, bump active.live_count
  elif active != null and (active.live_count < active.capacity):
    bump-allocate next slot from active, bump active.live_count
  elif partial != null:
    move partial head to active, retry
  elif cached_empty != null:
    move cached_empty to active, retry
  else:
    slab = mmap_aligned_slab()
    active = slab
    retry
  bump backend.live, update high_water, register stats once.
  return slot
```

### 2.4 Free algorithm

```
destroy(ptr):
  slab = slab_from_ptr(ptr)               // mask low 16 bits
  assert(slab.magic == SLAB_MAGIC)
  push slot index onto slab.free_list_head
  slab.live_count -= 1
  backend.live -= 1
  if slab.live_count == 0 and slab is not active:
    if cached_empty == null:
      // Hold one empty slab for reuse to avoid mmap/munmap thrash
      // on hot/cold oscillation.
      unlink from partial list
      cached_empty = slab
    else:
      // Already have a cached empty. Unmap this one.
      unlink from partial list
      munmap_slab(slab)
```

### 2.5 Aligned-mmap helper

On macOS/Linux, `posix.mmap` returns page-aligned memory but not arbitrarily aligned. To get 64 KiB alignment:

1. `mmap(NULL, 2 * slab_size, ...)` → over-allocate.
2. Compute `aligned_base = align_up(returned_addr, slab_size)`.
3. `munmap` the head (between `returned_addr` and `aligned_base`).
4. `munmap` the tail (after `aligned_base + slab_size`).
5. Result: exactly `slab_size` bytes at `aligned_base`, freed via `munmap(allocation_base, allocation_size)` — the slab header stores both `allocation_base` (potentially `returned_addr` if we want to be lazy about head trim) and `allocation_size`.

**Simpler alternative:** store the original `returned_addr` and full allocation in slab header. On unmap, free the full original allocation. This wastes 0–64 KiB per slab but eliminates the two extra munmap calls and the over-allocate/trim arithmetic. Pick this — it's simpler and the overhead is bounded.

For Apple Silicon (16 KiB pages): slab size = 65536 = 4 pages. Over-allocate to 131072 = 8 pages. The wasted head can be up to 48 KiB (3 pages). Mean waste ≈ 24 KiB per slab. For binarytrees N=21 at peak ~3.1M cells / 2725 slots = ~1137 slabs, that's ~27 MB of waste. **Not acceptable.** Do the head+tail trim.

### 2.6 Slot ↔ slab translation

Slabs are 64 KiB aligned, so `slab_base = ptr & ~0xFFFF`. Cast to `*SlabHeader`. Verify `header.magic == SLAB_MAGIC` in debug builds (cheap sanity check).

Slot index: `(ptr - slab_base - header_size) / slot_size`. Computed only on debug paths.

---

## 3. Concurrency model

**Phase 1 (this task):** pools remain thread-local per `(T, thread)`. No cross-thread allocation or free. Matches current `threadlocal var pool: Pool = .empty` semantics.

**Phase 2 (future, with BEAM):** lift to per-process pools, snmalloc-style remote-free message queue. **Out of scope for this task.**

**Thread-exit handling (latent bug today):** if a thread exits while its backend has live slabs, the slabs leak. The existing `MemoryPool`-based design has this same bug. Address as part of future BEAM work. Add a TODO comment but do not implement abandoned-segment reclaim now.

---

## 4. Soundness argument

- **Pointer identity preserved:** cells never move. Every `*Inner` pointer remains valid as long as `header.ref_count > 0`. ARC fast paths (retain/release) are unchanged.
- **Slab unmap precondition:** `slab.live_count == 0` is checked when each cell's release brings it to zero. By the time we unmap, no live cells in that slab exist — therefore no valid program state holds a pointer into it.
- **Active slab never unmapped:** the cached-empty + active separation guarantees the slab the next allocation will land in is never freed under us.
- **Cached empty reused before fresh mmap:** prevents `mmap`/`munmap` thrash when a workload oscillates around exactly one slab's worth of working set.
- **Existing arc_verifier (V1–V11) is unchanged:** the verifier reasons about Zap-level retain/release semantics; the allocator change is below that abstraction. All 999/999 tests stay green by construction. No new IR is emitted; no compile-time analysis is touched.

---

## 5. Implementation

### 5.1 File scope

**All changes in `/Users/bcardarella/projects/zap/src/runtime.zig`.**

No changes to:
- `src/arc_*.zig` (compiler passes)
- `src/zir_builder.zig`
- `src/ir.zig`
- `lib/*.zap`
- The Zig fork at `~/projects/zig`

The runtime change is invisible above the `allocAny` / `releaseAny` / `freeAny` ABI (`src/runtime.zig:1515-1650`).

### 5.2 Code structure within runtime.zig

Around the current `ArcPool(T)` (line 1485-1503), introduce:

1. **`const SLAB_SIZE: usize = 64 * 1024;`** plus `SLAB_ALIGN`, `SLAB_MASK`, `NULL_SLOT`.
2. **`fn SlabHeader(comptime Inner: type) type`** — generic header type computing slot layout at comptime.
3. **`fn ArcSlabPool(comptime T: type) type`** — replaces `ArcPool(T)`. Same `create()` / `destroy()` API.
4. **`mmapAlignedSlab(slab_size, slot_size, header_size) -> *SlabHeader`** — aligned-mmap helper.
5. **`unmapSlab(slab: *SlabHeader)`** — counterpart that unmaps the full original allocation.

The old `ArcPool` can be deleted once `ArcSlabPool` replaces it. Update line 1517 (`allocAny`) to call `ArcSlabPool(T).create()` and line 1593 / 1650 (`freeAny`, `destroyPreparedAny`) to call `ArcSlabPool(T).destroy()`.

### 5.3 Comptime considerations

- `@sizeOf(Inner)` and `@alignOf(Inner)` are comptime-known. The slot layout, header padding, and capacity per slab are all computed once per `T`.
- The slot type within the slab can be `[slot_size]u8` to keep the layout simple; `@ptrCast` between this and `*Inner` at create/destroy boundaries.
- `FreeNode = struct { next: u32 }` overlays the slot's first 4 bytes when free. Slot size must be `>= @sizeOf(FreeNode)`, which holds for any `Inner` with `ArcHeader` (4 bytes) as first field.

### 5.4 Avoiding the previous failure modes

The second attempt at this task died on a Zig identifier-shadowing bug at `src/runtime.zig:1799`:

```zig
const refcount_end = refcount_offset + candidate * @sizeOf(RefCount);  // line 1799
// ...
const refcount_end: usize = refcount_offset + slots_per_slab * @sizeOf(RefCount);  // line 1809
```

**Avoidance:** when introducing local constants inside nested loops or scopes, prefix with a scope-distinguishing word: `candidate_refcount_end`, `slot_count_refcount_end`, etc. Run `zig build test` BEFORE committing.

The first attempt died on parallel file writes. **Avoidance:** this is a single serial agent.

### 5.5 Verification

Before committing, run ALL of these in order. STOP and fix any failure before proceeding.

```bash
# 1. Compile cleanly
cd /Users/bcardarella/projects/zap
zig build 2>&1 | tail -5
# Must show: clean build, no errors.

# 2. Full test suite
zig build test --summary all 2>&1 | grep "tests passed"
# Must show: 999/999 tests passed (or higher if you added new tests).

# 3. Rebuild every benchmark, ensure none break
for bench in nbody mandelbrot binarytrees fannkuch-redux spectral-norm k-nucleotide; do
  cd ~/projects/lang-benches/$bench
  rm -rf zap-out .zap-cache
  /Users/bcardarella/projects/zap/zig-out/bin/zap build 2>&1 | tail -2
done
# Each must show "Compiling" without errors.

# 4. binarytrees N=10 smoke test (correctness)
cd ~/projects/lang-benches/binarytrees && ./zap-out/bin/binarytrees 10
# Must produce EXACTLY:
#   stretch tree of depth 11	 check: 4095
#   1024	 trees of depth 4	 check: 31744
#   256	 trees of depth 6	 check: 32512
#   64	 trees of depth 8	 check: 32704
#   16	 trees of depth 10	 check: 32752
#   long lived tree of depth 10	 check: 2047

# 5. binarytrees N=21 memory measurement
/usr/bin/time -l ./zap-out/bin/binarytrees 21
# Peak memory footprint must be UNDER 140 MB (was 193 MB).
# Wall time must not regress significantly (currently ~6.5s; allow up to +10%).

# 6. Smoke test other benchmarks to confirm no regressions
cd ~/projects/lang-benches/fannkuch-redux && /usr/bin/time -p ./zap-out/bin/fannkuch_redux 11
# Must complete and produce correct output.

cd ~/projects/lang-benches/spectral-norm && /usr/bin/time -p ./zap-out/bin/spectral_norm 2500
# Must complete; output line 1.274224153.

cd ~/projects/lang-benches/k-nucleotide && /usr/bin/time -p ./zap-out/bin/k_nucleotide < input.fasta > /dev/null
# Must complete in similar wall time (~0.5s, was 1.12s pre-hash-fix).
```

### 5.6 Tests to add

Add Zig unit tests in `runtime.zig` (mirroring the existing test pattern at the bottom of the file). Required tests:

1. **`slab pool: alloc/free returns same slab cell`** — verify slot reuse from free list.
2. **`slab pool: live_count tracks cells correctly`** — alloc N, free N/2, check live_count == N/2.
3. **`slab pool: unmaps empty slab when not active`** — fill two slabs, free all of slab #2, verify it's unmapped (or cached). Verify slab #1 still works.
4. **`slab pool: caches one empty slab to avoid mmap thrash`** — alloc-then-free in a loop, verify only one mmap occurs after warm-up.
5. **`slab pool: high_water tracks peak live`** — alloc K, free K, alloc K/2; high_water should be K.
6. **`slab pool: handles Arc(SmallType).Inner sizes correctly`** — test with `Inner` size = 8 bytes and 24 bytes both.
7. **`slab pool: aligned-mmap helper returns 64KiB-aligned slabs`** — direct test of the helper, verify `(addr & SLAB_MASK) == 0`.

### 5.7 Commit policy

**One atomic commit at the end.** No intermediate commits. The commit message must include:

- Summary: "feat(runtime): slab-class ArcPool with per-slab refcounting + eager unmap"
- The design choice and why (slab allocator vs Option A).
- The before/after measurements for binarytrees N=21 (peak RSS, wall time).
- Confirmation that all 999/999 (or more) tests pass.
- Reference to this spec.

---

## 6. Non-goals (defer)

The following are out of scope for this task. Do not attempt:

1. **Decay-based unmap.** Eager unmap (with one cached empty slab) is sufficient. Decay timers add complexity and a background thread, which Zap doesn't currently have infrastructure for.
2. **Cross-thread free / abandoned-segment reclaim.** Out of scope until BEAM concurrency lands.
3. **mremap-based slab resize.** mmap'd slabs are fixed size. If a slab fills up, allocate a new one. Resize is unnecessary.
4. **Compaction / cell migration.** Slabs hold cells by stable pointer; no migration. (Mesh-style is explicitly rejected by both research reports.)
5. **Compiler-driven phase detection.** Defer until research-level region inference matures (Tofte-Talpin lineage). Out of scope.
6. **Exposing `Arc.collect_unused()` as a Zap-level intrinsic.** The slab allocator subsumes this. No user-facing API change.
7. **Switching to `c_allocator` backing.** Slabs come directly from `posix.mmap`. malloc adds per-allocation overhead and contention.

If a non-goal becomes necessary during implementation, STOP and discuss before proceeding.

---

## 7. Expected outcome

**Acceptance criteria:**

- `zig build test --summary all`: ≥ 999/999 tests passing (≥ 999 + new slab tests).
- `binarytrees N=21` peak memory footprint: under 140 MB.
- `binarytrees N=21` wall time: within 10% of current (~6.5s).
- All other benchmarks unchanged.
- Single atomic commit on `main`.

**Likely outcome based on the analysis:**

- Peak RSS: ~135–145 MB (target met).
- Wall time: neutral or +/-5% (slab fast path is one extra branch vs MemoryPool; offset by better locality).
- Slab churn: minimal due to cached empty slab.

If peak RSS comes in HIGHER than 145 MB, the implementation has a bug. Common suspects: (a) head/tail trim not freeing the spare allocation (waste accumulating per-slab); (b) cached_empty not being reused; (c) slab header too large (eating into capacity). Investigate before committing.

---

## 8. References

- **arcpool1.md** — primary recommendation (slab allocator).
- **arcpool2.md** — alternative (Option A); rejected because it can't help during bands phase.
- **docs/binarytrees-pool-page-return-research-brief.md** — full problem context.
- **mimalloc paper / source** (MSR 2019; v3.2.6 rc1, 2026-01-08) — industrial reference for slab + page-purge design.
- **Zig stdlib `MemoryPool`** at `/Users/bcardarella/.asdf/installs/zig/0.16.0/lib/std/heap/memory_pool.zig` — what we're replacing.
- **`std.posix.mmap` / `munmap`** — backing primitives.
- **Linux kernel SLUB allocator** — closest open-source reference for per-slab-live-count design at scale.

---

## 9. The single most important rule

**Run `zig build test --summary all` BEFORE every commit.** A failing test suite is an automatic rollback. The previous attempt died because the compilation broke and no test was run; a single `zig build` would have caught the shadowing error immediately.

If the test suite fails: fix the failure, re-run, re-confirm. Only commit once green.
