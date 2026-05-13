# Pluggable Memory Management for Zap — Research Brief

**Audience.** A research agent with zero prior context on Zap, its Zig fork,
or the existing runtime. This document supplies all of that context plus the
proposed plan, the design decisions already taken, the known risks, and the
specific open questions the research agent is expected to investigate.

The end goal: a versioned, capability-based ABI for pluggable memory managers
that ships with two first-party implementations (ARC + Arena), supports
extensibility by third-party Zig packages, and is forward-compatible with the
future `Process.spawn(memory: ...)` per-process selection model.

---

## 1. What is Zap?

Zap is a general-purpose, purely functional, statically-typed programming
language that compiles ahead-of-time to native binaries. Its syntactic
heritage is Elixir; its runtime model is closer to a modern systems language
with ARC-managed values.

### 1.1 Language design

- **Functional and immutable.** No mutable variables, no in-place mutation of
  user-visible state. Persistent data structures (`Map`, `List`, `String`)
  share structure via copy-on-write at refcount 1 and full clone at refcount
  ≥ 2.
- **Statically typed, partial inference.** Function parameters require type
  annotations (`x :: i64`, `xs :: [String]`), return types are explicit
  (`-> i64`). Local bindings infer. Type unification across multi-clause
  function dispatch is structural.
- **Multi-clause function dispatch.** Functions can be defined with multiple
  clauses that pattern-match on argument values and types, plus optional
  guards:

      pub fn classify(n :: i64) -> String if n > 0 { "positive" }
      pub fn classify(n :: i64) -> String if n < 0 { "negative" }
      pub fn classify(_ :: i64) -> String { "zero" }

- **One struct per file.** Each `.zap` file declares exactly one top-level
  `pub struct`. Files in nested directories produce dotted names — e.g.,
  `lib/io/mode.zap` declares `pub union IO.Mode`.
- **Structs are the unit of namespacing and modules.** Functions live inside
  structs; there are no free functions:

      pub struct Math {
        pub fn double(x :: i64) -> i64 { x + x }
      }

- **Pattern matching, guards, list pattern matching.** `[head | tail]`-style
  destructuring is first class in both case expressions and function clause
  heads.
- **Atoms, tuples, lists, maps as primitive aggregates.** Tuples were
  recently formalized as first-class types (commit `4d9c887`).
- **Macros.** `lib/kernel.zap` provides the macros that desugar `if`,
  `unless`, `and`, `or`, `|>`, sigils, etc. User-defined macros via
  `pub macro` are supported.
- **Protocols (Elixir-style typeclasses).** `Enumerable`, `Concatenable`,
  `Stringable`, etc. Implementations declared per type.
- **No concurrency yet.** The eventual model is BEAM-style isolated
  processes communicating by message passing. The pluggable memory manager
  work is sequenced before concurrency so each process can pick its own
  manager.

### 1.2 Project layout

    /Users/bcardarella/projects/zap/
      src/                    Zig source: the compiler and runtime
        runtime.zig           single ~12 kLOC file with all runtime types
        main.zig              CLI: zap build/run/test/init
        zir_builder.zig       lowers Zap IR to ZIR via the Zig fork's C-ABI
        ...
      lib/                    Zap stdlib (Zap source)
        kernel.zap            macros (if, unless, and, or, |>, sigils)
        io.zap, list.zap, map.zap, string.zap, ...
        zap/                  meta — manifest, env, dep
        zest/                 test framework
      test/                   Zap unit tests under Zest
      examples/               example programs (snake, factorial, ...)
      docs/                   design docs, research briefs
      build.zap               root manifest (targets: :test, :doc)
      build.zig               Zig build script for the compiler itself

### 1.3 Build manifest

Every Zap project has a `build.zap` defining one or more build targets:

    pub struct MyApp.Builder {
      pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        %Zap.Manifest{
          name: "my_app",
          version: "0.1.0",
          kind: :bin,
          root: "MyApp.main/1",
          paths: ["./*.zap"],
          optimize: :release_fast,
          deps: [{:zap_stdlib, {:path, "../../lib"}}]
        }
      }
    }

This pluggable memory manager work introduces a new manifest field, `memory`,
defaulting to `Zap.ARC`.

### 1.4 Current state

