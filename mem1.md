# Pluggable, Versioned, Capability-Based Memory Manager ABI for Zap — Deep Design Recommendation

## TL;DR

- **Ship a Zig-native vtable (not a C-ABI flat struct) for the v1 ABI**, version it with a magic+major+minor triple in a `zap_memory_capabilities` const that the Zap compiler reads via `llvm-nm`/object-file parsing from a `zig build-lib`-produced `.o`; this gives you COM/dma_buf-style capability discovery without paying the symbol-resolution and TLS-recursion taxes that killed glibc malloc hooks and complicated `#[global_allocator]`. Recommend keeping compile-time retain/release elision (the Swift/Koka/Lobster lineage proves it is sound and zero-cost) but **revisit the "thread-safe from v1" rule for Arena** — once per-process heaps land, the lock is dead weight.
- **First-party managers belong in `src/runtime/memory/`** (mirrors Roc's `crates/compiler/builtins/bitcode` + Rust's `library/alloc` split between language-level and runtime-level code), and the Arena reclamation model should stay whole-program for v1 *but* the ABI must reserve a `lifetime_scope` field now (Vulkan's `VkSystemAllocationScope` is the prior art that wishes it hadn't been added later).
- **The biggest risk to the project is not linking or symbol reading — those are routine** (Rust's `rustc --emit=obj`, Roc's host model, MMTk's `cdylib` boundary all do this daily). The real risk is the **ArcHeader cost under Arena**: under the binary-tree benchmark it is a 25–33% memory tax on small nodes, and Swift's resilient-layout design is the only relevant prior art for fixing it without forking type definitions. Spike Q11 first, but plan a follow-on spike for header-elided types.

---

## Key Findings

### F1. The ABI shape question is already resolved by industry consensus, but not in the direction the current plan assumes.

Every successful pluggable-memory system in the last 15 years has converged on **one of two patterns**, not the third one (flat C-ABI vtable) the Zap plan currently uses:

| System | Pattern | Cross-language? | Versioning |
|---|---|---|---|
| Linux `dma_buf_ops` | Native struct-of-fn-ptrs, in-tree only | No (kernel C) | Implicit (kernel ABI) |
| HotSpot `CollectedHeap` (JEP 304) | C++ virtual class, in-tree only | No | Source-level |
| MMTk `Plan`/`Mutator` | Rust trait, `cdylib` boundary for Ruby/V8/JikesRVM | Yes via `extern "C"` shim | Crate semver |
| Microsoft COM `IUnknown::QueryInterface` | Flat C vtable + GUID capability lookup | Yes | GUID-per-interface |
| C++ `std::pmr::memory_resource` | C++ virtual class | C++ only | Standard versioning |
| Vulkan `VkAllocationCallbacks` | Flat C function pointers in a struct | Yes | Struct extension via pNext |
| Rust `GlobalAlloc` | Rust trait, single static instance | No (Rust-internal indirection) | Trait stability |
| Swift allocator | Runtime hook into `swift_slowAlloc` | No | Internal |
| glibc malloc hooks | Mutable global function pointers | Yes | **Deprecated/removed in glibc 2.34** |

**The flat-C-ABI-vtable + capability-bitmap pattern from the current Zap plan is essentially "COM minus QueryInterface".** It is workable but inferior to two alternatives:

1. **Zig-native vtable with versioned struct (the dma_buf_ops style).** Since Zap's runtime and managers are both written in Zig, the C-ABI restriction is gratuitous. Zig's `Allocator` interface (`std.mem.Allocator`) is itself a fat-pointer with a vtable struct, and the Zig 0.16 fork can directly expose this. You lose nothing if third-party managers are also Zig packages — and the user has already settled on "external Zig package linked at build time" for third-party managers (Q3 settled decision). Going C-ABI now adds friction (`extern struct`, no `comptime` constraints, awkward `?*anyopaque` user-data plumbing) for an extensibility you've already ruled out.
2. **COM-style QueryInterface for capabilities.** Instead of a static `zap_memory_capabilities` bitmap, have a single `query_interface(capability_id: u32) ?*const anyopaque` function. This is what dma_buf_ops effectively does (optional vtable slots are null), what HotSpot's JEP 304 effectively does (subclassing `CollectedHeap` and overriding virtual methods), and what COM exactly does. **The bitmap approach forces every manager to know about every capability** that may be defined in the future; QueryInterface allows late-bound discovery. For Zap's stated forward-compat goal (GCOL, REGN capabilities defined later), this is a meaningful difference.

**Recommendation:** Go Zig-native vtable + `query_interface(cap_id)` function pointer. Keep the `extern "C"` calling convention on the function pointers themselves so LLVM ABI is stable, but allow Zig types in the signatures (e.g., `Allocator.Error!`-style error unions via tagged returns).

### F2. Compile-time elision is the right call, and the prior art is overwhelming.

The relevant lineage is **Swift ARC opt → Lobster lifetime analysis → Counting Immutable Beans (Lean, Ullrich & de Moura 2019) → Perceus (Reinking, Xie, de Moura, Leijen, PLDI 2021) → Koka/Roc**. Key facts:

- **Lobster's compiler removes ~95% of retain/release pairs at compile time** ("95% of reference count ops removed at compile time thanks to lifetime analysis," per Wouter van Oortmerssen's documentation). The remaining 5% is in code where ownership cannot be statically resolved.
- **Perceus has a formal soundness proof in a linear resource calculus** ("We give a novel formalization of reference counting in a linear resource calculus, and prove that Perceus is sound and garbage free," Reinking et al., PLDI 2021). This is the strongest known correctness foundation for ARC elision.
- **Counting Immutable Beans (Ullrich & de Moura, ICFP 2019) is Lean 4's RC scheme**, and the paper explicitly motivates: "many disadvantages are frequently reported in the literature. First, incrementing and decrementing reference counts every time a reference is created or destroyed can significantly impact performance because they not only take time but also affect cache performance, especially in a multi-threaded program."
- **Swift's ARC optimizer runs at the SIL level, before LLVM IR**, because high-level semantic info is lost in LLVM IR (Swift docs: "The goal is to implement optimizations that can't be implemented in LLVM-IR because the high-level semantic information is lost"). This matters for Zap: **do your elision pass at HIR or IR, not ZIR/LLVM IR.**

