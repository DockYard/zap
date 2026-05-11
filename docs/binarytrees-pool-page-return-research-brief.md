# Research Brief: Binarytrees `MemoryPool` Page-Return Mechanism

**Audience:** Deep research agent with **zero context** on Zap. Everything you need to do production-grade research on this problem is in this document. Read it end-to-end before formulating recommendations.

**Status:** Open problem. Active branch HEAD: `239d084` (path-sensitive `shouldMove` + earlier ARC fixes). 999/999 tests green. Two previous parallel attempts to solve this problem failed (one due to file-write races against sibling agents, one due to a Zig identifier-shadowing bug). This brief exists so the next attempt has full context.

---

## 1. What is Zap?

**Zap** is a general-purpose, functional, native-compiled programming language. Surface syntax is reminiscent of Elixir / Erlang (dot-call method chains, pattern-matched multi-clause functions, `|>` pipelines, `<>` string concat), but it is statically typed and compiles ahead-of-time to a native binary.

Key properties relevant to this brief:

- **Purely functional from the user's perspective.** `List.set(arr, idx, val)` returns a NEW logical list with one element changed; the language has no language-level mutability primitives. Optimizations like in-place update happen via uniqueness analysis when the compiler can prove no other observer holds a reference.
- **ARC-managed runtime.** Heap-allocated values (`List(T)`, `Map(K, V)`, recursive structs like `Tree`, etc.) are reference-counted. Each heap cell has an `ArcHeader` (a single atomic `u32` ref count). Retain/release happen at function boundaries; the compiler tracks ownership conventions (`.owned` vs `.borrowed` vs `.trivial`) per parameter.
- **Statically compiled.** Source code lives in `lib/*.zap` (standard library) and user `*.zap` files. The compiler lowers to **ZIR** (Zig's intermediate representation; see §3) and then to LLVM IR via the Zig fork's compiler.
- **Single project.** Repository at `/Users/bcardarella/projects/zap`. Compiler in `src/`, standard library in `lib/`.

## 2. What is the Zig fork?

Zap ships against a **fork of Zig 0.16.0** at `/Users/bcardarella/projects/zig` (branch: `zap-zir-library-0.16`). The fork exposes Zig's internal ZIR API as a C-ABI-callable library (`libzap_compiler.a`) that Zap's compiler links against. The standard upstream Zig has these internals private; the fork makes them public so Zap can emit ZIR directly without going through Zig source text.

Stock Zig 0.16.0 will not build Zap. Always use the fork at `~/projects/zig`. When the fork is updated, run `make` in that repo to rebuild `libzap_compiler.a`; then `zig build` in the Zap repo picks it up.

The fork is in scope for changes when Zap needs a primitive Zig doesn't expose. The runtime (`runtime.zig`) is shipped with every Zap binary and IS pure Zig — it's compiled against the fork like everything else, but its source lives in the Zap repo.

## 3. How they work together (compilation pipeline)

```
User .zap source
    ↓ (parse, type-check, monomorphize)
HIR (Zap-internal IR)
    ↓ (IR-builder pass)
IR (src/ir.zig — Zap's mid-level IR)
    ↓ (escape analysis, ARC ownership inference, drop insertion, materialization)
ZIR (Zig's intermediate representation, via libzap_compiler.a)
    ↓ (Sema in the Zig fork)
LLVM IR
    ↓ (LLVM backend)
Native binary
```

The Zig fork's `Compilation.create()` API produces a `Compilation` value from a chunk of ZIR. Zap calls it via a thin C-ABI shim. The Zig fork then runs Sema (Zig's type/comptime analyzer) over the ZIR, lowers to LLVM IR, and emits the binary.

Files in this brief reference `src/*.zig` (Zap compiler), `lib/*.zap` (Zap stdlib), and the Zig fork at `~/projects/zig`.

## 4. ARC Runtime: How memory is managed

**`runtime.zig`** ships in every Zap binary. It defines:

- `ArcHeader` (line 385): a 4-byte atomic `u32` refcount with `init()`, `retain()`, `release()`, `count()` methods. `release()` returns `true` when the caller is the last owner (and should free).
- `Arc(T)` (line 421): generic wrapper that pairs `ArcHeader` with a `T` value field. `Arc(T).Inner` is the heap-allocated struct: `{ header: ArcHeader, value: T }`. Total size = 4 bytes (header, aligned) + sizeof(T), rounded up to T's alignment.
- `ArcRuntime` namespace (line 1431): contains `allocAny(T, allocator, value) -> *T` (allocate + initialize an Arc cell), `retainAny(ptr)` / `releaseAny(allocator, ptr)` (refcount up/down on the value pointer using `@fieldParentPtr`), `freeAny(allocator, ptr)` (force-free without checking refcount), and the split-phase `prepareReleaseAny`/`destroyPreparedAny` for deep-release walks.

The compiler emits ZIR calls to these runtime helpers at every retain/release/alloc site. The verifier (`src/arc_verifier.zig`) checks that every retain has a matching release on every path.

### 4.1 The pool: `ArcPool(T)` (the focus of this brief)

```zig
fn ArcPool(comptime T: type) type {
    return struct {
        const Pool = std.heap.MemoryPool(Arc(T).Inner);
        threadlocal var pool: Pool = .empty;
        threadlocal var stats: PoolStats = .{ .name = "Arc(" ++ @typeName(T) ++ ")" };

        fn create() *Arc(T).Inner {
            ensureArcStatsAtexit();
            stats.noteAllocation();
            return pool.create(std.heap.page_allocator) catch
                @panic("ArcRuntime: ArcPool out of memory");
        }

        fn destroy(inner: *Arc(T).Inner) void {
            stats.noteDeallocation();
            pool.destroy(inner);
        }
    };
}
```

Source: `src/runtime.zig:1485-1503`.

**Design intent.** Each distinct `T` gets its own thread-local `MemoryPool(Arc(T).Inner)`. Allocation is a free-list pop; free is a free-list push. No malloc/free traffic on the hot path. The pool grows in page-sized chunks from `std.heap.page_allocator` (mmap on macOS/Linux) and lives for the entire process.

**`std.heap.MemoryPool(Item)`** (Zig stdlib at `/Users/bcardarella/.asdf/installs/zig/0.16.0/lib/std/heap/memory_pool.zig`):

```zig
pub const Extra(comptime Item, comptime opts) = struct {
    arena_state: ArenaAllocator.State,  // backing storage as page chunks
    free_list: ...,                      // free-list of destroyed cells

    pub fn create(pool: *Pool, allocator: Allocator) Allocator.Error!ItemPtr {
        const ptr = if (pool.free_list.popFirst()) |node|
            @ptrCast(node)
        else if (opts.growable)
            @ptrCast(try pool.allocNew(allocator))  // arena bump for new cell
        else
            return error.OutOfMemory;
        ptr.* = undefined;
        return ptr;
    }

    pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
        ptr.* = undefined;
        pool.free_list.prepend(@ptrCast(ptr));  // back into free list, page stays mapped
    }

    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;
    pub fn reset(pool: *Pool, allocator: Allocator, mode: ResetMode) bool {
        var arena = pool.arena_state.promote(allocator);
        defer pool.arena_state = arena.state;
        const reset_successful = arena.reset(mode);
        pool.free_list = .{};
        return reset_successful;
    }
};
```

`ResetMode` is `.free_all` (deinit and re-init — unmaps every chunk, returns pages to OS), `.retain_capacity` (free all but the largest chunk, keep it for reuse), or `.retain_with_limit: usize`.

**Critical: `MemoryPool` already supports `reset(.free_all)` which unmaps every chunk.** The question is just whether the runtime / user code calls it at safe points.

`ArcPool(T)` as written in `runtime.zig:1485` does NOT expose `reset()` — only `create()` and `destroy()`. The pool is process-lifetime; reset is never invoked.

### 4.2 Why per-type pools

Different `T` have different `sizeof(Arc(T).Inner)`. A single global pool can't serve all sizes without slot-class machinery. The per-type pool gives each `Arc(T)` a tight free-list of correctly-sized slots.