- 1040+ unit tests under Zest, all green.
- Six benchmarks from the Computer Language Benchmarks Game (nbody,
  mandelbrot, binarytrees, fannkuch-redux, spectral-norm, k-nucleotide)
  produce byte-correct output and meet or beat C/Rust/Zig on several
  (e.g., Zap is fastest on nbody at 103ms vs C's 160ms).
- binarytrees N=21 peak RSS: 162 MB, vs C's 130 MB — the gap is the
  4-byte side-table refcount per cell (architectural floor for refcounted
  allocation in the current design).
- Compiler has known gaps in some struct-typing and nested-tuple paths
  (relevant for any work involving fresh struct types in collections —
  see `examples/turing_machine/README.md` for an enumeration).

---

## 2. The Zig Fork

Zap depends on a fork of Zig 0.16.0 living at `/Users/bcardarella/projects/zig`.

### 2.1 Why fork

Upstream Zig exposes its IR (ZIR) and Sema only through the `zig` binary
driver. Zap needs to *embed* the Zig compiler as a library so it can
construct ZIR programmatically (from its own HIR/IR) without ever emitting
Zig source text. The fork:

- Exposes a stable C-ABI surface: `libzap_compiler.a` and the headers in
  `~/projects/zig/src/zir_api.zig`.
- Adds Zap-specific helpers in the Zig runtime support (e.g., custom
  ArcRuntime helpers used by the Zap-emitted IR).
- Carries patches for issues Zap's lowering pattern surfaces (anonymous
  struct unification, fnreturn type expansion, tuple_decl resolveInst
  paths) — some are pending upstream contributions.

### 2.2 How Zap calls into it

The driver in `src/zir_backend.zig`:

1. Builds the user's program through Zap's own HIR → IR.
2. Calls into `libzap_compiler.a` via C-ABI: starts a `Compilation`,
   constructs ZIR, runs Sema, lowers to LLVM IR.
3. Receives a `.o` artifact, links it with Zig's linker into the final
   executable.

The Zap → Zig boundary is the C-ABI in `src/zir_api.zig` (Zig side) and
`src/zir_backend.zig` (Zap side). It is the stable interface between the
two projects.

### 2.3 Permission to modify the fork

Project rule: when a Zap feature requires Zig changes, modify the fork.
The same code quality bar applies to both. The fork is not a black box.

---

## 3. How Zap and the Zig Fork Work Together — the Compilation Pipeline