The alternative — runtime no-op vtable dispatch — has a real cost: the GlobalAlloc Rust trait's `#[global_allocator]` design has been criticized because "Many global allocators are zero-sized as their state lives outside of the Rust structure, but a reference to the allocator will be 4 or 8 bytes" and the indirection prevents many optimizations. The Rust Allocator API tracking issue (#49668) records years of churn over exactly this kind of issue. **Compile-time elision avoids the whole class of problems.**

**However, the "compile-time when manager doesn't declare REFCOUNT_V1" rule has a subtle correctness issue inherited from Swift:** Swift's is_unique check (`_swift_isUniquelyReferenced`) creates a hazard for LLVM-level ARC optimization where retain/release pairs that look removable are not, because the in-between code path may observe the count. Zap will eventually want a similar `unique?` primitive for Perceus-style reuse. **Lock down now that the elision pass operates on a HIR/IR level with explicit `dup`/`drop` nodes (Perceus style), not on post-IR pattern matching.** Otherwise, when GCOL or REGN capabilities arrive and need write barriers, you will inherit Swift's pre-2014 mess.

### F3. The Arena threading decision is the wrong default given the forward roadmap.

The user has set "all shipped managers thread-safe from v1" as non-negotiable. The evidence challenges this:

- **A single mutex around a bump pointer is catastrophic under concurrent allocation.** Bumpalo (the Rust de-facto bump arena) is explicitly single-threaded for this reason. The TBB scalable allocator, jemalloc, mimalloc, and snmalloc all use per-thread/per-CPU arenas; Hoard pioneered this in 2000. **No production bump allocator that matters uses global locking.**
- **BEAM's per-process heaps are exactly the forward model Zap is targeting.** From the Erlang docs: "The garbage collector Erlang uses to manage dynamic memory is a per process generational semi-space copying collector using Cheney's copy collection algorithm together with a global large object space." Per-process heaps mean *no synchronization is needed for the per-process arena at all* — only for the shared binary heap.
- **Pony's per-actor heaps achieve "concurrent garbage collection... per-actor, which eliminates the need to pause program execution or 'stop the world'"** (ponylang.org). The deny-capabilities paper (Clebsch et al.) is explicit: per-actor heaps with reference-capability-enforced sharing means GC runs locally without coordination.

**The contradiction:** if Zap's forward model is per-process heaps, then a thread-safe v1 Arena is dead weight forever — once `Process.spawn(memory: Zap.Arena)` lands, each process has its own arena that *cannot* be touched by other processes, so the lock is never contended. Worse, the lock is a *correctness liability* under the forward model because it suggests cross-process arena sharing might be legal, which it isn't.

**Recommended revision:** Ship the v1 Arena as a thread-confined arena (panic if cross-thread access detected via TLS check in debug, undefined in release). Reserve the right to relax this only via a capability bit (`ARENA_THREAD_SAFE_V1`) on a future variant. This matches Bumpalo, the Cyclone region model, and BEAM's per-process discipline. The "thread-safe by default" rule should apply to *managers that can legally be shared*, not to ones whose forward model forbids sharing.

### F4. The ArcHeader dead-weight problem under Arena is real and prior art is thin.

Under whole-program Arena, the 4-byte `ArcHeader` on every Map/List/String is pure waste. The cost analysis:

- A binary-tree benchmark allocating millions of 2-word cons cells pays a **25% memory overhead** (4 bytes header on a 16-byte object) and a corresponding L1 cache pressure increase.
- A mandelbrot-style benchmark with few allocations pays effectively zero.

The prior-art landscape for build-time conditional struct layout:

| System | Mechanism | Build-time / Run-time | Usable here? |
|---|---|---|---|
| C++ templates | Type-level | Build-time, but explodes binary | Per-type explosion is unacceptable |
| Rust `#[cfg(feature)]` fields | Crate-feature gated | Build-time | Closest match — recommended |
| D `static if` | Conditional compilation | Build-time | Same as Rust cfg |
| Zig `comptime` | Conditional layout via `comptime` | Build-time | **Natural fit for Zap's host language** |
| Swift resilient layout | Indirect field access via runtime metadata | Run-time | Too expensive for hot types |
| Swift `String`/`Array` | ARC-aware with native storage | Always pays header | Not a model — Swift accepts the cost |

