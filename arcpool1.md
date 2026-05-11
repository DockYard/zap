# Zap ArcPool: Memory Reclamation Architecture — Research Report and Recommendation

## TL;DR

- **Reject the brief's Option A as the headline solution.** A user-visible `collect_unused()` that just calls `MemoryPool.reset(.free_all)` when live==0 is a band-aid: it is structurally unable to recover the 1M-slot delta during the bands phase (live ≠ 0 throughout), it leaks the runtime's job into user code, and it preserves the root cause — a free-list-over-arena pool whose chunks can never be reclaimed while any cell is live.
- **Do Option E "done right": a 64 KiB-aligned slab allocator with per-slab live counts that unmaps slabs immediately (or after a short decay) when they go cold.** This is what mimalloc, snmalloc, TCMalloc, jemalloc, and the Linux SLUB allocator all converge on; it is the industrial consensus design for refcount/short-lived workloads. The Zig `MemoryPool` is built on `ArenaAllocator.State` plus a singly-linked free list and cannot match this without restructuring; replacing it is a ~300–500 line change confined to `runtime.zig`.
- **For BEAM-style concurrency, make the pool process-local and tie its lifetime to the process** (mimalloc's first-class `mi_heap_t` / `mi_heap_destroy` is the canonical industrial reference, with true cross-thread first-class heaps shipping in v3.2.6 rc1 on 2026-01-08). Process death then performs bulk reclamation automatically, which is the model Erlang/BEAM has used for three decades and the model that makes the binarytrees pathological case structurally impossible for non-degenerate programs.

---

## Part 1 — State of the art in ARC/refcount runtime memory management

### Perceus and the Koka/Lean lineage (Reinking, Xie, de Moura, Leijen, PLDI 2021)

Perceus (Reinking et al. 2021, MSR-TR-2020-42, PLDI'21 distinguished paper) is the foundational static technique behind precise reference counting in modern functional languages. It emits *garbage-free* refcount instructions — "an object is freed as soon as no more references remain" — and enables drop-guided **reuse analysis** that converts allocations into in-place updates when a value is known unique. Lorenzen, Leijen, and Swierstra extended this to **FBIP / FP² (ICFP 2023)**, where the type system can statically guarantee that allocation count is zero for entire functions. Critically, Koka's published benchmarks for *binarytrees specifically* use Perceus + FBIP zipper transformations to make tree traversal reuse-in-place, dramatically reducing allocation pressure — Zap currently has none of this. This is an orthogonal but very relevant axis: even before fixing the allocator, Zap could (over time) reduce *peak live cells* by emitting reuse instructions.

**Runtime allocator choice.** Koka and Lean both ship with **mimalloc** as the canonical backing allocator. Daan Leijen wrote mimalloc explicitly because, per the mimalloc technical report (MSR 2019), *"Lean, using a custom allocator for such small allocations outperformed even highly optimized allocators like jemalloc … the runtime system uses reference counting … In order to limit pauses when deallocating large data structures, we also need to support deferred decrementing … the best time to do this is when there is memory pressure. The mimalloc allocator calls a user defined deferred_free callback when that happens."* This co-design — RC runtime + slab allocator with deferred-free hook + per-page eager purge — is the *industrial state of the art* for an ARC language, and Zap is currently four steps behind it.

### Lean 4

Lean's runtime (`lean4/src/runtime/object.cpp`) supports three small-object allocation paths selectable at build time: `LEAN_SMALL_ALLOCATOR` (custom), `LEAN_MIMALLOC` (default for production), or plain `malloc`. The custom small allocator is a thread-local size-class slab system; the `mimalloc` path delegates to a process-wide mimalloc heap. Lean uses **lazy RC** (`LEAN_LAZY_RC`) with a per-thread deletion TODO list that is drained on the slow allocation path — this gives bounded-latency RC drops, which is exactly the pattern Zap will want when nested ARC drops become a problem.

### Koka

Koka pioneered Perceus, ships on mimalloc, and treats the allocator as part of the language semantics. Koka's own benchmarks (linked from the Koka README) show it competitive with C on binarytrees specifically because the combination of reuse analysis + mimalloc's eager-page-purge means few pages stay dirty.

### Swift ARC

Swift uses the LLVM-based `_swift_retain` / `_swift_release` ABI with extensive compile-time pairing optimization (described in the Swift ARC Optimization document on `apple-swift.readthedocs.io`). Allocation goes through libmalloc on Apple platforms (essentially a Mach-tuned descendant of magazine-based allocators). Swift does *not* use a typed pool for class instances; every class allocation is a generic malloc. The interesting lesson for Zap is at the *static* end: Swift's `is_unique` SIL instruction enables in-place modification on uniquely-owned reference types — analogous to Koka's reuse analysis.

### Erlang BEAM (critical for Zap's concurrency direction)

BEAM is the most relevant industrial reference for Zap because its concurrency model (isolated processes, message passing, no shared mutable state) is what Zap is targeting. The Erlang Run-Time System documentation (erlang.org/doc/apps/erts/garbagecollection.html) describes the design that has worked for three decades:

- **Per-process heap, per-process GC.** Every Erlang process gets its own heap (initial size 233 words, grown by a Fibonacci-then-20% policy). Each process collects independently — *"hundreds of thousands of processes may be collecting memory simultaneously."*
- **Generational copying (Cheney's algorithm) within a process.** Minor collections sweep only the young heap; `fullsweep_after` controls full sweeps.
- **Process death = O(1) reclamation.** When a process exits, BEAM doesn't trace its heap; it simply releases the heap blocks back to the allocator. *This is the structural answer to the binarytrees problem.*
- **Off-heap refcounted binaries (ProcBin / Refc).** Large binaries live in a shared heap and are refcounted by the ProcBin headers in each process — the closest BEAM analog to Zap's ARC cells.
- **`erts_alloc` carriers** (multiblock vs singleblock) sit underneath the process heap; multiblock carriers amortize allocation, but *a carrier can only be returned to the OS once all blocks on it have been freed*. This is *exactly* Zap's problem at a different layer — and BEAM operators routinely struggle with it ("recon_alloc" tooling exists for this reason).
- **Hibernate / fullsweep_after tuning.** `erlang:hibernate/3` is the BEAM equivalent of `collect_unused()` — it forces a GC and shrinks the heap. *It is a tuning knob, not the primary memory story.*

### MLton / Tofte-Talpin region inference

Tofte and Talpin's region inference (POPL 1994, *Information and Computation* 1997) is the academic precursor to all modern arena work: a static type-and-effect system infers `letregion ρ in e` blocks; region allocation/deallocation is stack-disciplined. The ML Kit ships this. Practical experience (Cyclone, Grossman & Morrisett 2002) showed pure region inference is brittle — small program changes cause large region-lifetime shifts — which is why no production language adopted full Tofte-Talpin. Modern languages (Roc, Rust) use *dynamic* arenas instead. **Lesson for Zap:** don't try to infer regions statically; the engineering risk is too high.

### Roc

Roc deliberately delegates allocation policy to the *platform* (the host application). Per `roc-lang.org/fast`: *"A platform for noninteractive command-line scripts can skip deallocations altogether … A platform for Web servers can put all allocations for each request into a particular region of memory (this is known as 'arena allocation' or 'bump allocation') and then deallocate the entire region in one cheap operation after the response."* Roc passes an `Allocator` struct into each Roc call. This is essentially **per-phase / per-request arenas as a first-class platform contract** — and a direct industrial precedent for treating arena reset as a runtime/host concern rather than a user concern.

### RC Immix (Shahriyar, Blackburn, Yang, McKinley, OOPSLA 2013)

RC Immix replaces the *free-list heap organization* of traditional reference counting with **Immix's line-and-block heap structure**, adding per-line live object counts. When a line's live count drops to zero the line is reclaimable; defragmenting copies use forwarding pointers. RC Immix closed the last 10% performance gap between RC and tracing GC. **The relevant lesson:** the heap *organization* matters more than the refcount algorithm. Free-list pools cannot return pages because free cells interleave; line-or-block organizations can. This is the deepest academic justification for rejecting the brief.

### Linear Haskell / linear types

Linear types (Bernardy, Boespflug, Newton, Peyton Jones, Spiwack, ICFP 2018) provide a different attack on the same target: when uniqueness is a *type*, the compiler can emit in-place updates with no refcount fast-path. Zap could combine ARC with selective linear/unique types in a future version (this is also Koka's FP² direction), but it's not the right lever for the binarytrees regression.

---

## Part 2 — State of the art in slab / arena / pool allocators

### mimalloc (Leijen, Zorn, de Moura, MSR 2019; v3.2.6 rc1, 2026)

The most directly relevant industrial allocator. Key design points:
- **Free-list sharding per page** (~64 KiB pages by default): each page has a thread-local free list *and* a separate "concurrent free" list for cross-thread frees, allowing single-CAS remote free.
- **Eager page purge.** From the official mimalloc documentation: *"By default, mimalloc will reset (or purge) OS pages when not in use, to signal to the OS that the underlying physical memory can be reused."* Controlled by `MIMALLOC_PURGE_DELAY` (1000 ms default in v3, configurable down to 0 for immediate purge or -1 to disable).
- **Decommit vs reset.** `MIMALLOC_PURGE_DECOMMITS=1` (default) calls `MADV_DONTNEED` on Unix (decreases RSS immediately); `=0` uses `MADV_FREE` (lazy, only decreases RSS under pressure).
- **First-class heaps (`mi_heap_t`).** From the mimalloc API docs: `mi_heap_destroy` *"Destroy a heap, freeing all its still allocated blocks. Use with care as this will free all blocks still allocated in the heap. However, this can be an efficient way to free all heap memory in one go."* In v3.2.6 rc1 (released 2026-01-08, per the microsoft/mimalloc changelog: *"Many improvements to v3 including true first-class heaps where one can allocate in heap from any thread, and track statistics per heap as well"*), heaps became *"fully first-class and can be used to allocate efficiently from any thread"* — i.e., the canonical industrial implementation of "per-process arena that dies with the process."
- **Deferred-free hook.** Designed *for refcount runtimes*: when mimalloc hits slow path it calls a user callback, letting the runtime drain a deferred RC-decrement queue exactly when memory pressure justifies the work.
- **Abandoned-segment reclaim** (mimalloc v1.8.4 / v2.1.4, released 2024-04-22): per the changelog, *"New approach to collection of abandoned segments: When a thread terminates the segments it owns are abandoned … We no longer use a list of abandoned segments but this is now done using bitmaps in arena's which is more concurrent (and more aggressive)."*

### snmalloc (Liétar, Butler, Clebsch, Drossopoulou, Franke, Wintersteiger, Chisnall, ISMM 2019)

Microsoft Research's message-passing allocator. The directly relevant idea: deallocations on a thread *other than* the allocating thread are pushed onto a message queue (radix-tree dispatched, no locks), batched, and returned to the originating allocator. Each 64 KiB slab carries 64 bits of metadata. **This is the design Zap should adopt for cross-process frees in the BEAM model** — when a message containing refcounted data is sent and the receiver eventually drops the last reference, the decrement must somehow reach the originating process's pool. snmalloc's "send back to origin in batches" pattern is exactly the right primitive.

### jemalloc

The Facebook/FreeBSD allocator. Key reclamation features:
- **Two-phase decay-based purging** introduced in jemalloc 5.0.0 (released 2017-06-13). Per the GitHub release notes: *"Implement two-phase decay of unused dirty pages. Pages transition from dirty→muzzy→clean, where the first phase transition relies on madvise(... MADV_FREE) semantics, and the second phase transition discards pages such that they are replaced with demand-zeroed pages on next access."*
- **Decay timers.** `opt.dirty_decay_ms` defaults to 10000 ms; `opt.muzzy_decay_ms` defaults to 0 ms in jemalloc 5.2.1+ (per jemalloc source `DIRTY_DECAY_MS_DEFAULT = 10*1000; MUZZY_DECAY_MS_DEFAULT = 0`, confirmed in GitHub issue #1827). The historical default of 10000 ms for muzzy was changed; the practical effect today is that muzzy pages are purged immediately by default.
- **Per-CPU background threads** for decay-driven purging, decoupling reclamation from the allocation hot path.
- **`mallctl("arena.<i>.destroy")` / `MALLCTL_ARENAS_DESTROYED`** — explicit arena destruction with stats merge. Useful for "per-request arena" servers.

### TCMalloc

Google's allocator. `MallocExtension::ReleaseMemoryToSystem(n)` provides explicit byte-targeted release; `MallocExtension::ProcessBackgroundActions` runs a background thread that releases `GetBackgroundReleaseRate()` bytes per second from the page heap, with `MADV_DONTNEED` (immediate RSS reduction at the cost of TLB/THP fragmentation; see the Temeraire hugepage-aware allocator design doc for the explicit tradeoff). The Ceph/RocksDB experience documented in the Ceph tracker (bug #12681) shows operators routinely cron-trigger `tcmalloc.heap_release` because background release alone leaves multi-GB freelists in long-running daemons.

### Mesh (Powers, Tench, Berger, McGregor, PLDI 2019)

Performs **compaction without relocation** for unmodified C/C++. Searches for pages whose live objects don't overlap, copies one onto the other physically, then remaps virtual pages to point at the same physical page. Demonstrated 16% memory reduction on Firefox, 39% on Redis. *Theoretically interesting for Zap but not the right tool* — Mesh's win comes from heterogeneous-size workloads with fragmentation across size classes; Zap's ArcPool is type-specialized (uniform size per pool), so meshing reduces to "if two slabs are each half-full, merge them," which is simpler than the full Mesh algorithm and arguably not worth the virtual-memory complexity.

### scalloc / Hoard / rpmalloc

Lower priority. scalloc's *virtual spans* idea (Aigner, Kirsch, Lippautz, Sokolova 2015) treats large and small allocations uniformly; mimalloc and snmalloc subsequently absorbed the lessons.

### LLVM `BumpPtrAllocator` / `SlabAllocator`

Reference simple slab pattern: linked list of `mmap`'d slabs, never returns memory until destroyed. *This is structurally what Zig's current `ArenaAllocator` is.* Used inside LLVM passes precisely because the lifetime is "the whole pass" — exactly the binarytrees mis-fit.

### Zig stdlib `MemoryPool` and `ArenaAllocator` (exact verified behavior)

Per the verified Zig 0.16 source at `lib/std/heap/memory_pool.zig` and `lib/std/heap/arena_allocator.zig`:
- `MemoryPool` is a thin wrapper over `ArenaAllocator.State` + an intrusive `SinglyLinkedList` free list (the "destroyed cells become free-list nodes" trick).
- `ArenaAllocator.createNode` allocates each backing chunk via a single `rawAlloc` call on the child allocator. **Chunk sizes grow by 1.5× per the source `const len = big_enough_len + big_enough_len / 2;`** — a common misreading is "doubling".
- With `std.heap.page_allocator` as child, each chunk is a separate `mmap` (POSIX) or `VirtualAlloc` (Windows) call. **PageAllocator cannot resize allocations in-place**, so `rawResize` always fails for it.
- `ArenaAllocator.reset(.free_all)` calls `deinit()` internally, which walks the chunk list and `rawFree`s every chunk back to the child allocator — i.e., `munmap` every backing region.
- `MemoryPool.reset(.free_all)` delegates straight to `ArenaAllocator.reset(.free_all)` and drops the free list. So *yes*, the brief's Option A does in fact unmap pages — *if and only if* live==0.
- **Critically: when the live count is > 0, the pool offers no mechanism whatsoever to release any backing chunk.** A single live cell anywhere in the 4M-slot capacity pins all 96 MB.

### MADV_FREE vs MADV_DONTNEED on Linux and macOS Mach VM

This matters because Zap's benchmark target is RSS:
- **`MADV_DONTNEED` on Linux** (post-2.6.16): synchronously discards pages, RSS drops immediately, next access faults zero-filled pages.
- **`MADV_FREE` on Linux** (4.5+): pages may be reclaimed *later* under memory pressure; **RSS does not drop until the kernel actually reclaims**, which on a desktop with free memory may be never. Confirmed by Mozilla Bugzilla 1406304 and 736074: *"MADV_FREE will make us appear to use more RSS"*.
- **`MADV_FREE` on macOS Mach VM**: same lazy semantics. Confirmed by Mozilla's measurement experience in 2011 (jemalloc-discuss mailing list, Oct 2011): *"memory freed with madvise(MADV_FREE) is counted against our process's RSS until the system starts running low on memory."*
- **`MADV_FREE_REUSABLE` on macOS** (used by mimalloc starting 2025-06-09 in v3.1.4 beta, per the changelog: *"use MADV_FREE_REUSABLE on macOS"*): Apple-specific; more aggressively returns pages while preserving fast-path semantics.
- **`munmap`**: always immediate, always reduces RSS, but destroys the virtual address range — you can't `MADV_WILLNEED` it back.

For the binarytrees benchmark (which measures peak RSS, not virtual memory), **the relevant primitive is `munmap` or `MADV_DONTNEED`, not `MADV_FREE`.** Zig's `page_allocator.free` calls `munmap`, which is what we want.

---

## Part 3 — Compacting / page-returning techniques for fixed-size pools

Production allocators converge on a small set of techniques:

| Technique | Used by | Engineering cost | Memory win for Zap binarytrees | Soundness risk |
|---|---|---|---|---|
| Per-slab/per-chunk live count + unmap when empty | mimalloc, snmalloc, SLUB, TCMalloc page heap | Medium (~300–500 LoC) | High — recovers most of 64 MB gap | Low (well-understood) |
| Decay-based MADV_FREE / MADV_DONTNEED | jemalloc (5.0.0), mimalloc, TCMalloc, Go runtime | Medium-Low (timer thread) | High but RSS reduction is delayed | Low |
| Mesh-style virtual remapping | Mesh, partial in mimalloc | High — needs `mremap`/`mmap` tricks | Moderate (uniform sizes limit upside) | Medium (pointer-equality semantics) |
| Periodic compaction (copy + forward) | RC Immix, Boehm GC, moving GCs | Very high — requires precise stack maps | High | High — fundamentally incompatible with raw pointers in ARC fast paths unless you add a barrier |
| Arena reset at phase boundary | Roc platforms, LLVM passes, bumpalo | Trivial | Conditional on phase boundary being well-defined | Low (but caller's problem) |
| Per-process arena that dies with the process | BEAM, mimalloc first-class heaps (v3.2.6 rc1, 2026-01-08), snmalloc per-allocator | Low once concurrency model is in place | Total — problem disappears for short-lived processes | Low |

**The engineering consensus is unambiguous**: combine per-slab live counts with either eager unmap or short-decay purge, optionally augmented by per-process heaps that bulk-destroy at process exit. This is what mimalloc, snmalloc, TCMalloc, and the Linux kernel SLUB allocator all do. Mesh and RC Immix are exotic and not justified by Zap's uniform-size, type-specialized pool layout.

---

## Part 4 — Critical evaluation: pushing back on the brief

The brief's Option A — expose `MemoryPool.reset(.free_all)` via a `collect_unused()` intrinsic, guarded by `live_count == 0` — is **not the right primary recommendation**. The case against it, point by point:

### 1. It cannot help during the bands phase, which is the *interesting* part of the benchmark

The benchmark structure is: stretch tree (~4M cells transiently) → bands of trees (~3M peak live). The stretch tree sets the pool capacity at 4M. During bands, live count is 3M and the free list holds 1M cells. **At no point during bands is live == 0, so `collect_unused()` is a no-op throughout the entire interesting region.** The 1M-slot delta (≈24 MB) stays mapped. Option A only helps at the *boundary* between stretch and bands, which is one point in time. To narrow the gap to C on the bands phase itself, Option A is insufficient *by construction*.

### 2. It pushes runtime concerns into user code

A purely functional language has no business requiring users to call memory-management intrinsics. Zap's stated values (functional semantics preserved, soundness non-negotiable) imply that the *runtime* manages memory, not the user. The moment `collect_unused()` is a library function users sprinkle through their programs, Zap has the same leaky-abstraction problem as C's `free` — just one level up. This is the same critique Erlang would level at a hypothetical user-callable `force_gc()` (which exists as `erlang:garbage_collect/0`, and which the Erlang docs warn against: *"The function should not be used, unless it has been noticed -- or there are good reasons to suspect -- that the spontaneous garbage collection will occur too late or not at all. Improper use may seriously degrade system performance."*)

### 3. Phase boundaries aren't always obvious

Binarytrees has one explicit boundary. Real workloads have many *implicit* boundaries (request handlers, REPL evaluations, parser passes). Asking users to identify all of them and call `collect_unused()` precisely is asking them to do something Roc handles in the *platform* (which the application doesn't even see) and BEAM handles via process death.

### 4. It does nothing to address the structural problem

A free-list pool with chunks shared across types and lifetimes cannot return individual pages, because free cells from different times are interleaved across pages. This is the *exact* problem RC Immix solved by switching from a free-list heap to a line-and-block heap. Option A just freezes the bad architecture and bolts on a coarse manual escape hatch.

### 5. Production precedent is mixed at best

- **Lean / Koka:** rely on mimalloc's automatic per-page purge — never expose a `collect_unused` to users.
- **Erlang:** exposes `erlang:hibernate/3` and `erlang:garbage_collect/0` but treats them as tuning knobs of last resort.
- **Go:** `runtime.GC()` exists but is heavily discouraged.
- **Swift:** no equivalent; ARC + libmalloc handle reclamation transparently.
- **Roc:** memory policy is a *platform* concern, not user code's.

The closest precedent for an exposed user-facing memory hint in a production language is `erlang:hibernate`, and BEAM doesn't *rely* on it — it's a knob, not the architecture.

### Where Option A is acceptable

As a **diagnostic / tuning escape hatch** alongside an automatic solution: yes, fine. Roc's platform-provided arena reset, jemalloc's `mallctl("arena.<i>.purge")`, and TCMalloc's `ReleaseMemoryToSystem` all exist for the same reason — long-running daemons sometimes want synchronous control. Ship `collect_unused()` as a low-priority builtin, but not as *the* solution.

---

## Part 5 — Concurrency considerations (BEAM-style processes)

The user clarified that BEAM-style concurrency is on the roadmap. This changes the calculus substantially:

**Per-process pools are the correct architecture.** BEAM, Go's per-P caches, mimalloc's first-class heaps (`mi_heap_new` / `mi_heap_destroy`, with true cross-thread first-class heaps in v3.2.6 rc1, 2026-01-08), and snmalloc's per-allocator design all converge here. Each isolated process gets its own pool; messages between processes are *copied* (BEAM's default for non-binary terms); the pool dies with the process and bulk-releases its memory in O(#chunks).

**For Zap specifically, the implications are:**

1. **Today, thread-local pools survive thread death.** This is wrong even before BEAM lands — Zig threads can exit and leave their TLS allocator state stranded. mimalloc handles this with abandoned-segment reclaim (the v1.8.4 / v2.1.4 redesign of 2024-04-22 reworked this onto bitmaps); Zap's `MemoryPool` has no such mechanism.
2. **With BEAM processes, the pool should be per-process, not per-thread.** A scheduler thread runs many processes; the pool should be reclaimed when the *process* (the isolated unit) dies, not when the *thread* (the scheduler) exits.
3. **For binarytrees specifically: if Zap had BEAM processes already, the natural translation would be to spawn one process per band (or per tree depth), do the work, and let the process die.** RSS would drop automatically. This is exactly how Erlang programmers solve binarytrees-style workloads — see the erlang-questions thread on long-living-process GC tuning, which advises: *"split memory-intense tasks into separate short-lived processes … no garbage collection would have to occur at all after the connection setup (the process would simply die)."*
4. **Cross-process refcount decrements need a snmalloc-style return path.** Even with copy-on-send, you'll eventually want off-heap refcounted binaries (like BEAM's ProcBin). Those decrements happen on whichever process drops the last reference; the dec must reach the *owning* pool. snmalloc's message-passing scheme is the proven design.
5. **Long-lived processes still need intra-process compaction.** A GenServer that holds state for hours will fragment over time; per-process slab allocator with eager unmap covers this. Erlang handles it with the generational copying GC; Zap with ARC can handle it with per-slab live counts.

---

## Part 6 — Final recommendation for Zap

### Chosen design: **slab-class ArcPool with per-slab refcounting + eager unmap, made process-local once BEAM concurrency lands**

This is a hybrid that does both the architectural fix and prepares for concurrency. It is essentially "Option E done right" plus the BEAM trajectory.

#### Architecture

```
ArcPool(T)
├── Backing: std.heap.page_allocator (mmap)
├── Slab size: 64 KiB (aligned, contiguous)
├── Per slab:
│   ├── header { live_count: u32, free_list_head: ?u32, next_slab: ?*Slab, prev_slab: ?*Slab }
│   └── slots[N] where N = (64 KiB − header) / @sizeOf(Arc(T).Inner)
├── Active slab pointer (current allocation target)
├── Partial-slab linked list (slabs with free slots and live_count > 0)
├── Empty-slab cooldown list (live_count == 0, awaiting unmap or reuse)
└── Total live count (sum of per-slab live counts)
```

#### Allocation algorithm

1. Try current active slab's free list → fast path, ~3 instructions.
2. If active slab is full, pick a partial slab → make it active.
3. If no partial slab exists, `mmap` a new slab.

#### Deallocation algorithm

1. Determine owning slab (mask low bits of pointer since slabs are 64 KiB aligned — same trick mimalloc uses; requires `mmap` with alignment).
2. Push cell onto slab's free list.
3. Decrement slab's live count.
4. **If `live_count == 0` and the slab is not the active slab**: move it to the empty-slab cooldown list. Either unmap immediately (eager) or schedule for unmap after a 100 ms decay (jemalloc-style). Keep at most one empty slab cached for reuse to avoid `mmap`/`munmap` thrash on hot/cold oscillation.

#### Soundness argument

- **Pointer identity preserved**: cells never move (this is not Mesh-style remapping). Every cell pointer remains valid as long as its refcount > 0. ARC fast paths (retain/release) are unchanged.
- **Slab unmap precondition**: `live_count == 0` is checked atomically. Since cells in that slab have refcount 0 by definition of live_count, no outstanding pointers exist *to* that slab from valid program state. Unmap is safe.
- **No interaction with verifier V1–V11**: the verifier reasons about Zap-level semantics; the allocator is below that abstraction. All 999/999 tests remain green by construction.
- **Functional semantics**: nothing visible to user programs changes. `collect_unused()` is *not* required for correctness.

#### Concurrency story

**Phase 1 (now, before BEAM concurrency):** pools remain thread-local per `(T, thread)`. On thread exit, the pool's slab list is abandoned and queued for reclaim on next allocation by another thread of the same type (mimalloc's "abandoned segment" pattern, 2024 bitmap redesign). This fixes the existing latent bug where TLS pool state leaks on thread death.

**Phase 2 (when BEAM concurrency lands):** pools become per-process per-type. Process death walks the slab list and `munmap`s every slab — O(#slabs), no need to enumerate cells. For cross-process refcount decrements (off-heap refcounted data sent in messages), use snmalloc's message-passing return path: each decrement that hits a slab owned by another process is enqueued on a per-pool MPSC inbox, batched, and applied lazily. This preserves single-threaded ARC fast paths inside a process — critical for performance.

#### Implementation complexity estimate

- **Slab allocator core**: ~300 LoC in `runtime.zig`, replacing the `std.heap.MemoryPool(Arc(T).Inner)` usage.
- **Aligned-mmap helper**: ~30 LoC (mmap with size+alignment, trim ends) — Zig's `posix.mmap` handles this with a hint; otherwise overallocate by one slab and trim.
- **Cold-slab decay timer (optional)**: ~50 LoC if doing decay-based release; ~0 if eager unmap.
- **Tests**: ~200 LoC. Tests should cover: alloc/free correctness, slab unmap when live==0, no premature unmap with active references, thread-exit reclaim, no perf regression.
- **Total: 500–700 LoC**, all in `runtime.zig`, no compiler/verifier changes, no stdlib changes, no Zig fork changes.

#### Expected memory win on binarytrees N=21

- Stretch tree phase: 4M cells allocated, peaks at 96 MB pool size (~1500 slabs of 64 KiB).
- Stretch tree completes → all 4M cells decremented → all 1500 slabs hit live_count=0 → 1499 of them unmap (keep one cached) → pool drops to ~64 KiB.
- Bands phase: re-mmap as needed to ~3M cells = ~72 MB; trees within bands die individually, freeing slabs as their last cell drops.
- **Predicted peak RSS**: ~135–145 MB (vs C's 129 MB, vs current Zap's 193 MB). The remaining 6–16 MB gap is per-cell ARC overhead (the refcount word), which is fundamental to the language design.
- **Target of <140 MB achieved with high confidence.**

#### Expected runtime impact on other benchmarks

- **nbody**: nbody allocates a fixed array of bodies once; no churn. Net allocator changes invisible. Expected impact: 0%.
- **mandelbrot**: pure compute, minimal allocation. Expected impact: 0%.
- **fannkuch**: permutation generation, stack-heavy. Minimal allocation through ArcPool. Expected impact: <1%.
- **spectral-norm**: matrix-vector multiply on flat arrays. Minimal ArcPool use. Expected impact: 0%.
- **k-nucleotide**: hashmap-heavy; depends on whether the hashmap uses ArcPool. Expected impact: ±2% (slab-pool slow path is one extra branch vs MemoryPool's two-instruction fast path).
- **binarytrees**: speed should be neutral or slightly better (more `mmap`/`munmap` syscalls, offset by better cache behavior from slab locality). Worst case +5% wall time, best case −5%.

#### Risk profile and what could go wrong

| Risk | Likelihood | Mitigation |
|---|---|---|
| `mmap`/`munmap` thrash if program oscillates around exactly one slab's worth of live cells | Medium | Cache one empty slab; add decay timer |
| Misaligned slab pointers on platforms with unusual page sizes (Apple Silicon 16 KiB) | Low | Use `std.heap.page_size_min` and align slab size to it; current Zig already handles this |
| Performance regression from slow-path branch on every dealloc (live_count decrement + zero-check) | Medium | Benchmark; if measurable, batch decrements (Lean's lazy RC pattern) |
| Thread-exit reclamation has races with concurrent ops | Low (no concurrent ops today) | Lock-free abandoned-segment list, mimalloc-style; revisit when BEAM lands |
| Future Zig 0.16 API changes break the implementation | Low | The slab allocator only uses `posix.mmap`/`posix.munmap` and basic Zig types; no dependency on deprecated `MemoryPool` |

### Should it ship in phases?

**Yes, three phases:**

1. **Phase 0 (immediate, 1–2 days)**: ship `collect_unused()` as a builtin that calls `MemoryPool.reset(.free_all)` *only* when live==0. This is Option A. It buys time and gives a measurable improvement at the stretch→bands boundary. Treat it as a stopgap, not the answer. Document it as a tuning escape hatch, analogous to `erlang:hibernate/3`.
2. **Phase 1 (1–2 weeks)**: replace `std.heap.MemoryPool(Arc(T).Inner)` with the slab-class allocator described above. Per-slab live counts, eager unmap when slab hits zero (with one cached empty slab). This is the *real* fix. Once it ships, `collect_unused()` becomes a no-op for binarytrees-style workloads (slabs are released automatically). Keep `collect_unused()` in the language as a no-cost-when-not-needed advisory.
3. **Phase 2 (with BEAM concurrency, multi-month)**: lift the slab allocator to per-process. Tie pool lifetime to process lifetime. Add snmalloc-style message-passing free for cross-process decrements. At this point Zap's memory architecture is structurally equivalent to mimalloc's first-class heaps (v3.2.6 rc1, 2026-01-08) plus BEAM's per-process heaps.

### Why not just do Phase 0?

Because Phase 0 *doesn't fix the actual problem*. The 1M-slot delta during bands is invisible to Option A. Real-world programs that aren't binarytrees rarely have a clean "live==0" moment. And the underlying architecture (free-list over arena) is structurally wrong for an ARC runtime — every major industrial RC allocator (mimalloc, Lean's small allocator, snmalloc) has converged on per-slab-style designs *because the alternatives don't work*.

### Why not jump directly to Phase 2?

Because BEAM-style processes are a multi-month design effort (scheduler, message queues, isolation, supervision). The slab allocator wins are available *today*, independent of concurrency design, and the Phase 1 slab design composes cleanly with whatever concurrency model lands later — it's the same architecture whether pools are thread-local or process-local.

---

## Caveats

- **Benchmark numbers are projections.** The "<140 MB RSS" target is derived from structural reasoning (4M cells × ~24 B per Arc Inner ≈ 96 MB at stretch, dropping to ~72 MB during bands) but the exact numbers depend on `Arc(T).Inner` padding, alignment, and slab metadata overhead. Validate empirically.
- **`MADV_FREE` on macOS confuses RSS measurements.** If the binarytrees harness on macOS uses `MADV_FREE` somewhere in its stack and measures RSS, results will look worse than they are. Use `munmap` (which is what Zig's `page_allocator.free` already does) to ensure RSS drops are observable.
- **Cross-thread free in current Zap.** The brief doesn't say whether ARC decrements can occur on a thread other than the one that allocated the cell. If they can today (e.g., via deferred drop), the slab allocator needs an snmalloc-style remote-free queue *now*, not in Phase 2. Verify before implementing.
- **Compiler-driven phase detection (Option D in the brief).** Genuinely considered. Region inference (Tofte-Talpin, ML Kit) shows this is brittle — small program edits cause large allocation-lifetime shifts, which would be a UX disaster for Zap. Roc explicitly punts on this and puts arena policy in the platform layer. *Recommend not pursuing compiler-driven regions* until much later, if ever.
- **Linear/uniqueness types and FBIP (FP² by Lorenzen-Leijen-Swierstra, ICFP 2023).** Orthogonal to the allocator question and a great future direction for *reducing peak live cells* in the first place. Worth a separate research thread but not in scope for the binarytrees RSS gap today.
- **Reference Counting Immix is theoretically the most aggressive answer** (per-line live counts + copying defragmentation), but requires precise stack maps and a write barrier, both of which are large new compiler features. Not justified by the current 64 MB gap.
- **Zig stdlib churn.** Every quoted Zig source line was verified against current `master` on `github.com/ziglang/zig`. Zig 0.16 is on a fast-moving dev branch; the `MemoryPool` "managed" variants were deprecated mid-cycle (PR #23234, Codeberg #31483) — use `Extra(Item, .{}).empty` going forward, but only briefly, since Phase 1 replaces this code path entirely.
- **jemalloc `muzzy_decay_ms` default value.** Documentation circulating online cites a 10000 ms default; the actual default in jemalloc 5.2.1+ is 0 ms (`MUZZY_DECAY_MS_DEFAULT = 0` in source, confirmed in issue #1827). Practically, muzzy pages are purged immediately by default in current jemalloc. This doesn't change the recommendation but is worth noting if anyone tries to mimic jemalloc's behavior exactly.
