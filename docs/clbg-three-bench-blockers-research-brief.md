# Zap: blockers on three CLBG benchmarks — research brief

> **Audience.** A deep-research AI agent with zero prior context on Zap,
> the Zap fork of the Zig compiler, the lang-benches harness, or how
> these repos fit together. Read top-to-bottom — §1–§6 establish the
> world model; §7–§9 describe the three concrete blockers; §10–§13
> are the constraints, reading list, and questions to answer. The
> intended deliverable is a recommended implementation plan for each
> of the three blockers, with concrete file paths and line numbers
> where changes should land.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [Memory model — pools + ARC](#5-memory-model--pools--arc)
6. [Stdlib state — what data structures and APIs Zap currently has](#6-stdlib-state--what-data-structures-and-apis-zap-currently-has)
7. [Blocker A — `MArray` (fannkuch-redux + spectral-norm)](#7-blocker-a--marray-fannkuch-redux--spectral-norm)
8. [Blocker B — `Enum.sort` / closure / protocol dispatch (k-nucleotide)](#8-blocker-b--enumsort--closure--protocol-dispatch-k-nucleotide)
9. [The three benchmarks in detail](#9-the-three-benchmarks-in-detail)
10. [Design constraints](#10-design-constraints)
11. [What's tested vs untested in the bench surface](#11-whats-tested-vs-untested-in-the-bench-surface)
12. [Research questions](#12-research-questions)
13. [Appendix A — file & line index](#13-appendix-a--file--line-index)
14. [Appendix B — current benchmark scoreboard](#14-appendix-b--current-benchmark-scoreboard)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles to
native binaries. The surface borrows from Elixir (immutable values,
pattern matching, multi-clause function dispatch with guards, the pipe
operator `|>`, macros over an AST, atom literals, persistent data
structures), but the runtime is native: there is no VM, no interpreter,
no tracing GC. Zap source compiles through Zig's intermediate
representation (ZIR) into LLVM, just like ordinary Zig code does, and
the produced binary is statically-linked machine code that links libc.

**Project tagline.** "Elixir's developer experience without the runtime
overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is a general-purpose tool that doesn't know
  about specific Zap structs (`IO`, `String`, `Math`, the ARC runtime).
  Standard library functions, macros, the test framework, and DSLs all
  live in `lib/*.zap` and call into Zig primitives only at the
  boundary.
* **The only things that belong in Zig** are the lexer/parser, type
  system primitives (`Bool`, `String`, `Atom`, `i64`, etc.), ZIR
  emission mechanics, and the runtime primitives that physically
  cannot be expressed in Zap (`stdout`, OS argv, raw memory
  allocation, posix syscalls).
* **No workarounds, hacks, or shortcuts.** Every solution must be the
  correct, production-grade fix — even if it requires multi-file
  changes or modifications to the Zig fork.
* **Top-level functions are illegal.** Every `pub fn` and `pub macro`
  must live inside a `pub struct Name { ... }` body.

**Sample syntax** (`~/projects/lang-benches/binarytrees/binarytrees.zap`):

```zap
pub struct Tree {
  left :: Tree | nil
  right :: Tree | nil
}

pub struct Binarytrees {
  pub fn make(0 :: i64) -> Tree {
    %Tree{left: nil, right: nil}
  }

  pub fn make(d :: i64) -> Tree {
    %Tree{left: Binarytrees.make(d - 1), right: Binarytrees.make(d - 1)}
  }

  pub fn check(nil) -> i64 {
    0 :: i64
  }

  pub fn check(t :: Tree) -> i64 {
    one = 1 :: i64
    one + Binarytrees.check(t.left) + Binarytrees.check(t.right)
  }
}
```

Note the multi-clause dispatch (`make(0)` vs `make(d)`, `check(nil)` vs
`check(t :: Tree)`), the `Tree | nil` recursive optional, the type
ascription syntax `1 :: i64`, and the struct construction with
`%Tree{...}`.

---

## 2. Project layout & toolchain

Three repositories on disk, all owned by the same author:

| path | role |
|------|------|
| `~/projects/zap` | the Zap compiler + stdlib + tests |
| `~/projects/zig` | a fork of Zig 0.16.0 (branch `zap-zir-library-0.16`) that exposes ZIR emission as a C-ABI library `libzap_compiler.a` |
| `~/projects/lang-benches` | the cross-language benchmark harness — directory per benchmark, source files for each language, hyperfine harness, HTML renderer |

`~/projects/zap/CLAUDE.md` and `~/projects/zap/README.md` are the
authoritative docs for the Zap project.

**Build** (from `~/projects/zap/README.md`):

```sh
zig build setup     # one-time: downloads pre-built libzap_compiler.a
zig build           # produces zig-out/bin/zap
zig build test      # runs the 675-test unit suite
./zig-out/bin/zap test    # runs the in-language Zap test suite
```

When the Zig fork changes, rebuild it and point `zap` at the result:

```sh
cd ~/projects/zig
/path/to/zig build lib -Dstatic-llvm -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none -Dcpu=baseline -Dversion-string=0.16.0

cd ~/projects/zap
zig build -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a
```

The `runtime.zig` file is `@embedFile`'d into the `zap` CLI at compile
time (see `src/compiler.zig:14`), so any change to `runtime.zig`
requires rebuilding the `zap` CLI before user programs pick it up.

---

## 3. Compilation pipeline

Zap source goes through several IRs before it becomes native code:

```
.zap source
   ↓ parse                     →  AST     (src/ast.zig)
   ↓ collect                   →  HIR     (src/hir.zig)
   ↓ macro-expand & desugar    →  HIR'    (src/macro.zig)
   ↓ analysis pipeline         →  IR      (src/ir.zig + src/analysis_pipeline.zig)
   ↓ ZIR emit                  →  ZIR     (src/zir_builder.zig → libzap_compiler.a)
   ↓ Sema + LLVM (Zig fork)    →  AIR/MIR/object code
   ↓ link                      →  ELF/Mach-O binary
```

Two layers do the heavy lifting:

* **`src/ir.zig`** — the IR. Per-function instruction streams, pattern-
  match lowering, multi-clause dispatch (case_block, switch_tag,
  `optional_dispatch`), tail-call rewrite, recursive-struct
  field-storage analysis. Reads HIR from `src/hir.zig`.

* **`src/zir_builder.zig`** — the ZIR backend. Walks IR functions and
  emits ZIR instructions through C-ABI calls into `libzap_compiler.a`
  (extern functions named `zir_builder_emit_*` and `zir_builder_set_*`).
  Owns the boxing decisions for recursive types, the buffered stdout
  hookup, and all the runtime helper call-site code generation.

Several passes between HIR and ZIR run analyses that the ZIR emitter
consults:

* **`src/escape_lattice.zig`** — central `AnalysisContext` that holds
  per-value escape state, region assignments, ownership state, lambda
  sets, drop specializations, ARC operations, and (recently) the
  `destructive_optional_dispatch` map for the Perceus borrow path.
* **`src/generalized_escape.zig`** — escape analysis driver.
* **`src/interprocedural.zig`** — call-graph + per-function summary
  (parameter ownership, return-value escape, etc.).
* **`src/region_solver.zig`** — region inference per function.
* **`src/lambda_sets.zig`** — 0-CFA lambda sets for closure
  specialization.
* **`src/perceus.zig`** — the Perceus reuse / drop-specialization /
  destructive-optional-dispatch detection pass. This is where most of
  the recent ARC-correctness work landed.
* **`src/arc_optimizer.zig`** — peephole pass over the arc_op stream
  (eliminates adjacent retain/release pairs on the same value at the
  same point).

The whole pipeline is wired in `src/analysis_pipeline.zig`.

---

## 4. The Zig fork and the C-ABI boundary

The Zap project depends on a fork of Zig 0.16.0 at
`~/projects/zig`, branch `zap-zir-library-0.16`. The fork's purpose is
exposing the Zig ZIR (Zig Intermediate Representation) emission +
Sema + LLVM-codegen pipeline as a C-callable library
(`libzap_compiler.a`) instead of a CLI tool.

**C-ABI surface** lives at `~/projects/zig/src/zir_api.zig` — every
`pub export fn zir_builder_*` and `pub export fn zir_compilation_*`
function is a stable point Zap calls. Examples:

```zig
extern "c" fn zir_builder_emit_param(handle, name_ptr, name_len, type_ref) u32;
extern "c" fn zir_builder_emit_call_ref(handle, fn_ref, args_ptr, args_len) u32;
extern "c" fn zir_builder_emit_field_val(handle, obj, field_ptr, field_len) u32;
extern "c" fn zir_builder_emit_struct_init_typed(handle, type_ref, …) u32;
extern "c" fn zir_compilation_update(ctx) i32;
```

A complete catalog is at the top of `~/projects/zap/src/zir_builder.zig`
(lines 30–200ish).

When Zap needs a new ZIR shape that the existing C-ABI doesn't expose,
the rule is **add the new function in the Zig fork**, rebuild
`libzap_compiler.a`, then call it from `zir_builder.zig`. Examples of
recently-added fork functions:

* `zir_builder_emit_param_optional_this_type` — emits `param: ?@This()`
  inside the param's type body.
* `zir_builder_emit_single_const_ptr_type` — wraps a Ref into a
  `*const T`.
* `zir_builder_set_root_field_static` — declares a struct decl with
  static type only.

Most fork-side additions follow the same pattern: build a `body` of
ZIR instructions in the fork, return the result's `Inst.Ref` to the
caller. C-ABI takes opaque `?*ZirBuilderHandle` so the Zig-side state
never crosses the boundary as data.

---

## 5. Memory model — pools + ARC

Zap is reference-counted. Recent work hardened this in three layers:

### 5.1 The ARC primitive (`src/runtime.zig`)

```zig
pub const ArcHeader = struct { ref_count: std.atomic.Value(u32), … };

pub fn Arc(comptime T: type) type {
    return struct {
        const Inner = struct { header: ArcHeader, value: T };
        ptr: *Inner,
        // pub fn init / retain / release / get / refCount / ...
    };
}
```

`Inner` is `{ header: ArcHeader, value: T }`; the user always sees a
`*T` whose `@fieldParentPtr("value", ptr)` recovers the `Inner`
allocation. Atomic refcounting is a `monotonic` increment on retain
and an `acq_rel` decrement on release.

### 5.2 Per-type memory pool

Allocations of `Arc(T).Inner` go through a thread-local
`std.heap.MemoryPool(Arc(T).Inner)` that grows in page-sized chunks
from `std.heap.page_allocator`. This is keyed on `T` at compile time:

```zig
fn ArcPool(comptime T: type) type {
    return struct {
        const Pool = std.heap.MemoryPool(Arc(T).Inner);
        threadlocal var pool: Pool = .empty;
        fn create() *Arc(T).Inner { … }
        fn destroy(inner: *Arc(T).Inner) void { … }
    };
}
```

Both `allocAny` and `freeAny` / `destroyPreparedAny` route through
`ArcPool(T).create / .destroy`. The previous implementation went
through `std.heap.c_allocator` (libc malloc) and before that
`std.heap.page_allocator`; the pool was the third iteration.
Binarytrees N=21 dropped 2.5× wall and 25% RSS from the c_allocator →
pool switch.

The pool is **threadlocal** — Zap programs are single-threaded today;
multi-threaded support would mean either per-thread pools (current
shape) or guarded shared pools.

### 5.3 The deep-release helper

```zig
pub fn releaseAny(allocator: std.mem.Allocator, ptr: anytype) void {
    const T = arcPtrChild(@TypeOf(ptr));
    releaseArcAny(T, allocator, ptr);
}
pub fn releaseArcAny(comptime T, allocator, ptr: *const T) void {
    if (prepareReleaseAny(T, ptr)) |owned| {
        releaseChildrenAny(T, allocator, owned.*);
        destroyPreparedAny(T, allocator, owned);
    }
}
pub fn releaseChildrenAny(comptime T, allocator, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        releaseFieldChildAny(f.type, allocator, @field(value, f.name));
    }
}
fn releaseFieldChildAny(comptime FT, allocator, value: FT) void {
    switch (@typeInfo(FT)) {
        .optional => if (value) |inner| releaseFieldChildAny(opt.child, …),
        .pointer => |p| if (p.size == .one)
            releaseArcAny(p.child, allocator, @constCast(value)),
        else => {},
    }
}
```

Comptime walk over the value's fields: each `?*const T` field
recursively triggers `releaseArcAny` on the pointee. Recursion
terminates because Zig memoizes generic instantiations.

### 5.4 Boxed recursive types

Recursive struct types (those with at least one field whose
`FieldStorage == .indirect` — set by an SCC walk in
`src/ir.zig:zigTypeReachesStructInCycle`) are uniformly represented
as `*const T` at the IR/ZIR level. Function parameters of recursive
type lower to `*const T`; returns lower to `*const T`; construction
sites heap-promote the outer aggregate. Indirect-storage field reads
do **not** auto-deref because the consumer's representation already
matches the storage's. See `~/projects/zap/docs/arc-indirect-storage-research-brief.md`
for the full architectural background.

### 5.5 Perceus drop / destructive-optional-dispatch

`src/perceus.zig` currently:

* identifies deconstruction sites (`case_block`, `switch_tag`,
  pattern-matching `if_expr`, and recently `optional_dispatch`);
* generates `DropSpecialization` records that the ZIR backend turns
  into actual release ops at the right insertion point;
* detects "destructive optional dispatch" — the borrow-eligible
  shape where every indirect-storage child of the scrutinee is
  extracted-and-consumed — and tags the function so the ZIR backend
  can suppress the field-get retain and emit shallow `freeAny`
  instead of deep `releaseAny`;
* runs reuse pairing for same-shape decon/con pairs (Perceus's
  classic optimization).

### 5.6 Buffered stdout

`runtime.zig` has a 64 KiB user-space stdout buffer. All
`stdoutWrite` / `stdoutPrint` / `IO.println` / `IO.inspect` /
`IO.write_byte` paths route through `stdoutBufferedWrite` /
`stdoutBufferedWriteByte`. Flushed via `atexit`, before stderr writes,
and before `IO.gets`. This is what makes streaming output (mandelbrot)
feasible at one-byte-per-call without a syscall per byte.

---

## 6. Stdlib state — what data structures and APIs Zap currently has

The stdlib lives in `~/projects/zap/lib/`. Each file is a `pub struct`
with `pub fn` clauses. Public API summarised below:

### 6.1 `lib/list.zap` — persistent List `[element]`

HAMT-backed persistent list. Source-level type syntax `[element]`.
Uses Zap type variables (the `element` identifier in declarations is
a free type variable resolved at use site).

```
pub fn empty?(list :: [element]) -> Bool
pub fn length(list :: [element]) -> i64
pub fn head(list :: [element]) -> element            # O(1)
pub fn tail(list :: [element]) -> [element]          # O(1)
pub fn at(list :: [element], i :: i64) -> element    # O(N)
pub fn last(list :: [element]) -> element            # O(N)
pub fn contains?(list :: [element], v :: element) -> Bool
pub fn reverse(list :: [element]) -> [element]
pub fn prepend(list :: [element], v :: element) -> [element]   # O(1)
pub fn append(list :: [element], v :: element) -> [element]    # O(N)
pub fn concat(a :: [element], b :: [element]) -> [element]
pub fn take, drop, uniq, head!, last!, at! …
```

There is **no `update_at(list, i, v)`**, **no `swap_at(list, i, j)`**,
and no mutable variant. The shape is "build by prepending to a
`[]`, reverse at the end". Indexing-heavy workloads (anything where
the inner loop is `arr[i] := …`) are O(N) per write, O(N²) per row,
and miss the size budget on fannkuch-redux at N=11 and spectral-norm
at N=2500.

### 6.2 `lib/map.zap` — persistent Map `%{key => value}`

HAMT-backed persistent map. Source-level type syntax `%{K => V}`.

```
pub fn get(m, k, default) -> value
pub fn has_key?(m, k) -> Bool
pub fn size, empty?, put, delete, merge, keys, values
pub fn get!(m, k, default) -> value     # error variant
```

Used by binarytrees (no — binarytrees doesn't use Map; the fields are
direct refs). No existing benchmark exercises `Map`. The k-nucleotide
benchmark would be the first.

### 6.3 `lib/string.zap`

```
pub fn length, byte_at, from_byte, contains?, starts_with?, ends_with?,
       trim, slice, to_atom, to_existing_atom, upcase, downcase,
       reverse, replace, index_of, pad_leading, pad_trailing, repeat,
       to_integer, to_float, capitalize, trim_leading, trim_trailing,
       count, split, join
```

`String` is opaque at the source level. The Zig backing is a slice
plus a pointer-typed allocation; it is **not** Arc-managed (pre-existing
runtime behaviour). `String.from_byte(byte :: i64) -> String` allocates
a one-byte string from the runtime arena.

### 6.4 `lib/io.zap`

```
pub fn puts(s) -> String
pub fn print_str(s) -> String
pub fn write_byte(byte :: i64) -> i64    # NEW — feeds stdoutBufferedWriteByte
pub fn gets() -> String
pub fn warn(s) -> String
pub fn mode, get_char, try_get_char
```

`IO.gets()` reads one line from stdin, returns `""` on EOF (and on
empty input lines — the two are not distinguished).

### 6.5 `lib/enum.zap` — Enumerable protocol

```
pub fn map, filter, reduce, sort, each, count, any?, all?, find, …

pub fn sort(collection :: Enumerable(element),
            comparator :: (element, element -> Bool)) -> [element]
```

`sort` takes a comparator function value (closure). Internally
implemented via repeated `sort_next` (insertion-sort-like). Closures
go through Zap's `make_closure` / `call_closure` IR, which is well-
exercised on simple cases but apparently not on the shapes
k-nucleotide demands (see §8).

### 6.6 `lib/integer.zap`, `lib/float.zap`

Standard arithmetic + `to_string` / `parse` / `to_float` /
`Integer.bsl` (shift left), `Integer.bor`, `Integer.bsr`,
`Integer.remainder`, `Float.to_string(value, decimals)` (the recently
added precision overload). `Integer.to_string` is multi-clause across
i8/i16/i32/i64/i128 and u variants.

### 6.7 `lib/concatenable.zap` — `<>` operator dispatch

```
pub protocol Concatenable {
  fn concat(left, right) -> any
}

# Implementations in:
lib/string/concatenable.zap   →  pub impl Concatenable for String
lib/list/concatenable.zap     →  pub impl Concatenable for List
```

The `<>` macro in `lib/kernel.zap` expands to
`Concatenable.concat(left, right)`. Protocol dispatch happens at
compile time and **requires the type to be statically known** —
when type inference falls back to a generic, the compile-time
dispatcher emits the diagnostic `protocol dispatch requires an exact
protocol constraint or a concrete impl`. This is one of the
k-nucleotide blockers.

### 6.8 What does NOT exist

* No mutable-array type. No `MArray(T)`, no `Vec(T)`, no `Buffer(T)`.
  No syntax for one. No `:zig.MArray.*` C-ABI.
* No `IO.read` / `IO.read_all` / batched stdin. Only `IO.gets()`
  (line-at-a-time, one syscall per byte read internally).
* No regex.
* No big integers.
* No mutable `String` builder.

---

## 7. Blocker A — `MArray` (fannkuch-redux + spectral-norm)

### 7.1 What the benchmarks need

Both fannkuch-redux and spectral-norm have an inner loop whose
canonical shape is "indexed read/write on a small mutable buffer".

**fannkuch-redux** (port at
`~/projects/lang-benches/fannkuch-redux/fannkuch-redux.c`):

```c
int p[16], pp[16], count[16];
for (int i = 0; i < n; ++i) p[i] = i;     /* init */
…
for (int i = 0; i < n; ++i) pp[i] = p[i]; /* full-array copy, hot */
while (pp[0] != 0) {
    for (int i = 0, j = pp[0]; i < j; ++i, --j) {
        int t = pp[i]; pp[i] = pp[j]; pp[j] = t;   /* swap */
    }
    flips++;
}
…
/* count-rotate next-permutation: rotates p[0..i+1] */
int t0 = p[0];
for (int j = 0; j <= i; ++j) p[j] = p[j+1];
p[i+1] = t0;
```

Every iteration: full array copy, repeated swaps (`pp[i] := pp[j];
pp[j] := pp[i]`), and a count-rotate (sliding `p[0..i]` left by one).
At N=11 the outer loop runs `11! / 2 = 19,958,400` times. With a
persistent list, each "swap" is `prepend(replace_at(replace_at(list,
i, b), j, a))` which is O(N) per call. Inner loop is O(N²) flips ×
O(N) swap = O(N³) per permutation. Outer loop multiplies. Wall time
becomes pathological well below standard size.

**spectral-norm** (port at `spectral-norm/spectral-norm.c`):

```c
double *u = malloc(sizeof(double) * n);
double *v = malloc(sizeof(double) * n);
for (int i = 0; i < n; ++i) u[i] = 1.0;
for (int iter = 0; iter < 10; ++iter) {
    /* eval_a_times_u: au[i] = sum_j a(i,j) * u[j] */
    /* eval_at_times_u: au[i] = sum_j a(j,i) * u[j] */
    for (int i = 0; i < n; ++i) {
        double s = 0.0;
        for (int j = 0; j < n; ++j) s += eval_a(i, j) * u[j];
        au[i] = s;
    }
}
```

Inner double-loop is `O(n²)` per pass, ten passes, two passes per
iteration = `20 * n²` random-access reads of `u[j]`. At N=2500 that's
1.25 × 10⁸ array reads. On `Enum.at(u, j)` over a persistent list
(`O(N)`), this is `N³` = 1.5 × 10¹¹ operations — roughly 10 minutes
of wall time per pass under a generous estimate.

### 7.2 The gap

Zap exposes no mutable-array type. Both benchmarks need:

* `fn new(size :: i64, init :: T) -> MArray(T)` — heap allocation,
  `size` slots all set to `init`.
* `fn get(arr :: MArray(T), i :: i64) -> T` — O(1) read.
* `fn set(arr :: MArray(T), i :: i64, v :: T) -> i64` — O(1) write,
  in-place mutation. Returns something (the new value, or unit, or
  the array — design choice).
* `fn length(arr :: MArray(T)) -> i64` — O(1).
* For `T` covering at least `i64` and `f64` (fannkuch needs `i64`,
  spectral-norm needs `f64`).

Open design questions for the agent to consider:

1. **One generic `MArray(T)` or two specialised `MArrayI64` /
   `MArrayF64`?** Generic is the right long-term answer (the
   stdlib already has parameterised types: persistent `List` uses the
   `[element]` variable, persistent `Map` uses `%{K => V}`). The
   generic approach needs Zap-level syntax — either a sigil like
   `<<T>>` / `[mut T]`, or a regular struct-type-with-type-parameter.
   Zap doesn't expose generic struct types at the source level today;
   the existing `List` and `Map` get sugar. Two specialised types
   ship faster but spend the API budget twice.

2. **Storage shape — Arc-wrapped slice, plain heap slice, or stack-
   allocated fixed-size buffer?**
   * Arc-wrapped: matches existing memory model. Costs a refcount
     on every reassignment. Awkward because mutation through `*const
     T` requires `@constCast` (the boxing-recursive ABI is built on
     `*const T` pointers).
   * Plain heap slice: a `*MArrayInner` where `Inner = struct {
     items: [*]T, len: usize }`. Allocated explicitly; freed by
     someone (caller? automatic on local-out-of-scope?). Doesn't fit
     the Zap "no manual free" promise unless integrated into the
     drop infrastructure.
   * Stack-allocated fixed-size: `[16]i64` for fannkuch (which uses
     N ≤ 16 in practice) — would fix only fannkuch, not spectral-
     norm. Not generally useful.

   The cleanest answer is **Arc-wrapped slice with a `MemoryPool`-
   backed allocator** (like `Arc(T).Inner` already does for boxed
   recursive types), so the whole array gets a refcount header and
   participates in the drop machinery. Mutability is fine — Zap's
   model already accepts that the *Arc header* is mutable through
   `*const T` (atomic counter). Mutating `items[i]` through the same
   pointer is the same shape, just one indirection deeper.

3. **Source-level syntax.** Without a parser change, the API has to
   be expressible as ordinary `pub fn` clauses. That means either a
   nominal struct (`MArray.new(…)`) or a sugar token added to the
   parser. Nominal struct ships fastest; sugar can come later.

4. **Type variable propagation.** `MArray(T).get` returns `T`. If
   `T` is `i64` Zap can compile that body cleanly. If `T` is a free
   type variable in user code (`pub fn at(arr :: MArray(t), i :: i64)
   -> t`), the IR builder needs to thread the variable through. This
   is solved for `List`/`Map`; the question is whether the same
   plumbing extends to a new nominal generic type.

5. **Runtime layer.** Whatever the source-level shape, the Zig-side
   primitives (`:zig.MArray.new_i64`, `:zig.MArray.get_i64`, …) need
   to live in `runtime.zig`. They allocate from `MemoryPool(Inner_T)`
   for whatever element type. The allocator argument that `IO.print`
   et al. carry is currently a no-op for Arc operations; the same
   convention probably applies here.

### 7.3 Why the workaround doesn't work

A "persistent-list emulation" implementation would compile but miss
the size budget: fannkuch-redux at N=8 runs in ~13 minutes on a
persistent list, and N=11 (the test size) would take days.
Spectral-norm at N=100 takes minutes. Implementations would be
algorithmically correct but the benchmark numbers aren't meaningful.
Listed as exclusions in the report rather than shown as a 1000× slow
reference.

### 7.4 Files the agent should look at

* `~/projects/zap/lib/list.zap` — the closest existing analog
  (persistent list with Zap-side type parameter). Especially
  `pub fn at`, the element-type threading, and the runtime
  delegation to `:zig.List.*`.
* `~/projects/zap/src/runtime.zig` lines 3500-3850 (the persistent
  `List` Zig implementation, for backing-allocator and dispatch
  patterns), lines 200-360 (the `Arc`/`ArcRuntime` infrastructure
  it would parallel).
* `~/projects/zap/src/zir_builder.zig` — search for how `List` calls
  surface (`emitListCellRef`, `setContainerReturnType`, etc.). An
  `MArray` would need similar return-type / type-construction
  support if it's exposed as a generic.
* `~/projects/zap/src/ir.zig:355` — `pub const StructInit` shows
  how aggregate construction lowers; `MArray.new` could be a
  call-builtin instead of going through `struct_init`.

---

## 8. Blocker B — `Enum.sort` / closure / protocol dispatch (k-nucleotide)

The k-nucleotide benchmark is implementable in five other languages
(C / Rust / Zig / Go / OCaml / Elixir all tested, output
byte-identical) but the Zap port hits multiple compiler / stdlib
issues. **This is the harder of the two blockers** because the failures
have multiple, unclear causes.

### 8.1 What the benchmark needs

The CLBG k-nucleotide algorithm:

1. Read FASTA from stdin one line at a time.
2. After the `>THREE` header, accumulate uppercased bases (ACGT only) into one big string.
3. For `k ∈ {1, 2}`: count every length-`k` substring; print a frequency table sorted by `(count desc, key asc)`, formatted as `KMER PCT.PCT` (3-decimal percentage).
4. For each fixed `kmer ∈ {GGT, GGTA, GGTATT, GGTATTTTAATT, GGTATTTTAATTTATAGT}`: count occurrences in the sequence; print `<count>\t<kmer>`.

Reference implementations live at
`~/projects/lang-benches/k-nucleotide/k-nucleotide.{c,rs,zig,go,ml,exs}`.
The expected output is at `~/projects/lang-benches/k-nucleotide/expected.txt`.
A test FASTA fixture is at `~/projects/lang-benches/k-nucleotide/input.fasta`
(1.25 M-base THREE block, generated deterministically from
`fasta-gen.py`).

### 8.2 Zap-shape attempt

The natural Zap implementation:

```zap
pub struct Knucleotide {
  pub fn count_loop(seq :: String, k :: i64, i :: i64, n :: i64,
                    m :: %{String => i64}) -> %{String => i64} {
    if i + k > n {
      m
    } else {
      kmer = String.slice(seq, i, i + k)
      cur = Map.get(m, kmer, 0 :: i64)
      Knucleotide.count_loop(seq, k, i + 1, n, Map.put(m, kmer, cur + 1))
    }
  }

  pub fn count_kmers(seq :: String, k :: i64) -> %{String => i64} {
    n = String.length(seq)
    Knucleotide.count_loop(seq, k, 0, n, %{})
  }

  pub fn freq_less(a :: {String, i64}, b :: {String, i64}) -> Bool {
    {a_kmer, a_count} = a
    {b_kmer, b_count} = b
    if a_count > b_count { true }
    else { if a_count < b_count { false } else { a_kmer <= b_kmer } }
  }

  pub fn print_freq(seq :: String, k :: i64) -> i64 {
    counts = Knucleotide.count_kmers(seq, k)
    total = Enum.reduce(Map.values(counts), 0 :: i64,
                        fn(v :: i64, acc :: i64) -> i64 { acc + v })
    rows = Enum.map(Map.keys(counts),
                    fn(key :: String) -> {String, i64} {
                      {key, Map.get(counts, key, 0 :: i64)}
                    })
    sorted = Enum.sort(rows,
                       fn(a :: {String, i64}, b :: {String, i64}) -> Bool {
                         Knucleotide.freq_less(a, b)
                       })
    …
  }
}
```

The full attempted source was deleted but is reproducible from
`docs/clbg-three-bench-blockers-research-brief.md`-cited reference
implementations. The version above hit two distinct failures.

### 8.3 Failure 1 — protocol dispatch on `<>` and `<=`

Two compile-time errors of the same shape:

```
error: first argument to protocol `Concatenable` does not satisfy
       `Concatenable`
  └─ ./knucleotide.zap:101:19
     protocol dispatch requires an exact protocol constraint or a
     concrete impl
```

Triggered by:
* `IO.puts(kmer <> " " <> Float.to_string(pct, 3))` — `<>` is a
  macro that expands to `Concatenable.concat(left, right)`. With
  `kmer` coming from a destructured tuple `{kmer, count} = pair`,
  Zap's type inference apparently can't resolve `kmer`'s type to
  `String` strongly enough for the protocol-dispatch resolver. The
  same body works if you use `:zig.String.concat(a, b)` directly.

* `a_kmer <= b_kmer` inside the comparator function. `<=` dispatches
  through `Comparator` (similar protocol). Same shape — destructured
  from a tuple, type not strongly inferred, dispatch fails.

The error message is the diagnostic from the protocol dispatcher
when it can't choose an impl; it's the same shape as
`docs/codegen-blockers-research-brief.md` mentions for unrelated
historical blockers.

Workarounds investigated and partial-success:

* Replace `kmer <> " " <> Float.to_string(…)` with a sequence of
  `IO.print_str(kmer)`, `IO.print_str(" ")`, `IO.print_str(Float.…)`
  — bypasses `<>` entirely. Compiles past this point.

* `a_kmer <= b_kmer` — no straight-line way to bypass the operator.
  Could call `String.compare(a, b) <= 0` if such a function exists
  (it doesn't — `lib/string.zap` has no `compare`). Adding one is
  a clean fix.

### 8.4 Failure 2 — `EmitFailed` after HIR stage

Even with the `<>` bypassed and the `<=` inlined as a Zap helper, the
compiler hit:

```
[hir 15/15] Knucleotide
Error: compilation failed: EmitFailed
```

`EmitFailed` is a generic ZIR-emission error. The HIR passes
completed, then `src/zir_builder.zig` returned `error.EmitFailed`
during `emitFunction` for one of the user-level functions. No more
detail in the user-facing message. The investigation hooks:

* `src/zir_builder.zig` returns `error.EmitFailed` from many places.
  `grep -n "return error.EmitFailed" src/zir_builder.zig` lists them.
  Adding stderr prints upstream of each `return error.EmitFailed`
  narrows the actual site.

* The most likely culprit: closures inside `Enum.reduce`,
  `Enum.map`, `Enum.sort`. The closure expressions return a tuple
  type (`{String, i64}`) or take a tuple parameter (`{String, i64}`
  destructured). Zap closures + tuple boundaries are exercised by
  some unit tests but apparently not in this composition.
  `src/zir_builder.zig` has dedicated paths for `make_closure` and
  `call_closure`; tuple-typed values inside those bodies may not
  fully thread through.

* Less likely: `Enum.sort`'s in-Zap implementation (`enum.zap:230`)
  recurses on `sort_next`. It builds `[element]` lists. Maybe the
  element-type inference fails when the comparator's input is a
  destructured tuple.

### 8.5 What "fix" would mean

The k-nucleotide implementation has two viable shapes:

* **Idiomatic Zap** — what was attempted. Map keyed on `String`
  k-mer, `Enum.sort` by tuple comparator. Requires fixing
  protocol dispatch on tuple-destructured String values and
  tracking down the `EmitFailed`.
* **Encoded-key shape** — encode each k-mer as a `u64` (2 bits per
  base) and key the Map on that integer instead of a String.
  Simpler comparator (integer compare), no String allocation per
  k-mer in the inner loop. This is what the C / Rust / Zig
  reference implementations do. A Zap port using this shape would
  exercise the `Map<i64, i64>` path instead of `Map<String, i64>`,
  but the closures-in-Enum issue is independent of that.

### 8.6 Files the agent should look at

* `~/projects/zap/lib/enum.zap:230-258` — `Enum.sort` and its
  recursion `sort_next`.
* `~/projects/zap/lib/concatenable.zap` and
  `~/projects/zap/lib/string/concatenable.zap` — what `<>`
  dispatches into.
* `~/projects/zap/lib/kernel.zap:255-280` — the `<>` and `<=`
  macros, and how they expand. Likely the dispatch failure starts
  here.
* `~/projects/zap/src/zir_builder.zig` — every `return error.EmitFailed`
  site, especially around `emitClosure`, `emitMakeClosure`,
  `emitCallClosure`, `emitTupleInit`, `emitFieldGet`.
* `~/projects/zap/src/ir.zig` — `Closure`, `MakeClosure`,
  `CallClosure`, and the param-type lowering for closures.
* `~/projects/zap/lang-benches/k-nucleotide/k-nucleotide.zig`
  — the Zig 0.16 reference. A Zap implementation would shape
  similarly.

---

## 9. The three benchmarks in detail

### 9.1 fannkuch-redux

**Purpose.** Knuth's pancake-sorting task. For every permutation of
`1..N` (in a defined iteration order), apply the "flip" — reverse
`pp[0..pp[0]+1]` until `pp[0] == 0`, counting flips — then update
the running max-flips and a parity-signed checksum.

**Standard size.** `N = 12` on the public CLBG. This suite uses
`N = 11` for desktop-tractable wall time (11! / 2 = 19,958,400
permutations).

**Output shape.** Two lines:

```
<signed checksum>
Pfannkuchen(<N>) = <max flips>
```

For N=10 → `73196\nPfannkuchen(10) = 38\n` (verified across all six
reference implementations).

**Hot-path operations** (per permutation):

1. Copy `p[0..N]` to `pp[0..N]` (linear).
2. While `pp[0] != 0`: reverse `pp[0..pp[0]+1]` (linear-in-window),
   increment flips.
3. Update max-flips, accumulate signed flips into checksum.
4. Generate next permutation: count-rotate `p[0..i+1]` left by one
   for the smallest `i` where `count[i]` hasn't reached `i`.

Each is a small mutable-buffer operation. With persistent lists,
each step is at minimum O(N), often O(N²) (the "rotate left" needs
shifting, which is O(N) on a persistent list).

**Reference timings (this suite, N=11)**: Rust 1.43 s / Zig 1.55 s
/ C 1.56 s / Go 1.60 s / OCaml 1.78 s / Elixir 25.0 s.

### 9.2 spectral-norm

**Purpose.** Power-iteration estimate of the spectral norm of an
infinite matrix `A[i,j] = 1 / ((i+j)(i+j+1)/2 + i + 1)`. Ten passes
of `(A · v)` then `(Aᵀ · v)`. Print `sqrt(v · u / v · v)` to nine
decimal places.

**Standard size.** `N = 5500` on CLBG; this suite uses `N = 2500`.

**Output shape.** One line: `<value>` formatted as `%.9f` (e.g.
`1.274224153`). For N=2500 the value is also `1.274224153` (doesn't
shift much past 5500).

**Hot-path operations** (per pass):

```
for i in 0..N:
  s = 0.0
  for j in 0..N:
    s += A(i, j) * u[j]   // A(i, j) is a scalar division
  au[i] = s
```

`O(n²)` random-access reads of a length-`N` `f64` vector, twice per
iteration (`A · v` then `Aᵀ · v`), times 10 outer iterations =
`20 n²`. At N=2500 that's `1.25 × 10⁸` reads. Each read on a
persistent list is `O(N)`.

**Reference timings (N=2500)**: Rust 158 ms / Zig 159 ms / C 194 ms /
Go 229 ms / OCaml 461 ms / Elixir 4.08 s.

### 9.3 k-nucleotide

**Purpose.** DNA k-mer frequency analysis. Real-world sequence-
processing workload.

**Standard input.** 25 M-base FASTA-format DNA from stdin
(canonical CLBG uses output of the `fasta` benchmark at N=25,000,000).
This suite uses N=250,000 → 1.25 M-base THREE block, fixed by a
deterministic Lehmer LCG seed (see
`~/projects/lang-benches/k-nucleotide/fasta-gen.py`). The fixture
file is checked in at `input.fasta`.

**Output shape.** Two frequency tables (1-mer, 2-mer) + five exact
counts. Specifically:

```
A 30.298
T 30.157
C 19.793
G 19.752

AA 9.177
TA 9.137
…etc, 16 lines for 2-mers…
GG 3.902

14717\tGGT
4463\tGGTA
472\tGGTATT
9\tGGTATTTTAATT
9\tGGTATTTTAATTTATAGT
```

Reference at `~/projects/lang-benches/k-nucleotide/expected.txt`.

**Reference timings (1.25 M bases)**: C 66 ms / Zig 80 ms / Rust
80 ms / Go 110 ms / OCaml 306 ms / Elixir 3.4 s.

**Workload shape.** Two passes (1-mer, 2-mer) over the full sequence
plus five passes for the specific k-mers, so 7 × 1.25 M ≈ 8.75 M
hash lookups + inserts. Plus the byte-level scan during FASTA
ingestion.

---

## 10. Design constraints

These come from `~/projects/zap/CLAUDE.md` and the existing
codebase. Any proposal must respect them.

* **No workarounds, hacks, shortcuts.** Production-grade fixes only.
  If a fix needs the Zig fork to grow a new C-ABI function,
  that's the right answer — `~/projects/zig/src/zir_api.zig` is
  meant to be extended.

* **Features in Zap, not in the compiler.** Don't hardcode struct
  names like `MArray` in `src/zir_builder.zig` as string literals
  the compiler tests against. The compiler stays generic; the
  user-visible feature lives in `lib/marray.zap` (or wherever).
  Compare to how `lib/list.zap` and `lib/map.zap` work today.

* **Test-driven development.** New features need failing tests
  first, passed once the feature lands. The test suite is run via
  `zig build test` and lives in `src/*.zig` with `test "..."`
  blocks plus the in-language test framework `lib/zest/`.

* **Always run `zig build test` before declaring work complete.**
  675 tests today; non-negotiable that they all pass after the
  work.

* **Top-level functions are illegal.** Every `pub fn` must be
  inside a `pub struct`.

* **Stdlib parity.** If a feature exists for `List`, the
  equivalent should usually exist for `MArray` too — `length`,
  `at`, etc. Discoverability matters; users shouldn't have to
  remember which container has which method.

* **Buffered I/O is now the default.** Any new `IO.*` function
  must route through `stdoutBufferedWrite` /
  `stdoutBufferedWriteByte` (in `runtime.zig`). Direct
  `posixWrite(STDOUT_FD, …)` is reserved for stderr or for the
  flush path itself.

* **Macro hygiene.** New macros go in `lib/kernel.zap` as
  `pub macro X(args) -> Expr { quote { ... } }`. They expand into
  protocol dispatches when the operation is type-polymorphic.

* **The Zig fork is forkable.** If a research recommendation needs
  a new Zig-side primitive — `addStructInitTyped`, `addParam`,
  whatever — adding it is acceptable. The fork already carries
  several Zap-specific functions (see §4).

---

## 11. What's tested vs untested in the bench surface

Every existing Zap benchmark exercises a different slice of the
runtime. Knowing what's exercised tells us what's likely solid and
what's likely brittle.

### 11.1 Exercised by existing benchmarks

* **n-body** — multi-clause integer dispatch
  (`step_loop(state, 0, dt)` / `step_loop(state, n, dt)`), tail-call
  loopification, by-ref `State` aggregate, `f64` arithmetic. No
  `Map`, no `Enum.sort`, no closures.
* **mandelbrot** — recursive multi-clause integer dispatch
  (`shift_left`), `if/else`, `Integer.bsl` / `Integer.bor`,
  `Integer.remainder`, `Integer.to_float`, `IO.write_byte`,
  buffered stdout. No `Map`, no `Enum.sort`, no closures.
* **binary-trees** — recursive struct types (`Tree { left, right }`),
  multi-clause optional dispatch (`check(nil)` / `check(t :: Tree)`),
  recursive heap allocation, ARC drop, Perceus
  destructive-optional-dispatch path. No `Map`, no `Enum.sort`, no
  closures.

### 11.2 Untouched by existing benchmarks

* `Map.put / Map.get / Map.values / Map.keys` — exists, has unit
  tests, but no benchmark exercises it at scale.
* `Enum.reduce / Enum.map / Enum.sort` — exists with unit tests,
  but no benchmark exercises closures threaded through them at
  scale.
* `String` keys in `Map` — supported, untested at scale.
* Tuple-destructuring in closure parameters — at-scale.
* The `<>` macro on values whose types come out of tuple
  destructuring.
* `<=` macro / `Comparator` protocol on `String` values.
* `IO.gets` in a tight loop (line-by-line FASTA reading is the
  first benchmark to do it).

The k-nucleotide failures are concentrated in the "untouched by
existing benchmarks" set, which is consistent with these paths
having latent issues that no test currently exercises.

---

## 12. Research questions

The agent's deliverable is an implementation plan answering each:

### 12.1 `MArray` design

1. **Storage shape.** Arc-managed slice (refcounted, pool-backed) or
   plain-heap slice (pool-backed, no refcount)? Argue from existing
   conventions in `runtime.zig` and the boxing-recursive ABI.

2. **Generic vs specialised.** One generic `MArray(T)` (requires
   solving generic-struct-type at the source level) or two
   specialised types (`MArrayI64`, `MArrayF64`)? Argue from how
   `List` and `Map` did it.

3. **Source-level syntax.** Can `MArray` be a nominal struct with
   `MArray.new(N, init)` / `MArray.get(arr, i)` / `MArray.set(arr,
   i, v)` style API and stay parser-clean? Or does it need
   sugar like `[mut t]`?

4. **Ownership and drop.** When an `MArray` value goes out of scope
   inside a function, how does it get freed? If Arc-managed, the
   existing `releaseAny` / `freeAny` infrastructure should pick it
   up via the comptime field-walker — but only if the array's
   `T` element doesn't need walking too (e.g. for an `MArray(Tree)`).
   Lay out the rules.

5. **Mutation through `*const T`.** The boxing-recursive ABI passes
   recursive types as `*const T` everywhere. `MArray` mutation
   needs to write through that pointer. Either widen `MArray` to
   `*T` instead of `*const T`, or `@constCast` at the runtime
   boundary like `ArcRuntime.retainAny` does for the header.
   Pick one and justify.

6. **C-ABI surface.** What new `:zig.MArray.*` runtime functions
   does Zap need? Names, signatures, where in `runtime.zig` they
   live.

7. **Test plan.** A failing test in `src/runtime.zig` that the
   `MArray` implementation makes pass; a Zap-level test in
   `lib/marray/` that exercises `new` / `get` / `set` / `length`;
   a `lang-benches/fannkuch-redux/fannkuch-redux.zap` and
   `lang-benches/spectral-norm/spectral-norm.zap` that produce
   byte-identical output against the C reference at the test sizes.

### 12.2 k-nucleotide blockers

8. **`<>` protocol-dispatch failure on tuple-destructured String.**
   Track down where Zap's protocol dispatcher gives up on
   `kmer <> " "` when `kmer` came from `{kmer, count} = pair`. Is
   it in the dispatcher itself (`src/macro.zig` or similar)? In the
   destructuring inference path? Propose a fix that doesn't
   require source-level type ascriptions.

9. **`<=` on `String` values.** Either (a) ship a `String.compare`
   in `lib/string.zap` and document the convention, or (b) make
   the `<=` macro / `Comparator` protocol resolve `String` correctly
   in the destructured-tuple context. Pick one.

10. **`EmitFailed` on closures-with-tuple-params inside `Enum.*`.**
    Locate the actual `return error.EmitFailed` site in
    `src/zir_builder.zig`. The agent's deliverable: which line,
    what's the immediate cause, what's the proper fix. Likely
    candidates: closure environment setup for tuple-typed locals,
    `make_closure` IR's handling of tuple captures, the
    `tuple_init` lowering path.

11. **Performance shape.** With an idiomatic Zap k-nucleotide
    running, what's the realistic perf target? Reference
    implementations are 66–110 ms (C / Zig / Rust / Go). Zap's
    persistent `Map` is HAMT-backed (`O(log N)` per op), and each
    String allocation goes through the runtime arena. Estimate
    where Zap lands. Is the target "within 5×" reasonable?
    "Within 2×"? Argue from binarytrees' 2.5× of OCaml.

12. **Encoded-key alternative.** Should the Zap k-nucleotide
    follow C/Rust/Zig's encoded-`u64`-key shape instead of a
    `String` key? It's a less-idiomatic but faster Zap
    implementation. Lay out trade-offs.

---

## 13. Appendix A — file & line index

Pre-validated as of the brief's writing.

### Zap repo (`~/projects/zap/`)

| path | what's there |
|------|--------------|
| `CLAUDE.md` | core design rules. read this first. |
| `README.md` | build instructions, fork rebuild instructions. |
| `lib/list.zap:24-260` | persistent List API. closest analog for an `MArray` design. |
| `lib/map.zap:23-200` | persistent Map API. type variable `%{key => value}`. |
| `lib/string.zap:30-410` | String API. no `compare`. |
| `lib/io.zap:48-90` | `IO.print_str`, `IO.write_byte` (buffered stdout). |
| `lib/enum.zap:230-258` | `Enum.sort` + `sort_next`. comparator-driven. |
| `lib/concatenable.zap` | the `<>` protocol. |
| `lib/string/concatenable.zap` | `String` impl of `<>`. |
| `lib/list/concatenable.zap` | `List` impl of `<>`. |
| `lib/kernel.zap` | macros including `<>` and `<=`. |
| `lib/zest/*.zap` | in-language test framework. |
| `src/runtime.zig:1-110` | `posixWrite`, buffered stdout, `flushStdoutBuf`. |
| `src/runtime.zig:120-200` | `ArcHeader`, `Arc(T)`. |
| `src/runtime.zig:202-380` | `ArcRuntime`: `allocAny`, `releaseAny`, deep-release helper. |
| `src/runtime.zig:6280-6500` | `IO`-namespace runtime functions. `println`, `print_str`, `gets`, `warn`, `inspect`, `write_byte`. |
| `src/runtime.zig:3500-3850` | `List` runtime. backing for `lib/list.zap`. |
| `src/runtime.zig:5482-5570` | `Float` runtime. `to_string_f64`, `to_string_f64_precision`. |
| `src/zir_builder.zig:30-200` | `extern "c" fn zir_builder_*` C-ABI declarations. |
| `src/zir_builder.zig:332-400` | `mapReturnType`, primitive type Refs. |
| `src/zir_builder.zig:548-560` | `shouldSkipArc`, escape gate. |
| `src/zir_builder.zig:629-650` | `setLocal`, `setLocalDecl`, ValueRef. |
| `src/zir_builder.zig:1268-1305` | `isRecursiveStruct`, `zigTypeIsRecursiveStruct`, `boxRecursiveZigType`. |
| `src/zir_builder.zig:2556-2700` | `emitTypedParam`. |
| `src/zir_builder.zig:2682-2900` | `emitComplexReturnType`. |
| `src/zir_builder.zig:3656-3720` | `emitAnalysisArcOps`, drop-spec emission. |
| `src/zir_builder.zig:3960-3990` | `param_get` IR handler. |
| `src/zir_builder.zig:5260-5310` | `field_get` IR handler. retain-on-extraction logic. |
| `src/zir_builder.zig:6500-6620` | `heapPromoteForIndirectField`, `emitIndirectFieldDeref`. |
| `src/zir_builder.zig:7543-7625` | `emitOptionalDispatch`. drop hook. |
| `src/ir.zig:49-82` | `FieldStorage`, `StructFieldDef`. |
| `src/ir.zig:103-140` | `Function` IR struct. |
| `src/ir.zig:168-250` | `Instruction` union — every IR op. |
| `src/ir.zig:355-540` | aggregate inits, field ops, calls. |
| `src/ir.zig:572-580` | `CallNamed`. |
| `src/ir.zig:709-735` | `OptionalDispatch`. |
| `src/ir.zig:1742-1980` | multi-clause group lowering, including the `optional_dispatch` path with the post-body `payload_local` allocation. |
| `src/ir.zig:6105-6175` | `zigTypeReachesStructInCycle`. |
| `src/escape_lattice.zig:949-1050` | `AnalysisContext`. `destructive_optional_dispatch` field. |
| `src/escape_lattice.zig:829-845` | `FieldDrop` with `kind: Kind` (`.deep` / `.shallow`). |
| `src/perceus.zig:62-80` | `MatchKind` enum (`case_block`, `switch_tag`, `if_expr`, `optional_dispatch`). |
| `src/perceus.zig:266-360` | `checkInstructionForDeconstruction`. |
| `src/perceus.zig:715-845` | `generateDropSpecialization`. |
| `src/perceus.zig:846-1010` | `isDestructiveOptionalDispatch` + `instructionUsesAreBorrowSafe`. |
| `src/analysis_pipeline.zig:280-340` | how Perceus output flows into `AnalysisContext`. |
| `docs/arc-indirect-storage-research-brief.md` | prior research brief on the now-shipped boxing/drop work. |
| `docs/codegen-blockers-research-brief.md` | older codegen blockers brief. mentions earlier protocol-dispatch issues. |

### Zig fork (`~/projects/zig/`)

| path | what's there |
|------|--------------|
| `src/zir_api.zig` | full C-ABI surface. add new functions here. |
| `src/zir_api.zig:2807-2820` | `zir_builder_set_custom_return_type` example (what a body-based type setter looks like). |
| `src/zir_api.zig:3601-3620` | `zir_builder_emit_param_type_body` example. |
| `src/zir_builder.zig` | the fork-side `Builder` / `FuncBody` / `RootStruct` types that the C-ABI calls into. |
| `src/Sema.zig` | semantic analysis. consult only when ZIR shapes don't make sense. |

### lang-benches (`~/projects/lang-benches/`)

| path | what's there |
|------|--------------|
| `nbody/nbody.zap` | n-body Zap port. example of multi-clause + tail-call loopification + by-ref struct. |
| `mandelbrot/mandelbrot.zap` | mandelbrot Zap port. example of buffered byte-stream output + `IO.write_byte`. |
| `binarytrees/binarytrees.zap` | binarytrees Zap port. example of recursive struct, multi-clause optional dispatch. |
| `fannkuch-redux/` | NEW, Zap impl missing. C/Rust/Zig/Go/OCaml/Elixir present. |
| `fannkuch-redux/fannkuch-redux.c` | reference C implementation. |
| `fannkuch-redux/fannkuch-redux.zig` | reference Zig 0.16 implementation. closest target shape for a Zap port. |
| `fannkuch-redux/expected_n10.txt` | expected output at N=10 (`73196\nPfannkuchen(10) = 38\n`). |
| `spectral-norm/` | NEW, Zap impl missing. |
| `spectral-norm/spectral-norm.c` | reference. |
| `spectral-norm/expected_n5500.txt` | expected output at N=5500 (`1.274224153\n`). |
| `k-nucleotide/` | NEW, Zap impl missing. |
| `k-nucleotide/k-nucleotide.c` | reference. uses inline u64-keyed open-addressing hash table. |
| `k-nucleotide/k-nucleotide.exs` | reference. uses `Map.update/4` shape, similar to a Zap port would. |
| `k-nucleotide/fasta-gen.py` | deterministic FASTA generator. |
| `k-nucleotide/input.fasta` | 1.25 M-base test fixture. |
| `k-nucleotide/expected.txt` | expected output. |
| `scripts/run-all.sh` | hyperfine harness. has Zap-as-exclusion sections for the three new benchmarks. |
| `scripts/measure-rss.sh` | per-process RSS pass. |
| `scripts/render-html.py` | HTML renderer. `EXCLUSIONS` dict carries the language-feature-gap notes. |

---

## 14. Appendix B — current benchmark scoreboard

After the boxing + Perceus + memory-pool + buffered-stdout +
streaming-mandelbrot work landed; before any `MArray` /
k-nucleotide work.

| benchmark | rank | language | wall | RSS |
|-----------|------|----------|------|-----|
| **nbody** N=5M | **1st** | **Zap** | **110 ms** | 1.3 MiB |
| | 2nd | C | 160 ms | 1.2 MiB |
| | 3rd | Zig | 161 ms | 1.3 MiB |
| **mandelbrot** N=8000 | 1st | Go | 1934 ms | 4.0 MiB |
| | 2nd | C | 1956 ms | 1.3 MiB |
| | 3rd | Zig | 2032 ms | 1.3 MiB |
| | **4th** | **Zap** | **2091 ms** | **1.4 MiB** |
| **binarytrees** N=21 | 1st | OCaml | 1111 ms | 215 MiB |
| | **2nd** | **Zap** | **2649 ms** | **193 MiB** |
| | 3rd | Zig | 3359 ms | 162 MiB |
| **fannkuch-redux** N=11 | 1st | Rust | 1433 ms | 1.4 MiB |
| | 2nd | Zig | 1550 ms | 1.3 MiB |
| | 3rd | C | 1556 ms | 1.2 MiB |
| | excluded | **Zap** | — | — |
| **spectral-norm** N=2500 | 1st | Rust | 158 ms | 1.5 MiB |
| | 2nd | Zig | 159 ms | 1.5 MiB |
| | 3rd | C | 194 ms | 1.3 MiB |
| | excluded | **Zap** | — | — |
| **k-nucleotide** | 1st | C | 66 ms | 26.6 MiB |
| | 2nd | Zig | 80 ms | 11.3 MiB |
| | 3rd | Rust | 80 ms | 14.8 MiB |
| | excluded | **Zap** | — | — |

Recent commits relevant to this brief:

* `zap` repo: `19f4ab6` deep-release helper, `364b31e` boxing,
  `4ffb616` c_allocator, `f133876` MemoryPool, `c736f34` borrow
  inference, `66d0454` buffered stdout + IO.write_byte,
  `8abdb3c` `Float.to_string` precision overload.
* `lang-benches` repo: `2afdf2d` adds the three new benchmarks
  with reference implementations + harness wiring + Zap
  exclusions; previous commits adding the original three.

---

**End of brief.** The agent should produce, for each blocker, a
concrete implementation plan: which files change, which functions
are added or modified, what the new C-ABI surface is (if any),
what the test plan looks like, and where the work meets the
"no compromises on code quality" bar from `CLAUDE.md`.