**Recommendation:** Use Zig `comptime` to generate the Map/List/String types parameterized by the active manager's capability set. The header field exists in the type iff `REFCOUNT_V1` capability is declared at build time. This is exactly the pattern Rust uses with `#[cfg(feature = "...")]` on struct fields and is well-trodden. **However, this conflicts with the settled decision that managers are linked late (after Zap source is compiled to ZIR).** You will need to push the active manager's capabilities into the compiler *before* HIR→IR lowering so type layout can branch on it. This is doable but requires the build pipeline to read the manager's capability const *before* compiling Zap source, not just before linking. **This is the most important architectural finding in this report.**

### F5. The capabilities-from-object-file problem has good solutions but requires picking one.

Three approaches, in order of preference:

1. **`zig build-lib --emit-h` + post-process the generated header.** When you build the manager as a static library with C-ABI exports, Zig emits a C header listing exported symbols. Parse that header (or use `llvm-nm -P obj.o`) to find `zap_memory_capabilities` and `zap_memory_capabilities_data`. Then read the value via either:
   - Encoding the capability bits *into the symbol name* (e.g., `zap_memory_capabilities_v1_0_0x000000F3`). `llvm-nm` exposes this with zero parsing of object section data. **Cheap, robust, portable across ELF/Mach-O/COFF.**
   - Reading the symbol's section data via `llvm-objcopy --dump-section` or `objdump -s -j .rodata`. More work; portable.
2. **Have the Zap compiler invoke `libzig.so`/`libzap_compiler.a` to evaluate the manager's `comptime` const directly.** This is what Roc does with its platform model and what `rustc -Zinstrument-coverage` does for similar metadata extraction. It requires a C-ABI entry point on the Zig fork like `zig_evaluate_const(source_path, symbol_name, out_buf)`. **More powerful (full Zig comptime available) but requires Zig-fork work.**
3. **Two-pass build: compile manager with a special `--print-capabilities` mode**, where the manager exposes a `_start`-equivalent that prints capabilities to stdout, capture, then real build. **Avoid** — fragile, doubles build time, breaks reproducibility.

