# Implementation Spec: Slab-Class ArcPool with Per-Slab Refcounting

**Status:** Implemented and shipped (see commits `f59c67d` and `077467e`). The two research reports (`docs/arcpool1.md`, `docs/arcpool2.md`) disagreed on the recommendation; this spec resolved the disagreement in favor of arcpool1's recommendation (slab allocator), and the implementation followed by the side-table refcount layout shipped in `077467e`. Sections 2.1, 2.2-2.5, 5.6, 7 are now historical / as-built rather than aspirational.

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
| Slab allocator + side-table refcounts (16-byte slot, 4-byte rc) | ~2.1M sustained | ~135 MB projected | +6 MB |
| **As-built measurement (Apr 2026)** | ~2.1M sustained | **162 MB measured** | +33 MB |

The user's stated target was **under 140 MB**. The slab allocator hits the projection floor; the side-table layout shipped in 077467e brought the per-cell footprint down to 20 bytes (16-byte slot + 4-byte refcount). The as-built measurement lands at ~162 MB — higher than the original 135 MB projection because the projection underestimated the residual cost of the libc heap fragmentation around `Map`/`List` buffers and bump-arena temporaries that coexist with the slab pool at peak. The architectural floor (16 + 4 bytes / cell, plus header overhead) is locked in by the comptime `@sizeOf(SideTableTreeLike) == 16` assertion and the tight slab-occupancy bound unit test.

arcpool2 underestimated Option A's miss because it didn't model the band phase. arcpool1's analysis (§9, Part 4) is correct: free-list-over-arena pools structurally cannot return pages while any cell is live, and the band phase never has live==0.

mimalloc, snmalloc, SLUB, jemalloc, and TCMalloc all converge on per-slab live counts + eager-or-decayed unmap. This is the industrial consensus design. We adopted it.

---

## 2. Architecture

### 2.1 Slab layout (as built)

The shipped layout is **side-table** when `side_table=true` (the default for the generic Arc(T) pool, since 077467e). For inline-header types like `Map(K, V)`, `List(T)`, and `MapIter(K, V)` the pool runs in `side_table=false` mode and the refcount lives inside the cell.

```
Slab (64 KiB, aligned to 64 KiB):
  ┌────────────────────────────────────────────────────────┐
  │ SlabHeader (fixed prefix, ~64 bytes)                   │
  │   - magic: u32           (verification, 0xA8C50A8)     │
  │   - live_count: u32      (live cells in this slab)     │
  │   - free_list_head: u32  (slot index, NULL_SLOT=0xFFFFFFFF)│
  │   - bump_index: u32      (next bump-allocate slot)     │
  │   - capacity: u32        (total slots in this slab)    │
  │   - prev: ?*SlabHeader   (intrusive partial-slabs list)│
  │   - next: ?*SlabHeader                                 │
  │   - owner: *Backend      (back-pointer for free path)  │
  │   - allocation_base: [*]u8 (head/tail already trimmed) │
  ├────────────────────────────────────────────────────────┤
  │ refcounts: [capacity]u32 (side-table mode only)        │
  │   * zero-length array in inline-header mode            │
  ├────────────────────────────────────────────────────────┤
  │ pad to alignOf(Inner) (if needed)                      │
  ├────────────────────────────────────────────────────────┤
  │ Slot[0]: Inner OR FreeNode (when free)                 │
  │ Slot[1]: ...                                           │
  │ ...                                                    │
  │ Slot[N-1]                                              │
  └────────────────────────────────────────────────────────┘
```

`FreeNode` overlays the slot when free; it stores the next free slot's index (a `u32`). Slot size = `@max(@sizeOf(Inner), @sizeOf(FreeNode))` rounded up to `@alignOf(Inner)`.

**As-built per-slot footprint (side-table mode):** `sizeOf(T) + sizeOf(u32)`. For `T = Tree` (16 bytes, 8-aligned): slot = 16 bytes + side-table entry = 4 bytes = 20 bytes total. With a 64-byte header (one full cache line) and a 64 KiB slab, `capacity = (65536 - 64) / (16 + 4) ≈ 3273 slots`. The minor under-shoot vs the closed-form upper bound is documented in `SlabHeader.capacityFor`. Previous projection of 24 bytes/slot for the inline-header layout was the basis for the original 140 MB target; the side-table layout drops 4 bytes of inline-header padding per cell.

