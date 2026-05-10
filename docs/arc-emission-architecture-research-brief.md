# Zap: ARC emission architecture — research brief

> **Audience.** A deep-research AI agent with zero prior context on Zap, the
> Zap fork of the Zig compiler, ARC (atomic reference counting), or how the
> two repos fit together. Read top-to-bottom — the technical detail in §7+
> only makes sense after §1–§6.
>
> **Goal.** Produce a recommended implementation strategy, with concrete file
> paths and line numbers, for an architectural refactor: making the IR the
> single source of truth for every ARC retain and release operation in a
> compiled Zap program. Today, several retain and release runtime calls are
> emitted directly from the ZIR backend without a corresponding `.retain` /
> `.release` IR instruction. This is a soundness gap: it has already produced
> at least one major memory leak (the binary-trees benchmark, ~12 GB RSS
> instead of a few hundred MB), and the architecture creates many places
> where future changes can silently introduce more leaks.
>
> The investigation that motivates this brief is documented in §8. The audit
> findings are in §9. The proposed refactor scope is in §10. The open design
> questions the agent must answer are in §11.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [The ARC runtime](#5-the-arc-runtime)
6. [The IR-level ARC pipeline](#6-the-ir-level-arc-pipeline)
7. [The architectural invariant we want to establish](#7-the-architectural-invariant-we-want-to-establish)
8. [The investigation: binary-trees as the canary](#8-the-investigation-binary-trees-as-the-canary)
9. [Audit findings](#9-audit-findings)
10. [Proposed refactor](#10-proposed-refactor)
11. [Design questions](#11-design-questions)
12. [Why it matters: the four CLBG benchmarks](#12-why-it-matters-the-four-clbg-benchmarks)
13. [Investigation hooks — file & line index](#13-investigation-hooks--file--line-index)
14. [Design constraints](#14-design-constraints)
15. [Research questions](#15-research-questions)
16. [Appendix A — IR dumps from the investigation](#16-appendix-a--ir-dumps-from-the-investigation)
17. [Appendix B — runtime ARC counter snapshots](#17-appendix-b--runtime-arc-counter-snapshots)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles to
native binaries. The surface ergonomics borrow heavily from Elixir
(immutable values, pattern matching, multi-clause function dispatch with
guards, pipe operator, macros over an AST), but the runtime is native:
there is no VM, no interpreter, and no tracing GC. Zap source compiles
through Zig's intermediate representation (ZIR) into LLVM, and the produced
binary is statically-linked machine code.

**Project tagline.** "Elixir's developer experience without the runtime
overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`, paraphrased):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is a general-purpose tool that doesn't know
  about specific Zap structs (`IO`, `String`, `Map`, the ARC runtime).
  Standard library functions, macros, the test framework, and DSLs all
  live in `lib/*.zap`.
* **The compiler only handles language primitives**: parsing, the type
  system, ZIR emission, and a tiny set of runtime primitives that
  cannot be expressed in Zap (stdout, raw allocation, OS argv, the
  ARC machinery).
* **No workarounds or hacks.** Every solution must be the correct,
  production-grade, long-term fix. If the proper fix requires changes
  to the Zig fork, that's the fix. If it requires re-architecting an
  IR pass, that's the fix. Cost and time are not concerns —
  correctness and quality are.

**Surface syntax — minimal example:**

```zap
pub struct Greeter {
  pub fn hello(name :: String) -> String {
    "Hello, " <> name <> "!"
  }

  pub fn main(_args :: [String]) -> String {
    Greeter.hello("World") |> IO.puts()
  }
}
```

**Recursive struct + multi-clause dispatch — this is the shape that
matters for §8:**

```zap
pub struct Tree {
  left  :: Tree | nil
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
    1 :: i64 + Binarytrees.check(t.left) + Binarytrees.check(t.right)
  }
}
```

`Tree` is self-referential. Multi-clause dispatch on `nil` vs `Tree`
unifies the parameter to `?Tree` and routes via an internal
`optional_dispatch` IR node. `Tree | nil` fields receive
`FieldStorage.indirect` storage internally so the layout cycle compiles
(see §6 for the rest of the recursive-struct pipeline).

---

## 2. Project layout & toolchain

Three coordinated repositories on the local filesystem.

```
~/projects/zap/        — the Zap compiler & language itself
~/projects/zig/        — the Zap fork of Zig 0.16.0
                          (branch: zap-zir-library-0.16)
~/projects/lang-benches/ — the cross-language benchmark harness
                            (uses hyperfine; reports vs C/Rust/
                             Zig/Go/OCaml/Elixir)
```

### `~/projects/zap` — directory layout (only the parts that matter)

```
src/                                  — compiler source
  parse.zig                           — lexer + parser → AST
  ast.zig, ast_data.zig               — AST data types
  collector.zig                       — scope graph / decl collection
  hir.zig                             — High-level IR (closer to source)
  desugar.zig                         — desugaring rules
  types.zig                           — TypeStore + TypeChecker
  ir.zig                              — Mid-level IR (lowering target)
  zir_builder.zig                     — IR → ZIR lowering (calls into the fork)
  zir_backend.zig                     — drives the fork's compile pipeline
  runtime.zig                         — Zap runtime: ARC, atom table, IO,
                                         List, Map, Vector, Tuple
  arc_liveness.zig                    — ARC live-set / arc_managed_locals
  arc_ownership.zig                   — share_value mode classifier
  arc_drop_insertion.zig              — scope-exit .release IR insertion
  arc_param_convention.zig            — borrowed→owned promotion
  arc_optimizer.zig                   — eliminate redundant retain/release
  arc_verifier.zig                    — invariant checks
  escape_lattice.zig                  — escape/ownership lattices
  generalized_escape.zig              — escape analysis worklist
  region_solver.zig                   — region inference (use-def)
  interprocedural.zig                 — call-graph + alias analysis
  ctfe.zig                            — comptime function evaluator
  compiler.zig                        — top-level pipeline driver
  main.zig                            — CLI entry point

lib/                                  — Zap stdlib, all in Zap source
  zap_runtime.zap                     — runtime helper bindings
  io.zap, string.zap, integer.zap,
  list.zap, map.zap, kernel.zap,
  zest/                               — test framework
  …

docs/                                 — design notes & briefs
  arc-indirect-storage-research-brief.md   — predecessor brief that
                                              motivated the recursive-
                                              struct / boxed-recursive
                                              ABI (now shipped)
  arc-emission-architecture-research-brief.md   — THIS DOCUMENT

zig-out/bin/zap                       — built compiler binary
build.zig, build.zig.zon              — build script (uses libzap_compiler.a)
```

### `~/projects/zig` (fork) — only files this brief touches

```
src/zir_builder.zig                   — Zap-facing ZIR builder API
                                         (Zap's additions on top of upstream
                                          Zig)
src/zir_api.zig                       — C-ABI exports consumed by Zap
                                         via extern "c" fn declarations
build.zig                             — `zig build lib` → libzap_compiler.a
```

The fork's branch is `zap-zir-library-0.16`. Build with:

```sh
cd ~/projects/zig
/path/to/zig build lib \
  --search-prefix /path/to/zig-bootstrap/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

Output: `~/projects/zig/zig-out/lib/libzap_compiler.a`.

Rebuild Zap pointing at the new fork artifact:

```sh
cd ~/projects/zap
zig build \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=/path/to/zig-bootstrap/out/aarch64-macos-none-baseline/lib
```

### Toolchain

* **Host Zig**: 0.16.0 (asdf-managed). The fork builds against this.
* **macOS / aarch64** (Apple Silicon). Some details in this brief are
  AArch64-specific; the underlying design generally holds on x86_64 too
  but the symptoms differ.
* **8 MB thread stack ceiling** on macOS. Solutions that work only by
  raising this ceiling on Linux are not acceptable.

### Running the test suite

```sh
cd ~/projects/zap
zig build test               # Zig-side unit tests (compiler internals)
./zig-out/bin/zap test       # Zap-side test suite (~819 tests)
```

**Important:** there is a separate target `zig build zir-test` that runs
end-to-end ZIR generation tests. **Do not run that target** in research
contexts — it is extremely slow and the user runs it manually when
needed.

---

## 3. Compilation pipeline

```
.zap source files
  ↓ parse.zig
AST (ast.zig)
  ↓ collector.zig          (scope graph, decl resolution)
  ↓ desugar.zig            (desugaring rules)
  ↓ macro expansion
HIR (hir.zig — high-level IR)
  ↓ types.zig              (type checking; populates TypeStore)
  ↓ generic monomorphisation
  ↓ ir.zig                 (lower HIR → IR; tail-call rewrite;
                              loopification flag)
IR (mid-level IR)
  ↓ analysis passes (in this rough order):
    arc_param_convention   (borrowed→owned promotion for self-recursive callees)
    arc_ownership          (.local_get → .borrow_value | .copy_value | .share_value)
    arc_liveness           (live-before-ret analysis; arc_managed_locals seed)
    arc_drop_insertion     (insert .release IR before terminators)
    arc_verifier           (invariant checks; will gain new invariants — see §10)
    arc_optimizer          (redundant retain/release elimination)
  ↓ zir_builder.zig        (lower IR → ZIR by calling into the fork's
                              C-ABI builder)
ZIR (Zig intermediate representation)
  ↓ libzap_compiler.a      (Sema + AIR + LLVM codegen, all from the
                              fork)
LLVM IR  →  machine code  →  native binary
```

A few stages matter heavily for this brief.

### HIR

`src/hir.zig` lowers AST into a representation closer to the type
system. Pattern-matrix compilation lives here; multi-clause function
groups become decision trees of `bind`, `extract_struct`,
`switch_literal`, `check_tuple`, etc.

Function groups that share name + arity are merged into one
`FunctionGroup` here, even if declared in separate `pub fn` decls.

### IR (mid-level)

`src/ir.zig` defines:

* `Function`, `Block`, `Instruction` (a tagged union of ~80 variants).
* `StructDef`, `StructFieldDef`, `FieldStorage` (the indirection
  decision the recursive-struct pipeline turns on — see §6).
* `Param`, `ZigType` (a structured union — `i64`, `string`,
  `optional`, `list`, `struct_ref(name)`, `ptr`, `map`, …).

Notable IR-level passes:

* `zigTypeReachesStructInCycle` — SCC-aware walker over the struct
  dependency graph. Marks a field's storage as `.indirect` when the
  field's type can transitively reach a struct in the same cycle as
  its owner. This is what makes recursive struct layouts compile.
* `rewriteTailCalls` — walks switch-return / optional-dispatch /
  case-block bodies and rewrites self-tail-calls (`call_named` or
  `call_direct` immediately followed by `ret return_value`) to
  `tail_call` IR nodes.
* `Function.loopify` — flag set when a function has `tail_call` IR and
  a non-TCO-safe signature; triggers loopification at ZIR-emit time.

### ZIR-emit time

`src/zir_builder.zig` is where IR meets the fork. Every IR instruction
has a `case` arm in `emitInstruction` (or specialized helpers) that
emits one or more ZIR instructions by calling `extern "c" fn
zir_builder_*` helpers defined in the fork's `zir_api.zig`.

**Crucially for this brief**, the ZIR backend also emits a number of
ARC retain/release runtime calls *directly* from various IR-instruction
arms — not as the lowering of an explicit `.retain` / `.release` IR
instruction. The full inventory of those direct emissions is in §9.

---

## 4. The Zig fork and the C-ABI boundary

Zap doesn't fork the entire Zig compiler — it adds a thin "ZIR builder"
library on top of upstream Zig 0.16.0 and exports a stable C-ABI for Zap
to call into.

### The C-ABI (`~/projects/zig/src/zir_api.zig`)

About 200 `pub export fn zir_builder_emit_*` functions. Examples:

```zig
pub export fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, v: i64) u32 { … }
pub export fn zir_builder_emit_call(handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8, name_len: u32,
    args_ptr: [*]const u32, args_len: u32) u32 { … }
pub export fn zir_builder_emit_field_val(handle: ?*ZirBuilderHandle,
    object: u32, field_name_ptr: [*]const u8, field_name_len: u32) u32 { … }
```

Each returns either a `Zir.Inst.Ref` (encoded as `u32`) or
`0xFFFFFFFF` on failure.

Zap-side bindings live at the top of `~/projects/zap/src/zir_builder.zig`:

```zig
extern "c" fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, v: i64) u32;
extern "c" fn zir_builder_emit_call_ref(handle: ?*ZirBuilderHandle,
    callee_ref: u32, args_ptr: [*]const u32, args_len: u32) u32;
…
```

### When you need to extend the fork

Whenever Zap needs a ZIR shape upstream Zig doesn't already produce.
Add it to the fork; don't simulate it from existing primitives.
Examples that recently shipped:

* Streaming per-field-body API for struct-decl fields
  (`begin_root_field_body` / `end_root_field_body` /
  `set_root_field_static`).
* `addParamOptionalDeclValType`, `addParamOptionalThisType` — for
  emitting `?T` parameter types where T is a sibling decl.
* `addSingleConstPtrType` — `*const T` emission for indirect-storage
  field types (`?*const Tree`).

### Sema (`~/projects/zig/src/Sema.zig`)

Upstream-Zig file, ~120k lines. Rarely modified. Read when you need to
understand what shape Sema expects from a particular ZIR instruction.

---

## 5. The ARC runtime

`src/runtime.zig` (~11k lines) hosts every runtime primitive the
compiled Zap program calls into.

### `ArcHeader`

```zig
pub const ArcHeader = extern struct {
    ref_count: std.atomic.Value(u32),

    pub fn init() ArcHeader { return .{ .ref_count = .{ .raw = 1 } }; }
    pub fn retain(self: *ArcHeader) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *ArcHeader) bool {
        return self.ref_count.fetchSub(1, .acq_rel) == 1;
    }
    pub fn count(self: *const ArcHeader) u32 {
        return self.ref_count.load(.monotonic);
    }
};
```

Every ARC-wrapped allocation has a refcount header in front of the
user-visible value. Initialized at 1; `retain` increments; `release`
decrements and returns `true` on the zero-transition (caller must free).

### Two header strategies

**Wrapped header** — a separate `Arc(T).Inner` struct of
`{ header, value }` is allocated; the user holds `*T` (a pointer to
`value`); `@fieldParentPtr("value", ptr)` recovers `Inner` and the
header. Used for plain types (e.g., recursive struct nodes).

**Inline header** — `T` itself contains the header as its first field
(e.g., `List(T)`, `Map(K, V)`, `Vector(T)`). No extra allocation; the
type provides its own `retain` / `release` / `arcReleaseDeep` methods.

`hasInlineArcHeader(T)` (around `runtime.zig:1100`) discriminates the
two.

### Pool allocation

Every `Arc(T).Inner` allocation comes from a per-type
`std.heap.MemoryPool` (`ArcPool(T)`) rather than `page_allocator`
directly. Pool stats are tracked in `PoolStats` (`runtime.zig:389`):

```zig
pub const PoolStats = struct {
    name: []const u8,
    live: u64 = 0,         // current live cells (alloc - destroy)
    high_water: u64 = 0,
    registered: bool = false,
    next: ?*PoolStats = null,
    …
};
```

When `ZAP_ARC_STATS=1` is set in the environment of a compiled Zap
binary, an `atexit` hook prints the global retain/release totals and
every pool's high-water mark to stderr. **This was the load-bearing
signal for §8's investigation.**

### Public ARC entry points

```zig
pub const ArcRuntime = struct {
    pub fn allocAny(comptime T, allocator, value) *T;        // alloc + init rc=1

    pub fn retainAny(ptr: anytype) void;                     // generic retain
    pub fn retainAnyPersistent(ptr: anytype) void;           // long-lived owner
                                                              // (struct field /
                                                              // container slot)
    pub fn retainAnyOpt(ptr: anytype) void;                  // through optional
                                                              // (?*const T)

    pub fn releaseAny(allocator, ptr: anytype) void;
    pub fn releaseArcAny(comptime T, allocator, ptr) void;
    pub fn prepareReleaseAny(comptime T, ptr) ?*T;           // phase 1: dec & test
    pub fn destroyPreparedAny(comptime T, allocator, ptr);   // phase 2: free

    pub fn releaseChildrenAny(comptime T, allocator, value); // walk struct fields
    pub fn retainChildrenAny(comptime T, value);             // mirror walk
    pub fn freeAny(comptime T, allocator, ptr) void;         // shallow free
};
```

The split-phase release (`prepareReleaseAny` + `releaseChildrenAny` +
`destroyPreparedAny`) is what makes recursive struct teardown work:

1. Phase 1: atomically decrement refcount and report whether the caller
   is now the last owner.
2. Phase 2 (only if last owner): walk `T`'s indirect-storage fields at
   comptime via `releaseChildrenAny`; recursively release each child
   pointer.
3. Phase 3: destroy the parent's allocation.

This was added by the recursive-struct work that shipped in commits
591a9ed, ba2a423, 3c13772, 80010aa, 8f312f7. It's documented in detail
in `docs/arc-indirect-storage-research-brief.md` (the predecessor
brief).

### Counters

Three global counters tracked at runtime:

```zig
pub var arc_retains_total:  u64 = 0;   // every retainAny / retain method
pub var arc_releases_total: u64 = 0;   // every releaseAny / release method
pub var arc_consumes_total: u64 = 0;   // share_value mode=consume call sites

pub var list_mut_calls_total:    u64 = 0;
pub var list_rc1_fast_path_total: u64 = 0;
pub var list_unchecked_total:     u64 = 0;
pub var dense_map_mut_calls_total:    u64 = 0;
pub var dense_map_rc1_fast_path_total: u64 = 0;
pub var dense_map_unchecked_total:     u64 = 0;
```

Dump format (`runtime.zig:434`):

```
[zap-arc-stats] retains_total=N releases_total=N consumes_total=N return_elisions_total=N
[zap-arc-stats] dense_map_mut_calls_total=N dense_map_rc1_fast_path_total=N dense_map_unchecked_total=N
[zap-arc-stats] list_mut_calls_total=N list_rc1_fast_path_total=N list_unchecked_total=N
[zap-arc-stats] pool=Arc(T) live=N high_water=N
```

For a leak-free program, `retains_total ≈ releases_total` (delta = 0
modulo a small noise term from atexit ordering and the program's own
return-from-`main` path). Any persistent positive delta is leaked
retains.

### Inline-header types: `List(T)`, `Map(K, V)`, `Vector(T)`, `Tuple(...)`

These types carry their refcount inline and have their own `retain` /
`release` / `arcReleaseDeep` methods. They also have *runtime-internal*
ARC operations:

* **COW (copy-on-write) clone with retains.**  `List.set` /
  `List.push` etc. mutate in place at `rc==1` and clone at `rc>1`. The
  clone path retains every ARC-managed child element of the new
  buffer (`cloneBufferRetainingChildren`, `runtime.zig:1851`).
* **Element retain on extraction.**  `List.get` / `List.head` /
  `List.last` retain the extracted element so the caller receives a
  fresh ARC owner (`retainElement`, `runtime.zig:1970`+).
* **Deep release on zero-transition.**  When `List.release` brings the
  refcount to 0, `bufferFreeDeep` walks every element and releases it
  before destroying the buffer (`runtime.zig:1805`+). Map and Vector
  have analogous walks.

These runtime-internal retains/releases balance internally **provided
the caller correctly manages the lifecycles of the IR-visible values**.
A balanced program emits one IR-level `.release` for the input List
when it's reassigned (so the old buffer's refcount drops to 0,
triggering the deep walk that releases all children). If the
IR-level release is missed, the leak cascades through every retained
child.

This is exactly the failure shape we observe in fannkuch-redux (§8):
the runtime's per-clone retains balance against the buffer's eventual
deep release, *if and only if* that deep release fires. The compiler
side missed the rebind release, the deep release never fired, and the
COW retains became permanent leaked refcounts.

---

## 6. The IR-level ARC pipeline

The IR design today encodes ARC effects through a mix of:

* **Explicit `.retain` and `.release` IR instructions** —
  the canonical primitives. ZIR lowers `.retain` to
  `ArcRuntime.retainAny(...)` calls, `.release` to
  `ArcRuntime.releaseAny(allocator, ...)`.
* **IR instructions with implicit ARC semantics** —
  e.g., `.copy_value` always retains its dest; `.share_value`
  with `mode=.retain` retains its dest; `.field_get` of an
  indirect-storage recursive struct field retains the extracted child.
  These retains are emitted **directly by the ZIR backend** without
  a corresponding `.retain` IR instruction.
* **Param conventions** — `.borrowed` vs `.owned` parameter conventions
  that determine whether the callee or the caller owns the parameter's
  refcount.
* **Return-source elision** — when a returned value is the source of
  an ARC retain that would have been balanced by a scope-exit release,
  both ops are elided (ownership transfers directly to the caller's
  return slot).
* **Runtime-internal ARC** — e.g., COW retains inside
  `List.set` (§5).

### IR ARC instructions (`src/ir.zig`)

`Instruction` is a tagged union (~80 variants). The ARC-relevant
subset:

* `.retain { value: LocalId }` — bump the refcount of `value`.
* `.release { value: LocalId }` — drop the refcount; runtime decides
  whether to free.
* `.share_value { dest, source, mode: { .consume, .retain } }` — passes
  `source` to a callee. `.consume` = caller transfers ownership (no
  retain at site); `.retain` = caller keeps ownership (retain at site,
  matching post-call `.release` is emitted by the call lowering in
  `ir.zig`).
* `.copy_value { dest, source }` — produces a new persistent ARC owner
  of the source's cell. ZIR emits an implicit retain at the lowering
  site.
* `.borrow_value { dest, source }` — a value alias with no ARC effect;
  `dest` does not own the cell. Verifier enforces no destroy at scope
  exit for borrows.
* `.move_value { dest, source }` — ownership transfer with the source
  invalidated. Today's lowering treats it identically to `.local_get`
  for ARC purposes; full move semantics are partially-implemented (see
  §11 question Q3).
* `.local_get { dest, source }` — pre-classification dataflow alias.
  Replaced by one of the above by `arc_ownership.zig` (Phase C).
* `.local_set { dest, value }` — assignment to an existing local.
* `.field_get { dest, object, field, struct_type }` — read a struct
  field. **For indirect-storage recursive fields**, the lowering at
  `zir_builder.zig:5673` emits an implicit `retainAnyOpt(extracted)`.
* `.struct_init { dest, fields }`, `.tuple_init`, `.list_init`,
  `.map_init` — aggregate construction. Element-level ARC retains are
  emitted by the lowering as the elements are placed into the
  aggregate.
* `.list_get { dest, list, index }`, `.list_head`, `.list_tail`,
  `.list_last` — element extraction; runtime helper retains the
  extracted element.
* `.map_get { dest, map, key }` — analogous.
* `.list_set { dest, list, index, value }`, `.list_push`, `.list_pop`,
  `.list_append`, `.list_cons` — list mutations; runtime helper handles
  rc==1 in-place vs rc>1 COW; clone path retains children.
* `.call_named`, `.call_direct`, `.call_builtin`, `.tail_call` —
  call instructions. Caller emits `.share_value` per ARC arg, post-call
  `.release` per shared arg (in `.retain` mode); callee receives
  borrowed references and emits its own scope-exit releases (per the
  `.borrowed` param convention) or doesn't (per `.owned`).
* `.ret { value }`, `.cond_return`, `.switch_return`,
  `.union_switch_return`, `.optional_dispatch` — return / multi-arm
  return constructs; each ret-equivalent terminator carries
  `live_before_ret` analysis state and gets scope-exit releases
  inserted by `arc_drop_insertion`.

### The analysis passes

#### `arc_param_convention.zig` (~4600 lines)

Promotes parameter convention from `.borrowed` (default for ARC-managed
types) to `.owned` for self-recursive callees that meet specific
conditions:

1. The function has at least one self-recursive call site (a `tail_call`
   referencing itself).
2. Every self-recursive call site at slot `i` passes a `move_value`
   source.
3. Every non-recursive caller passes slot `i` at last use (so consume
   semantics are sound).

When all three hold, slot `i` is promoted to `.owned`. The callee then
emits a scope-exit `.release` on the parameter; the caller emits a
`.share_value(.consume)` with no retain at the call site.

If any condition fails, the slot stays `.borrowed`: callee no
scope-exit release; caller retains before the call and releases after.

This is why `Binarytrees__check__1`'s `t` parameter stays `.borrowed`
in §8 — `check` calls itself but the recursive sites are inside an
arithmetic expression (`1 + check(t.left) + check(t.right)`), not in
tail position, so condition 1 fails.

#### `arc_ownership.zig` (~6900 lines)

Phase C of the ARC pipeline. Transforms `.local_get` IR instructions
into `.borrow_value`, `.copy_value`, or `.share_value` based on how the
local flows downstream:

* used only as a borrowing call argument → `.borrow_value`
* used as a persistent owner (closure capture, struct field, return
  source) → `.copy_value`
* passed to a call as a transferable arg → `.share_value`

Modes on `.share_value` are decided by last-use analysis: a last-use
flowing into a call is `.consume`, otherwise `.retain`.

#### `arc_liveness.zig` (~5990 lines)

Computes per-instruction live-set information (`live_before_ret`,
`live_after_ret`, `arc_managed_locals`).

`arc_managed_locals` is the set of locals that participate in ARC. It
is seeded from:

* the source and dest of `.share_value`
* the value of `.retain` and `.release`
* (and, indirectly via the type system, `.copy_value` dest because
  ownership classification routes ARC-managed types through copy)

**Critically**, `arc_managed_locals` is **not** seeded from the dest of
`.field_get` even when the field type is indirect-storage recursive —
this is the binarytrees-class bug.

`live_before_ret` is keyed by `arc_liveness.InstructionId` values
produced by the analyzer's depth-first traversal. To look these up
correctly, downstream consumers must traverse IR in the same order and
assign the same IDs. `arc_drop_insertion` mirrors that traversal.

#### `arc_drop_insertion.zig` (~3411 lines)

The pass that inserts `.release` IR instructions at scope-exit points.
For every ret-equivalent terminator, it rewrites the enclosing
instruction stream so that immediately before the terminator:

1. A `.release{value=X}` is emitted for each ARC-managed local X
   recorded in `ownership.live_before_ret[id]`.
2. A `.retain{value=L}` is emitted when the terminator carries a
   return value L that is ARC-managed AND not in
   `ownership.return_source_locals`. (When L IS in
   `return_source_locals`, the Phase 5 `isReleaseSuppressed` filter
   elides the release and the retain is skipped — net zero refcount
   ops, ownership transfers directly to the caller's return slot.)

Tail calls receive no retain — there's no return value at the IR site.

This pass is the canary for the binarytrees bug: because
`Binarytrees__check__1`'s `t` and the field-extracted `t.left` /
`t.right` locals are not in `arc_managed_locals`, they are not in
`live_before_ret`, and no scope-exit `.release` is emitted for them.
Yet the field-get retains fire at runtime (via the implicit
`retainAnyOpt` ZIR-level emission), so retains accumulate without
matching releases. (See §8 for the IR dump that proves this.)

#### `arc_verifier.zig` (~2674 lines)

Runs invariant checks after drop insertion. Currently enforces:

* Borrowed parameters cannot be returned (would alias the caller's
  cell).
* Owned-result functions must produce return values backed by retain
  or by retained-and-elided sources.
* Various refcount-balance invariants.

The verifier will gain new invariants under the proposed refactor (see
§10).

#### `arc_optimizer.zig`

Eliminates redundant retain/release pairs. Operates on the IR after
drop insertion.

---

## 7. The architectural invariant we want to establish

> **Every retain and release operation that the compiled Zap program
> executes at runtime corresponds 1:1 to a `.retain` or `.release` IR
> instruction in its lowered IR.**

The ZIR backend's role becomes purely mechanical: it lowers `.retain`
and `.release` IR instructions into runtime calls
(`ArcRuntime.retainAny` / `ArcRuntime.releaseAny` etc.) and emits no
other retain/release calls itself. Higher-level IR ops (`.copy_value`,
`.share_value`, `.field_get`, aggregate construction) are pure
dataflow.

### Why it must be IR-level

If ARC operations live below the IR level — emitted by the ZIR backend
in response to ad-hoc compiler logic that the IR-level passes don't
see — then the IR-level passes are blind to those operations. They
cannot:

* Verify retain/release balance.
* Eliminate redundant pairs.
* Insert matching scope-exit releases.
* Reason about ownership transfer.
* Detect leaks at compile time.

This is not a hypothetical concern. **The binarytrees benchmark leaks
~610 million tree nodes (~12 GB RSS) at every run** because the
field-extraction retain is emitted at ZIR level without a `.retain` IR
instruction, so `arc_drop_insertion` doesn't see the local as
ARC-managed and doesn't emit the matching `.release`. The IR pipeline
is sound; it just isn't being told everything.

The current code happens to work for `.copy_value` and `.share_value`
mode=retain because the analysis passes were taught — separately, in
each pass — to recognize the implicit retain semantics. That's
coordination, not soundness. Any future ZIR-level retain emission that
fails to teach every analysis pass produces a silent leak.

### Two interpretations of "IR is the source of truth"

The architectural invariant has two coherent readings.

**Strict interpretation.** Every retain or release runtime call is
produced by the ZIR lowering of an explicit `.retain` or `.release` IR
instruction. *No other code path may emit a retain/release runtime
call.* Higher-level IR ops are pure dataflow.

Under strict, runtime helpers that internally retain (e.g., `List.get`
retaining the extracted element) must be refactored to return borrowed
references. The IR adds an explicit `.retain` after each
`.list_get` whose dest is ARC-managed.

**Centralized-effect interpretation.** Runtime helpers may continue to
retain/release internally (current `List.get` behavior is fine), but
every IR instruction's ARC effect is documented in a single central
function (e.g., `arcEffectOf(instr) -> { retains: [LocalId], releases:
[LocalId] }`). All analysis passes consult this function. ZIR
lowering keeps emitting the runtime calls per-op.

The agent must choose between these interpretations. They have
different scopes:

| | Strict | Centralized-effect |
|---|---|---|
| Scope of refactor | Compiler + runtime helper contracts | Compiler only |
| Lines changed (rough) | ~3000 | ~500 |
| Long-term invariant strength | Stronger (every ARC op is IR) | Weaker (some ops are runtime-internal but documented) |
| Future-proofing | Adding a new ARC effect = emit `.retain`/`.release` IR; nothing else changes | Adding a new ARC effect = update `arcEffectOf` AND every pass that consults it |
| Compatibility with existing runtime data structures (`List`, `Map`, etc.) | Requires refactoring every helper that retains/releases | Runtime stays as-is |

§11 discusses both options as research questions.

---

## 8. The investigation: binary-trees as the canary

This is the concrete bug that surfaced the architectural mismatch.

### Symptom

The CLBG `binary-trees` benchmark at N=21 runs `Binarytrees.make` and
`Binarytrees.check` (the source is in §1) ~610 million times across
9 even-depth bands plus the stretch and long-lived trees. The reference
implementations (C, Rust, Zig, Go, OCaml) finish in seconds with RSS
< 250 MB. Zap finishes (correct output, byte-identical to C) but with
**RSS ≈ 12 GB**, suggesting essentially nothing gets freed during the
run.

### Reproduction

```sh
cd ~/projects/lang-benches/binarytrees
~/projects/zap/zig-out/bin/zap build
ZAP_ARC_STATS=1 ./zap-out/bin/binarytrees 21 > /dev/null 2>/tmp/binarytrees-arc.txt
cat /tmp/binarytrees-arc.txt
```

Output:

```
[zap-arc-stats] retains_total=922047838 releases_total=5592388 consumes_total=0 return_elisions_total=0
[zap-arc-stats] dense_map_mut_calls_total=0 dense_map_rc1_fast_path_total=0 dense_map_unchecked_total=0
[zap-arc-stats] list_mut_calls_total=0 list_rc1_fast_path_total=0 list_unchecked_total=0
[zap-arc-stats] pool=Arc(Tree) live=610970300 high_water=610970303
```

**Reading the counters:**

* 922,047,838 retains, 5,592,388 releases. Delta: **+916,455,450 leaked
  retains.** Releases at 0.6% of retains.
* `Arc(Tree).live = 610,970,300` at process exit. The pool's
  high-water mark is 610,970,303. Almost every Tree node ever
  allocated is still alive at exit; effectively no trees are freed
  during the run.
* `consumes_total = 0`: zero `share_value` sites in this binary fire
  in `.consume` mode. Every Tree argument is passed in `.retain` mode.

### Localizing the bug via IR dump

The compiler honors the `ZAP_DUMP_IR_FN=<glob>` environment variable
during `zap build` to dump the post-drop-insertion IR for any function
whose name matches the glob (`compiler.zig:2313`).

```sh
cd ~/projects/lang-benches/binarytrees
rm -rf .zap-cache zap-out
ZAP_DUMP_IR_FN=Binarytrees__ ~/projects/zap/zig-out/bin/zap build 2>&1 \
  | tee /tmp/binarytrees-allir.log
```

The `Binarytrees__check__1` dump (full text in Appendix A):

```
=== IR dump (post-drop-insertion): Binarytrees__check__1 ===
  param_conventions=[.borrowed]
  block[0]:
    [0] optional_dispatch scrutinee_param=0 payload_local=12
      nil result=1:
        [0] const_int dest=1
      struct result=3:
        [0] const_int dest=2
        [1] local_set dest=0 value=2
        [2] borrow_value dest=5 source=0
        [3] param_get dest=8 index=0
        [4] field_get
        [5] call_named name=Binarytrees__check__1 dest=6 args=[7]
        [6] call_named name=Integer___plus__2__clause_3 dest=4 args=[5,6]
        [7] param_get dest=11 index=0
        [8] field_get
        [9] call_named name=Binarytrees__check__1 dest=9 args=[10]
        [10] call_named name=Integer___plus__2__clause_3 dest=3 args=[4,9]
=== end ===
```

**`Binarytrees__check__1` has ZERO IR-level ARC operations.** No
`.share_value`, no `.retain`, no `.release` — anywhere in the function.
The two recursive calls (`call_named name=Binarytrees__check__1`)
pass field-extracted Tree locals (7 and 10) directly with no retain at
the call site, no release after, and no scope-exit release.

For comparison, the same dump shows `Binarytrees__sum_iter__3` does
have IR-level ARC ops:

```
[6] call_named name=Binarytrees__make__1 dest=9 args=[10]
[7] share_value dest=11 source=9 mode=retain     ← retain at call site
[8] call_named name=Binarytrees__check__1 dest=8 args=[11]
[9] release value=11                              ← release after call
[10] call_named name=Integer___plus__2 dest=6 args=[7,8]
[11] release value=9                              ← release of make's return
[12] tail_call name=Binarytrees__sum_iter__3 args=[2,5,6]
```

Balanced. The IR-level ARC pipeline works *when it can see the local is
ARC-managed*. It can see the result of `make`, but it cannot see the
field-extracted children inside `check`.

### Tracing the retain that fires but isn't IR-visible

`zir_builder.zig:5673`–`5727` lowers `.field_get`. For indirect-storage
recursive fields (`?*const Tree` shape), it emits a direct ZIR call to
`ArcRuntime.retainAnyOpt`:

```zig
.field_get => |fg| {
    const obj_ref = self.refForLocal(fg.object) catch return;
    var ref = zir_builder_emit_field_val(self.handle, obj_ref, fg.field.ptr, @intCast(fg.field.len));
    if (ref == error_ref) return error.EmitFailed;
    if (fg.struct_type) |sname| {
        if (self.findStructDef(sname)) |sdef| {
            if (findFieldDef(sdef, fg.field)) |fdef| {
                if (fdef.storage == .indirect) {
                    ref = try self.emitIndirectFieldDeref(ref, fdef.type_expr);
                    if (self.zigTypeIsRecursiveStruct(fdef.type_expr)) {
                        // Retain so the parent's eventual deep release and the
                        // extracted value's release each decrement exactly once…
                        const skip_retain = self.destructive_scrutinee_locals.contains(fg.object);
                        if (!skip_retain) {
                            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                            const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                            const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAnyOpt", 12);
                            const args = [_]u32{ref};
                            _ = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
                        }
                    }
                }
            }
        }
    }
    try self.setLocal(fg.dest, ref);
},
```

This retain fires at runtime (~610 million times — roughly 2 retains per
interior tree node × 305 million interior nodes after leaf-elision).
The IR has no record of this retain happening. `arc_liveness` doesn't
seed local 7 or local 10 into `arc_managed_locals`. `arc_drop_insertion`
doesn't see them in `live_before_ret` and doesn't emit a `.release`.

The retains accumulate. Trees are never freed. RSS hits 12 GB.

### Counter arithmetic

Where the 5.6 M releases come from: the ~5.6 M `.release` IR
instructions inside `sum_iter`'s tail-recursive loop, fired across
~2.8 M iterations summed across all bands. Plus a handful from `main` /
`make`.

Where the 922 M retains come from:

* `sum_iter` mode=retain `.share_value`: ~2.8 M retains.
* Direct ZIR `retainAnyOpt` calls from `Binarytrees__check__1`'s
  `.field_get` lowering: ~2 retains per interior call × ~305 M interior
  calls ≈ ~610 M.
* Direct ZIR `retainAny` from share_value mode=retain emission inside
  `check`'s call sites: would have been another ~610 M, but these
  also bypass the IR-level pipeline so they balance against each other
  via post-call IR `.release` instructions… **except no such IR
  releases exist in `check` either**, so this is a separate strand of
  the same architectural mismatch.

Bottom line: the count delta of 916 M leaked retains is the cost of
the implicit-retain-without-implicit-release shape compounded across
~610 M tree nodes.

---

## 9. Audit findings

Three parallel audits were run to find the full scope of the
architectural mismatch.

### 9.1 ZIR-side direct emission audit (`src/zir_builder.zig`)

**Finding: 7 sites where the ZIR backend emits ARC retain/release
runtime calls outside the canonical `.retain` / `.release` IR-instruction
lowering.** Three of these are the implicit-retain-on-alias class
(`.copy_value`, `.share_value`, `.field_get`); the other four are
analysis-driven side emissions.

| # | File:Line | Context | ARC runtime call | Trigger |
|---|---|---|---|---|
| 1 | `zir_builder.zig:4194` | Inside `.copy_value` IR handler | `retainAnyPersistent` | source local not stack-eligible |
| 2 | `zir_builder.zig:4299` | Inside `.share_value` mode=retain handler | `retainAny` | source local not stack-eligible |
| 3 | `zir_builder.zig:5716` | Inside `.field_get` IR handler | `retainAnyOpt` | field is indirect-storage recursive |
| 4 | `zir_builder.zig:3950, 3965` | Helper `emitDropSpecializationsForCurrentInstr` | `releaseAny` / `freeAny` | Drop specializations from analysis context |
| 5 | `zir_builder.zig:3982, 3984` | Helper `emitPerceusResetForCase` | `resetAny` | Reuse-pair reset bookkeeping |
| 6 | `zir_builder.zig:5573` | `.struct_init` handler, reuse-pair branch | `reuseAllocByType` | Struct reallocation via reuse token |
| 7 | `zir_builder.zig:5921` | `.union_init` handler, reuse-pair branch | `reuseAllocByType` | Union reallocation via reuse token |

The canonical reference for "correct paired emission" is the `.retain`
and `.release` IR-instruction handlers at approximately
`zir_builder.zig:3900`–`3927`. Every other emission site listed above
is a violation.

**Patterns:**

* **Class A (sites 1–3): implicit-retain on alias instructions.**
  `.copy_value`, `.share_value` mode=retain, and `.field_get` of
  indirect-recursive emit retain runtime calls without an
  accompanying `.retain` IR. The fix: convert each to emit an explicit
  `.retain` IR after the alias instruction at IR-build time.

* **Class B (sites 4–5): analysis-driven side emissions.**
  `emitDropSpecializationsForCurrentInstr` and `emitPerceusResetForCase`
  consult analysis metadata (e.g., `ArcOperation` records from
  `arc_optimizer`) and emit `releaseAny` / `freeAny` / `resetAny` calls
  directly. These should become first-class IR instructions
  (`.release`, `.reset_alloc` or similar) emitted by the analysis
  pass, lowered by ZIR's `.release` / `.reset_alloc` handlers.

* **Class C (sites 6–7): Perceus reuse allocation.**
  `.struct_init` and `.union_init` reuse-pair branches emit
  `reuseAllocByType` for Perceus-style allocation reuse. This is an
  optimization that touches the allocator without the IR's knowledge.
  Should become a first-class `.reuse_alloc` IR instruction.

### 9.2 Runtime-side audit (`src/runtime.zig`)

**Finding: 67 sites that retain/release at runtime; zero soundness
gaps.** Every retain/release operation inside `runtime.zig` falls into
one of three categories:

* **(a) Genuinely runtime-internal** — destructors walking children,
  COW clones retaining elements, deep-release walks. The IR-visible
  operation (e.g., `.list_set`, `.release`) covers them semantically;
  the retains/releases balance internally provided the IR pipeline
  manages the wrapper's lifecycle correctly. **66 sites.**
* **(c) Bookkeeping** — counter-only (no actual ARC effect). E.g.,
  `noteConsume`, `noteReturnElision`, `PoolStats.noteAllocation` /
  `noteDeallocation`. **3 sites.**

No category-(b) sites: nothing in the runtime is doing ARC work that
the IR ought to surface. The runtime contract is sound.

The fannkuch-redux leak that pairs with binarytrees in §12 is
*compiler-side*: the IR-level rebind release on `v = List.set(v, …)`
is missing, the input List's eventual deep release never fires, and
the COW retains on its children become permanent leaked refcounts.
The runtime helpers themselves are blameless.

### 9.3 IR semantics audit

**Finding: every IR instruction whose handling depends on implicit ARC
semantics — and which pass(es) encode the semantic.**

| IR instruction | Implicit ARC effect | Encoded in | Status |
|---|---|---|---|
| `.copy_value` | +1 retain on dest | ZIR lowering at line 4194; ownership classifier in `arc_ownership.zig` | **Violation (Class A)** |
| `.share_value` mode=retain | +1 retain on dest | ZIR lowering at line 4299 | **Violation (Class A)** |
| `.share_value` mode=consume | No retain (ownership transfer) | ZIR lowering at line 4287 (`noteConsume`) | OK (counter only) |
| `.field_get` (indirect-recursive) | +1 retain on dest | ZIR lowering at line 5716 | **Violation (Class A)** |
| `.field_get` (other) | No ARC effect | — | OK |
| `.borrow_value` | No ARC effect | — | OK |
| `.move_value` | Ownership transfer (semantics partially defined) | None — see §11 Q3 | **Incomplete** |
| `.local_get` | No effect itself; replaced by ownership classifier | `arc_ownership.zig` Phase C | OK (intermediate form) |
| `.local_set` | No ARC effect | — | OK |
| `.struct_init`, `.tuple_init`, `.list_init`, `.map_init` | +1 retain per ARC-managed element placed | ZIR lowering + ownership pass coordination | **Implicit (centralized-effect-OK, strict-violation)** |
| `.list_get`, `.list_head`, `.list_tail`, `.list_last` | +1 retain on dest (runtime helper retains) | Runtime helper; type-driven `arc_managed_locals` seeding | **Implicit (centralized-effect-OK, strict-violation)** |
| `.list_set`, `.list_push`, `.list_pop`, `.list_append` | Runtime-internal COW retains/releases; no IR-visible retain on dest beyond the new owner | Runtime helper; type-driven seeding | OK (runtime-internal balance) |
| `.map_get`, `.map_head`, etc. | +1 retain on dest | Runtime helper | **Implicit** |
| `.param_get` | Depends on param convention (`.borrowed` vs `.owned`) | `arc_param_convention.zig` | OK (ARC encoded in convention contract) |
| `.call_named`, `.call_direct`, `.call_builtin`, `.tail_call` | Caller emits `.share_value` per arg + post-call `.release`; tail call elides post-call release | `ir.zig` call lowering | OK (releases are explicit IR) |
| `.ret`, `.cond_return`, `.switch_return`, `.union_switch_return`, `.optional_dispatch` | Result ownership matches `result_convention`; scope-exit releases inserted by drop pass | `arc_drop_insertion.zig`, `arc_verifier.zig` | OK (releases are explicit IR) |
| `.retain`, `.release` | Explicit; lowered to runtime calls | ZIR `.retain` / `.release` handlers | OK (canonical primitives) |

**Three implicit-retain classes** stand out:

1. **Alias-with-retain** (`.copy_value`, `.share_value` mode=retain,
   `.field_get` indirect-recursive). Pure compiler-side aliasing; the
   retain happens at ZIR level. Easy to fix by emitting explicit
   `.retain` IR.

2. **Aggregate-construction element retains** (`.struct_init`,
   `.tuple_init`, `.list_init`, `.map_init`). Each ARC-managed element
   is implicitly retained as it's stored into the aggregate.

3. **Runtime-helper extraction retains** (`.list_get`, `.map_get`,
   `.list_head`, etc.). The runtime helper retains the extracted
   element on its way out so the caller receives a fresh owner. The
   IR pipeline tracks the lifecycle via type-driven `arc_managed_locals`
   seeding.

Class (3) is the centralized-effect / strict question (§11 Q1).

---

## 10. Proposed refactor

### 10.1 Refactor scope

**At minimum (no choice):** convert Class A and Class B/C from §9.1 to
explicit IR. This is *required* under either strict or
centralized-effect interpretation — these are bare ZIR-direct emissions
that no analysis can see today.

| Class | Sites | Refactor |
|---|---|---|
| A | 1–3 | Move retain to explicit `.retain` IR emitted at IR-build time after the alias instruction. ZIR `.copy_value` / `.share_value` / `.field_get` lowerings become pure dataflow. |
| B | 4–5 | Convert `emitDropSpecializationsForCurrentInstr` and `emitPerceusResetForCase` to emit IR-level instructions (`.release`, `.reset_alloc` or similar). The analysis pass produces these IR instructions; ZIR's existing `.release` / new `.reset_alloc` handlers lower them. |
| C | 6–7 | Define new `.reuse_alloc` IR instruction. Perceus reuse-pair `.struct_init` / `.union_init` lowerings emit `.reuse_alloc` followed by the construction. ZIR's `.reuse_alloc` handler emits `reuseAllocByType`. |

**At maximum (strict interpretation):** in addition to the above,
convert Classes 2 and 3 from §9.3 to explicit `.retain` IR. This
requires runtime contract changes for `List.get`, `Map.get`, etc. — the
runtime helpers return borrowed references, and the IR adds explicit
`.retain` after each extraction.

The agent must determine which scope is appropriate. See §11 Q1.

### 10.2 Phased implementation

Whichever scope is chosen, the implementation is phased TDD-first.

1. **Add an invariant test in `arc_verifier.zig` (or a new lint
   test).** Walk `zir_builder.zig`'s AST and assert no retain/release
   runtime call (`retainAny`, `retainAnyPersistent`, `retainAnyOpt`,
   `retainChildrenAny`, `releaseAny`, `releaseArcAny`,
   `releaseChildrenAny`, `freeAny`, `resetAny`, `reuseAllocByType`)
   appears outside the canonical IR-instruction handlers (`.retain`,
   `.release`, `.reset_alloc`, `.reuse_alloc`). This test fails today;
   it pins the invariant going forward.

2. **Per-class fixes (separate commits).** For each violation class,
   write a failing runtime-counter-balance test on a minimal repro
   (similar to the binarytrees ARC counter check), implement the fix,
   verify retains == releases within noise.

   * Class A: alias-with-retain → explicit `.retain` IR. (Smallest
     change; fixes binarytrees.)
   * Class B: analysis-driven side emissions → first-class IR.
   * Class C: Perceus reuse → first-class `.reuse_alloc` IR.
   * (If strict scope) Aggregate construction → explicit per-element
     `.retain` IR before construction.
   * (If strict scope) Runtime extraction → runtime helpers return
     borrowed; IR adds explicit `.retain` after extraction.

3. **Audit `arc_liveness.zig`'s `arc_managed_locals` seed walk.**
   Independent of the refactor scope, ensure every IR op that produces
   a fresh ARC owner correctly seeds its dest. With Class A
   converted, the seed walk becomes the union of:
   `.retain` source/dest, `.release` value, `.share_value` source/dest,
   plus type-driven seeds for runtime-helper extraction ops if
   centralized-effect is chosen.

4. **Run all four CLBG benchmarks; verify `retains_total ≈
   releases_total` under `ZAP_ARC_STATS=1` for each.**

5. **Run `zig build test` and `zap test`.** The refactor will
   likely surface latent bugs in `arc_param_convention.zig`,
   `arc_ownership.zig`, etc. that were masked by implicit-retain
   coordination. Each is a real bug — fix per the project rule (no
   fallbacks, root-cause it).

### 10.3 What success looks like

Numerical:

| Benchmark | Current retains_total | Current releases_total | Current delta | After: delta |
|---|---|---|---|---|
| binary-trees N=21 | 922,047,838 | 5,592,388 | **+916 M** | ≈ 0 |
| fannkuch-redux N=11 | 5,122,875,140 | 5,102,916,743 | **+20 M** | ≈ 0 |
| spectral-norm N=2500 | 500,320,237 | 500,320,239 | ≈ 0 | ≈ 0 |
| k-nucleotide | 17,541,984 | 17,542,182 | ≈ 0 | ≈ 0 |

| Benchmark | Current Zap RSS | Target |
|---|---|---|
| nbody | ~1.4 MB | unchanged |
| mandelbrot | ~1.4 MB | unchanged |
| binary-trees N=21 | ~12 GB | ~150–250 MB |
| fannkuch-redux N=11 | ~2.2 GB | < 100 MB |
| spectral-norm N=2500 | ~2.2 GB | < 50 MB |
| k-nucleotide | ~4.2 GB | < 200 MB |

(spectral-norm and k-nucleotide RSS are not directly fixed by the
ARC refactor — they're allocator-churn issues from a separate root
cause — but the ARC counter delta should remain at 0 after the
refactor, and the lifetime management should still be precisely
tracked.)

Architectural:

* The `arc_verifier` invariant test passes: the only ZIR sites
  emitting retain/release runtime calls are the `.retain` /
  `.release` / `.reset_alloc` / `.reuse_alloc` IR-instruction
  handlers.
* `arc_managed_locals` is seeded only from explicit `.retain` /
  `.release` / `.share_value` sources (and optionally type-driven
  seeds for runtime extraction, if centralized-effect is chosen).
* The IR-level analysis passes can be reasoned about as a complete
  description of every retain/release the program will execute.

---

## 11. Design questions

The agent should investigate, and produce a recommended approach with
concrete implementation guidance for, each of these.

### Q1. Strict or centralized-effect?

§7 frames the two interpretations. Which should Zap adopt?

Inputs to weigh:

* **Strict** is more invariant-respecting and future-proofs against the
  next "implicit ZIR retain that nobody remembered to teach the
  pipeline about" bug. But it requires refactoring `runtime.zig`'s
  `List`, `Map`, `Vector`, `Tuple` extraction methods to return
  borrowed references rather than retained owners. That's ~2000 lines
  of runtime + ~1000 lines of compiler.
* **Centralized-effect** is smaller (~500 lines compiler, no runtime
  contract change) but doesn't fully eliminate the implicit-retain
  pattern — it just centralizes its documentation. New analysis
  passes have one place to consult, but the implicit semantics still
  exist.

Specific sub-question: for each implicit-ARC IR op listed in §9.3, is
the strict refactor *worth the cost*? Some ops (e.g., `.struct_init`
element retains) are very natural to express explicitly; others (e.g.,
`.list_set` rc==1 vs rc>1 dispatch) live deep in runtime helpers and
the IR boundary is messy.

The agent should produce a per-op recommendation table.

### Q2. `.retain` / `.release` flavor design

Today there's one `.retain` IR variant (and one `.release`). The ZIR
lowering of `.retain` has to choose between three runtime helpers
based on the local's type and context:

* `retainAny` — transient borrow (call args).
* `retainAnyPersistent` — long-lived owner (struct field, container
  slot).
* `retainAnyOpt` — through an optional pointer (`?*const T`).

Two design options:

* **(a) Flavored variants.** `.retain { kind: .transient | .persistent
  | .optional, value: LocalId }`. ZIR dispatches per kind. IR is
  fully self-describing.
* **(b) Single variant + type dispatch.** `.retain { value: LocalId }`.
  ZIR inspects the local's type and picks the helper. Implicit type
  dispatch.

Which is better? My instinct is (a) for invariant strength. But (b) is
simpler and may be sufficient if the type-driven dispatch is itself
well-defined.

### Q3. `.move_value` semantics

`.move_value` exists in the IR but its ARC semantics are partially
specified. Today the lowering treats it like `.local_get` for ARC
purposes. What's the right semantics?

Options:

* `.move_value` is pure dataflow with an *invalidation* effect — the
  source is no longer live after the move. No retain at the move site;
  no release of the source at scope exit. Suitable for consume-mode
  argument passing.
* `.move_value` is identical to `.local_get` plus the invalidation —
  effectively a `.borrow_value` whose source is consumed.

The verifier needs to enforce that a moved-from local is not used
after the move.

### Q4. Class C (Perceus reuse) instruction design

Sites 6–7 emit `reuseAllocByType` directly. The natural lowering is:

```
.reuse_alloc { dest, type, source_token }   ; new IR instruction
.struct_init { dest, fields, … }            ; existing
```

Where `source_token` is the LocalId of the about-to-be-consumed
allocation that the new struct will reuse the storage of.

Is this the right shape? Or should `.struct_init` gain an optional
`reuse_token` field, keeping reuse coupled to construction? The
trade-off is composability vs explicitness.

### Q5. Class B (drop specializations) instruction design

`emitDropSpecializationsForCurrentInstr` consults `ArcOperation`
records produced by `arc_optimizer` and emits `releaseAny` / `freeAny`
calls. Should these become explicit `.release` IR instructions
(possibly with a `.kind: { .release, .free, .reset }` enum)? Or should
they remain analysis metadata that the ZIR backend reads, but with the
analysis pass renamed to "drop insertion" and unified with
`arc_drop_insertion.zig`?

The latter is closer to what the existing `arc_drop_insertion.zig`
does. The former is more invariant-respecting.

### Q6. Aggregate-construction element retains

`.struct_init`, `.tuple_init`, `.list_init`, `.map_init` each
implicitly retain every ARC-managed element placed into the
aggregate. Under strict, this becomes:

```
.retain { value: e1 }
.retain { value: e2 }
.retain { value: e3 }
.struct_init { dest, fields: [e1, e2, e3] }
```

… for every element. That's verbose but explicit. Under
centralized-effect, the implicit retain stays and the analysis
passes consult `arcEffectOf(.struct_init)` to know about the per-
element retains.

Are there special cases (e.g., literal values, stack-eligible
elements) that should *not* retain at construction? The agent should
audit the existing aggregate-construction lowerings to make sure the
explicit-retain refactor doesn't double-count.

### Q7. Verifier strengthening

What new invariants should `arc_verifier.zig` enforce after the
refactor?

Candidates:

* For every `.retain` IR, there must be a balancing `.release`
  reachable on every path.
* For every `.release` IR, there must be a preceding `.retain` (or a
  fresh allocation that initialized rc=1) on every path.
* The ZIR-side audit: no retain/release runtime call appears outside
  the canonical IR-instruction handlers (the test from §10.2 step 1).
* `arc_managed_locals` is exactly the set of locals that are the source
  or dest of at least one ARC-affecting IR instruction.

Some of these are static; some require dataflow analysis. Which are
worth the engineering cost?

### Q8. Interaction with TCO and parameter convention

The `arc_param_convention.zig` pass promotes parameters from
`.borrowed` to `.owned` for self-recursive callees with specific
properties (§6). Under the refactor, does the promotion logic need to
change?

The hypothesis is no — the promotion operates on parameter conventions,
which are independent of how retains/releases are emitted. But the
`isReleaseSuppressed` filter and the return-source elision logic
interact subtly with explicit `.retain` IR, and the agent should
verify.

### Q9. Backward compatibility with existing tests

There are ~819 tests in `zap test`. Many encode current-IR shape
assumptions (e.g., "this function generates exactly one `.release`
IR"). The refactor will change the IR shape of nearly every function.

What's the right strategy?

* Update each affected test as the refactor progresses. (Lots of
  churn.)
* Add a migration helper that translates old-IR-shape assertions to
  new-IR-shape. (Test infra change.)
* Replace shape-based tests with behavior-based tests (assert
  retains == releases at runtime, leave IR shape unspecified).

The agent should recommend.

### Q10. Performance impact

Each implicit retain becomes an explicit `.retain` IR followed by a
ZIR call. Under LLVM, these should fuse with surrounding code. But:

* Will explicit `.retain` after `.field_get` prevent any optimization
  the implicit retain enabled?
* Does emitting explicit `.retain` IR create more work for
  `arc_optimizer.zig`? (Probably yes — more retain/release pairs to
  examine.)
* Are there benchmarks (especially nbody / mandelbrot which currently
  show no leak) that could regress in wall-clock?

The agent should sketch a benchmark plan.

---

## 12. Why it matters: the four CLBG benchmarks

Computer Language Benchmarks Game's Zap entries currently exhibit
specific failure modes. The architectural refactor unblocks at least
two of these and improves the diagnosis for all four.

### Current Zap performance vs reference languages

(Apple M4, 32 GB; reduced sizes for harness tractability — see
`~/projects/lang-benches/scripts/run-all.sh`.)

| Benchmark | Zap time | vs winner | Zap RSS | Winner RSS |
|---|---|---|---|---|
| nbody (N=5e6) | **102 ms** | **1.50× faster than C** | 1.36 MB | 1.31 MB (C) |
| mandelbrot (N=8000) | 2.06 s | 1.11× slower than C | 1.43 MB | 1.36 MB (C) |
| binary-trees (N=21) | 5.88 s | 5.44× slower than OCaml | **~12 GB** | 226 MB (OCaml) |
| fannkuch-redux (N=11) | 16.48 s | 11.5× slower than Rust | **~2.2 GB** | 1.49 MB (Rust) |
| spectral-norm (N=2500) | 1.84 s | 11.8× slower than Rust | **~2.2 GB** | 1.59 MB (Rust) |
| k-nucleotide | 1.59 s | 27.9× slower than C | **~4.2 GB** | 27.9 MB (C) |

Stateless benchmarks (nbody, mandelbrot) are fine. Every benchmark
that allocates inside its hot loop blows up by 1500×–9000× on RSS.

### Per-benchmark diagnosis

* **binary-trees** — leaks ~610 M tree nodes (~916 M leaked retains)
  due to the `.field_get` indirect-recursive Class A violation. **Fixed
  by Class A refactor.**

* **fannkuch-redux** — leaks ~20 M retains, exactly equal to the
  number of `List.set` COW clone events. The IR-level rebind release
  (`v = List.set(v, …)`) is missing; old buffers leak with their
  retained children. **Likely fixed by Class A or by a separate
  `arc_managed_locals` seeding fix for `.list_set` dest assignment.**

* **spectral-norm** — retains/releases balanced at runtime, but 100,000
  of 105,000 `List.set` calls hit the rc>1 COW path. The compiler's
  uniqueness analysis only proves 4.8% of mutations unique. The
  resulting clone churn (100k × 20 KB = 2 GB) is held by libc
  malloc as accumulated arena pages. **Not directly fixed by ARC
  refactor**, but the refactor makes the IR-level lifecycle
  precisely trackable, which is a prerequisite for fixing the
  uniqueness analysis.

* **k-nucleotide** — retains/releases balanced. RSS comes from Map
  allocator churn. Map mutations are 100% uniqueness-elided (no
  runtime ARC dispatch), so the leak is allocator-side, not
  ARC-side. **Not directly fixed by ARC refactor.**

So the binary-trees and fannkuch-redux failures are direct
consequences of the architectural mismatch this brief addresses; the
spectral-norm and k-nucleotide failures are separate problems that
become more tractable once the IR is the source of truth for ARC
lifecycles.

---

## 13. Investigation hooks — file & line index

All paths relative to `~/projects/zap/`.

### IR data structures

| concept | file & line |
|---|---|
| `Instruction` tagged union | `src/ir.zig:168` |
| `FieldStorage` enum | `src/ir.zig:49` |
| `StructFieldDef` | `src/ir.zig:65` |
| `Function.loopify` | `src/ir.zig:135` |
| `isArcManagedTypeId` | `src/ir.zig:1175` |
| `structTypeUsesRecursiveBoxing` | `src/ir.zig:1211` |
| `typeReferencesTargetStruct` | `src/ir.zig:1221` |
| `containsTailCall` | `src/ir.zig:2273` |
| `rewriteTailCalls` | `src/ir.zig:8735+` (test at `:8735`) |

### Runtime ARC primitives

| concept | file & line |
|---|---|
| `ArcHeader` | `src/runtime.zig:~257` |
| `arc_retains_total` | `src/runtime.zig:356` |
| `arc_releases_total` | `src/runtime.zig:~365` |
| `list_mut_calls_total` | `src/runtime.zig:377` |
| `PoolStats` | `src/runtime.zig:389` |
| `dumpArcStats` | `src/runtime.zig:434` |
| `dumpArcStatsToStderr` | `src/runtime.zig:475` |
| `ensureArcStatsAtexit` | `src/runtime.zig:490` |
| `ArcRuntime.allocAny` | `src/runtime.zig:1296` |
| `ArcRuntime.releaseAny` | `src/runtime.zig:1387` |
| `ArcRuntime.prepareReleaseAny` | `src/runtime.zig:1416` |
| `ArcRuntime.destroyPreparedAny` | `src/runtime.zig:1428` |
| `ArcRuntime.releaseArcAny` | `src/runtime.zig:1446` |
| `ArcRuntime.releaseChildrenAny` | `src/runtime.zig:1466` |
| `ArcRuntime.releaseFieldChildAny` | `src/runtime.zig:1477` |
| `ArcRuntime.retainChildrenAny` | `src/runtime.zig:1498` |
| `ArcRuntime.retainAny` | `src/runtime.zig:1538` |
| `ArcRuntime.retainAnyPersistent` | `src/runtime.zig:1564` |
| `ArcRuntime.retainAnyOpt` | `src/runtime.zig:1592` |
| `List(T).set` (rc==1 fast / rc>1 COW) | `src/runtime.zig:2016` |
| `List(T).push` | `src/runtime.zig:2054` |
| `cloneBufferRetainingChildren` | `src/runtime.zig:1851` |
| `cloneBufferMovingChildren` | `src/runtime.zig:1870` |
| `bufferFreeDeep` (List) | `src/runtime.zig:1805` |
| `releaseElement` / `retainElement` (List) | `src/runtime.zig:2745, 2749` |

### IR ARC pipeline

| concept | file & line |
|---|---|
| `arc_managed_locals` field | `src/arc_liveness.zig:210` |
| `arc_managed_locals` seed walk | `src/arc_liveness.zig:499` |
| `arc_param_convention` doc + algorithm | `src/arc_param_convention.zig:1–110` |
| `arc_drop_insertion` doc | `src/arc_drop_insertion.zig:1–125` |
| `insertScopeExitDrops` | `src/arc_drop_insertion.zig:~150` |
| `arc_ownership` Phase C overview | `src/arc_ownership.zig:1–150` |

### ZIR backend (the violations and the canonical handlers)

| concept | file & line |
|---|---|
| `.copy_value` lowering (Class A violation #1) | `src/zir_builder.zig:4178–4207` |
| `.share_value` mode=consume (`noteConsume`) | `src/zir_builder.zig:4283–4291` |
| `.share_value` mode=retain (Class A violation #2) | `src/zir_builder.zig:4292–4310` |
| `.field_get` indirect-recursive (Class A violation #3) | `src/zir_builder.zig:5673–5727` |
| `.struct_init` reuse-pair (Class C violation #6) | `src/zir_builder.zig:5573` |
| `.union_init` reuse-pair (Class C violation #7) | `src/zir_builder.zig:5921` |
| `emitDropSpecializationsForCurrentInstr` (Class B violation #4) | `src/zir_builder.zig:3950, 3965` |
| `emitPerceusResetForCase` (Class B violation #5) | `src/zir_builder.zig:3982, 3984` |
| `.retain` / `.release` IR-instruction handlers (canonical) | `src/zir_builder.zig:3900–3927` |
| `emitIndirectFieldDeref` | `src/zir_builder.zig:7142+` |
| `heapPromoteForIndirectField` | `src/zir_builder.zig:7105+` |
| `loop_skip_retain_locals` doc | `src/zir_builder.zig:506` |
| `arc_managed_locals` mirror | `src/zir_builder.zig:537, 544` |

### Compiler driver

| concept | file & line |
|---|---|
| `ZAP_DUMP_IR_FN` env var handling | `src/compiler.zig:2313` |
| `dumpStream` | `src/compiler.zig:2335` |

### Predecessor brief

`docs/arc-indirect-storage-research-brief.md` — the brief that
motivated the recursive-struct / boxed-recursive ABI work whose
implicit-retain is the binarytrees Class A violation.

### Existing tests

Tests that exercise the recursive-struct path and should pass after
the refactor:

* `test/struct_test.zap` — `Recursive struct field auto-deref` describe
  block.
* `test/recursion_test.zap` — `byref tail-call loopification` describe
  block.
* `test/arc_*_test.zap` — ARC-specific tests.
* The benchmarks themselves (`~/projects/lang-benches/binarytrees/`,
  `fannkuch-redux/`, etc.) verify byte-identical against
  `expected_n*.txt` at small N.

### How to verify the fix worked

```sh
# Architectural: invariant test
cd ~/projects/zap
zig build test    # the new arc_verifier invariant test must pass

# Behavioral: ARC counter balance
cd ~/projects/lang-benches/binarytrees
rm -rf .zap-cache zap-out
~/projects/zap/zig-out/bin/zap build
ZAP_ARC_STATS=1 ./zap-out/bin/binarytrees 21 > /dev/null 2>/tmp/bt-arc.txt
grep retains_total /tmp/bt-arc.txt
# Expect: retains_total ≈ releases_total (delta < 1000)

# Functional: byte-identical output
diff <(./binarytrees-c 21) <(./zap-out/bin/binarytrees 21)
# Expect: empty diff

# Resource: bounded RSS
/usr/bin/time -l ./zap-out/bin/binarytrees 21 > /dev/null
# Expect: maximum resident set size < 500 MB

# Repeat for fannkuch-redux, spectral-norm, k-nucleotide
```

The fix is correct iff:

1. The `arc_verifier` invariant test passes (no ZIR-direct ARC
   emissions outside canonical handlers).
2. ARC counter delta < 1000 for binarytrees and fannkuch-redux.
3. `diff` shows no difference vs the C reference at every benchmark's
   reference N.
4. Wall-clock time is finite and bounded; RSS is bounded by the
   working-set sizes targeted in §10.3.
5. The existing 819 `zap test` tests still pass.

---

## 14. Design constraints

Hard rules. Violations are not acceptable.

* **No workarounds or hacks.** Every solution must be the correct,
  production-grade, long-term fix. If the proper fix requires changes
  to the Zig fork, that's the fix. If it requires re-architecting an
  IR pass across multiple files, that's the fix. Cost and time are
  not concerns — correctness and quality are.

* **Features in Zap, not in the compiler.** The compiler must remain a
  general-purpose tool that doesn't know about specific Zap structs.
  ARC primitives in `src/runtime.zig` are an exception because they
  require Zig-only constructs (atomics, raw allocation), but
  *behavior* should live in Zap whenever possible.

* **Tests must stay green.** ~819 tests in `zap test`. Many tests in
  `zig build test`. All examples in `~/projects/zap/examples/` must
  continue to compile and produce expected output.

* **macOS thread-stack ceiling is 8 MB.** Solutions that work only on
  Linux are not acceptable. The recursive-release walk in
  `releaseChildrenAny` already needs to be stack-bounded for deeply
  nested recursive structs (the binarytrees long-lived tree alone is
  21 deep).

* **Backwards-compatibility hacks are forbidden.** When refactoring,
  fully commit to the new approach. Remove old code entirely. If the
  new approach fails, that's a bug to surface, not hide.

* **All public Zap functions need `@fndoc`.** If you add Zap-side
  functions in `lib/*.zap`, document them.

* **Don't hardcode struct names in the compiler.** If you find
  yourself writing a Zap struct name as a string literal in Zig
  source, find the Zap-level solution.

* **Cost and time are not concerns.** Correctness is. If the proper
  fix touches twenty files across both repos, that's still better
  than a one-file workaround.

* **Always TDD.** Failing test first, implement minimum code to pass,
  run `zig build test` locally, push only when green.

* **Never run `zig build zir-test`.** It's slow; the user runs it
  manually.

---

## 15. Research questions

The agent must produce, for each of these, a concrete recommendation
with file paths, line numbers, and proposed code shape (Zig code, not
Zap code, since this is compiler internals).

1. **Q1 — Strict or centralized-effect?** Recommendation with
   per-implicit-ARC-op cost/benefit table from §9.3. (See §11 Q1.)

2. **Q2 — `.retain` / `.release` IR design.** Flavored or
   single-variant? Sketch the IR struct definition. (§11 Q2.)

3. **Q3 — `.move_value` semantics.** Define the invalidation contract
   and what the verifier enforces. (§11 Q3.)

4. **Q4 — Class C (Perceus reuse) IR design.** Standalone
   `.reuse_alloc` or composite `.struct_init` with `reuse_token`?
   (§11 Q4.)

5. **Q5 — Class B (drop specializations) IR design.** First-class
   instructions or unify with `arc_drop_insertion.zig`? (§11 Q5.)

6. **Q6 — Aggregate-construction element retains.** Should every
   element retain become explicit `.retain` IR before construction,
   or stay implicit? (§11 Q6.)

7. **Q7 — Verifier strengthening.** Which new invariants are worth
   the engineering cost? (§11 Q7.)

8. **Q8 — Interaction with TCO / param convention.** Does
   `arc_param_convention.zig` need to change? (§11 Q8.)

9. **Q9 — Test migration strategy.** Update each test, migration
   helper, or replace with behavior-based tests? (§11 Q9.)

10. **Q10 — Performance impact.** Sketch a benchmark plan. (§11 Q10.)

11. **Q11 — Phase ordering.** Among Class A, B, C (and optionally
    aggregate / extraction strict-only refactors), which order is
    least risky? Each phase should leave the test suite green. Are
    there inter-phase dependencies that force a particular order?

12. **Q12 — `arc_managed_locals` seeding correctness.** Independent
    of the refactor scope: audit the current seed walk in
    `arc_liveness.zig` and identify any IR ops whose dest produces a
    fresh ARC owner but is *not* seeded. The binarytrees bug is one
    such case (`.field_get` indirect-recursive); are there others?
    (E.g., `.list_get`, `.map_get` — are these correctly seeded
    today via type-driven analysis, or is this another latent
    binarytrees-class bug?)

13. **Q13 — Should the refactor extend to the Zig fork?** Current
    expectation is no — the fork's C-ABI is for ZIR primitives and
    doesn't know about ARC. But: if ARC primitives gain new IR
    instructions (`.reuse_alloc`, etc.), the fork might need new
    ZIR-builder helpers. Confirm or refute.

14. **Q14 — Documentation.** Where in the codebase should the
    invariant ("IR is the only source of truth for ARC") be
    written down so the next person doesn't accidentally re-introduce
    a violation? Module-level doc comment in `src/zir_builder.zig`?
    A new `docs/arc-architecture.md`? Section in `CLAUDE.md`?

---

## 16. Appendix A — IR dumps from the investigation

Generated with `ZAP_DUMP_IR_FN=Binarytrees__ ~/projects/zap/zig-out/bin/zap build` from
`~/projects/lang-benches/binarytrees/`.

### `Binarytrees__make__1`

```
=== IR dump (post-drop-insertion): Binarytrees__make__1 ===
  param_conventions=[.trivial]
  block[0]:
    [0] release value=0
    [1] release value=3
    [2] switch_return
      case[0]:
        [0] const_nil
        [1] const_nil
        [2] struct_init
        [3] retain value=0
      default:
        [0] param_get dest=6 index=0
        [1] const_int dest=7
        [2] call_named name=Integer___minus__2__clause_3 dest=5 args=[6,7]
        [3] call_named name=Binarytrees__make__1 dest=4 args=[5]
        [4] param_get dest=10 index=0
        [5] const_int dest=11
        [6] call_named name=Integer___minus__2__clause_3 dest=9 args=[10,11]
        [7] call_named name=Binarytrees__make__1 dest=8 args=[9]
        [8] struct_init
=== end ===
```

Has releases (`[0]`, `[1]`) and a retain (`case[0][3]`).

### `Binarytrees__check__1` (the bug)

```
=== IR dump (post-drop-insertion): Binarytrees__check__1 ===
  param_conventions=[.borrowed]
  block[0]:
    [0] optional_dispatch scrutinee_param=0 payload_local=12
      nil result=1:
        [0] const_int dest=1
      struct result=3:
        [0] const_int dest=2
        [1] local_set dest=0 value=2
        [2] borrow_value dest=5 source=0
        [3] param_get dest=8 index=0
        [4] field_get
        [5] call_named name=Binarytrees__check__1 dest=6 args=[7]
        [6] call_named name=Integer___plus__2__clause_3 dest=4 args=[5,6]
        [7] param_get dest=11 index=0
        [8] field_get
        [9] call_named name=Binarytrees__check__1 dest=9 args=[10]
        [10] call_named name=Integer___plus__2__clause_3 dest=3 args=[4,9]
=== end ===
```

**Zero `.share_value`, zero `.retain`, zero `.release`.** The two
recursive `call_named` instructions pass field-extracted Tree locals
(7 and 10) directly with no retain at the call site, no release after,
no scope-exit release. Yet the runtime emits ~610 M retains via the
implicit `retainAnyOpt` direct ZIR call from the `.field_get`
lowering.

### `Binarytrees__sum_iter__3`

```
=== IR dump (post-drop-insertion): Binarytrees__sum_iter__3 ===
  param_conventions=[.trivial, .trivial, .trivial]
  block[0]:
    [0] switch_return
      case[0]:
        [0] param_get dest=0 index=2
      default:
        [0] param_get dest=3 index=0
        [1] const_int dest=4
        [2] call_named name=Integer___minus__2__clause_3 dest=2 args=[3,4]
        [3] param_get dest=5 index=1
        [4] param_get dest=7 index=2
        [5] param_get dest=10 index=1
        [6] call_named name=Binarytrees__make__1 dest=9 args=[10]
        [7] share_value dest=11 source=9 mode=retain
        [8] call_named name=Binarytrees__check__1 dest=8 args=[11]
        [9] release value=11
        [10] call_named name=Integer___plus__2__clause_3 dest=6 args=[7,8]
        [11] release value=9
        [12] tail_call name=Binarytrees__sum_iter__3 args=[2,5,6]
=== end ===
```

**Has IR-level ARC ops.** `share_value` mode=retain at `[7]`, post-call
`.release value=11` at `[9]`, `.release value=9` at `[11]` (releases
the result of `make` after `check` consumes its borrowed view). This
is the IR shape `check` *should* have but doesn't.

### `Binarytrees__main__1`

```
=== IR dump (post-drop-insertion): Binarytrees__main__1 ===
  param_conventions=[.borrowed]
  block[0]:
    [0] call_named name=Binarytrees__parse_max_depth__0 dest=8 args=[]
    [1] local_set dest=0 value=8
    [2] borrow_value dest=10 source=0
    [3] call_named name=Binarytrees__min_depth_floor__1 dest=9 args=[10]
    [4] local_set dest=1 value=9
    [5] const_int dest=11
    [6] local_set dest=2 value=11
    [7] borrow_value dest=13 source=1
    [8] const_int dest=14
    [9] call_named name=Integer___plus__2__clause_3 dest=12 args=[13,14]
    [10] local_set dest=3 value=12
    [11] borrow_value dest=17 source=3
    [12] call_named name=Binarytrees__make__1 dest=16 args=[17]
    [13] share_value dest=18 source=16 mode=retain
    [14] call_named name=Binarytrees__check__1 dest=15 args=[18]
    [15] release value=18
    [16] local_set dest=4 value=15
    …
    [49] release value=5
    [50] release value=16
    [51] ret value=37
=== end ===
```

Main has releases at `[15]`, `[49]`, `[50]` (the stretch tree, the
long-lived tree, and a borrow/local). Balanced for those three trees
specifically; the leak is inside `check` and `sum_iter`'s inner
calls, not in main.

---

## 17. Appendix B — runtime ARC counter snapshots

From `ZAP_ARC_STATS=1` runs at the same N as the bench harness
(`~/projects/lang-benches/scripts/run-all.sh`).

### binarytrees N=21

```
[zap-arc-stats] retains_total=922047838 releases_total=5592388 consumes_total=0 return_elisions_total=0
[zap-arc-stats] dense_map_mut_calls_total=0 dense_map_rc1_fast_path_total=0 dense_map_unchecked_total=0
[zap-arc-stats] list_mut_calls_total=0 list_rc1_fast_path_total=0 list_unchecked_total=0
[zap-arc-stats] pool=Arc(Tree) live=610970300 high_water=610970303
```

Delta: **+916,455,450 leaked retains.** Effectively no Tree freed
during the run.

### fannkuch-redux N=11

```
[zap-arc-stats] retains_total=5122875140 releases_total=5102916743 consumes_total=0 return_elisions_total=0
[zap-arc-stats] dense_map_mut_calls_total=0 dense_map_rc1_fast_path_total=0 dense_map_unchecked_total=0
[zap-arc-stats] list_mut_calls_total=2153776615 list_rc1_fast_path_total=487714710 list_unchecked_total=1646103505
```

Delta: **+19,958,397 leaked retains.** Matches `list_mut_calls_total -
list_rc1_fast_path_total - list_unchecked_total ≈ 19.96 M COW
clones`. Each leaked retain is a buffer (or its child) that the
caller's IR-level rebind release didn't reach.

### spectral-norm N=2500

```
[zap-arc-stats] retains_total=500320237 releases_total=500320239 consumes_total=0 return_elisions_total=0
[zap-arc-stats] dense_map_mut_calls_total=0 dense_map_rc1_fast_path_total=0 dense_map_unchecked_total=0
[zap-arc-stats] list_mut_calls_total=105000 list_rc1_fast_path_total=2500 list_unchecked_total=2500
```

Delta: **−2** (within atexit-ordering noise; balanced). But ~100,000
of 105,000 `List.set` calls hit the COW path. The compiler's
uniqueness analysis only proves 4.8% of mutations unique. RSS comes
from libc malloc fragmentation across the 2 GB of cycled buffers, not
from leaked refcounts.

### k-nucleotide

```
[zap-arc-stats] retains_total=17541984 releases_total=17542182 consumes_total=0 return_elisions_total=0
[zap-arc-stats] dense_map_mut_calls_total=8749968 dense_map_rc1_fast_path_total=0 dense_map_unchecked_total=8749968
[zap-arc-stats] list_mut_calls_total=7 list_rc1_fast_path_total=7 list_unchecked_total=0
```

Delta: **−198** (atexit-ordering noise). All 8.75 M Map mutations are
uniqueness-elided (no runtime ARC dispatch). RSS is Map allocator
churn, not ARC.

### Summary

| Benchmark | Retains | Releases | Delta | Diagnosis |
|---|---|---|---|---|
| binary-trees N=21 | 922,047,838 | 5,592,388 | +916 M | Class A `.field_get` leak |
| fannkuch-redux N=11 | 5,122,875,140 | 5,102,916,743 | +20 M | List rebind release missing |
| spectral-norm N=2500 | 500,320,237 | 500,320,239 | ≈ 0 | Allocator churn from COW |
| k-nucleotide | 17,541,984 | 17,542,182 | ≈ 0 | Map allocator churn |

binarytrees and fannkuch are the two ARC-counter-imbalanced
benchmarks. They're the direct beneficiaries of the architectural
refactor.
