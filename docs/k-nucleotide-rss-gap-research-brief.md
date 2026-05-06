# Zap: k-nucleotide RSS gap — research brief

> **Audience.** A deep-research AI agent with zero prior context on Zap,
> the Zap fork of the Zig compiler, the lang-benches harness, the ARC
> memory model, or how these repos fit together. Read top-to-bottom —
> §1–§8 establish the world model; §9–§11 describe the concrete
> performance gap and what the runtime substrate already does; §12 is
> the open compiler-pass problem you are being asked to design;
> §13–§15 are constraints, prior art, and questions to answer. The
> intended deliverable is a recommended implementation plan with
> concrete file paths, line numbers, design alternatives weighed, and
> a verification matrix.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [Memory model — pools + ARC](#5-memory-model--pools--arc)
6. [`@native_type` and stdlib bridging](#6-native_type-and-stdlib-bridging)
7. [The Map runtime today (post commit `07f56c7`)](#7-the-map-runtime-today)
8. [The Perceus / move-semantics literature](#8-the-perceus--move-semantics-literature)
9. [The k-nucleotide benchmark](#9-the-k-nucleotide-benchmark)
10. [Measured RSS gap and scaling](#10-measured-rss-gap-and-scaling)
11. [Why allocations leak today — root cause](#11-why-allocations-leak-today--root-cause)
12. [The codegen integration gap](#12-the-codegen-integration-gap)
13. [Why the previous implementation attempt failed](#13-why-the-previous-implementation-attempt-failed)
14. [Design constraints (non-negotiable)](#14-design-constraints-non-negotiable)
15. [Verification matrix](#15-verification-matrix)
16. [Suggested prior art to study](#16-suggested-prior-art-to-study)
17. [Research questions](#17-research-questions)
18. [Appendix A — file & line index](#18-appendix-a--file--line-index)
19. [Appendix B — relevant code excerpts](#19-appendix-b--relevant-code-excerpts)
20. [Appendix C — current benchmark scoreboard](#20-appendix-c--current-benchmark-scoreboard)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles
to native binaries. The surface borrows from Elixir (immutable values,
pattern matching, multi-clause function dispatch with guards, the pipe
operator `|>`, macros over an AST, atom literals, persistent data
structures), but the runtime is native: no VM, no interpreter, no
tracing GC. Zap source compiles through Zig's intermediate
representation (ZIR) into LLVM, just like ordinary Zig code. The
produced binary is statically-linked machine code linking libc.

**Project tagline.** "Elixir's developer experience without the runtime
overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is general-purpose. It does not know about
  IO, String, Kernel, Map, etc. as named entities — those live in
  `lib/*.zap` and dispatch through `:zig.X.method(...)` calls into a
  small set of runtime primitives.
* **No workarounds, hacks, or shortcuts.** Every fix must be the
  correct, production-grade, long-term solution regardless of cost or
  time. If a proper fix requires deep architectural changes across
  multiple files, that is the fix. If it requires changes to the Zig
  fork, those are made.
* **Code generation always lowers to ZIR via `src/zir_builder.zig`,
  which calls C-ABI helpers in the Zig fork.** There is no text
  codegen. `src/codegen.zig` is dead legacy code.

**Type system.** Hindley-Milner-flavored with subtyping for atoms and
union types. Concrete primitives include `i8`/`i16`/`i32`/`i64`,
`u8`/`u16`/`u32`/`u64`, `f32`/`f64`, `Bool`, `Atom`, `String`, `List`,
`Map`, `Range`, tuples (`{T1, T2, ...}`), and user-defined `struct` /
`enum` (algebraic data types). Generic functions are
parameterised at the type level and monomorphised per call signature.

**Concurrency.** None yet. Single-threaded today.

---

## 2. Project layout & toolchain

Three repos cooperate:

```
~/projects/zap/                 — language, compiler, stdlib
~/projects/zig/                 — fork of Zig 0.16.0 (branch zap-zir-library-0.16)
~/projects/lang-benches/        — CLBG benchmark suite, polyglot
```

**`~/projects/zap/` layout:**

```
src/                            — compiler (Zig source)
  main.zig                      — CLI entry
  lexer.zig parser.zig          — text → AST
  collector.zig scope.zig       — name resolution
  hir.zig                       — high-level IR (typed)
  monomorphize.zig              — generic specialization
  ir.zig                        — main IR layer (this is huge — ~7500 lines)
  perceus.zig                   — Perceus-style ownership pass
  escape_lattice.zig            — escape analysis
  zir_builder.zig               — IR → ZIR (calls fork's C-ABI)
  runtime.zig                   — Zig runtime primitives, ARC, HAMT, MArray
  zir_integration_tests.zig     — end-to-end integration test harness
  test_reductions/              — minimal reproducers for known compiler gaps
lib/                            — Zap stdlib (each file is a Zap module)
  kernel.zap io.zap string.zap integer.zap float.zap math.zap
  bool.zap atom.zap range.zap
  list.zap map.zap                          (@native_type-bridged)
  marray_i64.zap marray_f64.zap             (@native_type-bridged)
  enum.zap                                  (protocol over List/Map/Range)
docs/                           — design docs and research briefs
build.zig build.zig.zon         — build manifest
```

**Toolchain.**

* `zig build` — compile the `zap` CLI binary (linking the fork lib).
* `zig build test` — Zig-side unit tests (681 today).
* `zig build zir-test -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`
  — end-to-end integration tests (99 today). Each test compiles a
  Zap snippet, runs the resulting binary, asserts on stdout and exit
  code.
* `./zig-out/bin/zap build <target>` — Zap user-facing build CLI; reads
  `build.zap` manifests in user projects.

**Always rebuild the fork lib first** if changes touched
`~/projects/zig/src/zir_api.zig`:

```sh
cd ~/projects/zig
zig build lib \
  --search-prefix /Users/bcardarella/zig-bootstrap-0.16.0/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

The default `zig build` in the Zap repo uses a *bundled* fork lib at
`zap-deps/aarch64-macos-none/libzap_compiler.a` that is committed to
the Zap repo for reproducible CI builds. To pick up a freshly built
local fork, pass `-Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`
to every Zap-side `zig build` invocation. Without that flag, the build
will appear to succeed but link against the *old* bundled lib and
your runtime / ZIR-API changes will not take effect.

---

## 3. Compilation pipeline

```
Zap source (.zap)
     │  src/lexer.zig + src/parser.zig
     ▼
AST (Zap-flavored)
     │  src/collector.zig (collect declarations, attributes)
     │  src/scope.zig (build scope graph, resolve names)
     │  src/discovery.zig (file-name discovery for stdlib structs)
     ▼
Resolved AST + scope graph
     │  src/hir.zig (lowering: types, generics resolved per-clause)
     ▼
HIR (typed)
     │  src/monomorphize.zig (generic specialization, closure capture)
     ▼
Specialized HIR
     │  src/ir.zig (the main IR layer — instructions, locals, control flow)
     ▼
IR
     │  src/perceus.zig (ownership: retain/release insertion, last-use analysis)
     │  src/escape_lattice.zig (escape analysis: stack vs heap)
     ▼
IR with ARC pseudo-instructions (share_value, release, ...)
     │  src/zir_builder.zig (IR → ZIR via fork C-ABI)
     ▼
ZIR (Zig's intermediate representation, emitted via libzap_compiler.a)
     │  Zig fork (Sema, AIR, codegen, LLVM)
     ▼
Native binary
```

**Critical detail.** ZIR is the same intermediate Zig itself uses. The
fork exports a set of C-ABI functions that let *another* program build
ZIR programmatically and feed it through the rest of the Zig pipeline.
Zap is one such program. The fork is otherwise a stock-shaped Zig
compiler with `@import`, type system, comptime evaluation, LLVM
backend, etc. all unchanged. This means everything Zap can express has
to lower to a shape Zig's Sema accepts; conversely, anything Zig's
Sema accepts is reachable by Zap as long as zir_builder can emit it.

**Generic types in Zap-runtime backed types.** Stdlib types like
`List`, `Map`, `Range`, `MArrayI64`, `MArrayF64`, `String` are written
as Zap structs in `lib/*.zap` but their runtime representation is a
Zig type defined in `src/runtime.zig`. The `@native_type = "<kind>"`
attribute on the Zap struct registers the binding. See §6.

---

## 4. The Zig fork and the C-ABI boundary

**Repo.** `~/projects/zig` — branch `zap-zir-library-0.16`. Forked from
upstream Zig 0.16.0.

**What the fork adds.** A C-ABI surface (`~/projects/zig/src/zir_api.zig`)
that exposes Zig's ZIR builder and Sema to external programs. Zap calls
into this lib as `libzap_compiler.a`. Examples of exposed primitives:

* `zir_builder_emit_return`
* `zir_builder_emit_param_decl_val_type` (and variants:
  `_emit_param_optional_decl_val_type`, `_emit_param_optional_this_type`)
* `zir_builder_emit_single_const_ptr_type`
* `zir_builder_call`
* `zir_builder_emit_struct_decl_begin` / `_end`
* `zir_builder_emit_field_decl`
* `zir_builder_begin_root_field_body` / `_end_root_field_body`
* `zir_builder_set_root_field_static`

The fork adds these helpers; otherwise it is upstream Zig 0.16.0. Recent
fork commits (in `git log` order):

```
692eab25c3  zir_builder: add ?T param helpers for optional dispatch
7c5d77c5e8  zir_builder: add single-const ptr_type emission
8352916bdb  zir_builder: streaming per-field-body API for root struct fields
723462996e  zir_builder: body-track struct_init_field_type instructions
a44da4d970  feat: expose ZIR inline type body helpers
```

**Implication for the RSS gap problem.** If the fix needs a new ZIR
primitive that Zap can emit but Zig itself doesn't currently emit
(e.g., a "drop-elided argument move" or a "consuming call"), it needs
to be added to `~/projects/zig/src/zir_api.zig` *and* the rest of
Sema/AIR/codegen must already accept the underlying ZIR opcode. ZIR
opcodes themselves are a fixed set; the fork generally exposes
*existing* Zig opcodes through a C-ABI surface rather than inventing
new opcodes. Any "consuming call" semantics Zap wants must be
expressible in terms of standard Zig (e.g., manual refcount management
in the runtime + ordinary calls + ordinary releases).

---

## 5. Memory model — pools + ARC

Zap's runtime model has two layers:

**5.1 Per-type `MemoryPool`s.** Stdlib container types
(`List(T)`, `Map(K,V)`, `MArrayI64`, `MArrayF64`, `String`,
`DynClosure`, etc.) each allocate cells from a `std.heap.MemoryPool(Inner)`
specialized per type. The pool is `threadlocal`. This makes alloc and
free O(1) free-list ops (no malloc/free per cell). Variable-length
payloads (e.g., `String` bytes, `MArrayI64.items`, HAMT
`children_entries[]`) come from `std.heap.page_allocator` (or
`c_allocator`) directly because pools are fixed-size.

**5.2 Per-cell `ArcHeader`.** Every pooled cell starts with an
`ArcHeader = struct { count: u32 }`. On allocation, count = 1. The
runtime exposes:

* `retain(cell)` — atomic increment of count.
* `release(cell)` — atomic decrement; on transition to 0, deep-free
  walks the cell's children, releases each child's Arc, then returns
  the cell's Inner allocation to its pool and its payload arrays to
  page_allocator.
* `retainOpaque` / `releaseOpaque` — non-generic versions for
  ZIR-emitted code (which doesn't carry comptime types around).
* `ArcRuntime.releaseAny(allocator, ptr)` — type-erased release driven
  by a runtime tag. Used when the IR doesn't have access to the
  monomorphized type.
* `ArcRuntime.releaseFieldChildAny(FieldType, allocator, value)` —
  recursively releases struct fields that contain Arc'd children.

**5.3 The `Arc(T)` generic.** A single-field
`struct { inner: ?*const Inner }` where `Inner = struct { header: ArcHeader, payload: T }`.
Mostly used for indirect storage of values that cross stack frames.
List/String/Map/MArray use a *flatter* design: `*const Self` where
`Self` carries the `ArcHeader` *inline as its first field*. This is
the "inline ArcHeader" pattern — `hasInlineArcHeader(T)` at
`src/runtime.zig:383` detects it. The release helper checks for
inline header first; if present, retain/release manipulate the cell
directly without an indirection.

**5.4 The IR's view of ARC.** `IrBuilder.isArcManagedType`
(`src/ir.zig:4537`) returns `true` for types that need
retain/release pairs around scope boundaries. Today it returns true
**only for `.opaque_type`** (the catch-all variant for List, String,
MArrayI64, MArrayF64, Range, DynClosure). It does **not** return true
for `.map`. This is the central asymmetry that produces the bug.

**5.5 The IR's `share_value` and `release` instructions.**

* `share_value { dest, source }` — semantics: `dest = source; retain(source)`.
  Emitted whenever an Arc local is "borrowed" into another local
  (e.g., copied into an arg slot, returned, captured).
* `release { value }` — emitted at scope exit for every Arc local
  that was bound during the scope.
* `arc_share_skipped` (set in `zir_builder.zig:498`) — locals whose
  `share_value` retain was skipped because the source was
  stack-eligible (escape-eligible). The matching scope-exit `release`
  also gets suppressed via this set, which closes a subtle correctness
  hole that previously caused double-decrements.

**5.6 What's currently missing.** A *last-use analysis* and
*move-mode argument lowering*. Today, every `share_value` retains
unconditionally (modulo escape lattice). When an Arc local is passed
as an arg whose call-site is its last use, the caller still emits a
retain (caller's count++), the callee acquires its own borrow and
when its scope exits releases (callee's count--). Net: a wasted
refcount round-trip per call. Worse: when the caller's local has
*only one consumer* (the call), the retain/release pair is logically a
no-op but the IR doesn't know to elide it. With small Arc-managed
types (List, String, where allocations are bounded by program-input
size) this is a constant-factor perf hit; with Map, where every put
allocates a path-spine, the retain/release ping-pong interacts with
the path-copy spine and the allocations *accumulate* because the IR
emits scope-exit drops on locals that are *also* the value being
returned.

This is the surface Map ARC was meant to fix. Read on.

---

## 6. `@native_type` and stdlib bridging

Stdlib types like `Map` and `List` are declared in Zap source like
this (`lib/map.zap`):

```
@native_type = "map"

pub struct Map {
  pub fn put(map :: %{K => V}, key :: K, value :: V) -> %{K => V} {
    :zig.Map.put(map, key, value)
  }
  pub fn get(map :: %{K => V}, key :: K, default :: V) -> V {
    :zig.Map.get(map, key, default)
  }
  ...
}
```

`@native_type = "map"` tells the compiler this Zap struct is the
user-visible spelling of the runtime type registered as kind
`map`. The `NativeTypeKind` enum at `src/scope.zig:468` enumerates
the kinds:

```
list, map, range, string, marray_i64, marray_f64
```

`ScopeGraph.native_type_names` maps each kind → user-visible struct
StringId. The HIR pass collapses references to e.g. `MArrayI64` to
the canonical TypeId for that kind. The IR / ZIR emitter then knows
to emit calls to `Map.put` as calls to the runtime function
`Map_K_V_put` (with `K`/`V` instantiated per-call).

`:zig.Map.put(map, key, value)` is a syntactic escape into the
runtime: a call to a known runtime function rather than another Zap
function. The `:zig` prefix is a sigil-like marker. The runtime
function names follow the pattern `<TypeName>_<Method>_<Arity>` after
generic instantiation.

---

## 7. The Map runtime today

> **Status as of commit `07f56c7 runtime: rebuild Map(K, V) as
> Arc-headered, pool-allocated cells`** (current tip of `main`).

`Map(K, V)` is a hybrid:

* **Flat representation** for ≤ 8 entries: an inline array of
  `MapEntry { key: K, value: V }`.
* **HAMT (Hash Array Mapped Trie)** for > 8 entries: a 32-way
  branching trie with depth ≤ 7, keyed by the hash of K split into
  5-bit chunks (`BITS_PER_LEVEL = 5`, `BRANCHING_FACTOR = 32`).
  At depth 7 every hash bit is exhausted; collisions beyond depth 7
  go into a flagged collision-bucket node (`is_collision: bool`)
  that does linear scan.

**Concrete shapes** (`src/runtime.zig:3025-3700`):

```zig
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        header: ArcHeader,                          // <-- inline Arc, layout-stable
        total_count: u32,
        repr_tag: u8,                               // 0 = flat, 1 = trie
        flat_entries: [*]const MapEntry,
        flat_count: u32,
        trie_root: ?*const HamtNode,

        const FLAT_THRESHOLD = 8;
        const BITS_PER_LEVEL = 5;
        const BRANCHING_FACTOR = 1 << BITS_PER_LEVEL;
        const LEVEL_MASK: u32 = BRANCHING_FACTOR - 1;
        const MAX_DEPTH = 7;

        pub const MapEntry = struct { key: K, value: V };

        const HamtNode = struct {
            header: ArcHeader,                      // <-- inline Arc again
            bitmap: u32,
            children_entries: [*]const MapEntry,
            children_nodes: [*]const ?*const HamtNode,
            child_count: u6,
            is_collision: bool = false,
        };

        // ... hamtPut, hamtDelete, hamtGet, etc.
    };
}
```

**Path-copy `put`**: `hamtPut` walks down the trie, allocating new
nodes along the spine to the leaf where `key` lands, and reusing
unaffected sibling subtrees. Each retained sibling-subtree pointer
gets a `retain()` so the new spine owns its own refcount. The old
spine is then released. Sibling subtrees survive because they got the
extra refcount from the retain.

**Deep release.** When `Map.release` drops the cell to count 0:

* Walk `trie_root`, recursively release every `HamtNode` child.
* For each `HamtNode` released to count 0, release every non-null
  pointer in `children_nodes`, decRef every entry in
  `children_entries` (if K or V are Arc-managed), free the two
  arrays back to `page_allocator`, return the Inner to the per-(K,V)
  `MemoryPool`.
* Return the Map cell's Inner to its pool.

**Per-instantiation pools.** `Map(K, V)` and its `HamtNode` each have
their own `MemoryPool(Inner)` keyed by the (K, V) pair (in practice,
threadlocal slots indexed by a comptime instantiation id).

**This is the substrate.** It is correct in isolation: a unit test
that calls `Map.put` 100k times in a tight loop with proper Zig-side
release at scope exit *does not leak*. The substrate is good. The
problem is that the *compiler* doesn't yet emit those releases for
Zap-source-level Map locals.

---

## 8. The Perceus / move-semantics literature

For background, you'll need to be familiar with:

* **Perceus** (Reinking, Xie, de Moura, Leijen, 2021,
  *Perceus: Garbage Free Reference Counting with Reuse*, PLDI'21).
  This is the ownership-tracking pass used by the Koka compiler. Each
  binding has *exactly one consumer*; if the binding's last use is at
  call site X, ownership transfers to X (no retain, no release at
  scope exit). If a binding has multiple uses, retains are inserted at
  the duplication points so each consumer gets its own ownership.
* **Reuse analysis** (extension of Perceus). When a function
  destructures a value and rebuilds a similar value, the freed cells
  can be reused in-place rather than freed-and-reallocated. Lean 4
  uses this aggressively. Probably out of scope for this gap but
  worth knowing about.
* **Roc's reference counting** — Roc takes a similar Perceus-flavored
  approach for its persistent data structures. Worth comparing how
  Roc handles persistent maps with refcounting.
* **Swift's ARC + ARC optimizer.** Swift inserts retain/release around
  every reference passed to a function and relies on the optimizer to
  pair-eliminate redundant retain/release pairs. This is the
  *opposite* design from Perceus — insert eagerly, eliminate via
  optimization. Worth understanding because Zap's *current* behavior
  is closer to Swift's eager insertion (modulo `arc_share_skipped`).
* **Rust's ownership and `Drop`**. Different model entirely (no
  refcounting in the language, ownership is unique by construction),
  but the *compiler-pass* implementation of "track each value's last
  use and elide drop after move" is the same shape. `rustc`'s NLL
  (non-lexical lifetimes) and drop elaboration passes are worth
  reading.
* **OCaml's `Map`** — implemented as an immutable balanced tree. With
  GC there's no refcount issue, but the persistent-tree shape is the
  same. Useful for understanding the data structure independently of
  the memory-management strategy.
* **Clojure's persistent data structures** — Bagwell HAMT. The HAMT
  is the same; Clojure runs on the JVM so memory mgmt is delegated
  to the GC. Useful to compare allocation-rate-vs-working-set
  characteristics.

---

## 9. The k-nucleotide benchmark

**CLBG benchmark.** The Computer Language Benchmarks Game's
`k-nucleotide` benchmark reads a synthetic DNA FASTA file from stdin,
finds the sequence after the `>THREE` header, concatenates the
sequence lines into a single uppercase byte sequence, and prints
three sections:

1. **Single-nucleotide frequencies** (k=1). Print each as
   `LETTER pct.fff` sorted by frequency descending, alphabetical
   ascending on ties. There are exactly 4 letters (A, C, G, T).
2. **Di-nucleotide frequencies** (k=2). 16 di-nucleotides, same sort.
3. **Exact occurrence counts** for these specific k-mers, in this
   exact order: `GGT`, `GGTA`, `GGTATT`, `GGTATTTTAATT`,
   `GGTATTTTAATTTATAGT`. Output `count\tkmer` per line.

Reference output for the standard 250k-char input is in
`~/projects/lang-benches/k-nucleotide/expected.txt`. The Zap port
matches it byte-exactly today.

**Algorithm.** For each k, slide a window of k bytes across the
sequence, encode each k-mer as an `i64` (2 bits per base — A=0, C=1,
G=2, T=3 — fits 32-mers in 64 bits, well past the 18-mer maximum
queried), increment a count in a `Map<i64, i64>`. For section 3, look
up specific k-mers' counts. For sections 1-2, sort the map's entries
by `(count desc, kmer-string asc)` and format.

**The hot loop in `k_nucleotide.zap:185-197`:**

```
pub fn count_kmers_loop(seq :: String, n :: i64, k :: i64, i :: i64,
                        m :: %{i64 => i64}) -> %{i64 => i64} {
  if i + k > n {
    m
  } else {
    one = 1 :: i64
    zero = 0 :: i64
    key = KNucleotide.encode_at(seq, i, k, zero)
    previous = Map.get(m, key, zero)
    next_count = previous + one
    next_map = Map.put(m, key, next_count)
    KNucleotide.count_kmers_loop(seq, n, k, i + one, next_map)
  }
}
```

This is canonical tail-recursive accumulator-threading. With proper
ARC + Perceus-style move semantics:

* `m` enters with refcount = 1 (handed off from caller).
* `Map.put(m, ...)` produces `next_map` with refcount = 1; internally
  retains shared subtrees, releases the old root spine (which decRefs
  the unused spine path and frees pool cells). `m` is *consumed* by
  the put.
* `count_kmers_loop(..., next_map)` is a tail call; `next_map` is the
  last use, ownership transfers to the callee.
* Function exits (jumps to recursive call); no per-iteration drops,
  no per-iteration retains. Steady-state working set = one map (~all
  ~2M entries × ~50 bytes = ~100 MiB).

With current naïve drop semantics:

* IR emits `share_value` for every Arc local that gets passed into a
  call; emits `release` at scope exit for every Arc local that was
  bound during the scope. (Today this only fires for `.opaque_type`,
  not `.map`.)
* If we naïvely flip `.map` into `isArcManagedType`, the IR would
  emit a release on `m` AND on `next_map` at scope exit. But the
  scope is a tail-call shape — the function never returns to its own
  body after the recursive call. The post-call drops would fire
  *after* the callee has already taken ownership of `next_map`. The
  drop's decRef would race against the callee's retain (no, no
  threading — but it would decRef before the callee has done its own
  work, free'ing memory the callee is iterating).

This is exactly the segfault pattern the previous attempt produced.

---

## 10. Measured RSS gap and scaling

Hardware: Apple M-series, ~32 GiB RAM. Input is `input.fasta` —
synthetic FASTA, 250k characters in the `>THREE` block.

| Implementation | Runtime | Peak RSS |
|----------------|--------:|---------:|
| C              | 57 ms   | 27 MiB   |
| Rust           | 79 ms   | 15 MiB   |
| Zig            | 77 ms   | 11 MiB   |
| Go             | 104 ms  | 14 MiB   |
| OCaml          | 305 ms  | 35 MiB   |
| Elixir         | 3.2 s   | 140 MiB  |
| **Zap**        | **3.6 s** | **7.36 GiB** |

(Pre-`07f56c7` substrate fix: 7.90 GiB. Post-fix: 7.36 GiB. The
substrate-only fix gave a ~7% reduction; the rest needs codegen.)

**Scaling with input size** (Zap):

| Input chars | Peak RSS | Bytes / char |
|------------:|---------:|-------------:|
| 25k         | 1.07 GiB | 42 KiB/char  |
| 100k        | 4.43 GiB | 44 KiB/char  |
| 250k        | 7.90 GiB | 32 KiB/char  |

(Slope ~32-44 KiB/char. The dropoff at 250k is from MemoryPool
amortization — the per-pool minimum-block-size kicks in at smaller
inputs.)

**Reference Zig peak RSS scales sublinearly** (the steady-state map
size is bounded by the unique-k-mer count which saturates well below
total chars — there are only 4^18 ≈ 68B possible 18-mers, of which
~250k are actually present in any reasonable input).

---

## 11. Why allocations leak today — root cause

After commit `07f56c7`, the Map *runtime* is correct: a Zig-side
test that calls `Map.put` in a loop without explicit releases does
in fact leak — the test would need to call `Map.release` on the
discarded old map, or the persistent-data-structure caller's
release pattern. With the calls in place, no leak.

The k-nucleotide benchmark leaks because **the IR doesn't emit
those releases**. Specifically:

1. `IrBuilder.isArcManagedType` (`src/ir.zig:4537`) returns false
   for `.map`. That means:
2. The IR emits no `share_value` retain at the call site of
   `Map.put(m, ...)` (treats `m` as if it were a plain value type).
3. The IR emits no `release` at scope exit for `m`, `next_map`, or
   the bare-return arm's `m`.
4. Net effect: every `Map.put` call *creates* new pool cells in the
   per-(K,V) pool, *but* never releases any of them. The pool grows
   linearly with calls. Pools never return memory to the OS.

This is observable: peak RSS = pool high-water-mark = total alloc
size across the program's life, regardless of working set.

**The substrate fix is correct.** The runtime semantics now mean
*if* the IR emits `release` on the right locals at the right times,
the path-copy spine releases free pool cells, the steady-state
working set drops to ~one Map snapshot (~tens of MiB).

---

## 12. The codegen integration gap

The compiler-pass change required has four parts:

### 12.1 Last-use analysis

**Goal.** For each Arc-managed local in each function body, determine
the IR instruction at which it is *last used*. "Used" means:

* Source of a `share_value` (passed into another local / arg slot).
* Source of a `release` (about to be dropped).
* Source of a `local_get` (read for any other purpose, including
  return).
* An argument to a `call_named` / `call_indirect`.

The dataflow is **backward**: walk basic blocks in reverse, mark
each local as "live" at every program point until its last use. The
"last use" of a local is the program point where the live-out set
no longer contains it.

For straight-line code (no branches, no joins), this is trivial.
For loops and joins, last-use becomes per-edge: a local may be
last-used on one branch and not another. Most prior art handles this
by either (a) treating "last use within a basic block" as the
relevant unit and inserting drops at block boundaries (the Rust /
Lean approach), or (b) treating the entire CFG with full liveness
analysis (the Swift / LLVM approach).

For Zap's IR, basic-block-local last-use is probably sufficient
because the existing drop-emission already runs per-function-exit and
the new logic is "exclude drops where the local was last-used
mid-block at a move site". The `tryCollapseTailCallSharedReleases`
pattern the previous agent attempted was a degenerate version of
this — it handled only the trailing-tail-call shape — but the
correct generalization is full per-block liveness.

### 12.2 Move-mode argument lowering

**Goal.** When an Arc local's last use is as an argument to a call,
the caller transfers ownership: no retain at the call site, no
release at scope exit.

**Mechanism.** The existing `arc_share_skipped` set in
`src/zir_builder.zig:498` already tracks "share retains that we
skipped because the source was escape-eligible". Extending it to
also track "share retains skipped because the source was at its
last use" is the natural shape. The corresponding scope-exit
release is then suppressed via the existing matching logic at
`src/zir_builder.zig:6443-6447`.

**Subtle case.** When *multiple* args to the same call are last-uses
of the same local (not common, but possible with `call(x, x)`),
only the *first* gets move treatment; the rest need a retain. The
analysis must order the duplicates.

### 12.3 Return-source drop elision

**Goal.** When a function's `ret` instruction's value source is an
Arc local, that local's scope-exit release must be elided — the
caller now owns the returned value.

**Mechanism.** At function epilogue (search for the drop-emission
site near `ret` in `src/ir.zig` — should be in the function-body
finalize step), filter the drop list against `{return_source_local}`.
If the return value is sourced from `local_ref(L)`, exclude `L`.

**Subtle case.** What if `L` is an arg parameter? Then `L` was
"borrowed-in" (caller already retained, callee borrows). The natural
behavior is: callee *transfers* L back to the caller's ownership of
the *return slot*. Conceptually L's borrow-ref goes to the caller.
The existing param-borrow code in the IR already has this notion;
your task is to make sure return-source elision composes with it.

### 12.4 Flip the flag

Once 12.1-12.3 are implemented, extend
`IrBuilder.isArcManagedType` (`src/ir.zig:4537`):

```zig
fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
    const store = self.type_store orelse return false;
    const t = store.getType(type_id);
    return switch (t) {
        .opaque_type => true,
        .map => true,    // <-- new
        else => false,
    };
}
```

Plus audit every other site that handles `.opaque_type` to make sure
`.map` is also covered. Search for `.opaque_type` across `src/ir.zig`
and `src/zir_builder.zig`.

### 12.5 Allocation considerations

Once retain/release are correctly emitted, the path-copy spine
allocates ~7 cells per `put` and the dropped spine releases ~7 cells.
Steady-state allocation rate equals deallocation rate; pool
high-water-mark equals working-set size, not lifetime allocation
count. Expected RSS for k-nucleotide 250k input: ~50-200 MiB
(reference is 11 MiB; Zap's per-cell overhead from inline ArcHeader
+ pool block headers is ~2-4×).

---

## 13. Why the previous implementation attempt failed

Two prior agent runs landed (fully or partially) on this problem:

**Run 1 — runtime substrate (commit `07f56c7`, landed).** Wrapped
`Map(K,V)` and `HamtNode` in inline ArcHeader, per-instantiation
MemoryPools, deep release walking the trie, retain on shared
subtrees in path-copy puts. Tests stayed 681/681 + 99/99 green; all
3 benchmark ports remained byte-exact. RSS dropped 7.90 → 7.36 GiB
(modest, as expected — this is the *substrate*, not the codegen).

**Run 2 — codegen integration attempt (NOT landed, reverted).** Tried
the narrow pattern-match approach: detect `call_named + releases +
ret` at end of function and rewrite into `tail_call`, collapsing the
trailing share/release pairs. Implemented as
`tryCollapseTailCallSharedReleases` in `src/ir.zig` (~158 lines).

It broke `zap run doc` — an internal CTFE-using doc-generation
command — by triggering an infinite loop. The agent spent 1+ hour
hung waiting on builds that never returned. Was killed and reverted
to `07f56c7`.

**Why the narrow approach is wrong:**

* It pattern-matches IR after-the-fact rather than tracking ownership
  through lowering. The IR shape it expects (specific sequence of
  share/call/releases/ret) is one of many possible shapes; in the doc
  generator, control flow took a different path that the matcher
  didn't expect.
* It can fire on cases where the share/release pair *isn't* balanced
  — e.g., locals freshly allocated inside the function body (no
  preceding share, but a release at exit). Collapsing those silently
  drops the release.
* It doesn't handle the return-source-elision case at all.
* It doesn't handle Arc args on non-tail calls.
* It interacts unpredictably with macros that may rewrite IR in
  passes that run before / after.

The correct shape is the four-part Perceus pass described in §12.

---

## 14. Design constraints (non-negotiable)

From `~/projects/zap/CLAUDE.md`:

* **No workarounds.** No "skip Map ARC for now and use a flat-array
  hash set in k-nucleotide". The persistent-Map perf path must be
  fundamentally correct.
* **Zap is a language.** The fix is in the compiler / IR, not in
  user-level Zap code. No "just use linear types" annotations on
  user-facing struct definitions unless the design genuinely calls
  for that semantic shift.
* **Lower to ZIR.** Any new ZIR primitive must be expressible as
  standard Zig (compose existing operations); the fork only exposes
  surface, it doesn't extend Zig's IR opcode set.
* **TDD.** Failing tests must drive every commit. Don't break the
  current 681/99 test sweep at any step.
* **Don't regress benchmarks.** The 3 CLBG ports
  (`fannkuch-redux`, `spectral-norm`, `k-nucleotide`) must remain
  byte-exact in output. Spectral-norm in particular is at 0.79s vs
  Zig's 0.75s and a regression there would be a real problem.

From observation:

* **Don't touch `lib/io/mode.zap`.** There's a feedback memory note
  to never inline it.
* **Always verify `zig build` actually rebuilds with the local fork
  lib.** The default uses bundled `zap-deps/`. Pass
  `-Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`.
* **`zig build test` and `zig build zir-test`** are the two test
  sweeps. Both must stay green. Run both after each meaningful
  change.

---

## 15. Verification matrix

Any proposed implementation must satisfy:

* `zig build test --summary all` → `681/681 tests passed`.
* `zig build zir-test --summary all -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a` → `99/99 tests passed`.
* `cd ~/projects/lang-benches/k-nucleotide && rm -rf zap-out zap.lock .zap-cache && ~/projects/zap/zig-out/bin/zap build k_nucleotide && diff <(./zap-out/bin/k_nucleotide < input.fasta) expected.txt` → empty.
* Same for `fannkuch-redux 10` against `expected_n10.txt`.
* Same for `spectral-norm 5500` against `expected_n5500.txt`.
* `/usr/bin/time -l ./zap-out/bin/k_nucleotide < input.fasta > /dev/null` → peak RSS < 500 MiB (target < 100 MiB; the reference Zig binary is 11 MiB).
* k-nucleotide runtime should drop from current 3.6s closer to OCaml's 305ms range (reasonable target: ≤ 1s).
* Other 2 benchmarks within 5% of current runtimes (no regression).

A new microbenchmark / integration test exercising just the
persistent-map tail recursion (something like 100k Map.put calls in
a tight tail loop) is recommended to catch RSS regressions early
without re-running the full k-nucleotide fixture.

---

## 16. Suggested prior art to study

Reading list ranked by relevance:

1. **Perceus paper.** Daan Leijen et al., *Perceus: Garbage Free
   Reference Counting with Reuse*. PLDI 2021. Linked from the Koka
   project page. Read carefully — this is the closest match to
   what Zap should implement.
2. **Koka source.** `~/<wherever>/koka/` — the Koka compiler in
   Haskell; the Perceus pass is implemented there. Read the
   `Backend/C/FromCore.hs` and `Core/Borrowed.hs` for the actual
   algorithm.
3. **Roc compiler.** `~/<wherever>/roc/` — Roc has a similar
   refcounting + reuse strategy. The mod_solve/mono crates are the
   right places.
4. **Lean 4's reuse analysis.** Significantly more aggressive than
   Perceus; the relevant pass is in
   `lean4/src/Lean/Compiler/IR/ResetReuse.lean`. Probably out of
   scope for this gap but useful for context.
5. **Swift's ARC optimizer.** `swift/lib/SILOptimizer/ARC/`. The
   *opposite* design pattern — eager retain/release insertion +
   pair elimination via dataflow — but the dataflow analysis is the
   same shape. Useful for understanding the transformation
   discipline.
6. **Rust's drop elaboration and NLL.** `rustc_mir_build/src/build/scope.rs`
   and `rustc_borrowck/`. Different ownership model (unique by
   construction), but the *placement* of drops is the same problem.
7. **Bagwell HAMT.** Phil Bagwell, *Ideal Hash Trees*. Useful for
   understanding the persistent-data-structure shape independently of
   memory mgmt.
8. **OCaml stdlib `Map` implementation.** Balanced binary tree. Zap's
   HAMT is a different shape but the persistent-rebuild logic
   transfers.

---

## 17. Research questions

The deep-research deliverable should answer:

### 17.1 Algorithm

* What is the right shape of a last-use analysis for Zap's IR? Should
  it be per-basic-block or full CFG-wide liveness? What's the cost
  difference?
* How does Perceus handle the "multiple last uses on different
  branches" case? Does it insert drops at each branch's exit, or
  hoist a single drop out?
* What about loops? In `count_kmers_loop`, the recursive call is
  inside the `else` branch of an `if`. The `then` branch
  (`if i + k > n { m }`) is a return-source case. The `else` branch
  has the move-into-call case. Both must be handled.
* How does Perceus handle the case where a function takes an Arc
  parameter, modifies it, and returns the modified value? (Standard
  pattern for accumulator-threading.) Does ownership transfer
  naturally, or does the analysis need a special case?

### 17.2 Implementation in Zap's IR

* Where in the existing pipeline should the new pass run? Before or
  after monomorphization? Before or after `escape_lattice`? Are
  there ordering dependencies?
* `src/perceus.zig` exists today — does it already do *some* of this
  analysis? Is it a stub? Read the file and report.
* `escape_lattice.zig` does escape analysis. How does it interact
  with the new last-use analysis? Does last-use *imply* escape, or
  vice versa?
* The IR currently stores instructions as `[]const Instruction` per
  block. Is there a CFG explicit somewhere, or is control flow
  encoded structurally? If structurally (if-expressions etc.), how
  does last-use analysis traverse it?

### 17.3 The "drop list" location

* Where does the IR currently emit the function-epilogue drop list?
  Search for "release" emission near `ret` / `return_value` in
  `src/ir.zig`. Likely there's a function that builds a list of all
  Arc locals bound during the function and emits releases for each.
  The new logic filters that list by last-use map.

### 17.4 Tail-call interaction

* Zap's IR has a `tail_call` instruction. How is it currently emitted?
  When does it fire? Does it interact with the existing share/release
  logic? Is there a known "no drops between the last share and the
  call" invariant that gets violated when adding new drops?

### 17.5 Benchmark

* Once the codegen lands, what's the expected RSS for k-nucleotide
  250k input given the inline-ArcHeader overhead and pool-block
  metadata? Estimate from first principles. Can it match the
  reference Zig 11 MiB, or is there a fundamental ~5x overhead from
  refcount headers + pool management?
* Is there a path to *also* improve the runtime? The current 3.6s
  runtime is dominated by HAMT path-copy overhead (lots of pointer
  chasing + node copying). A faster Map (e.g., backing trie nodes
  with stack-allocated buffers in a thread-local arena that gets
  reset between toplevel statements) is a separate optimization but
  worth exploring if it composes with the codegen fix.

### 17.6 Alternative designs

* Linear / unique-ownership Map (Rust-style `Box`). What changes
  semantically? What user-facing code breaks? Is the perf better than
  Perceus + ARC, or roughly the same?
* Region-based allocation (escape-analysis-driven regions) — as
  used in some ML dialects. Does that compose with persistent
  data structures, or only with one-shot data?
* Mutable Map primitive (`MMap(K,V)`) as a parallel native_type to
  `MArrayI64`. *Defer* — the user's directive says no shortcuts;
  this is a workaround, not a fix. But for completeness, what would
  the user-facing API look like, and what's the perf compared to a
  Perceus-correct persistent Map?

---

## 18. Appendix A — file & line index

Run all paths from `/Users/bcardarella/projects/zap/`.

| Path | What lives there |
|------|------------------|
| `CLAUDE.md` | Project rules. Read first. |
| `README.md:639-655` | Zig-fork rebuild command |
| `src/runtime.zig:176` | `runtime_arena` (no longer used for Map post-`07f56c7`) |
| `src/runtime.zig:214-248` | `ArcHeader` definition |
| `src/runtime.zig:303-509` | `ArcRuntime` namespace — retain/release/free helpers |
| `src/runtime.zig:317-331` | `ArcPool(T)` per-type pool |
| `src/runtime.zig:383` | `hasInlineArcHeader(T)` detection |
| `src/runtime.zig:434` | `releaseAny` type-erased release |
| `src/runtime.zig:454` | `releaseFieldChildAny` per-field release |
| `src/runtime.zig:528` | `retainAny` type-erased retain |
| `src/runtime.zig:602+` | MArray runtime (parallel design to Map) |
| `src/runtime.zig:2489-2569` | Map bridge helpers (`mapBridge*`) |
| `src/runtime.zig:2951-3700` | **Map(K, V) impl — the runtime substrate** |
| `src/runtime.zig:3041-3068` | Map allocation helpers |
| `src/runtime.zig:3083-3105` | `HamtNode` definition |
| `src/runtime.zig:3136` | `hamtPut` |
| `src/runtime.zig:3253` | `hamtDelete` |
| `src/runtime.zig:3306-3373` | `copyNodeWithUpdatedChild` etc. |
| `src/scope.zig:468` | `NativeTypeKind` enum |
| `src/scope.zig:474-480` | `NativeTypeKind.fromName` |
| `src/scope.zig:506` | `native_type_names` map |
| `src/types.zig:97` | `Type.opaque_type` variant |
| `src/types.zig` (search `.map`) | `Type.map` variant + uses |
| `src/hir.zig` | HIR layer, `resolveTypeExpr` |
| `src/monomorphize.zig` | Generic specialization |
| `src/perceus.zig` | **Existing Perceus pass — read first** |
| `src/escape_lattice.zig` | Escape analysis |
| `src/ir.zig:2337+` | `tryCollapseTailCallSharedReleases` (reverted; for context) |
| `src/ir.zig:4537-4540` | `IrBuilder.isArcManagedType` — flag to flip |
| `src/ir.zig:4928` | A site that uses `isArcManagedType` |
| `src/ir.zig:5048` | Generic call-name encoding (Map/List dispatch) |
| `src/ir.zig:5111` | Same as above |
| `src/ir.zig` (search `share_value`, `release`) | Drop emission sites |
| `src/zir_builder.zig:498-504` | `arc_share_skipped` set |
| `src/zir_builder.zig:547` | Set deinit |
| `src/zir_builder.zig:4063-4097` | `arc_share_skipped` population |
| `src/zir_builder.zig:6443-6447` | Matching release suppression |
| `src/zir_builder.zig:2587-2599` | `mapBridgeMethodToHelper` |
| `src/zir_builder.zig:4727-4748` | Generic-container dispatch |
| `lib/map.zap` | User-facing Map stdlib (don't edit unless API change) |
| `lib/marray_i64.zap` | Reference for native_type Arc-managed pattern |
| `~/projects/lang-benches/k-nucleotide/k_nucleotide.zap:185-197` | The hot loop |
| `~/projects/lang-benches/k-nucleotide/expected.txt` | Byte-exact target output |
| `~/projects/zig/src/zir_api.zig` | Zig-fork C-ABI surface (for reference) |

---

## 19. Appendix B — relevant code excerpts

### 19.1 `IrBuilder.isArcManagedType` (the flag)

`src/ir.zig:4537-4540`:

```zig
fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
    const store = self.type_store orelse return false;
    return store.getType(type_id) == .opaque_type;
}
```

### 19.2 `arc_share_skipped` machinery

`src/zir_builder.zig:498-504`:

```zig
/// Locals whose `share_value` retain was skipped (because the source
/// is escape-eligible / stack-allocated and a retain would be a
/// double-counted refcount). The matching scope-exit `release` is
/// suppressed via `containsArcShareSkipped`, closing a pre-existing
/// asymmetry where the unpaired release would double-decrement.
arc_share_skipped: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
```

`src/zir_builder.zig:6443-6447` (release-suppression):

```zig
if (self.arc_share_skipped.contains(rel.value)) {
    // Matching share_value retain was skipped; suppress this release.
    continue;
}
```

### 19.3 The hot loop in user-source Zap

`~/projects/lang-benches/k-nucleotide/k_nucleotide.zap:185-197`:

```
pub fn count_kmers_loop(seq :: String, n :: i64, k :: i64, i :: i64,
                        m :: %{i64 => i64}) -> %{i64 => i64} {
  if i + k > n {
    m
  } else {
    one = 1 :: i64
    zero = 0 :: i64
    key = KNucleotide.encode_at(seq, i, k, zero)
    previous = Map.get(m, key, zero)
    next_count = previous + one
    next_map = Map.put(m, key, next_count)
    KNucleotide.count_kmers_loop(seq, n, k, i + one, next_map)
  }
}
```

### 19.4 Map runtime overview comment

`src/runtime.zig:3025-3049` (header comment in the Map impl, summarizing
the substrate design):

```
// Map — Generic HAMT-based persistent map.
//
// Map(K, V) generates a type-specific map for any key/value types.
// Maps use nullable pointers: null = empty, non-null = map cell.
// Hybrid: flat array for small maps, HAMT trie for larger.
//
// Memory model: Self and HamtNode are ARC-managed. Each carries an
// `ArcHeader` as its first field so retain/release is a refcount bump
// on the cell pointer. Path-copy `put`/`delete` produce a new spine
// whose nodes carry refcount=1; every shared subtree pointer carried
// forward into the new spine is `retain`'d. When a Map cell or
// HamtNode reaches refcount zero it deep-releases its trie children
// before its Inner allocation returns to the per-(K,V) MemoryPool;
// the variable-length entries / node-ptrs buffers are freed back to
// page_allocator. This keeps persistent semantics while ensuring
// O(active set) memory rather than O(total mutations).
```

### 19.5 `MArrayI64` runtime (parallel design — reference pattern)

`lib/marray_i64.zap` declares:

```
@native_type = "marray_i64"

pub struct MArrayI64 {
  pub fn new(size :: i64, init :: i64) -> MArrayI64 {
    :zig.MArrayI64.new(size, init)
  }
  pub fn get(arr :: MArrayI64, index :: i64) -> i64 {
    :zig.MArrayI64.get(arr, index)
  }
  pub fn set(arr :: MArrayI64, index :: i64, value :: i64) -> i64 {
    :zig.MArrayI64.set(arr, index, value)
  }
  pub fn length(arr :: MArrayI64) -> i64 {
    :zig.MArrayI64.length(arr)
  }
}
```

`src/runtime.zig:602+` defines `MArrayOf(T)` with the same inline-ArcHeader
+ MemoryPool + retain/release pattern as Map. **MArrayI64 lives entirely
inside `isArcManagedType` returning true (via `.opaque_type`)** today
and works correctly. It demonstrates that the codegen *can* handle this
pattern — the question is what's missing for `.map` specifically.
There may be a hint here: investigate why `.opaque_type` is
distinguished from `.map` in `isArcManagedType` in the first place.
Was `.map` deliberately excluded due to a known issue, or was it just
historical (Map was never Arc-managed before commit `07f56c7`)?

The "previous attempt failed" notes from §13 say *flipping the flag
naively triggers segfaults* in tail-recursive accumulator patterns.
But MArray works in tail-recursive patterns (fannkuch-redux's
recursive driver uses MArrayI64 exactly this way and runs at 0.146s
with no segfaults). So the issue isn't fundamentally Arc — it's
specifically the path-copy spine where `Map.put` produces a NEW value
that *shares* substructure with the input, and the IR doesn't know
that the input has been "consumed".

This points at the answer: **Maps are *consumed* by `Map.put`** in a
way that MArrays aren't. `MArrayI64.set` mutates in-place when
refcount=1; otherwise it reallocates. Either way, the input is *not
freed* by `set` — the caller still holds it. With Map, the input is
*freed (decRef'd)* by `put`'s internal "release old root spine" call.
So `m` going out of scope normally would double-decrement on
release.

This is the actual semantic mismatch the new pass needs to handle.
Map.put consumes the old map (decref); the IR should not also emit a
release of the param. The fix is either:
  (a) Map.put internally retain()s its first arg (so its decref is
      symmetric), and the IR emits releases at scope exit normally.
      Cost: extra refcount round-trip per put.
  (b) Map.put consumes (no internal retain) and the IR knows to NOT
      emit a release on a local whose last use is being passed to a
      consuming function. Cost: per-call-site annotation of which
      args are consumed.

Option (a) is simpler but pessimal. Option (b) is what Perceus does.
Option (b) requires the IR to carry consume-mode metadata per
function-arg-site, which is a substantial schema change.

Investigate in the implementation plan: which option does the
existing IR support / lean toward?

---

## 20. Appendix C — current benchmark scoreboard

Hardware: Apple M-series, ~32 GiB RAM. Times are mean over 5 runs
under hyperfine warmup=2. RSS measured separately via
`/usr/bin/time -l`.

| Benchmark | Lang | Time | RSS | Notes |
|-----------|------|-----:|----:|-------|
| nbody N=5M | C | 105 ms | 1.3 MiB | reference |
| nbody N=5M | Zap | 184 ms | 1.4 MiB | within 1.7x of C |
| mandelbrot N=8000 | C | 145 ms | 1.4 MiB | reference |
| mandelbrot N=8000 | Zap | 270 ms | 1.4 MiB | within 1.9x of C |
| binarytrees N=21 | C | 0.71 s | 130 MiB | reference |
| binarytrees N=21 | Zap | 1.3 s | 194 MiB | within 1.8x of C |
| **fannkuch-redux N=11** | C | 1.55 s | 1.3 MiB | reference |
| **fannkuch-redux N=11** | **Zap** | **1.76 s** | **1.4 MiB** | **within 1.13x of C, beats OCaml** |
| **spectral-norm N=2500** | C | 192 ms | 1.4 MiB | reference |
| **spectral-norm N=2500** | **Zap** | **165 ms** | **1.5 MiB** | **faster than C** |
| **k-nucleotide** | C | 57 ms | 27 MiB | reference |
| **k-nucleotide** | Zap | **3.6 s** | **7.36 GiB** | **the gap this brief is about** |

Bold entries are the three CLBG-blocker benchmarks ported to Zap
across this iteration of work. The first two are competitive; the
third has a 60× runtime gap and ~270× RSS gap that remains.

---

## End of brief

The deliverable from a deep-research session on this brief should be:

1. A **recommended implementation plan** spelling out, in order:
   * The exact layout and algorithm of the new last-use analysis pass
     (file/function-level pseudocode acceptable).
   * The exact integration points in `src/ir.zig` and
     `src/zir_builder.zig` where the existing share/release machinery
     gets the new last-use input.
   * The exact return-source-elision logic at function epilogue.
   * The exact form of the `isArcManagedType` flip and any other
     `.opaque_type`-vs-`.map` audit changes.
2. A **decision memo** on the consume-vs-retain question raised in
   §19.5 — option (a) symmetric retain in Map.put vs option (b)
   per-arg consume-mode in the IR. Pick one; justify.
3. **An estimated effort budget** in person-days, with sub-budget for
   each of (analysis pass, move-arg lowering, return elision, flag
   flip, debugging benchmark regressions, fork-side changes if any).
4. **A risk register** — what's likely to go wrong, what tests are
   likely to flake, what other Arc-managed types might surface bugs
   when the flag flips.
5. **An iteration plan** for an implementation session — what's the
   first commit that's safe to land in isolation, the second, and so
   on. The previous attempt failed by trying to do everything at
   once; small commits are vital.