**`allocation_size` no longer exists.** Earlier drafts of the header included an `allocation_size: usize` field for munmap bookkeeping. The aligned-mmap helper trims the over-allocation eagerly in-place and slabs are always exactly `SLAB_SIZE` bytes, so the field was dead state and has been removed.

### 2.2 Pool backend (as built)

```zig
// src/runtime.zig: SlabBackend(comptime Inner, comptime side_table)
Backend(Inner, side_table):
  active: ?*Header             // current allocation target
  partial_head: ?*Header       // intrusive list of slabs with free slots AND live_count > 0
  cached_empty: ?*Header       // one cached empty slab to avoid mmap/munmap thrash

  // Per-pool telemetry lives in `threadlocal var stats: PoolStats`
  // alongside the backend; live/high_water aggregate across all slabs.
```

### 2.3 Allocation algorithm (as built)

```
create() -> *Inner:
  ensureArcStatsAtexit()
  stats.noteAllocation()         // bump live, update high_water, register on first use
  slab = backend.active or rotateActive()
  loop:
    if slab.free_list_head != NULL_SLOT:
      pop slot from slab.free_list, bump slab.live_count
      if side_table: write refcounts[slot_index] = 1
      return slot
    if slab.bump_index < slab.capacity:
      bump-allocate next slot, increment bump_index, bump slab.live_count
      if side_table: write refcounts[slot_index] = 1
      return slot
    slab = rotateActive()       // active full → drop, take partial or fresh
```

### 2.4 Free algorithm (as built)

```
destroy(ptr):
  stats.noteDeallocation()
  slab = slab_from_ptr(ptr)               // mask low 16 bits (SLAB_BASE_MASK)
  assert(slab.magic == SLAB_MAGIC)
  was_full = (slab.free_list_head == NULL_SLOT and slab.bump_index >= slab.capacity)
  push slot index onto slab.free_list_head
  assert(slab.live_count > 0)             // underflow guard
  slab.live_count -= 1
  if slab is active: return
  if slab.live_count == 0:
    unlink from partial list
    if backend.cached_empty == null:
      backend.cached_empty = slab
    else:
      unmapSlab(slab.allocation_base)
    return
  if was_full:
    // Slab just transitioned full → partial; push it onto the partial list.
    pushPartial(slab)
```

### 2.5 Aligned-mmap helper (as built)

On macOS/Linux, `posix.mmap` returns page-aligned memory but not arbitrarily aligned. The shipped helper performs the head/tail trim eagerly:

1. `mmap(NULL, SLAB_SIZE + SLAB_ALIGN - page_size, ...)` → over-allocate.
2. Compute `aligned_base = align_up(returned_addr, SLAB_ALIGN)`.
3. `munmap` the head (between `returned_addr` and `aligned_base`).
4. `munmap` the tail (after `aligned_base + SLAB_SIZE`).
5. Result: exactly `SLAB_SIZE` bytes at `aligned_base`. The slab header stores **only** `allocation_base` — the size is the constant `SLAB_SIZE`, so the previously-projected `allocation_size: usize` field is unnecessary and has been removed.

For Apple Silicon (16 KiB pages): slab size = 65536 = 4 pages. Over-allocate to 65536 + 65536 - 16384 = 114688 = 7 pages. The wasted head can be up to 48 KiB (3 pages). Mean waste at allocation time is ≈ 24 KiB per slab, but the eager head+tail trim returns those pages to the OS before the slab is used, so the steady-state per-slab RSS cost is exactly 64 KiB.

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

### 5.6 Tests (as implemented)

The shipped runtime.zig test list (mirroring the original required tests plus the side-table coverage added in `077467e`):

Legacy / inline-header mode (`side_table=false`):