For binarytrees, the only ARC'd cell type is `Arc(Tree).Inner`. `Tree` is `pub struct Tree { left :: Tree | nil, right :: Tree | nil }` — two optional pointer-to-Tree fields. With Zap's indirect-storage ABI for recursive struct fields, `Tree` is laid out as `?*const Tree` × 2 = 16 bytes. Plus the 4-byte ArcHeader, rounded up to 8-byte alignment = 24 bytes per cell.

## 5. The binarytrees benchmark

Source: `/Users/bcardarella/projects/lang-benches/binarytrees/binarytrees.zap`. The benchmark is part of CLBG (Computer Language Benchmarks Game).

### 5.1 Algorithm

```
make(0) → leaf Tree{left: nil, right: nil}
make(d) → %Tree{left: make(d-1), right: make(d-1)}     # tree with 2^d - 1 nodes

check(nil) → 0
check(t :: Tree) → 1 + check(t.left) + check(t.right)  # sums 1 per node

main(args):
    max_depth = parse(args[0])  // e.g., 21
    min_depth = 4
    stretch_depth = max_depth + 1

    stretch = make(stretch_depth)             # ~4M nodes for N=21
    print(check(stretch))                     # consumes stretch (.owned param)

    long_lived = make(max_depth)              # ~2M nodes, persists

    for depth in min_depth..=max_depth step 2:
        iterations = 2^(max_depth - depth + min_depth)
        for i in 1..iterations:
            tempTree = make(depth)            # 2^depth - 1 nodes per iteration
            check += check(tempTree)          # consumes tempTree
        print(iterations, depth, check)

    print(check(long_lived))                  # consumes long_lived
```

For N=21:
- Stretch tree: depth 22, ~4 M nodes; built, checked, freed.
- Long-lived tree: depth 21, ~2 M nodes; lives until end.
- Bands at depths 4, 6, ..., 20: each band creates many short-lived trees.

### 5.2 Lifecycle of `Arc(Tree).Inner` cells