For a Zap source file `foo.zap`:

    foo.zap
       │  (Zap-side: src/*.zig)
       ▼
    Parse  ──────────►  AST
       │
       ▼
    Macro expand ────►  AST with Kernel and user macros expanded
       │
       ▼
    Desugar ────────►  surface forms normalized
       │
       ▼
    Re-collect ─────►  struct/function tables
       │
       ▼
    HIR  ──────────►   high-level IR; type unification across clauses
       │
       ▼
    IR  ───────────►   Zap's IR; ownership/uniqueness analysis applied
       │  (C-ABI boundary into libzap_compiler.a)
       ▼
    ZIR  ──────────►   Zig fork's IR
       │  (Zig fork: Sema, code generation)
       ▼
    LLVM IR
       │
       ▼
    Native object
       │
       ▼  (linker; Zig handles linking)
    Executable

Each phase appears in the Zap CLI's build progress (`[1/11] Parse`,
`[2/11] Collect`, ...).

The pluggable memory manager work introduces new code in roughly three of
these phases: HIR/IR (ownership analysis, retain/release-elision pass),
ZIR-emit (skip emitting retain/release calls when the active manager
declares it doesn't need refcounts), and the build pipeline (resolve the
manifest's `memory:` field, compile the manager's Zig source, link it in).

---

## 4. Current Runtime Architecture (the thing being made pluggable)

### 4.1 ARC overview

Every heap-allocated value in Zap is reference-counted. There are two
parallel pools / strategies in the current implementation:

**a) The generic `ArcSlabPool(Inner, name)` pool** for `Arc(T)` cells where
`T` is any user struct type. This pool services binarytrees-style trees,
arbitrary nested records, etc.

**b) Inline-header types** (`Map`, `List`, `String`, etc.) — types that
embed an `ArcHeader` field inline in their layout. These bypass the
generic pool and manage their own buffers because their size is variable
(a `Map` has an `entry_cap`-sized buffer; a `List` has a `capacity`-sized
buffer). They share retain/release semantics with the generic pool but
own their own allocation logic.

Both routes go through the same retain/release entry points:
`ArcRuntime.retainAny` / `releaseAny` / `prepareReleaseAny` /
`destroyPreparedAny` (in `src/runtime.zig` around lines 2250-2360).

### 4.2 The slab allocator (`ArcSlabPool`)

Live as of commit `f59c67d` ("slab allocator with eager unmap") and
extended by `077467e` ("side-table refcounts collapse Arc(T) cell size"):

- Each slab is a 64 KiB-aligned `mmap`'d region.
- Slab header (~64 bytes) tracks: magic, live_count, free_list_head,
  bump_index, capacity, prev/next links, owner backptr, allocation_base.
- Side-table refcount array follows the header, sized `capacity * u32`,
  one entry per slot.
- Slots come last in the slab, aligned to `alignOf(Inner)`.
- Pointer→slab lookup: mask low 16 bits.
- Pointer→slot index: `(ptr - slot_array_base) / sizeOf(Inner)`.
- Refcount for `ptr`: `slab.refcounts[slot_index]` (atomic u32).
- Eager unmap when a slab's `live_count` hits zero (except one
  "cached_empty" slab kept around to avoid mmap thrash).
- Per-pool stats surface via `ZAP_ARC_STATS=1`: live, high_water,
  slab_mmap_count, slab_active_partial_count, slab_active_partial_live_sum.

For `Arc(Tree).Inner` (Tree is two `?*const Tree` pointer fields = 16
bytes), the effective per-cell footprint is 16 bytes (cell) + 4 bytes
(refcount) = 20 bytes. binarytrees N=21 stretch tree has 8.4M live cells
at peak → 162 MB RSS architectural floor.

### 4.3 Inline-header types — `Map`, `List`, `String`

- `Map(K, V)` is a dense open-addressing hash map (with HAMT fallback for
  large maps). Header layout starts with an inline `ArcHeader` followed
  by `len`, `capacity`, `entry_cap`, `hash_seed`, then the buckets array.
- `List(T)` (formerly Vector) is a flat-buffer contiguous list. Layout:
  inline `ArcHeader` followed by `len`, `capacity`, then the elements
  array.
- `String` is similar — buffer + inline header — with a 256-byte static
  `byte_intern_table` for stable single-byte strings.
- `MapIter` (commit `c4f4758`) is an extern struct that uses the
  `capacity == 0` discriminator to coexist with `Map` in the same
  pointer-handed-out shape — `Map.next` returns an iter cell as its
  state; subsequent calls advance through the map without cloning.

These three inline-header types are the load-bearing data structures
across the runtime. Their cleanup is recursive: when a `Map`'s refcount
hits zero, the runtime walks all live entries releasing keys and values
(deep release).

### 4.4 The uniqueness analyzer + ownership conventions

`src/arc_param_convention.zig` proves when ARC fast-paths are sound:

- Each parameter is tagged `.borrowed`, `.owned`, or `.trivial`.
- Borrow elision (commit `239d084`): when both a caller's source slot
  and the callee's parameter slot are `.borrowed`, the retain/release
  pair around the call is elided.
- The analyzer's correctness is the primary defense against accidental
  refcount drops; relevant when designing the codegen elision pass for
  the Arena manager.

### 4.5 What's currently hard-wired

- Every `Arc(T)` allocation goes through `ArcSlabPool`.
- Every retain/release call lowers to a direct call into the runtime's
  helpers, with type-specific deep-walk paths for inline-header types.
- Slab pools are pre-instantiated at startup for the common types.

This is what the pluggable manager work has to abstract behind a vtable
without regressing correctness, tests, or benchmark performance.

---

## 5. Recent Memory Optimizations (context for "why does this matter")

These shipped in the last few weeks; they explain the current performance
profile and the constraints the pluggable manager design has to respect.

| Commit    | Title                                                            |
|-----------|------------------------------------------------------------------|
| `f59c67d` | slab allocator with eager unmap                                  |
| `077467e` | side-table refcounts collapse `Arc(T)` cell size (24→16+4 bytes) |
| `c4f4758` | `MapIter` cursor type for O(N) iteration                         |
| `239d084` | borrow elision for `.borrowed`/`.borrowed` retain/release pairs  |
| `b32e95e` | 13-gap analysis on Map/ArcSlabPool/MapIter                       |
| `548a70e` | 4-gap second-round analysis fixes                                |

binarytrees N=21 peak RSS trajectory across these changes: ~250 MB →
194 MB (slab allocator) → 162 MB (side-table refcounts) — vs C's 130 MB
on the same machine. Wall time on the suite: Zap currently beats C on
nbody, mandelbrot, binarytrees, spectral-norm; within ~5% on
fannkuch-redux; ~4.5× slower on k-nucleotide (gap is in `Map.next`
iteration despite the new cursor).

---

## 6. The Proposed Plan — Pluggable Memory Manager

### 6.1 Goal

A capability-based, versioned ABI under which:

1. The existing ARC implementation is repackaged as a first-party manager
   `Zap.ARC` (the default).
2. A new first-party `Zap.Arena` manager wraps Zig's
   `std.heap.ArenaAllocator` with a mutex for thread safety.
3. Programs select a manager via `%Zap.Manifest{memory: Zap.Arena}`.
4. Third parties ship their own managers as external Zig packages — no
   compiler changes required.
5. The design is forward-compatible with `Process.spawn(memory: ...)`
   when concurrency lands.

### 6.2 Scoping decisions already taken

These were settled during a back-and-forth scoping session with the
project owner and should be treated as fixed unless the research turns
up evidence to revisit:

- **Arena reclamation model: whole-program.** Allocations live until the
  process exits. No `Arena.reset()`, no scoped arenas. Maps cleanly to
  the future per-process model since each process's arena dies with the
  process.
- **Retain/release elision strategy: compile-time elision.** When the
  active manager doesn't declare `REFCOUNT_V1` capability, the compiler
  doesn't emit retain/release calls at all (zero overhead, smaller
  binary).
- **Third-party manager location: external Zig package linked at build
  time.** Not pure Zap (FFI overhead would tank ARC's fast paths), not
  Zig-fork-internal (high barrier to entry), not C-ABI dynamic library
  (extra indirection). External Zig package gives a clean middle ground
  with native perf.
- **Interface model: versioned core vtable + capability discovery**
  (`COM`/`dma_buf_ops`-style). Core vtable is mandatory and minimal;
  optional capabilities are independent versioned vtables retrieved via
  `get_capability(id)`.
- **All shipped managers thread-safe.** ARC already is (atomic refcounts,
  atomic slab head); Arena gets a mutex around the bump pointer.

### 6.3 ABI sketch

    typedef enum {
        ZAP_CAP_REFCOUNT_V1   = 1 << 0,
        ZAP_CAP_TRACING_GC_V1 = 1 << 1,  // reserved, not defined yet
        ZAP_CAP_REGION_V1     = 1 << 2,  // reserved, not defined yet
        ZAP_CAP_STATS_V1      = 1 << 3,  // reserved, not defined yet
        // ...
    } ZapCapabilityFlags;

    typedef uint32_t ZapCapabilityID;
    #define ZAP_CAP_ID_REFCOUNT_V1   0x52454643u   /* 'REFC' */
    #define ZAP_CAP_ID_TRACING_GC_V1 0x47434F4Cu   /* 'GCOL' */
    /* ... */

    typedef struct {
        uint32_t version;                       /* ABI version (1 today) */
        ZapCapabilityFlags capabilities;        /* comptime-readable bitfield */
        void* (*init)(const ZapInitOptions*);
        void  (*deinit)(void* ctx);
        void* (*allocate)(void* ctx, size_t size, uint32_t align);
        void  (*deallocate)(void* ctx, void* ptr, size_t size, uint32_t align);
        const void* (*get_capability)(void* ctx, ZapCapabilityID id);
    } ZapMemoryManagerV1;

    /* Capability v1 vtables — each manager implements only those it declares. */
    typedef struct {
        void (*retain)(void* ctx, void* ptr);
        void (*release)(void* ctx, void* ptr, void (*deep_walk)(void*));
    } ZapRefcountCapability;

    /* Each manager package exports exactly these two symbols. */
    extern ZapMemoryManagerV1 zap_memory_manager_v1(void);
    extern const ZapCapabilityFlags zap_memory_capabilities;

The compiler reads `zap_memory_capabilities` from the linked manager's
`.o` symbol table at build time and uses it to decide which capability
calls to emit in codegen.

### 6.4 First-party managers

**`Zap.ARC`.** Refactor of the existing slab pool + side-table refcounts
into a self-contained Zig module at `src/memory/arc.zig`. Exports the
v1 vtable, declares `REFCOUNT_V1`, implements the refcount capability
vtable with the existing logic.

**`Zap.Arena`.** Thin wrapper around `std.heap.ArenaAllocator` at
`src/memory/arena.zig`:

    const Arena = struct {
        arena: std.heap.ArenaAllocator,
        mutex: std.Thread.Mutex,
    };

    fn allocate(ctx: *Arena, size: usize, align: u32) ?*anyopaque {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        return ctx.arena.allocator().alignedAlloc(u8, align, size) catch return null;
    }

    fn deallocate(_: *Arena, _: *anyopaque, _: usize, _: u32) void {
        // No-op: arena reclaims at deinit.
    }

Capabilities = 0 (no refcount, no anything). The most basic possible
manager — exists to validate the ABI's "no capabilities" path.

### 6.5 Phases

| Phase | Description                                                 |
|-------|-------------------------------------------------------------|
| 0     | Spec the ABI (`docs/memory-manager-abi.md`)                 |
| 1     | Define extern structs + globals in `src/runtime.zig`        |
| 2     | Refactor ARC into `src/memory/arc.zig` as a manager         |
| 3     | Implement `src/memory/arena.zig`                            |
| 4     | Wire `memory:` field in `lib/zap/manifest.zap`              |
| 5     | Codegen capability-elision pass                             |
| 6     | Verification — full test suite + lang-benches under both    |

### 6.6 Deferred

- `Process.spawn(memory: ...)` — needs the concurrency runtime first.
- Tracing GC, region, stats capability struct definitions — reserve IDs
  now, define when first consumer arrives.
- Per-manager type layout (e.g., dropping `ArcHeader` from `Map`/`List`/
  `String` under Arena). Accept the 4-byte/object waste under Arena for
  v1; revisit if measurements show it matters.
- Mixed-manager binaries / mid-program manager switching.

---

## 7. Open Research Questions

The plan is concrete enough to start work, but several decisions would
benefit from depth-research before locking. The research agent should
investigate each and produce a recommendation with citations.

### 7.1 Build-pipeline integration

**Q1.** Zap's current build pipeline lowers a Zap program to LLVM IR via
`libzap_compiler.a` and links a single object. The proposed design needs
to additionally compile a separately-supplied Zig source file (the
manager) and link it into the final binary. What's the cleanest way to
extend the pipeline?

- Sub-question: does `zig build-lib` invoked as a subprocess produce
  a `.o` that Zap's linker can pick up?
- Sub-question: does the Zig fork need a new C-ABI entry point that
  takes a "side module" path and links it through the same Compilation?

**Q2.** How does the compiler read `extern const zap_memory_capabilities`
from a Zig-produced `.o` *without* running the manager's `init`? Standard
ELF/Mach-O symbol-table inspection works for this, but Zap doesn't
currently do it. Is the right answer to invoke `nm`/`llvm-nm` and
parse output, to add a Zig fork helper that reads the const value at
link time, or to require the value also be encoded into the symbol
name (e.g., `zap_memory_capabilities__1`)?

### 7.2 Prior art for the ABI shape

**Q3.** The proposed shape (versioned core vtable + per-capability
sub-vtables retrieved via `get_capability(id)`) is modeled on Linux's
`dma_buf_ops` and COM's `QueryInterface`. Survey other systems that
solve "pluggable allocators / memory managers with capability discovery":

- Swift's allocator hooks / runtime allocator overrides.
- Rust's `GlobalAlloc` trait and `AllocRef` proposal history.
- OCaml multicore's per-domain heaps.
- Erlang BEAM's per-process heaps and garbage-collection-per-process.
- LLVM's `MemoryAllocator` hierarchy.
- jemalloc/mimalloc/tcmalloc's pluggable allocation hooks.
- C++'s `std::pmr::memory_resource` (polymorphic memory resources).

For each: how do they handle capability discovery? Versioning? ABI
stability across years of evolution?

### 7.3 Tracing GC capability shape (forward-looking)

**Q4.** When the eventual tracing-GC capability ships, what's the minimum
viable vtable? The reserved slot is `ZapTracingGCCapability` (capability
ID `GCOL`). Survey:

- Boehm GC's API surface.
- The JVM's `GarbageCollectorMXBean` / write-barrier conventions.
- Go's runtime GC interface boundaries.
- OCaml multicore's per-domain GC roots.
- MMTk (Memory Management Toolkit, the modular GC research framework).

Recommend a v1 surface that's small enough to ship and rich enough to
cover the common case (mark-and-sweep, generational, concurrent
marking). Do not implement; only specify.

### 7.4 Region-based memory capability (forward-looking)

**Q5.** For a `ZapRegionCapability` (capability ID `REGN`), survey:

- Cyclone's region system.
- MLkit's regions and region inference.
- Rust's lifetime-as-regions model.
- ATS's linear types + regions.

Recommend a v1 surface and discuss whether the region capability can
coexist with refcounting in the same program, or whether it's mutually
exclusive at the manager level.

### 7.5 Thread-safe Arena specifics

**Q6.** A single `std.Thread.Mutex` around the bump pointer scales poorly
under heavy concurrent allocation. Survey alternatives:

- Per-thread sub-arenas with thread-local bump pointers.
- Lock-free bump (atomic CAS on the offset).
- Hazel/jemalloc-style per-CPU caches.
- Erlang BEAM's per-scheduler heaps and the migration discipline.

For Zap's likely workload (many short-lived processes each making bursts
of allocations on a single OS thread), which strategy gives the best
correctness/performance tradeoff?