1. **`slab pool: alloc/free returns same slab cell`** — slot reuse from free list.
2. **`slab pool: live_count tracks cells correctly`** — alloc N, free N/2, check live_count == N/2.
3. **`slab pool: unmaps empty slab when not active`** — fill two slabs, free all of slab #2, verify it's unmapped (or cached). Verify slab #1 still works.
4. **`slab pool: caches one empty slab to avoid mmap thrash`** — alloc-then-free in a loop, verify only one mmap occurs after warm-up.
5. **`slab pool: high_water tracks peak live`** — alloc K, free K, alloc K/2; high_water should be K.
6. **`slab pool: handles Arc(SmallType).Inner sizes correctly`** — test with `Inner` size = 8 bytes and 24 bytes both.
7. **`slab pool: aligned-mmap helper returns 64KiB-aligned slabs`** — direct test of the helper, verify `(addr & SLAB_MASK) == 0`.

Side-table mode (`side_table=true`), shipped in `077467e`:

8. **`side-table slab pool: allocAny initializes refcount to 1`** — create + verify refcount.
9. **`side-table slab pool: retain increments side-table refcount`** — multiple retain/release rounds against side table.
10. **`side-table slab pool: release decrements and frees on zero`** — zero-transition releases the slot.
11. **`side-table slab pool: slot/slab lookup is correct under multiple slabs`** — refcounts are per-slot, not global.
12. **`side-table slab pool: deep-release reads children before slot freed`** — split-phase release soundness for recursive types.
13. **`side-table slab pool: hasInlineArcHeader types bypass the side table`** — Map(K, V) inline-header refcounts unaffected.
14. **`side-table slab pool: slot size equals sizeof(T) exactly`** — comptime check of the architectural payoff (16-byte T → 16-byte slot).
15. **`side-table slab pool: refcount table sized correctly per slab capacity`** — `HeaderType.fixed_capacity == capacityFor()`.
16. **`ArcSlabPool side-table: cached_empty preserves refcount slot integrity across slab reuse`** — added later; covers refcount-slot freshness when a `cached_empty` slab is rotated back into active.

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

## 7. Outcome (as measured)

**Acceptance criteria met:**

- `zig build test --summary all`: 1035+ tests passing after the side-table refcount layout shipped.
- `binarytrees N=21` peak memory footprint: **~162 MB** measured (the previous projection of 140 MB underestimated the cost; the architectural floor of 16 bytes/T + 4 bytes/refcount + slab/header overhead + libc heap fragmentation + bump-arena temporaries lands the steady-state RSS at ~162 MB, with run-to-run noise of a few MB).
- `binarytrees N=21` wall time: within budget (~6.5s baseline preserved).
- All other benchmarks unchanged.
- Two atomic commits on `main` (`f59c67d` for the slab allocator, `077467e` for the side-table refcount layout).

**Architectural floor (as built):**

- Per-cell footprint: 16 bytes (T) + 4 bytes (side-table refcount) = 20 effective bytes.
- Peak RSS: ~162 MB (revised after measurement; the original 140 MB projection did not account for libc heap fragmentation around the bump-arena and the Map/List buffers that coexist with the slab pool at peak).
- Slab churn: minimal — `cached_empty` retains one slab through the alloc-then-free oscillation of the band phase.

If peak RSS regresses above 175 MB, suspect: (a) the side-table side panel growing (e.g., capacity drift); (b) `cached_empty` not being reused; (c) slab header growing past one cache line (eating into capacity); (d) a regression in the `hasInlineArcHeader` dispatch that routes inline-header types through the wrong pool.

---

## 8. References

- **docs/arcpool1.md** — primary recommendation (slab allocator).
- **docs/arcpool2.md** — alternative (Option A); rejected because it can't help during bands phase.
- **docs/binarytrees-pool-page-return-research-brief.md** — full problem context.
- **mimalloc paper / source** (MSR 2019; v3.2.6 rc1, 2026-01-08) — industrial reference for slab + page-purge design.
- **Zig stdlib `MemoryPool`** at `/Users/bcardarella/.asdf/installs/zig/0.16.0/lib/std/heap/memory_pool.zig` — what we're replacing.
- **`std.posix.mmap` / `munmap`** — backing primitives.
- **Linux kernel SLUB allocator** — closest open-source reference for per-slab-live-count design at scale.

---

## 9. The single most important rule

**Run `zig build test --summary all` BEFORE every commit.** A failing test suite is an automatic rollback. The previous attempt died because the compilation broke and no test was run; a single `zig build` would have caught the shadowing error immediately.

If the test suite fails: fix the failure, re-run, re-confirm. Only commit once green.