- **Stretch phase**: pool grows to ~4 M cells. Then `check(stretch)` consumes the tree and the deep-release walk frees all 4 M cells. They return to `pool.free_list` but the pages stay mapped. Pool capacity = ~4 M slots ≈ 4 M × 24 = 96 MB.
- **Long-lived phase**: 2 M new cells allocated. These come from the free-list (re-using stretch's slots), so no new pages. Capacity stays at ~4 M slots.
- **Bands phase**: each band's trees create up to 2^d - 1 cells, then immediately free them. Peak simultaneous live = long-lived (2 M) + current band's tree (~1 M for d=20). All come from free-list re-use. Capacity stays at ~4 M slots.

**The pool's high-water-mark is set by the stretch tree alone** (~4 M slots), even though peak simultaneous live during the rest of the program is ~3 M. The extra ~1 M slots × 24 = ~24 MB of unused capacity stays mapped.

### 5.3 Reference comparison

The C reference (`/Users/bcardarella/projects/lang-benches/binarytrees/binarytrees.c`) uses **plain `malloc`/`free` per node**, NOT Apache APR pools (an earlier diagnosis was wrong — confirm by reading the C source). C's `treeNode` is 16 bytes (2 pointers). malloc on macOS uses zone allocators with their own slab-style internal chunking. Each `free(tree)` returns the chunk slot to malloc's free list; macOS malloc has heuristics (`madvise(MADV_FREE_REUSABLE)`) to return unused pages to the OS when free-list pressure permits.

Peak RSS comparison at N=21:
- C: 129 MB
- Zap (current): 193 MB
- Gap: ~64 MB ≈ Zap's pool over-allocation + per-cell header overhead

Per-node memory:
- C: 16 bytes + malloc per-allocation header (typically 16 bytes) = 32 bytes effective.
- Zap: 24 bytes (Arc(Tree).Inner) + pool/chunk overhead. The chunk overhead is amortized but the high-water is set by the peak slot count, not average.

If Zap could release pool slots back to the OS between phases, its peak RSS would track the peak simultaneous live count instead of the all-time peak (stretch tree).

## 6. Where this problem came from

This brief is task #32 in a recent multi-day series of ARC and uniqueness fixes for the lang-benches suite. The work to date (HEAD at `239d084`):

| Benchmark | Before | After | C ref | Status |
|---|---|---|---|---|
| nbody | 1 MB | 1 MB | 1 MB | tied; Zap beats C on time |
| mandelbrot | 1 MB | 1 MB | 1 MB | tied |
| binarytrees | 7.1 GB | 193 MB | 129 MB | **1.5×, this brief** |
| fannkuch-redux | 13.8 GB | 1 MB | 1 MB | tied |
| spectral-norm | 2.1 GB | 1 MB | 1 MB | tied; Zap beats C on time |
| k-nucleotide | 4.0 GB | 59 MB | 26 MB | 2.3×, separate brief |

The remaining gap on binarytrees is precisely the pool retention. Every leak / retain-release imbalance / over-conservative analysis path has been eliminated. The 64 MB delta is purely "the pool peaked at 4 M slots and never gave back the unused slots."

## 7. The constraints

Read these carefully. Any solution that violates them is unacceptable.

1. **NO workarounds.** Production-grade architectural fix only. No hacks, no temp solutions, no "good enough for the benchmark." If the right answer is invasive, do the invasive thing.
2. **Functional semantics preserved.** No new language-level mutability primitives. `make`/`check` in user code stays purely functional. Optimization happens entirely under the runtime/compiler.
3. **999/999 test suite must remain green.** Run `zig build test --summary all` BEFORE committing. Failing tests are a hard rejection.
4. **No regression on other benchmarks.** nbody, mandelbrot, fannkuch, spectral-norm, k-nucleotide must continue passing and not regress more than measurement noise (~5%).
5. **Verifier (`arc_verifier.zig`) must continue to accept all valid programs.** V1-V11 are static ARC invariant checks; any change to the pool's contract that breaks them is wrong.
6. **Soundness is non-negotiable.** If `reset()` is exposed to user code (directly or via a Zap-level intrinsic), it MUST be sound — calling it when live cells exist is a use-after-free of those cells. Either prove statically that no live cells exist at the call site, or have `reset()` assert (panic) when called with live cells.
7. **Zig stdlib's `MemoryPool` already supports `reset(.free_all)`.** Don't reimplement what's already there. The fix is plumbing, not implementation.

## 8. What was tried

### 8.1 First parallel-agent attempt (failed)

Three subagents launched in parallel:
- k-nucleotide hash optimization (touches `runtime.zig` `DenseMap`)
- k-nucleotide arena fix (touches `runtime.zig` `bumpAlloc`/`runtime_arena`)
- **binarytrees pool fix** (touches `runtime.zig` `ArcPool` / `MemoryPool`)

All three wrote to `runtime.zig` concurrently. The binarytrees agent's write happened before another agent's overlapping write; the later agent's write clobbered the earlier work. Symptom: agent reported "The file shrunk back to 11472 lines (was 12200+). Something reverted my changes!" The agent then stalled (no progress for 600s) and was killed by the watchdog.

**Lesson:** parallel agents must not write to the same file. Either serialize, or use `isolation: "worktree"` to give each agent a separate worktree.

### 8.2 Second attempt (failed)

Single serial agent. Made 752 lines of changes including a slab-based pool with per-slab refcounting. Compiled with a Zig identifier-shadowing error:

```
src/runtime.zig:1799:23: error: local constant shadows declaration of 'refcount_end'
                const refcount_end = refcount_offset + candidate * @sizeOf(RefCount);
                      ^~~~~~~~~~~~
src/runtime.zig:1809:9: note: declared here
        const refcount_end: usize = refcount_offset + slots_per_slab * @sizeOf(RefCount);
```

The agent's API call errored before it could fix the shadowing. The work was rolled back to `239d084`.

**Lesson:** the agent attempted option (C) from §9 below (slab-based pool with per-slab refcounting). It's the most complex option. The error itself is trivial — rename the inner constant — but the agent didn't complete the implementation.

## 9. Options to consider

Each option below has been pre-scored on (a) invasiveness, (b) soundness risk, (c) expected memory win, (d) expected runtime impact. These are starting points; the deep research agent should verify them against the actual data and pick the right one.

### Option A: Add a `reset()` method to `ArcPool(T)`, expose via Zap-level intrinsic

**Sketch:**
- Add `fn reset() void` to `ArcPool(T)` that calls `pool.reset(std.heap.page_allocator, .free_all)` if `stats.live == 0`, else panics or no-ops.
- Add a Zap-level intrinsic `:zig.Arc.collect_unused/0` (or `Arc.reset_pools/0`) that walks every registered `pool_stats_head` and calls `reset()` on pools with `stats.live == 0`.
- Benchmark calls `Arc.collect_unused()` between phases (after stretch is freed, between bands).

**Soundness:** trivially safe because the `live == 0` guard ensures no live cells.
**Invasiveness:** small. Add the runtime intrinsic, the Zap-level binding, document.
**Memory win:** ~64 MB on binarytrees (returns the stretch tree's slot pages to OS).
**Runtime impact:** zero on hot path. One bulk-unmap call per phase boundary.
**Caveat:** Requires user code to call the intrinsic. Acceptable as long as the intrinsic is documented and discoverable.

### Option B: Switch ArcPool's backing allocator from `page_allocator` to `c_allocator`

**Sketch:**
- Change `pool.create(std.heap.page_allocator)` → `pool.create(std.heap.c_allocator)` (line 1494) and `pool.destroy` similarly.
- Rely on libc malloc to return freed pages to OS via `madvise(MADV_FREE)` heuristics.

**Soundness:** trivially safe — no semantic change.
**Invasiveness:** one-line change.
**Memory win:** uncertain. macOS malloc has good page-return behavior but only under memory pressure. Likely sub-30 MB win on binarytrees.
**Runtime impact:** malloc has more per-call overhead than page_allocator (libc lock, slab routing). Probably a 5-10% slowdown on the hot path. Not acceptable if it pushes binarytrees above C's runtime (currently 6.5s vs C's 7.7s).
**Caveat:** Adds malloc lock contention if Zap ever goes multithreaded.

### Option C: Slab-based pool with per-slab refcounting

**Sketch:**
- Replace `std.heap.MemoryPool` with a custom slab allocator. Slabs are page-sized; each slab tracks its live cell count.
- On `create`: find a slab with free space, bump its live counter, bump-allocate the cell within it.
- On `destroy`: decrement the slab's live counter. If it reaches zero, unmap the slab.

**Soundness:** correct if implemented correctly. Tracking per-slab live counts is straightforward but the code is non-trivial.
**Invasiveness:** large. Replaces the Zig stdlib's MemoryPool with custom code.
**Memory win:** ~64 MB on binarytrees, and pages return continuously (not just at phase boundaries).
**Runtime impact:** custom code is risky for perf. The free-list pop in MemoryPool is one pointer load; in a slab allocator, slab selection has more branches.
**Caveat:** This was the failed attempt's approach. Complex to get right. If the deep research agent picks this, write tests covering the slab-empty-unmap path explicitly.

### Option D: Compiler-driven phase detection

**Sketch:**
- The Zap compiler analyzes the user program for "natural phase boundaries" — points where local variables holding ARC cells are dead and no live cells remain in any pool.
- At such points, the compiler emits `:zig.Arc.collect_unused()` automatically.
- For binarytrees, the boundary is the line between `check(stretch)` and `long_lived = make(max_depth)`.

**Soundness:** depends on the analysis. Hard to prove "no live cells anywhere in any pool" without escape analysis across module boundaries.
**Invasiveness:** large. New compiler pass.
**Memory win:** ~64 MB, same as A.
**Runtime impact:** zero on hot path.
**Caveat:** Probably overkill. Option A's manual call is more honest about the lifetime semantics.

### Option E: Reference-counted pool chunks (similar to C but for chunks, not cells)

**Sketch:**
- Each MemoryPool chunk has a refcount of how many live cells it contains.
- When a cell is destroyed, the chunk's refcount decrements. When it hits zero, the chunk is unmapped.
- Cells in the same chunk share a header pointing to the chunk.

**Soundness:** correct if implemented correctly.
**Invasiveness:** similar to (C); reimplements MemoryPool.
**Memory win:** continuous page return (like C).
**Runtime impact:** extra atomic on every cell destroy.
**Caveat:** Similar concerns as (C).

## 10. Recommended approach

**Start with Option A.** It's the smallest sound change with the biggest expected win. The `:zig.Arc.collect_unused/0` intrinsic is a real production primitive — many runtime systems (Roc, OCaml, Lean 4) expose similar "compact pool" / "gc.compact" entry points. Users who care about RSS in long-running phases can call it; users who don't pay nothing.

**If Option A is rejected for any reason**, fall back to Option B (switch to c_allocator). It's lower-risk than C/E and benchmarks will tell whether the malloc overhead is acceptable.

**Do not pick Option C or E unless A and B are both ruled out.** The complexity isn't justified.

## 11. Implementation plan for Option A

1. **Read the current ArcPool source** (`runtime.zig:1485-1503`). Understand the `threadlocal var pool: Pool = .empty;` declaration and the registration via `PoolStats`.

2. **Add `fn reset() void`** to `ArcPool(T)`:
   ```zig
   fn reset() void {
       if (stats.live != 0) {
           @panic("ArcPool.reset called while cells are live");
       }
       _ = pool.reset(std.heap.page_allocator, .free_all);
       stats.high_water = 0;  // optional: also reset the high-water mark
   }
   ```

3. **Expose via a runtime entry point** — a non-generic function callable from ZIR. The compiler doesn't know `T` for every Arc'd type at any single call site. Solution: register every `ArcPool(T)`'s `reset` in a list and walk it. This is similar to `pool_stats_head` (line 579):

   ```zig
   const ResetFn = *const fn () void;
   var pool_reset_head: ?*PoolResetEntry = null;
   const PoolResetEntry = struct {
       reset_fn: ResetFn,
       next: ?*PoolResetEntry,
   };

   fn registerPoolReset(entry: *PoolResetEntry) void { ... }

   pub fn collectUnusedArcPools() void {
       var cursor = pool_reset_head;
       while (cursor) |entry| : (cursor = entry.next) {
           entry.reset_fn();
       }
   }
   ```

   Each `ArcPool(T)` registers its `reset` on first allocation, parallel to `PoolStats` registration.

4. **Add a Zap-level intrinsic.** Two options:
   - **Direct ZIR call:** add `:zig.Arc.collect_unused` mapping to `collectUnusedArcPools` via `zir_builder.zig`'s `mapBridgeMethodToHelper` (similar pattern as `Map.get` → `mapGet`).
   - **Stdlib helper:** add `pub fn collect_unused() -> Nil` to `lib/arc.zap` (new file) or `lib/system.zap` calling `:zig.Arc.collect_unused`.

5. **Call from `binarytrees.zap`** between phases:
   ```zap
   stretch_check = Binarytrees.check(Binarytrees.make(stretch_depth))
   IO.puts("stretch tree of depth " <> ... <> Integer.to_string(stretch_check))
   _ = :zig.Arc.collect_unused()   # ← here

   long_lived = Binarytrees.make(max_depth)
   ...
   ```
   And optionally between band iterations.

6. **Verify:**
   - `zig build test --summary all` — 999/999 green.
   - Rebuild binarytrees: `cd ~/projects/lang-benches/binarytrees && rm -rf zap-out .zap-cache && /Users/bcardarella/projects/zap/zig-out/bin/zap build`.
   - Smoke test N=10: `./zap-out/bin/binarytrees 10` — output must match expected (check values 31744, 32512, 32704, 32752, 2047).
   - Memory measurement at N=21: `/usr/bin/time -l ./zap-out/bin/binarytrees 21` — peak RSS under 140 MB.
   - Wall time at N=21 must not regress (currently 6.5s).

7. **Commit ONLY ONCE** at the end. Run tests immediately before commit. Atomic commit with everything.

## 12. Key files

- `/Users/bcardarella/projects/zap/src/runtime.zig`:
  - Lines 385-419: `ArcHeader`.
  - Lines 421-464: `Arc(T)` (generic, not directly used — Zap uses inline-header types and `Arc(T).Inner` via `ArcPool`).
  - Lines 559-594: `PoolStats` and `pool_stats_head` (the existing registration pattern to mirror).
  - Lines 1431-1650: `ArcRuntime` namespace.
  - **Lines 1485-1503: `ArcPool(T)`** — the focus of this work.
  - Lines 1515-1523: `allocAny` — the ZIR-call site that allocates via `ArcPool`.
  - Lines 1647-1650: `destroyPreparedAny` — the ZIR-call site that returns cells to the pool.
- `/Users/bcardarella/projects/zap/src/zir_builder.zig`:
  - Search `mapBridgeMethodToHelper` for the pattern that maps Zap method names to runtime helpers.
- `/Users/bcardarella/projects/zap/lib/`:
  - `system.zap` or new `arc.zap` for the Zap-level `:zig.Arc.collect_unused` binding (if going through the stdlib).
- `/Users/bcardarella/projects/lang-benches/binarytrees/binarytrees.zap`:
  - Benchmark source. Insert `:zig.Arc.collect_unused()` (or `Arc.collect_unused()`) at the phase boundary.
- `/Users/bcardarella/.asdf/installs/zig/0.16.0/lib/std/heap/memory_pool.zig`:
  - Zig stdlib MemoryPool source. Look at `reset(.free_all)` semantics.
- `/Users/bcardarella/.asdf/installs/zig/0.16.0/lib/std/heap/ArenaAllocator.zig`:
  - Underlying arena. `reset(.free_all)` calls `arena.deinit()` which walks `used_list` + `free_list` and calls `child_allocator.rawFree` on each node — actually returns pages to OS.

## 13. Verification commands (verbatim, copy-paste)

```bash
# Build & test
cd /Users/bcardarella/projects/zap
zig build test --summary all  # expect: 999/999 (or higher if you add tests)

# Build the Zap compiler binary
zig build

# Build the binarytrees benchmark
cd ~/projects/lang-benches/binarytrees
rm -rf zap-out .zap-cache
/Users/bcardarella/projects/zap/zig-out/bin/zap build

# Smoke test at N=10 (output must match)
./zap-out/bin/binarytrees 10
# Expected:
#   stretch tree of depth 11	 check: 4095
#   1024	 trees of depth 4	 check: 31744
#   256	 trees of depth 6	 check: 32512
#   64	 trees of depth 8	 check: 32704
#   16	 trees of depth 10	 check: 32752
#   long lived tree of depth 10	 check: 2047

# Memory at N=21 (target: peak memory footprint < 140 MB)
/usr/bin/time -l ./zap-out/bin/binarytrees 21

# Stats dump (optional, for debugging)
ZAP_ARC_STATS=1 ./zap-out/bin/binarytrees 21 2>&1 | grep "pool=Arc(Tree)"
# Look for: pool=Arc(Tree) live=N high_water=M
# live should be 0 at exit; high_water bounded by peak simultaneous live (~3M for N=21)
```

## 14. What to deliver in your final commit

- Production-grade implementation of the chosen option.
- Tests for any new runtime entry points (especially the soundness guard on `reset` — the panic-on-live-cells case).
- Documentation of the Zap-level intrinsic if you add one. Where it lives in `lib/`, how to call it from user code, when it's safe to call.
- A clear commit message describing:
  - The option chosen and why.
  - The soundness argument (what makes this safe to call).
  - Before/after measurements (peak RSS at N=21, wall time, test count).
  - Any deferred follow-up work.
- The benchmark source change to call the new intrinsic at the phase boundary.

## 15. Final reminders

- **No workarounds.** If the right answer is invasive, do it.
- **No mutability primitives.** The user's program stays purely functional.
- **Tests must pass before commit.** Run `zig build test --summary all` immediately before `git commit`. If it fails, fix the failure before committing.
- **Atomic commit.** One commit at the end with everything.
- **Read this entire brief before starting.** You'll save time vs. discovering each constraint mid-implementation.
- **Watch out for Zig identifier shadowing.** The previous attempt died on this. Use unique names for inner constants in nested scopes.

Good luck.