### 7.6 Codegen elision correctness

**Q7.** The compile-time switch that elides retain/release under
non-refcounting managers must be correct: every site that currently
emits a retain or release call must be visited. Survey prior art:

- Swift ARC's elision passes (LLVM ARC opt).
- Lobster's ARC elision compiler passes.
- Perceus' refcount-elision research.

What testing strategies do these projects use to gain confidence that
their elision passes are correct? Property-based testing,
differential testing, exhaustive symbolic execution?

### 7.7 Coexistence of ARC-aware types under Arena

**Q8.** Zap's `Map`, `List`, `String` embed an inline `ArcHeader` field.
Under Arena, this 4-byte field is dead weight per object. The plan
accepts this for v1. Investigate:

- What's the cost in real workloads? For binarytrees-like (millions of
  small allocations) the waste is significant. For mandelbrot-like
  (few allocations) it's negligible.
- Is there a Zap-internal redesign that lets these types declare their
  refcount slot conditionally (per-binary, based on active manager) without
  forking the entire type definition? Sketch the compiler change.
- What does Swift do for `String`/`Array`/`Dictionary` under their ARC?

### 7.8 Process-isolation semantics for future spawn-time selection

**Q9.** When `Process.spawn(memory: Zap.Arena)` lands, two questions
must be answered cleanly:

- Can processes share heap references at all, or are they fully
  isolated (BEAM-style copy-on-send)? If shared references are
  allowed, how does cross-manager retain/release work?
- If a process running under Arena receives a message containing
  ARC-managed data from another process, who owns it?

Survey BEAM's exact discipline here, plus newer languages with
per-task heaps (OCaml multicore domains, Pony's actors).

### 7.9 First-party manager source location

**Q10.** Three locations under consideration for the first-party manager
Zig sources:

- `src/memory/arc.zig` and `src/memory/arena.zig` (parallel to existing
  `src/*.zig` runtime).
- `src/runtime/memory/arc.zig` and `.../arena.zig` (nested under a new
  `runtime/` subdirectory; would prompt renaming the existing
  `src/runtime.zig`).
- `lib/zap/memory/arc.zap` (declarative wrapper in Zap, pointing at
  Zig sources elsewhere).

What's idiomatic for Zap? Survey how the existing `src/` directory is
organized and recommend.

### 7.10 Risk mitigation prototype

**Q11.** The two biggest implementation risks are (a) linking an external
Zig module into a Zap-built binary, and (b) reading the
`zap_memory_capabilities` constant at build time. Recommend a minimal
spike — what's the smallest end-to-end prototype that proves these two
risks are tractable before we commit to the rest of the plan?

---

## 8. Constraints and Non-Negotiables

These are project rules. Any recommendation that violates them is
out of scope.

- **No workarounds.** Solutions must be production-grade, regardless of
  cost. If a proper fix requires deep changes to Zap, the Zig fork, the
  build pipeline, or the runtime, those are the fix.
- **No regressions.** All 1040+ tests must remain green under
  `Zap.ARC`. All six lang-benches must continue producing correct output.
- **Thread safety baked in.** Every shipped manager is thread-safe from
  v1. No "single-threaded mode" carve-outs.
- **No mid-program mutability primitives.** Zap is purely functional.
  The manager itself can use mutation internally (e.g., the slab pool's
  atomic refcount); user-visible Zap code does not.
- **Forward compatibility with concurrency.** The ABI must not preclude
  `Process.spawn(memory: ...)` per-process selection.

---

## 9. Deliverables Expected from Research

1. A recommendation document covering Q1–Q11 above, with each
   recommendation backed by citations to prior art or implementation
   evidence.
2. A revised ABI sketch incorporating findings (especially for Q3, Q4,
   Q5 which directly shape the vtable layout).
3. A risk-mitigation spike outline (Q11) that the team can execute
   before locking the design.
4. A list of any *new* open questions that the research surfaces but
   doesn't resolve.

---

## 10. References

### 10.1 Files in `~/projects/zap/`

- `src/runtime.zig` — all runtime types; `ArcSlabPool` ~1543-2200,
  retain/release entry points ~2250-2360, inline-header types
  ~3000-7700.
- `src/zir_builder.zig` — Zap IR → ZIR lowering.
- `src/zir_backend.zig` — C-ABI boundary to the Zig fork.
- `src/arc_param_convention.zig` — ownership analysis.
- `src/main.zig` — CLI; build pipeline orchestration.
- `lib/zap/manifest.zap` — `Zap.Manifest` struct.
- `lib/zap/env.zap` — build environment.
- `lib/kernel.zap` — top-level macros.
- `lib/io/mode.zap` — `pub union IO.Mode` example of a dotted-name struct.
- `CLAUDE.md` (root) — project rules and conventions.

### 10.2 Files in `~/projects/zig/`

- `src/zir_api.zig` — C-ABI exposed to Zap.
- `src/Sema.zig` — semantic analysis (this is where the
  `tuple_decl → resolveInst` null-pointer bug lives; see Q11
  if the research agent encounters tuple-typed nested signatures).
- `src/Compilation.zig` — overall compile orchestration.
- `src/Zcu/PerThread.zig` — per-thread compilation state (relevant
  for the Sema-level work the codegen-elision pass may touch).

### 10.3 Recent commits relevant to the runtime

- `f59c67d perf(runtime/ArcPool): slab allocator with eager unmap`
- `077467e perf(runtime/ArcPool): side-table refcounts collapse Arc(T) cell size`
- `c4f4758 feat(runtime): MapIter cursor type for O(N) iteration`
- `239d084 perf(compiler): borrow elision`
- `b32e95e fix(runtime): close 13-gap analysis on Map/ArcSlabPool/MapIter post-mortem`
- `548a70e fix(runtime,docs): close 4-gap second-round analysis on Map guards + slab telemetry`

### 10.4 Existing design docs

- `docs/arcpool-slab-allocator-implementation-spec.md` — slab allocator
  spec (as built; references the side-table layout).
- `docs/binarytrees-pool-page-return-research-brief.md` — earlier
  research brief format used as the template for this document.
- `docs/arcpool1.md`, `docs/arcpool2.md` — research output from the
  slab allocator deep-research pass.

### 10.5 External references (starting points for the research agent)

- Linux kernel: `include/linux/dma-buf.h` for the `dma_buf_ops`
  capability vtable pattern.
- COM: Microsoft's `IUnknown::QueryInterface` documentation.
- Zig stdlib: `std/heap.zig` — `ArenaAllocator`, `Allocator` interface.
- Boehm GC: `gc.h` API.
- MMTk: `mmtk-core` source on GitHub, particularly `Plan` and `Mutator`
  traits.
- Swift ARC optimization: LLVM's `ObjCARC` passes.
- Perceus paper: "Perceus: Garbage Free Reference Counting with Reuse"
  (Reinking et al., Microsoft Research).