**Recommended: option 1, symbol-name encoding.** The encoding is `zap_mm_caps_v{major}_{minor}_{hexbits}_{name}`. To read it, run `nm` (or use the LLVM `Object` library directly via the Zig fork's C ABI). This is exactly the technique used by ELF section attributes for things like `__attribute__((section("..."))) static const` in glibc and the kernel module system.

### F6. Region capability (REGN) — design before you commit to whole-program Arena.

The region literature is the most relevant *theoretical* prior art for Zap's Arena and for future capability shapes:

- **Tofte–Talpin region inference (1994)** in the MLkit: regions are inferred from types, and each region has a lifetime tied to a lexical scope. Reclamation is *stack-discipline*: when the scope exits, the region is freed.
- **Cyclone (Grossman, Hicks, Jim, Morrisett, 2002)** added regions to C with explicit `region r { ... }` blocks and pointer types annotated with regions (`int *@r`).
- **Rust's lifetimes** are a degenerate form of regions — every reference has a region (lifetime), and the borrow checker enforces region discipline at compile time. **Rust did not adopt arena-as-runtime-value because compile-time regions subsume it.**
- **Koka's effect-typed regions** (Leijen) and **Mae's regions** are recent functional reinterpretations.
- **MLkit's region inference** has a notorious failure mode: long-lived regions accumulate garbage, leading to the "region bloat" problem solved by mixing GC into regions.

**The crucial observation for Zap:** *whole-program arena is a degenerate region — there is exactly one region, scoped to the program.* This is why it works for short-running batch jobs (a compiler pass, a CLI tool) and fails for servers. The decision to ship whole-program-only is the right v1 move *if and only if* you commit to making Arena a poor choice for long-running programs. Document this loudly.

For a future REGN capability, the v1 vtable surface should be:
```
region_create(name: []const u8) RegionHandle
region_alloc(rh: RegionHandle, size, align) ?[*]u8
region_free_all(rh: RegionHandle) void   // whole-region reclamation
region_destroy(rh: RegionHandle) void
// optional: region_subscope(rh) RegionHandle (Cyclone-style nesting)
```
Coexistence with ARC: **regions and refcounting are NOT mutually exclusive at the manager level if you forbid heap pointers from RC objects into region memory.** Cyclone solves this with the `@region` type annotation; without static enforcement, Zap should ship REGN as a *separate* manager that disables ARC (i.e., REGN and REFCOUNT_V1 are mutually exclusive capability bits in v1).

### F7. GCOL capability — minimum viable vtable from MMTk and HotSpot.

MMTk's `Plan` and `Mutator` traits are the most rigorous published interface. Drawing also from JEP 304's `CollectedHeap` and Go's runtime GC:

**Minimum viable v1 GCOL vtable:**
```
// Mutator-side (per-thread / per-process)
mutator_bind(thread_id) MutatorHandle
mutator_destroy(MutatorHandle) void
mutator_alloc(mh, size, align, semantics: enum {Default, Immortal, LargeObject}) [*]u8
mutator_flush(mh) void   // for remembered-set / TLAB sync

// Object model (write barriers)
write_barrier(slot: **anyopaque, new_value: *anyopaque) void  // post-write
write_barrier_pre(slot: **anyopaque, old_value: *anyopaque) void  // optional, declared via subcap

// Collection control
gc_request(reason: enum {Heuristic, Forced, Emergency}) void
gc_safepoint() void   // mutator yields if collector wants to stop the world

// Object model queries (required by collector)
object_size(obj: *anyopaque) usize
trace_object(obj, visitor: TraceFn) void
finalize_register(obj, fn: FinalizeFn) void
```

This surface covers:
- **Mark-and-sweep collectors** (use only `gc_request`, no barriers needed)
- **Generational collectors** (use `write_barrier` post-write for old→young remembered set)
- **Concurrent marking collectors** like Shenandoah/ZGC (use `write_barrier_pre` for SATB-style snapshot-at-the-beginning marking, or post-write for incremental update)

Per MMTk's documented design: "It includes components such as allocators, spaces and work packets that GC implementers can choose from to compose their own GC plan easily." The pattern of *parameterizing the collector by allocation semantics* (Default/Immortal/LargeObject) is critical — MMTk's `AllocationSemantics` enum is the right precedent. **Specify these semantics in the v1 GCOL spec even though v1 GCOL is not implemented**, so the Map/List/String types can be coded to request them.

JEP 304 also splits responsibilities into `GCInterpreterSupport`, `GCC1Support`, `GCC2Support` — i.e., the GC interface contains *codegen-side helpers for each tier of the compiler*. For Zap, this means **the GCOL capability needs to extend the codegen to emit barrier calls or inline barriers**. Plan for this: the capability discovery process should let the compiler know whether to emit `barrier(slot, val)` calls at all assignment sites involving heap pointers.

### F8. Thread-safe Arena — concrete recommendation matrix.

| Strategy | Allocation cost | Memory overhead | Correctness complexity | Fits per-process model? |
|---|---|---|---|---|
| Global mutex on bump pointer | High (contention) | None | Low | No — wasted lock |
| Atomic CAS on offset | Low when uncontended; livelock under heavy contention | None | Medium | No — wasted atomics |
| Per-thread sub-arenas (Bumpalo-per-thread) | Lowest | Per-thread waste (typ. 64–256KB) | Low | **Yes — degenerates to per-process arena** |
| Per-CPU caches (mimalloc, jemalloc style) | Lowest | Per-CPU waste | High | Overkill |
| TBB scalable allocator | Lowest | Moderate | High (TBB has many corner cases) | Overkill |
| Snmalloc message-passing free | Very low | Moderate | Very high | Overkill |

**Recommendation:** For Zap v1, **ship a thread-confined Arena, not a thread-safe Arena.** Document that cross-thread access aborts in debug builds and is UB in release. Reserve the capability bit `ARENA_THREAD_SAFE_V1 = 0x...` for a future variant that wraps a per-thread sub-arena strategy. This is exactly the BEAM/Pony discipline: per-actor heaps require no synchronization because the type system (or runtime) prevents sharing.

### F9. Process-isolation semantics — pick BEAM-style copy-on-send.

Evidence:
- **BEAM copies on send**: messages between processes are *deep-copied* through the receiving process's heap (with a large-binary exception that is reference-counted in a shared heap). Per Erlang's official docs: "the payload may be placed in a heap-fragment and that fragment is added to young heap when the message is matched in a receive clause." This means **no cross-process pointer ever exists** in normal code.
- **Pony shares via reference capabilities**: `iso` (isolated, single writer), `val` (immutable, freely shared), `tag` (only identity, no read/write). Sharing is allowed but the type system makes data races impossible. GC is per-actor and runs without coordination because deny-capabilities prevent cross-actor mutation.
- **OCaml multicore**: per-domain minor heaps (private), shared major heap with concurrent GC. Cross-domain pointers exist and the GC handles them. Conceptually richer but vastly more complex than BEAM.
- **Rust's Send/Sync**: compile-time discipline, not runtime separation.

**Recommendation for Zap:** Adopt BEAM-style copy-on-send. When `Process.spawn(memory: Zap.Arena)` lands:
1. Each process has its own manager instance.
2. `send/2` between processes deep-copies the message through the receiver's manager.
3. Cross-process references are forbidden by construction (no syntax to create one).
4. Reserve a future capability `SHARED_HEAP_V1` for large-binary-style shared, refcounted blobs — but DO NOT design for cross-manager retain/release in v1. That problem has consumed years in Java's GC literature; you do not need to solve it in v1.

If a process running under Arena receives a message containing ARC-managed data, the message is copied through Arena's allocator, and the original sender's ARC-managed data is unaffected. **The data is by definition not shared.** This is the only semantics that scales.

### F10. First-party manager location — `src/runtime/memory/`.

Surveying comparable projects:

| Project | Layout | Rationale |
|---|---|---|
| Roc | `crates/compiler/builtins/bitcode/src/` (LLVM IR) + `crates/roc_std/` | Split between compile-time and runtime |
| Swift | `stdlib/public/runtime/` (C++ runtime) + `stdlib/public/core/` (Swift stdlib) | Runtime separate from compiler |
| Rust | `library/alloc/` + `library/std/` + compiler in `compiler/` | Allocator API in `alloc`, not in compiler |
| Crystal | `src/` (stdlib) + `src/gc/` for GC bindings | Memory mgmt in stdlib subdirectory |
| Ruby | `gc/default/` and `gc/mmtk/` (Ruby 3.4 modular GC) — explicitly subdir-of-gc | Each GC is a self-contained subdir |

**Recommendation: `src/runtime/memory/arc/` and `src/runtime/memory/arena/`.** This mirrors Ruby 3.4's `gc/{default,mmtk}/` exactly — the precedent that most closely matches Zap's situation (statically-typed-AOT-language adding pluggable GC). The `src/runtime/memory/` prefix communicates that this is *runtime support code, not language semantics*. Avoid `lib/zap/memory/` — `lib/` suggests user-facing API, which it isn't. Avoid `src/memory/` — too generic; future contributors will not know whether to look there for VM-level or stdlib-level memory code.

### F11. Risk-mitigation spike prose outline (Q11).

**Goal:** Validate the two highest-risk technical assumptions: (a) external Zig `.o` linking into a Zap binary, (b) reading the `zap_memory_capabilities` constant at build time. Plus build end-to-end confidence with a no-op manager.

**Estimated total duration: 3–5 engineer-days.**

**Step 1 — Skeleton no-op manager package (~2 hours).**
Create `spike/noop_manager/build.zig` and `spike/noop_manager/src/manager.zig`. The Zig source exports:
- `export const zap_mm_caps_v1_0_0x00000000_noop: u64 = 0;` (capability bitmap is zero — no REFCOUNT_V1, no nothing)
- `export fn zap_mm_alloc(size: usize, align: u8) callconv(.C) ?[*]u8` — returns `null` always (this proves linking without needing actual heap behavior)
- `export fn zap_mm_free(ptr: [*]u8, size: usize, align: u8) callconv(.C) void` — no-op
- `export fn zap_mm_init() callconv(.C) void` — no-op
- `export fn zap_mm_deinit() callconv(.C) void` — no-op

**Success criterion:** `zig build-lib -static -O ReleaseSmall` produces `libnoop_manager.a` (or `.o`). Run `nm libnoop_manager.a` and verify the exported symbols appear with their expected mangled names.

**Failure modes & fixes:**
- *Symbols missing*: ensure `export` keyword and `callconv(.C)`. Zig requires both.
- *Static lib link issue on macOS*: on Mach-O, use `--emit=obj` to get a single `.o` rather than `.a` if `.a` archives are stripping unused symbols.

**Step 2 — Capability discovery via symbol parsing (~4 hours).**
Write `spike/zap-caps-probe/main.zig`, a small standalone tool that:
1. Takes a `.o` or `.a` path.
2. Shells out to `llvm-nm -P <path>` (or links against `libLLVM` if available in the Zig fork).
3. Parses output for symbols matching the regex `^zap_mm_caps_v(\d+)_(\d+)_0x([0-9a-fA-F]+)_(\w+)$`.
4. Returns the major, minor, bitmap, and manager name.

**Success criterion:** Running the probe against `libnoop_manager.a` prints `v1.0 caps=0x00000000 name=noop`.

**Failure modes & fixes:**
- *llvm-nm not on PATH*: bundle it (Zig 0.16 already vendors LLVM tooling). Fall back to a hand-rolled ELF/Mach-O/COFF parser if needed — there's well-known prior art in the Zig stdlib's `std.elf` / `std.macho`.
- *Symbol-name mangling differs on Windows*: COFF prepends underscore on x86 (not x86_64); strip uniformly.

**Step 3 — Compiler integration: capability info available before HIR lowering (~1 day).**
Modify Zap's build pipeline so that:
1. The build command takes `--memory-manager <path-to-zig-pkg>`.
2. The driver first calls `zig build-lib` on the manager.
3. Then invokes `zap-caps-probe` on the resulting object.
4. Then *threads the bitmap into the compiler's HIR-lowering pass* via a context field (e.g., `Compiler.target_caps: u64`).
5. The HIR pass uses `if (caps & REFCOUNT_V1 != 0) { emit dup; emit drop; }`.

**Success criterion:** Compile a trivial Zap program (`def main do; "hello" end`) with the no-op manager. Verify the resulting LLVM IR contains *no* calls to `zap_arc_retain`/`zap_arc_release`. Verify the program crashes at runtime when it tries to allocate (since the no-op alloc returns null), proving the manager is actually called.

**Failure modes & fixes:**
- *ZIR generation happens before HIR lowering can see manager caps*: shows that the caps must be available *very* early — perhaps even before parse-time. Reshape the pipeline so caps are loaded from a project config file (e.g., `zap.toml`) and validated against the manager's `.o` after manager compilation. This is the "most important architectural finding" from F4.

**Step 4 — Link integration (~2 hours, may go wrong).**
Modify the linker invocation to include the manager's `.o` alongside Zap-generated `.o` files. Two approaches:
- (a) `zig build-lib` produces `.o`; Zap's existing link step adds it to the file list.
- (b) Add a C-ABI entry point to the Zig fork: `zig_compilation_add_side_module(comp: *Compilation, path: [*:0]const u8) c_int;` that runs the manager source through the *same* `Compilation` instance Zap is already using.

**Success criterion:** `./zap-no-op-program` runs, calls `zap_mm_init`, attempts allocation, crashes with null pointer (or graceful OOM).

**Failure modes & fixes:**
- *Two LLVM contexts collide* if approach (b) is taken: this is the classic LLVM library reentrancy issue. Approach (a) avoids this entirely. **Prefer (a).** Approach (b) is what Roc does for its host model and what Rust's `rustc_codegen_*` does internally; it works but requires care.
- *Symbol collisions between Zap stdlib and manager*: namespace all manager exports under `zap_mm_*`.

**Step 5 — Real ARC manager port-over (~1 day).**
Take the existing Zap ARC implementation, repackage it as a Zig package exporting `zap_mm_caps_v1_0_0x{REFCOUNT_V1}_arc`, and prove that the build pipeline picks it up *with no changes to Zap source code*. Run the 1040-test suite and the 6 lang-benches.

**Success criterion:** Zero regressions on tests, zero perf regression on benches.

**Failure modes & fixes:**
- *ArcHeader layout assumption broken*: discovered during this step. This is the F4 finding cashed in. Stop and design the comptime-conditional layout before proceeding.

**Step 6 — Arena manager from scratch (~1 day).**
Implement thread-confined Arena: single bump pointer, growing-chunk strategy (a la Bumpalo), no `free` implementation. Wire it up via the same pipeline.

**Success criterion:** `mandelbrot.zap` runs to completion. Memory usage grows monotonically. Process exit triggers whole-arena free. Benchmark shows allocation speedup vs. ARC.

**Spike exit criteria (cumulative):**
1. ✅ Can link external Zig `.o` into Zap binary.
2. ✅ Can read const from it at build time.
3. ✅ Can make a no-op manager work end-to-end.
4. ✅ ARC and Arena both work; capability discovery routes correctly.
5. ✅ No regression on existing tests.

**If the spike fails at step 3 or 4**, the architectural finding is that capability discovery cannot be a pure post-compile step — it must influence parse/HIR. Pivot to: caps are declared in `zap.toml`, manager build is validated against declared caps.

---

## Details

### Comparative matrix: capability discovery / versioning across systems

| System | Discovery | Versioning | ABI stability | Lessons for Zap |
|---|---|---|---|---|
| **Swift allocator** | Internal only; runtime sets via private hooks | Tied to Swift runtime | Re-broken on each Swift major | Don't tie ABI to runtime version |
| **Rust GlobalAlloc** | `#[global_allocator]` attr; single instance per crate graph | Trait semver | Stable since 1.28 | Single-instance constraint is painful for testing |
| **Rust Allocator (allocator_api)** | Per-collection generic param | Unstable since 2018 | Notorious for churn | Cautionary tale of over-design |
| **OCaml multicore domains** | Domain-local heaps + shared atomic heap | Tied to OCaml version | Major change in 5.0 | Per-domain heap is the right primitive |
| **Erlang BEAM** | Implicit; per-process always | OTP versioning | Stable for 25+ years | **Strongest model for Zap forward direction** |
| **C++ std::pmr** | Runtime polymorphism via `memory_resource*` | C++17 standard | Standard, stable | Runtime polymorphism cost is non-zero |
| **Vulkan VkAllocationCallbacks** | Per-API-call optional callback struct | pNext chain extension | Stable since 1.0 | **pNext is how you extend without breaking** |
| **glibc malloc hooks** | Global function pointer variables | None | **Removed in 2.34** for MT-unsafety | **Cautionary tale** — don't use global mutable pointers |
| **HotSpot JEP 304** | C++ virtual class `CollectedHeap` | Source-level only | Refactor in JDK 10, stable since | Codegen-side helpers are part of the interface |
| **MMTk** | Rust traits; cdylib boundary | Crate semver | Evolving; Ruby 3.4 first stable user | Modularity proven across V8/JikesRVM/Ruby/Julia |
| **COM IUnknown** | `QueryInterface(GUID)` | GUID-per-interface | Stable since 1993 | **Best capability discovery primitive in industry** |
| **dma_buf_ops** | Optional vtable slots (NULL = unsupported) | Implicit kernel ABI | Stable; evolves additively | Closest to what Zap should ship |
| **Zig Allocator** | Fat-pointer with vtable | Manual | Stable across 0.11→0.15 | Native model; embrace it |

### Comparative matrix: tracing GC interfaces

| System | Mutator API | Barrier API | Collector triggers | Codegen integration |
|---|---|---|---|---|
| Boehm GC | `GC_malloc`, `GC_register_finalizer` | None (conservative) | Auto on alloc | None — works post-codegen |
| HotSpot JEP 304 | `CollectedHeap::mem_allocate` | `GCInterpreterSupport`, `GCC1Support`, `GCC2Support` | Per-policy | **Per-compiler-tier helper class** |
| Go runtime | Built-in; mallocgc | Built-in write barriers, hybrid SATB | Auto with target rate | Compiler-internal |
| OCaml multicore | Per-domain minor heap; major shared | Block.set write barrier | Per-domain minor + global major | OCaml-specific |
| MMTk | `bind_mutator`, `Mutator.alloc` | Configurable per Plan | `gc()` request | Via Plan trait |
| V8 | Isolate-local; many specialized allocators | Many variants | Generational + concurrent marking | V8-internal |
| .NET pluggable GC | `IGCHeap` interface | Card table + ephemeral barriers | Per-policy | Loaded via env var |

The **.NET pluggable GC** (introduced in .NET Core 2.1, made official in .NET 5+) is worth singling out as the most successful production example of an out-of-tree GC for a managed runtime. It loads a separate `.so`/`.dll` via the `DOTNET_GCName` environment variable and implements `IGCHeap`/`IGCHandleManager`. **This is the most encouraging precedent for Zap's plan** — the .NET case proves a stable C-ABI-shaped GC interface is achievable for a real production language, and that the interface needs barriers, finalization, and allocation context per-thread.

### Why the Vulkan model is partly wrong for Zap

The Zap plan's "flat C-ABI vtable" closely resembles `VkAllocationCallbacks`. But Vulkan was designed when:
- The callbacks are *optional* (`pAllocator = NULL` is normal).
- The Vulkan implementation is C and cannot use vendor-extension types without `pNext` chains.
- Performance is dominated by GPU operations, not allocations.

Zap's situation is the opposite: the allocator is *not* optional, the language is Zig, and allocator performance is on the critical path. Vulkan's design is conservative because of cross-vendor constraints Zap does not have.

### Reference-capability lessons from Pony for the future Process model

The Clebsch et al. "Deny Capabilities for Safe, Fast Actors" paper formalizes Pony's `iso`/`val`/`ref`/`box`/`trn`/`tag` capability lattice. The crucial property: **per-actor heaps are sound because the type system prevents any reference from leaking outside the actor that owns the heap.** Zap does not have reference capabilities. If Zap adopts BEAM-style copy-on-send (the recommendation in F9), it avoids needing them. **If Zap ever wants pony-style zero-copy message passing, the type-system work required is enormous.** Make the copy-on-send commitment now to avoid that rabbit hole.

---

## Recommendations (Staged)

### Stage 0 — Before any code is written

1. **Re-decide the C-ABI vs. Zig-native vtable question.** Recommendation: Zig-native, with `extern "C"` calling convention on function pointers only. Document rejection of pure-C-ABI with reasoning.
2. **Re-decide thread-safe Arena.** Recommendation: thread-confined Arena, panic on cross-thread in debug.
3. **Re-scope the "build-time const reading" assumption.** Recommendation: capabilities are declared in `zap.toml` (project config), validated against the manager's `.o` symbol table at build time. This eliminates the chicken-and-egg between HIR lowering and manager compilation.
4. **Add ArcHeader-elision to the v1 roadmap.** Make a binding decision: either (a) accept the dead-weight cost for v1 and fix it in v1.1, or (b) use Zig comptime to conditionally include the header based on declared capabilities. Recommend (b) — the technical lift is moderate, the perf win is large (25% memory on binarytrees).

### Stage 1 — Execute Q11 spike

Days 1–5 as outlined in F11. **Exit criteria are the four cumulative checkmarks**, not "spike code is pretty." Throw the spike code away after — its sole purpose is to derisk.

**Trigger to revisit settled decisions:** if the spike reveals that the Zap compiler cannot read capability bitmap before HIR lowering without `zap.toml`-style declared caps, *that* is the moment to confirm the Stage-0 decisions stick.

### Stage 2 — Ship v1

1. Build the actual ABI based on spike findings.
2. Port ARC to the ABI as a first-party manager.
3. Build Arena as the second first-party manager.
4. Confirm zero regression on 1040+ tests and 6 lang-benches.

**Threshold to slip:** if the perf regression on benches is >2%, do not ship; investigate.

### Stage 3 — Reserve capability namespace now

Even though GCOL and REGN are out of scope for v1, **reserve their capability bits now** so third-party managers cannot accidentally pick conflicting values:

```
const REFCOUNT_V1: u64 = 0x0000_0001;
const ARENA_V1:    u64 = 0x0000_0002;
const REGN_V1:     u64 = 0x0000_0004;  // reserved
const GCOL_V1:     u64 = 0x0000_0008;  // reserved
const ARENA_RESET_V1: u64 = 0x0000_0010;  // reserved
const ARENA_THREAD_SAFE_V1: u64 = 0x0000_0020;  // reserved
const SHARED_HEAP_V1: u64 = 0x0000_0040;  // reserved (large-binary-style)
const FINALIZER_V1: u64 = 0x0000_0080;   // reserved
const WEAK_REF_V1: u64 = 0x0000_0100;    // reserved
const TRACING_V1: u64 = 0x0000_0200;     // reserved (write barriers)
```

Even just documenting this list pre-commits the design space and prevents v1 implementers from picking conflicting bits.

### Stage 4 — Add diagnostic managers

Add two test-only managers to expose elision and discipline bugs:

- **`leak` manager** (declares no caps): every alloc succeeds, free is no-op. Confirms ARC elision under non-ARC manager is correct.
- **`tracking` manager** (wraps another): logs every alloc/free, optional canary bytes, optional poisoning on free. Detects use-after-free.

These are not user-facing; they are CI tools. They are the single most cost-effective investment in correctness confidence.

### Stage 5 — Future capability roadmap

| Version | Capability | Trigger |
|---|---|---|
| v1.0 | REFCOUNT_V1, ARENA_V1 | Initial ship |
| v1.1 | ArcHeader-elided types under ARENA_V1 | If F4 finding confirmed |
| v1.2 | ARENA_RESET_V1 (scoped/reset arenas) | First user request for it |
| v2.0 | Per-process selection (`Process.spawn(memory: ...)`) | Concurrency model lands |
| v2.x | GCOL_V1 | When write-barrier infrastructure stabilizes |
| v3.x | REGN_V1 | When region inference research integrates |

---

## Caveats

1. **The "challenge settled decisions" framing in the question is taken seriously.** Two settled decisions are challenged with evidence: (a) thread-safe Arena (F3) and (b) flat C-ABI vtable (F1). The other settled decisions stand.

2. **The Q11 spike outline is high-confidence on steps 1–2, medium-confidence on steps 3–4.** Step 3 contains the architectural finding (caps must be available before HIR lowering). If the spike reveals this earlier, the team should pivot to `zap.toml`-declared caps without going through step 4–5.

3. **The ArcHeader cost analysis (25% memory on binarytrees, ~0% on mandelbrot) is from-first-principles reasoning, not from measurement.** Validate with an actual binarytrees-style benchmark before committing to comptime-conditional layout.

4. **The recommendation against runtime-no-op vtable dispatch (in favor of compile-time elision) assumes the elision pass can be made bulletproof.** Perceus' soundness proof exists in a linear resource calculus; Zap's HIR may not match that calculus exactly. Plan to formalize the elision rules at least at the level of rigorous test cases driven by the Perceus paper's example terms.

5. **The Pony/BEAM per-process-heap recommendation assumes Zap accepts copy-on-send.** If Zap ever wants zero-copy sharing of immutable values across processes (BEAM does this for atoms and large binaries via reference counting in a shared heap), this is a significant additional design effort. Defer until v2.0.

6. **The Vulkan VkAllocationCallbacks has a `pUserData` opaque pointer mechanism that the current Zap plan should adopt.** Every callback in the ABI must take an opaque manager-state pointer as its first argument — otherwise the manager is forced to use globals, recreating the glibc-hooks problem.

7. **Several published systems were not deeply analyzed due to search budget exhaustion**: D allocators, Mojo memory model, ATS linear types + regions, snmalloc internals, Project Loom virtual threads memory implications, FBIP follow-on papers. These are flagged as **open questions for follow-up research** below.

---

## New Open Questions Surfaced (Not Resolved)

1. **Can the Zap compiler load manager capabilities before HIR lowering without the `zap.toml` intermediate?** This is the architectural pivot point identified in F4. Answer determines whether comptime-conditional struct layout is feasible.

2. **What's the exact perf cost of ArcHeader under Arena in real Zap workloads?** Estimated 25% on binarytrees; needs measurement.

3. **Should the v1 ABI commit to a fixed-size header (4/8/16 bytes) for cross-manager binary compatibility?** Vulkan does this; COM does not. Implications for future shared-heap capability.

4. **How does the no-op manager interact with Zap's existing `defer`/destructor semantics?** If Zap source uses `defer free(x)` and the manager is no-op, does that compile away or stay as a no-op call?

5. **MMTk binding: should Zap consider becoming an MMTk binding for the GCOL capability?** MMTk handles V8, JikesRVM, Ruby, Julia. Joining that ecosystem might be cheaper than building a bespoke GC. Worth a separate prior-art investigation.

6. **What does Ruby 3.4's modular GC build-time integration look like at the source level?** This is the most directly comparable precedent and was found via search but not deeply analyzed.

7. **For the Process.spawn(memory:) model, what is the minimum primitive Zap needs to expose to user code to control per-process manager selection?** A keyword argument? A type-system marker? An effect annotation (Koka-style)?

8. **Are there any academic papers specifically on capability-based memory manager ABIs?** Search results showed industry implementations (COM, dma_buf_ops) but no formal academic treatment of *the ABI design itself*. This may be a publication opportunity for the Zap team.

---

## Where Settled Decisions Should Be Revisited

| Settled decision | Evidence | Recommended action |
|---|---|---|
| Arena reclamation: whole-program | Stands; matches Cyclone/MLkit failure mode literature | **KEEP** but document the long-running-program limitation loudly |
| Compile-time retain/release elision | Strong (Lobster 95% elision, Perceus soundness proof) | **KEEP** |
| Third-party managers as external Zig packages | Strong (matches Ruby 3.4 modular GC, .NET pluggable GC) | **KEEP** |
| Versioned core vtable + capability discovery | Mixed; QueryInterface (COM) is strictly more flexible than a bitmap | **REVISE** to `query_interface(cap_id)` function pointer in addition to or instead of bitmap |
| All shipped managers thread-safe from v1 | **Weak** given per-process forward model; contradicts Bumpalo/BEAM/Pony precedent | **REVISE** — Arena should be thread-confined, lock-free, and the v1 ABI should reserve `ARENA_THREAD_SAFE_V1` for a future variant |
| Flat C-ABI vtable | **Weak** given both runtime and managers are Zig; gratuitous restriction | **REVISE** — Zig-native vtable with `extern "C"` calling convention on function pointers |

The first three stand; the last three are challenged with cited prior art. The two strongest challenges are (a) thread-safe Arena (the BEAM/Pony evidence is overwhelming) and (b) flat-C-ABI (the only argument for it was cross-language extensibility that's already been ruled out).

---

*Sources cited inline: Rust RFC 1974 (global-allocators), Rust issue #49668 (GlobalAlloc tracking), Perceus paper (Reinking, Xie, de Moura, Leijen, PLDI 2021 + MSR-TR-2020-42), Counting Immutable Beans (Ullrich & de Moura, arXiv:1908.05647), Swift OptimizerDesign.md & ARCOptimization.html docs, MMTk documentation (docs.mmtk.io) and core source (mmtk/mmtk-core), Ruby 3.4 modular GC blog (Rails at Scale, Jan 2025), JEP 304 (Garbage-Collector Interface), JEP 475 (Late Barrier Expansion for G1), Khronos Vulkan spec VkAllocationCallbacks, Red Hat Developer "Securing malloc in glibc" (Aug 2021), Linux kernel dma-buf documentation and `include/linux/dma-buf.h`, cppreference std::pmr::polymorphic_allocator, Lobster docs (aardappel.github.io/lobster), Erlang/OTP garbage collection documentation (erts v16.x), Pony tutorial and "Deny Capabilities for Safe, Fast Actors" (Clebsch et al.).*
