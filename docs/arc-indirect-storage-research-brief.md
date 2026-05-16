# Zap: ARC release on indirect-storage struct fields — research brief

> **Audience.** A deep-research AI agent with zero prior context on Zap, the
> Zap fork of the Zig compiler, ARC, or how the two repos fit together.
> Read top-to-bottom — the technical detail in §6 only makes sense after
> §1–§5. Goal: produce a recommended implementation strategy, with concrete
> file paths and line numbers where the change should land, for one
> specific runtime gap that's currently the only thing keeping Zap from
> finishing the binary-trees benchmark.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [Memory model — arena + ARC](#5-memory-model--arena--arc)
6. [Recursive structs — what shipped](#6-recursive-structs--what-shipped)
7. [The open problem: ARC release on `FieldStorage.indirect` drop](#7-the-open-problem-arc-release-on-fieldstorageindirect-drop)
8. [Why it matters: binary-trees](#8-why-it-matters-binary-trees)
9. [Investigation hooks](#9-investigation-hooks)
10. [Design constraints](#10-design-constraints)
11. [Research questions](#11-research-questions)
12. [Appendix A — file & line index](#12-appendix-a--file--line-index)
13. [Appendix B — current bench numbers](#13-appendix-b--current-bench-numbers)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles to
native binaries. The surface ergonomics borrow heavily from Elixir
(immutable values, pattern matching, multi-clause function dispatch with
guards, pipe operator, macros over an AST), but the runtime is native:
there is no VM, no interpreter, and no tracing GC. Zap source compiles
through Zig's intermediate representation (ZIR) into LLVM, just like
ordinary Zig code does, and the produced binary is statically-linked
machine code.

**Project tagline.** "Elixir's developer experience without the runtime
overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is a general-purpose tool that doesn't know
  about specific Zap structs (`IO`, `String`, `Math`, the ARC runtime).
  Standard library functions, macros, the test framework, and DSLs all
  live in `lib/*.zap`.
* **The compiler only handles language primitives**: parsing, the type
  system, ZIR emission, and a tiny set of runtime primitives that
  cannot be expressed in Zap (stdout, raw allocation, OS argv, the
  ARC machinery).
* **No workarounds or hacks.** Every solution must be the correct,
  production-grade, long-term fix. If the proper fix requires changes
  to the Zig fork, that's the fix. If it requires re-architecting an
  IR pass, that's the fix.

**Surface syntax** — minimal example:

```zap
pub struct Greeter {
  pub fn hello(name :: String) -> String {
    "Hello, " <> name <> "!"
  }

  pub fn main(_args :: [String]) -> u8 {
    Greeter.hello("World") |> IO.puts()
    0
  }
}
```

**Recursive struct + multi-clause dispatch** — this is the shape that
matters for the rest of the brief:

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

`Tree` is self-referential: a `Tree` value contains optional `Tree`
children. The compiler handles the layout indirection internally
(see §6); the source-level type stays exactly what the user wrote.
Multi-clause dispatch on `nil` vs `Tree` unifies the parameter to
`?Tree` and routes via an internal `optional_dispatch` IR node.

---

## 2. Project layout & toolchain

Two coordinated repositories, both on the local filesystem of the
machine you're working on.

```
~/projects/zap/        — the Zap compiler & language itself
~/projects/zig/        — the Zap fork of Zig 0.16.0
                          (branch: zap-zir-library-0.16)
~/projects/lang-benches/ — the cross-language benchmark harness
                            (uses hyperfine; reports vs C/Rust/
                             Zig/Go/OCaml/Elixir)
```

### `~/projects/zap` directory layout (only the parts that matter):

```
src/                                  — compiler source
  parse.zig                           — lexer + parser → AST
  ast.zig, ast_data.zig               — AST data types
  collector.zig                       — scope graph / decl collection
  hir.zig                             — High-level IR (closer to source)
  types.zig                           — TypeStore + TypeChecker
  ir.zig                              — Mid-level IR (lowering target)
  zir_builder.zig                     — IR → ZIR lowering (calls into the fork)
  zir_backend.zig                     — drives the fork's compile pipeline
  runtime.zig                         — Zap runtime: ARC, atom table, IO
  analysis_pipeline.zig               — orchestrates escape + ARC analyses
  escape_lattice.zig                  — escape/ownership lattices
  generalized_escape.zig              — escape analysis worklist
  interprocedural.zig                 — call-graph + alias analysis
  arc_optimizer.zig                   — eliminate redundant retain/release
  region_solver.zig                   — region inference (use-def)
  ctfe.zig                            — comptime function evaluator
  compiler.zig                        — top-level pipeline driver
  main.zig                            — CLI entry point

lib/                                  — Zap stdlib, all in Zap source
  zap_runtime.zap                     — runtime helper bindings
  io.zap, string.zap, integer.zap,
  list.zap, map.zap, kernel.zap,
  zest/                               — test framework
  …

bench/                                — Zap-side bench scripts (small)
docs/                                 — design notes & briefs
                                        (codegen-blockers-research-brief.md
                                         is the precursor to this one)

zig-out/bin/zap                       — built compiler binary (~187 MB,
                                        statically links LLVM)
build.zig, build.zig.zon              — build script (uses libzap_compiler.a)
```

### `~/projects/zig` (fork) — only files this brief touches:

```
src/zir_builder.zig                   — Zap-facing ZIR builder API
                                         (this is *Zap's* additions on top
                                          of upstream Zig)
src/zir_api.zig                       — C-ABI exports consumed by Zap
                                         via extern "c" fn declarations
src/Sema.zig                          — upstream Zig Sema (occasionally
                                          read for ZIR semantics; rarely
                                          modified)
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

The output is `~/projects/zig/zig-out/lib/libzap_compiler.a` (~430 MB).
Zap's `build.zig` accepts `-Dzap-compiler-lib=<path>` to point at this
local artifact instead of the prebuilt one in `zap-deps/`.

### Toolchain

* **Host Zig**: 0.16.0 (asdf-managed). The fork builds against this.
* **macOS / aarch64** (Apple Silicon). Some details in this brief are
  AArch64-specific (fastcc byref ABI for instance); the underlying
  design generally holds on x86_64 too but the symptoms differ.
* **8 MB thread stack ceiling** on macOS. Solutions that work only by
  raising this ceiling (`ulimit -s unlimited` on Linux) are not
  acceptable.

---

## 3. Compilation pipeline

```
.zap source files
  ↓ parse.zig
AST (ast.zig)
  ↓ collector.zig          (scope graph, decl resolution)
  ↓ hir.zig                (desugar, macro expansion, decision trees)
HIR (high-level IR)
  ↓ types.zig              (type checking; populates TypeStore)
  ↓ analysis_pipeline.zig  (escape, ownership, region, ARC optimizer)
  ↓ ir.zig                 (lower HIR → IR; tail-call rewrite;
                              loopification flag)
IR (mid-level IR)
  ↓ zir_builder.zig        (lower IR → ZIR by calling into the fork's
                              C-ABI builder)
ZIR (Zig intermediate representation)
  ↓ libzap_compiler.a      (Sema + AIR + LLVM codegen, all from the
                              fork)
LLVM IR  →  machine code  →  native binary
```

A few of these stages matter heavily for this brief and warrant a
closer look.

### HIR

`src/hir.zig` lowers the AST into a representation closer to the
type system. Pattern-matrix compilation lives here; multi-clause
function groups become decision trees of `bind`, `extract_struct`,
`switch_literal`, `check_tuple`, etc.

Function groups that all share a name and arity are merged into one
`FunctionGroup` here, even if they were declared in separate
`pub fn` decls.

### IR (mid-level)

`src/ir.zig` defines:

* `Function`, `Block`, `Instruction` (a tagged union of ~80 ops).
* `StructDef`, `StructFieldDef`, `FieldStorage` (the indirection
  decision the rest of this brief turns on).
* `Param`, `ZigType` (a structured union — `i64`, `string`,
  `optional`, `list`, `struct_ref(name)`, `ptr`, …).

Notable IR-level passes done in `ir.zig`:

* `zigTypeReachesStructInCycle` — SCC-aware walker over the struct
  dependency graph. Marks a field's storage as `.indirect` when the
  field's type can transitively reach a struct in the same cycle as
  its owner. This is what makes recursive struct layouts compile.
* `rewriteTailCalls` — walks switch-return / optional-dispatch /
  case-block bodies and rewrites self-tail-calls (`call_named` or
  `call_direct` immediately followed by `ret return_value`) to
  `tail_call` IR nodes.
* `Function.loopify` — flag set when a function has `tail_call` IR
  *and* a non-TCO-safe signature. Triggers the ZIR-emit-time
  loopification path.

### ZIR-emit time

`src/zir_builder.zig` is where IR meets the fork. Every IR
instruction has a `case` arm that emits one or more ZIR
instructions by calling `extern "c" fn zir_builder_*` helpers
defined in the fork's `zir_api.zig`.

### Analyses (analysis_pipeline.zig and friends)

After IR is built but before ZIR emission, several analyses run:

* `interprocedural.zig` — call graph, parameter alias analysis,
  return-source tracking.
* `generalized_escape.zig` — escape lattice (`no_escape` →
  `local_escape` → `global_escape`) per local.
* `region_solver.zig` — use-def per local for region inference.
* `arc_optimizer.zig` — combines the above to decide which
  `retain` / `release` operations to emit and which to skip
  (stack-allocated values, borrowed parameters, etc.).

The output of `arc_optimizer.optimize()` is a list of
`ArcOperation` records (see `src/escape_lattice.zig:738`), each
of which carries a `kind` (`retain` / `release` / `reset` /
`reuse_alloc`), a `value: LocalId`, an `insertion_point`, and an
`ArcReason` (e.g. `scope_exit`, `function_return`,
`shared_binding`).

`zir_builder.zig:3514` (`emitAnalysisArcOps`) reads that list and
emits the actual runtime calls (`ArcRuntime.retainAny` /
`releaseAny`) at the right positions.

---

## 4. The Zig fork and the C-ABI boundary

Zap doesn't fork the entire Zig compiler — it adds a thin "ZIR builder"
library on top of upstream Zig 0.16.0 and exports a stable C-ABI for
Zap to call into.

### The C-ABI (`~/projects/zig/src/zir_api.zig`)

About 200 `pub export fn zir_builder_emit_*` functions. Examples:

```zig
pub export fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, v: i64) u32 { … }
pub export fn zir_builder_emit_call(handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8, name_len: u32,
    args_ptr: [*]const u32, args_len: u32) u32 { … }
pub export fn zir_builder_emit_param_optional_decl_val_type(
    handle: ?*ZirBuilderHandle,
    param_name_ptr: [*]const u8, param_name_len: u32,
    type_name_ptr: [*]const u8, type_name_len: u32) u32 { … }
```

Each returns either a `Zir.Inst.Ref` (encoded as `u32`) or
`0xFFFFFFFF` on failure. Some are body-tracked (the instruction is
appended to the active body), some are emit-only (the caller chooses
where the inst lands by capturing).

Zap-side bindings live at the top of `~/projects/zap/src/zir_builder.zig`:

```zig
extern "c" fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, v: i64) u32;
…
```

### When you need to extend the fork

Whenever Zap needs a ZIR shape upstream Zig doesn't already produce.
Examples that recently shipped:

* Streaming per-field-body API for struct-decl fields
  (`begin_root_field_body` / `end_root_field_body` /
  `set_root_field_static`) — needed because struct field types in
  Zap are arbitrary expressions, not simple Refs.
* `addParamOptionalDeclValType`, `addParamOptionalThisType` — for
  emitting `?T` parameter types where T is a sibling decl in the
  current file.
* `addSingleConstPtrType` — `*const T` emission for indirect-storage
  field types (`?*const Tree`).

If you find yourself wanting a ZIR helper that doesn't exist, the
right answer is almost always: add it to the fork. Don't simulate it
in Zap by routing through five existing primitives.

### Sema (`~/projects/zig/src/Sema.zig`)

Upstream-Zig file, ~120k lines. Rarely modified. Read when you need
to understand what shape Sema expects from a particular ZIR
instruction. The most common gotcha is body-shape requirements:
several ZIR instructions only resolve correctly when their operands
appear in specific block/body contexts.

---

## 5. Memory model — arena + ARC

Two layers, both currently implemented.

### Layer 1: process-lifetime arena (`std.heap.page_allocator`)

`src/runtime.zig` exposes `emitAllocatorRef()` which produces a ZIR
ref to `std.heap.page_allocator`. Every heap allocation in a
running Zap program — every list cons, every struct allocated via
`ArcRuntime.allocAny`, every map cell — pulls from this allocator.

`page_allocator` returns 16 KiB chunks straight from the OS. **It
never frees during the process lifetime; everything is reclaimed
when the process exits.** That's intentional for long-running
servers and for tiny CLI tools, but it's the bug from the
binary-trees benchmark's point of view (see §8).

There is currently no per-iteration sub-arena. You can't write a
"build this tree, throw it away" block in Zap and have the bytes
actually freed before exit.

### Layer 2: atomic reference counting (`src/runtime.zig` ArcRuntime)

```zig
pub const ArcHeader = struct {
    count: std.atomic.Value(u32),

    pub fn init() ArcHeader { return .{ .count = .init(1) }; }
    pub fn retain(self: *ArcHeader) void { … atomic add … }
    pub fn release(self: *ArcHeader) bool { … atomic sub; return prev==1 … }
};

pub const ArcRuntime = struct {
    pub fn allocAny(comptime T: type, alloc: std.mem.Allocator, value: T) *T {
        const Inner = struct { header: ArcHeader, value: T };
        const inner = alloc.create(Inner) catch @panic(...);
        inner.* = .{ .header = .init(), .value = value };
        return &inner.value;
    }

    pub fn freeAny(comptime T: type, alloc: std.mem.Allocator, ptr: *T) void {
        const Inner = struct { header: ArcHeader, value: T };
        const inner: *Inner = @fieldParentPtr("value", ptr);
        if (inner.header.release()) alloc.destroy(inner);
    }

    pub fn releaseAny(comptime T, alloc, ptr) = freeAny(T, alloc, ptr);
    pub fn retainAny(comptime T, ptr) { … inner.header.retain() … }
    pub fn refCountAny(comptime T, ptr) u32 { … inner.header.count() … }
    pub fn resetAny(...) ?*anyopaque { … Perceus reset/reuse … }
};
```

Every ARC-wrapped allocation has a 4-byte refcount header in front
of the user-visible value. The header is initialised at 1; `retain`
increments; `release` decrements and frees the underlying allocation
through `page_allocator.destroy(inner)` when the count hits zero.

**`releaseAny` does free the memory when the count drops to 0.** It
calls `allocator.destroy(inner)` (line 229 of `src/runtime.zig`),
which on `page_allocator` returns the page to the OS. So the arena
isn't strictly forever — values released to RC=0 are reclaimed. The
question is just whether the compiler is emitting enough release
calls.

### How releases land in compiled code

The `analysis_pipeline.zig` runs the escape / ownership / region /
ARC-optimizer passes in order. The output is
`AnalysisContext.arc_ops: []ArcOperation`, each
`ArcOperation { kind: retain|release|reset|…, value: LocalId,
insertion_point: InsertionPoint, reason: ArcReason }`.

`zir_builder.zig:emitAnalysisArcOps` (line 3514) iterates that list
at every IR instruction's emission site, checks whether the current
instruction matches each op's `insertion_point`, and emits:

```
@import("zap_runtime").ArcRuntime.releaseAny(allocator, value)
```

at the right spot. The `ArcReason.scope_exit` case is the one that
matters for short-lived values like the per-iteration trees in
binary-trees: when a local goes out of scope without being captured
or returned, the analyzer decides it's safe to release.

For *direct-storage* struct fields, this works correctly today.
A `Point { x :: i64, y :: i64 }` allocated via `allocAny` and dropped
at scope exit hits `releaseAny` → `inner.header.release()` returns
true → `allocator.destroy(inner)` → page returned. ✓

For *indirect-storage* fields, it does not. That's the entire
problem this brief is about.

---

## 6. Recursive structs — what shipped

Before context-setting can be sufficient, the agent needs to know
exactly what the recently-shipped recursive-struct work does. Five
concepts you'll see referenced everywhere:

### 6.1 `FieldStorage`

```zig
// src/ir.zig:49
pub const FieldStorage = enum {
    direct,    // field is laid out by value at its declared type
    indirect,  // field is laid out via a hidden pointer indirection
};
```

A field is marked `.indirect` iff its type, when traversed through
`optional` / `ptr` / `list` / `tuple` / `function` / `map`
wrappers, transitively reaches a `struct_ref` to a struct in the
same SCC as the owning struct. Computed by
`zigTypeReachesStructInCycle` in `src/ir.zig:6028`.

For `Tree { left :: Tree | nil, right :: Tree | nil }`, both
`left` and `right` are marked `.indirect`. The user wrote `?Tree`
but the runtime layout is `?*const Tree`. The user never sees this.

### 6.2 Heap promotion at construction

`src/zir_builder.zig:6450` — `heapPromoteForIndirectField`:

```zig
fn heapPromoteForIndirectField(self: *ZirDriver, value_ref: u32) BuildError!u32 {
    const type_ref = zir_builder_emit_typeof(self.handle, value_ref);
    const alloc_ref = try self.emitAllocatorRef();   // page_allocator
    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
    const arc_runtime = emitRuntimeNamespaceField(...arc_runtime);
    const alloc_fn = zir_builder_emit_field_val(self.handle, arc_runtime,
                                                  "allocAny", 8);
    const args = [_]u32{ type_ref, alloc_ref, value_ref };
    return zir_builder_emit_call_ref(self.handle, alloc_fn, &args, 3);
}
```

Every `%Tree{left: subtree, right: subtree}` triggers a call into
`ArcRuntime.allocAny` for each `.indirect` field whose value isn't
`nil`. The result is a `*T` (which Zig coerces to `*const T` →
`?*const T` at the field assignment).

### 6.3 Auto-deref at field access

`src/zir_builder.zig:6483` — `emitIndirectFieldDeref`:

* For non-optional indirect (`*const T`): emit `load(ptr)`.
* For optional indirect (`?*const T`): emit
  `if (storage) |p| @as(?T, p.*) else null` via `if_else_bodies`.

So `t.left` produces `?Tree` even though storage is `?*const Tree`.
Source-level types match what the user wrote.

### 6.4 Optional dispatch (`OptionalDispatch` IR)

`src/ir.zig:706` defines the IR node for the multi-clause `f(nil) /
f(t :: T)` shape. The dispatcher param unifies to `?T`. ZIR emit
expands it to:

```
if (param == null) { nil_body; ret nil_result }
else { payload = param.?; struct_body; ret struct_result }
```

`payload_local` is read inside the struct branch when the body
references the param via `param_get(scrutinee_param)` — the ZIR
emitter temporarily swaps `param_refs[scrutinee_param]` to the
unwrapped payload ref. See `src/zir_builder.zig:7377`
(`emitOptionalDispatch`).

### 6.5 Loopification (`Function.loopify`)

For tail-recursive functions whose param/return shape is byref
(structs, optionals, lists, …), LLVM `musttail` rejects the call
under fastcc on AArch64. Setting `Function.loopify = true` (in
`src/ir.zig:127`) tells the ZIR backend to emit a different
shape for `tail_call`:

* Allocate one mutable stack slot per parameter (`alloc_mut`).
* Wrap the body in a `loop` block.
* `param_get(i)` emits a `load(slot[i])`.
* `tail_call` to self emits `store(slot[i], new_arg[i])` for each
  i; no explicit `repeat` (relies on the wrapping loop's implicit
  back-edge via fall-through).
* The captured loop body ends with an explicit `repeat` because the
  dispatcher's value-producing block isn't itself noreturn.

This is what made the n-body benchmark beat C/Rust/Zig in the
recent harness run (see §13).

### 6.6 Inhabitability check

`src/types.zig:checkUninhabitedRecursiveTypes` runs a fixpoint over
the struct dependency graph and flags structs with no finite base
case (`Tree { left :: Tree, right :: Tree }` with no nil escape).
Diagnostic fires before Sema, with a help line suggesting the
typical escapes (`T | nil`, `[T]`, a tagged-union leaf).

---

## 7. The open problem: ARC release on `FieldStorage.indirect` drop

This is the entire reason this brief exists.

### Symptom

`bench/binary-trees/binarytrees.zap` (in `~/projects/lang-benches/`)
verifies byte-identical against the C reference at N = 10. At
CLBG's full N = 21 — 2^21 trees of depth 4, 2^19 of depth 6, …,
2^5 of depth 20, plus the long-lived tree and a stretch tree at
depth 22 — the process is killed by the macOS OOM killer at
~45 seconds with exit code 137. Resident set climbs past 12 GB
within 30 seconds. The 32 GB test machine can't fit the workload's
transient working set.

C, Rust, Zig, Go, OCaml, Elixir all complete this same workload in
1–8 seconds with bounded memory. Their per-band trees are freed
between bands (manual `free`, `bumpalo::Bump::reset`,
`ArenaAllocator.deinit`, GC, etc.).

### Root cause

The Zap compiler emits exactly one heap allocation per Tree node
(`ArcRuntime.allocAny`, see §6.2). Each allocation comes back with
refcount = 1. The analysis pipeline then asks: "is this value
captured? returned? does it escape the function?". For a per-band
loop body like

```zap
acc + Binarytrees.check(Binarytrees.make(d))
```

the result of `make(d)` is consumed by `check`, which returns an
`i64`. The Tree itself does not escape — at the source level it has
a single unique owner that drops at the end of the call to `check`.

The analysis pipeline notices the drop and emits a `releaseAny`
call. The release fires. `inner.header.release()` returns true
(refcount was 1 → 0). `allocator.destroy(inner)` runs.

**But that only frees the *root* Tree node.** Its `left` and
`right` fields each hold a `?*const Tree` pointing at a different
heap allocation that *also* has refcount 1. Those don't get
released. Each child has its own children. The entire subtree is
leaked.

You can verify the asymmetry by reading the existing release
emission in `src/zir_builder.zig:6100`:

```zig
.release => |rel| {
    if (op.reason == .perceus_drop) continue;
    if (!self.shouldSkipArc(op.value)) {
        const val_ref = self.refForLocal(op.value) catch continue;
        const alloc_ref = try self.emitAllocatorRef();
        // … import zap_runtime, get arc_runtime …
        const release_fn = zir_builder_emit_field_val(
            self.handle, arc_runtime, "releaseAny", 10);
        const args = [_]u32{ alloc_ref, val_ref };
        _ = zir_builder_emit_call_ref(
            self.handle, release_fn, &args, 2);
    }
},
```

That's one `releaseAny(alloc, val)` call per IR-level release.
There's no walk of `val`'s fields, no recognition that some of
those fields are `.indirect` and own heap allocations of their own.

**Heap promotion at construction without recursive release at drop
is by definition a leak.** The asymmetry is the bug. The runtime
allocator is healthy; the compiler is asymmetric.

### What "fixing it" looks like

The semantically clean fix is a recursive release that, on a
struct value with `FieldStorage.indirect` fields, also releases
each of those fields' pointees before destroying the parent.

Two places to do that, with different tradeoffs:

**Option A — runtime-side.** Add a generic `freeAnyWithChildren`
helper in `src/runtime.zig` that the compiler calls instead of
`freeAny` for every indirect-bearing struct. The helper walks the
struct's fields at comptime (using `@typeInfo`) and recurses on
`?*const X` and `*const X` field shapes. Pros: one new helper,
no IR/ZIR changes. Cons: comptime recursion across user-defined
structs is gnarly (mutual recursion needs careful handling), and
the helper has to know the struct's *Zap-level* `FieldStorage`
metadata — which today only exists in the IR, not in the emitted
Zig type. You'd need to either pass the metadata in (extra
parameters) or rebuild it at comptime (fragile).

**Option B — compiler-side.** Extend the ARC analysis to recognize
indirect fields and emit per-field releases at the same insertion
point as the parent's release. So a `release(t)` where `t :: Tree`
becomes:

```
release(t.left)            ; pseudo-IR
release(t.right)
releaseAny(alloc, t)
```

The recursive walk happens at codegen, not at runtime, because the
compiler knows the field structure. Pros: integrates with the
existing `arc_optimizer` skip rules (we already skip release for
borrowed params, stack-allocated values, etc.); no comptime tricks
in `runtime.zig`. Cons: requires extending `escape_lattice.zig`'s
`ArcOperation` to optionally carry a list of child releases, or
adding a new `release_recursive` IR op, or always pre-emitting the
child releases as separate IR `release` ops.

**Recommend Option B** for the project's design rules: the
compiler is the one that knows about `FieldStorage`, so the
compiler is where the knowledge should live. `src/runtime.zig`'s
job is to expose primitives, not to encode language-level layout
decisions.

### The exact wiring (sketch)

There's likely a set of changes in this neighbourhood. The
research agent's job is to validate / refine this and produce
concrete edit points. Provisionally:

1. **`src/ir.zig`**: when a struct is heap-promoted at construction
   (the `heapPromoteForIndirectField` site is in `zir_builder.zig`,
   but the *decision* is recorded at IR time via `FieldStorage.indirect`),
   record an "owns this child via indirect storage" edge in the
   per-function escape lattice. Today the analysis treats the
   construction's argument as an ordinary local that flows into the
   constructor; it doesn't notice that the constructor heap-allocates
   the child.

2. **`src/generalized_escape.zig`**: when a struct's release is
   `global_escape` (or really, when its release fires), the children
   of indirect fields should be considered released too. Today the
   `seedInstruction(.struct_init)` handler at line 177 marks the
   struct's overall escape but doesn't propagate per-field escapes
   correctly for indirect fields.

3. **`src/escape_lattice.zig`**: extend `ArcOperation` (line 738)
   with an optional `child_releases: []ArcOperation` slice, OR add
   a new `ArcOpKind.release_recursive` and let the codegen expand
   it at emission time.

4. **`src/zir_builder.zig`**: at the `emitAnalysisArcOps` site
   (line 3514), when processing a `release_recursive`, walk the
   value's `StructFieldDef` list, find each `.indirect` field,
   emit `field_val` to read the child pointer, emit
   `is_non_null` if the field is optional, gate the recursive
   release on non-null, and emit a recursive release for the
   child. The recursion bottoms out when the child's struct has
   no `.indirect` fields. (Note that if the child's struct also
   has indirect fields — the typical recursive case! — the
   recursion needs to either continue at codegen time or call
   into a runtime helper. Codegen-time recursion is cleaner but
   produces unbounded code size for deeply self-referential
   types; a runtime helper plus a generated per-struct dispatch
   table is the textbook answer.)

5. **`src/runtime.zig`**: add a `releaseTree(comptime T, alloc, ptr)`
   helper that walks `T`'s fields at comptime and recursively
   releases each `?*const X`. Same machinery as `allocAny` but
   in reverse. (This effectively becomes Option A's helper, but
   called from compiler-emitted code instead of being the only
   release path.)

The agent should research which of (codegen-time recursion,
runtime-side recursion via a generated dispatch table, or a
hybrid) is the cleanest given how the rest of the ARC pipeline
is structured. The decision affects code size, recursion
behaviour at runtime (a 600M-node tree's release walk needs to
not blow the stack itself — see §10), and how cycles in the
struct graph interact with the recursion strategy.

### Stack safety of the release walk itself

A 21-deep tree has ~4M nodes. A naive recursive `releaseTree(t)`
that calls `releaseTree(t.left); releaseTree(t.right)` recurses
21 deep — fine. A linked list of length N (`Cons { head: i64, tail: List }`)
recursed naively would blow the stack at N ≈ 100k.

Solutions: (a) loopify the release walk for tail-recursive shapes
via the same `Function.loopify` machinery that already exists for
user code (only works for linear/tail-recursive shapes); (b)
explicit work-list / stack-vector inside the release helper,
allocated from a side arena. The agent should think about which
applies and how to prove it stack-bounded.

### Cycles

ARC doesn't handle cycles. Zap's recursive-struct path makes cycles
representable (`Tree { parent: Tree | nil, children: [Tree] }` could
encode a back-pointer, though the current SCC analysis would still
mark both fields `.indirect`). Today the user can build a cycle and
the compiler will silently leak it. That's a separate problem from
this brief, but the recursive-release design needs to at least not
infinite-loop on a cyclic structure. A typical answer is: ARC's
release walk uses a "decrement and free if zero" rule, so a cycle
of two nodes with refcount 2 each (each holding a ref to the
other) sees its outer release decrement to 1, find non-zero, stop.
Memory leaks but doesn't infinite-loop. That's the same
correctness story C++ shared_ptr / Swift / Rust Rc have. The agent
should confirm that's the right answer here too.

---

## 8. Why it matters: binary-trees

Computer Language Benchmarks Game's `binary-trees` is the canonical
allocator-pressure benchmark. The official problem statement is at
<https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/binarytrees.html>.

Algorithm:

1. Build a "stretch tree" of depth N+1, walk it for its node count
   (the "check"), throw it away.
2. Build a "long-lived tree" of depth N. Keep it.
3. For every even depth d from 4 to N, build `2^(N-d+4)` short-lived
   complete binary trees of depth d, sum their checks, throw them
   all away. Print the per-d row.
4. Walk the long-lived tree, print its check.

Total node count at N=21 is ~600 million. Each language's CLBG
entry uses an arena that resets between bands so the working set
stays bounded around the largest single band (~67 M nodes). Zap
currently can't reset because there's no `releaseTree`-equivalent
that empties the heap when each band's trees go out of scope.

### Cross-language baseline (run on this machine, Apple M4, 32 GB)

* OCaml 1.06 s
* Zig 3.39 s
* Elixir 5.26 s
* C 7.45 s
* Go 7.66 s
* Rust 8.15 s
* **Zap — exit 137 (OOM-kill at ~45 s)**

The Zap source (`~/projects/lang-benches/binarytrees/binarytrees.zap`)
is small and idiomatic — same shape as the language reference
example in §1. The codegen path is healthy: at N = 10 every check
value matches the published `expected_n10.txt` byte-for-byte. The
binary just leaks memory until the OS kills it.

### What "fixed" would look like

After the fix:

* Working set stays bounded at the largest single band (~67M
  nodes × ~32 bytes = ~2 GB) plus the long-lived tree (~4 M nodes
  × 32 bytes ≈ 130 MB). Well under 32 GB.
* Wall-clock time should be in the same order of magnitude as the
  other native compilers — anywhere from 5 s to 30 s is the
  plausible range. Slower than OCaml's 1 s is likely (OCaml's
  generational GC is highly optimized for this exact shape), but
  not by orders of magnitude.

If wall-clock comes out much worse than 30 s, the additional
investigation is: ARC retain/release atomic-fence overhead. Every
release is `@atomicLoad(.acquire) → sub → @atomicStore(.release)`,
which is ~5 ns on M4. 600 M of those is 3 s of pure ARC overhead.
That's the unavoidable cost of refcounting compared to a copying
GC; languages that win this benchmark with millisecond times
(OCaml) are paying a different price elsewhere (every other
allocation goes through a write barrier).

---

## 9. Investigation hooks

Concrete starting points for the research agent. All paths
relative to `~/projects/zap/`.

### Where the relevant data structures live

| concept                          | file & line                                     |
| -------------------------------- | ----------------------------------------------- |
| `FieldStorage` enum              | `src/ir.zig:49`                                 |
| `StructFieldDef`                 | `src/ir.zig:65`                                 |
| `Function.loopify`               | `src/ir.zig:135`                                |
| `Instruction` tagged union       | `src/ir.zig:168`                                |
| `containsTailCall`               | `src/ir.zig:2273`                               |
| `rewriteTailCalls`               | `src/ir.zig:2312`                               |
| `zigTypeReachesStructInCycle`    | `src/ir.zig:6105`                               |
| `OptionalDispatch` IR            | `src/ir.zig:706` (search for `OptionalDispatch`)|
| `ArcOperation`                   | `src/escape_lattice.zig:738`                    |
| `ArcOpKind` (release/retain/…)   | `src/escape_lattice.zig:745`                    |
| `ArcReason`                      | `src/escape_lattice.zig:760`                    |
| `AnalysisContext.arc_ops`        | `src/escape_lattice.zig:984`                    |
| `ArcOptimizer`                   | `src/arc_optimizer.zig`                         |
| seed escape per IR instruction   | `src/generalized_escape.zig:174`                |
| call-graph + alias               | `src/interprocedural.zig`                       |
| `emitAnalysisArcOps`             | `src/zir_builder.zig:3514`                      |
| `release` IR emission            | `src/zir_builder.zig:6100`                      |
| `reset` IR emission (Perceus)    | `src/zir_builder.zig:6118`                      |
| `heapPromoteForIndirectField`    | `src/zir_builder.zig:6450`                      |
| `emitIndirectFieldDeref`         | `src/zir_builder.zig:6483`                      |
| `emitOptionalDispatch`           | `src/zir_builder.zig:7377`                      |
| `Arc(T)` wrapper                 | `src/runtime.zig:157`                           |
| `ArcRuntime.allocAny`            | `src/runtime.zig:213`                           |
| `ArcRuntime.freeAny`             | `src/runtime.zig:225`                           |
| `ArcRuntime.releaseAny`          | `src/runtime.zig:235`                           |
| `ArcRuntime.refCountAny`         | `src/runtime.zig:247`                           |
| `ArcRuntime.resetAny` (Perceus)  | `src/runtime.zig:256`                           |
| `TypeChecker.checkProgram`       | `src/types.zig:2546`                            |
| `checkUninhabitedRecursiveTypes` | `src/types.zig:3069`                            |

### Tests that exercise the existing recursive-struct path

These pass today and should pass after the fix.

* `test/struct_test.zap` — `Recursive struct field auto-deref`
  describe block. Tests that `head.next` reads correctly through
  `FieldStorage.indirect`, that `?LinkedNode` parameters compile
  and dispatch correctly, that 4-deep chains build without
  segfaulting (i.e., heap promotion holds).
* `test/recursion_test.zap` — `byref tail-call loopification`
  describe block. Tests 10000-deep recursion with byref `LoopState`.
* The benchmark itself (`~/projects/lang-benches/binarytrees/`)
  verifies byte-identical against `expected_n10.txt` at N=10.

### How to know your fix worked

```sh
cd ~/projects/lang-benches/binarytrees
rm -rf zap-out .zap-cache
~/projects/zap/zig-out/bin/zap build
diff <(./binarytrees-c 21) <(./zap-out/bin/binarytrees 21)  # must match
time ./zap-out/bin/binarytrees 21                            # must finish, RSS <16 GB
```

Then re-run the harness:

```sh
cd ~/projects/lang-benches
# Re-add Zap to scripts/run-binarytrees.sh and scripts/run-all.sh
bash scripts/run-binarytrees.sh
python3 scripts/render-html.py
open results/index.html
```

The fix is correct iff:

1. `diff` shows no difference vs C at N = 21.
2. Wall-clock time is finite and bounded.
3. The existing 819 tests in `zap test` still pass.
4. The four other benchmarks in `~/projects/lang-benches/`
   (mandelbrot + nbody) continue to pass — including their
   timing characteristics, since the new release path could
   regress n-body if it adds release calls inside the loopified
   body.

---

## 10. Design constraints

Hard rules. Violations are not acceptable.

* **No workarounds or hacks.** From `CLAUDE.md`: every solution
  must be the correct, production-grade, long-term fix. If the
  proper fix requires changes to the Zig fork, that's the fix.
  If it requires extending the analysis pipeline across three
  files, that's the fix.

* **Features in Zap, not in the compiler.** The general rule is
  that anything that *can* be in Zap source (`lib/*.zap`) MUST
  be. The runtime ARC helpers (`ArcRuntime.allocAny` etc.) are
  in `src/runtime.zig` because they need access to Zig
  primitives that can't be expressed in Zap (raw allocation,
  atomic refcount). If the recursive-release walk can be
  expressed as a runtime helper without too much comptime
  awkwardness, it should be — but the *decision* of when to
  call it is compiler-side metadata (the per-struct field
  storage map).

* **Tests must stay green.** 819 tests in `zap test`. 671 tests
  in the fork's `zig build test`. All 24 examples in
  `~/projects/zap/examples/` must continue to compile and produce
  expected output.

* **One struct per file.** When adding new structs (e.g., for a
  new IR pass), each goes in its own file matching the path.

* **macOS thread-stack ceiling is 8 MB.** Solutions that work
  only on Linux (where `ulimit -s unlimited` is available) are
  not acceptable. The release-walk recursion in particular needs
  to be stack-bounded for the deepest recursive shape Zap
  supports — currently 10000+ deep via loopification.

* **Backwards-compatibility hacks are forbidden.** When
  refactoring, fully commit to the new approach. Remove old code
  entirely. If the new approach fails, that's a bug to surface,
  not hide.

* **All public Zap functions need `@fndoc`.** If you add Zap-side
  functions in `lib/*.zap`, document them.

* **Don't hardcode struct names in the compiler.** This applies
  throughout — see `CLAUDE.md`. If you need to detect a specific
  Zap struct (`IO`, `Map`, …) from `src/*.zig`, you're almost
  certainly doing it wrong; route through `lib/*.zap` instead.

* **Cost and time are not concerns.** Correctness is. If the
  proper fix touches ten files across both repos, that's still
  better than a one-file workaround.

---

## 11. Research questions

The agent should investigate, and produce a recommended approach
with concrete implementation guidance for, each of:

### Q1. Recursion strategy

Should the recursive release walk be:

* **Codegen-time (Option B, full inline).** `release(t :: Tree)`
  expands at ZIR-emit time to inlined `is_non_null` checks plus
  recursive `release(t.left)` / `release(t.right)` plus the
  parent's `releaseAny`. Pros: no runtime dispatch, LLVM can
  optimize. Cons: code-size blowup for deeply nested struct
  graphs; the same struct's release expansion lives in every
  callsite.

* **Codegen-time (Option B, function-per-struct).** Each
  `.indirect`-bearing struct gets one synthesized
  `release_T(alloc, ptr)` function emitted once per program;
  callers all dispatch into it. Pros: bounded code size; LLVM
  can still inline at hot sites. Cons: needs
  per-struct-codegen orchestration, similar to the Zap side's
  existing `emitNestedTypeDecl` machinery.

* **Runtime-side (Option A).** A single comptime-generic
  `releaseAnyDeep(comptime T, alloc, ptr)` in `src/runtime.zig`
  that walks `T`'s fields at comptime. Pros: smallest compiler
  change. Cons: comptime recursion across mutual struct cycles
  needs careful base-case handling; the helper has to know the
  struct's `FieldStorage` map at comptime, which today only
  lives in the Zap-side IR; passing the map in as comptime
  metadata is fragile.

Recommend the function-per-struct codegen variant unless the
agent finds a specific reason to differ. Argue the choice.

### Q2. Where in the analysis pipeline does the recursive release get scheduled?

Today `ArcOperation` is `{ kind, value, insertion_point, reason }`.
Options:

* Add `child_releases: []ArcOperation` to `ArcOperation` — recursive
  releases are explicit ops the analyzer emits.
* Add `ArcOpKind.release_recursive` — codegen knows how to expand it.
* Don't change `ArcOperation`; expand at codegen time based on the
  value's static type alone (look up the struct, walk its fields).

The agent should pick one and explain how it interacts with the
existing skip rules in `arc_optimizer.zig` (stack-allocated values
skip ARC entirely; borrowed parameters skip retain/release at the
boundary; etc.).

### Q3. How does this interact with `Function.loopify`?

In a loopified function, `tail_call` lowers to slot stores plus a
`repeat`. Today the analysis pipeline doesn't insert releases
inside loopified bodies (the loop carries state by reference, not
by ownership transfer). After this fix, the Tree walks inside the
loopified body should still work — the release should fire on
loop-exit values, not per-iteration values.

The agent should verify: does the n-body benchmark (which uses
loopification on a non-recursive `State` struct) regress after
this fix lands? `bench/n-body/zap` is the test case; it currently
beats C at 1.50× (104 ms vs 156 ms at N = 5 M).

### Q4. Stack-safety of the release walk itself

The recursive release of a depth-21 tree can be expressed naively
(stack depth 21) but a depth-10000 linked list can't (stack
overflow at ~4000 frames on macOS). What's the right answer?
Options:

* **Naive recursion + accept the limit.** Document that release
  trees must be shallower than ~4000.
* **Loopify the release walk itself** for linear shapes. Use the
  existing `Function.loopify` machinery on the synthesized
  `release_T` function.
* **Explicit work-list inside the release helper.** Allocate a
  side `std.ArrayList(*anyopaque)` from `page_allocator`, push
  children onto it, drain in a loop.

For tree-shaped releases the depth is logarithmic in node count,
so naive recursion is usually fine. For list-shaped releases it's
linear — needs loopification or explicit work-list.

### Q5. Cycles

ARC can't handle cycles. The current SCC analysis allows cycles
to be expressed in the struct graph (`A { b: B }, B { a: A }`) —
both are inhabitable iff at least one of the cycle fields is
optional / list / map. If the user constructs a cycle (`a.b = b;
b.a = a`), the recursive release walk could either infinite-loop
or leak both. The textbook answer is: "decrement and free if
refcount hits zero" naturally stops at non-zero counts, so the
walk doesn't infinite-loop; it leaks both. Confirm or refine.

### Q6. Perceus reuse interaction

`ArcRuntime.resetAny` (line 256 of `src/runtime.zig`) implements
Perceus-style reuse: if refcount is 1, return the existing
allocation as a reuse token instead of freeing. If a recursive
release is interacting with a struct that's about to be reset
(refcount-1 → reused for a new construction), the release-walk
should *not* fire on the children — they're still live in the
new constructed value. The agent should map out the interaction
between the new release_recursive path and the existing
`reset_alloc` IR op (`src/ir.zig` `.reset` handler in
`zir_builder.zig:5967`).

### Q7. Memory ordering

Atomic refcounts use acquire/release semantics today
(`src/runtime.zig:ArcHeader`). Multi-threaded code (Zap currently
runs single-threaded in the user-facing semantics, but the
runtime is thread-safe) requires the recursive release to use
the same ordering. Confirm there are no relaxations the new path
would need.

---

## 12. Appendix A — file & line index

For quick navigation during research. All paths relative to
`~/projects/zap/`.

```
src/runtime.zig:7         envGetRuntime — getenv via libc
src/runtime.zig:18        STDOUT_FD / STDERR_FD constants
src/runtime.zig:108       Arc-machinery overview comment
src/runtime.zig:115       ArcHeader — atomic refcount
src/runtime.zig:151       releaseOpaque (non-generic, for ZIR)
src/runtime.zig:157       Arc(T) — generic ARC wrapper
src/runtime.zig:213       ArcRuntime.allocAny
src/runtime.zig:225       ArcRuntime.freeAny
src/runtime.zig:235       ArcRuntime.releaseAny
src/runtime.zig:240       ArcRuntime.retainAny
src/runtime.zig:247       ArcRuntime.refCountAny
src/runtime.zig:256       ArcRuntime.resetAny — Perceus
src/runtime.zig:266       ArcRuntime.reuseAllocByType — Perceus

src/ir.zig:49             FieldStorage enum
src/ir.zig:65             StructFieldDef
src/ir.zig:103            Function struct
src/ir.zig:135            Function.loopify field
src/ir.zig:168            Instruction tagged union
src/ir.zig:706            OptionalDispatch IR shape
                            (search for `OptionalDispatch` — the line
                             number drifts when adjacent IR ops are added)
src/ir.zig:2273           containsTailCall
src/ir.zig:2312           rewriteTailCalls
src/ir.zig:6105           zigTypeReachesStructInCycle (SCC walker)

src/types.zig:120         StructType
src/types.zig:2546        TypeChecker.checkProgram
src/types.zig:2606        registerUserTypes (two-pass)
src/types.zig:3069        checkUninhabitedRecursiveTypes (added recently)

src/escape_lattice.zig:738  ArcOperation
src/escape_lattice.zig:745  ArcOpKind
src/escape_lattice.zig:760  ArcReason
src/escape_lattice.zig:984  AnalysisContext.arc_ops
src/escape_lattice.zig:1167 AnalysisContext.addArcOp

src/arc_optimizer.zig       full file — ~500 lines
src/generalized_escape.zig  full file — escape lattice worklist
src/interprocedural.zig     full file — call graph + alias
src/region_solver.zig       full file — use-def regions
src/analysis_pipeline.zig   full file — orchestrator

src/zir_builder.zig:3514  emitAnalysisArcOps (where retains/releases land)
src/zir_builder.zig:3725  param_get IR emission (with loopify slot redirect)
src/zir_builder.zig:4401  tail_call IR emission (with loopify slot stores)
src/zir_builder.zig:4863  field_get IR emission (with auto-deref)
src/zir_builder.zig:6100  release IR emission
src/zir_builder.zig:6118  reset IR emission (Perceus)
src/zir_builder.zig:6450  heapPromoteForIndirectField
src/zir_builder.zig:6483  emitIndirectFieldDeref
src/zir_builder.zig:7377  emitOptionalDispatch
```

In the fork (`~/projects/zig`):

```
src/zir_builder.zig:1530  addParamImportedType
src/zir_builder.zig:1684  addParamDeclValType
src/zir_builder.zig:1719  addParamTypeBody
src/zir_builder.zig:3494  addLoop
src/zir_builder.zig:3520  addRepeat

src/zir_api.zig           — Zap-facing C-ABI exports
                            (search for `pub export fn zir_builder_emit_*`)
```

---

## 13. Appendix B — current bench numbers

From the most recent harness run on this machine (Apple M4, 32 GB,
hyperfine 1.20, 5 runs after 2 warmups, single-thread):

### nbody (N = 5 000 000)

| lang   | mean ms | vs Zap |
|--------|---------|--------|
| **Zap**| **104** | 1.00×  |
| C      | 156     | 1.50×  |
| Rust   | 159     | 1.53×  |
| Zig    | 160     | 1.54×  |
| OCaml  | 176     | 1.69×  |
| Go     | 270     | 2.59×  |
| Elixir | 5681    | 54.6×  |

### mandelbrot (N = 8 000)

| lang   | mean s | vs C  |
|--------|--------|-------|
| C      | 1.90   | 1.00× |
| Go     | 1.97   | 1.04× |
| Zig    | 2.03   | 1.07× |
| Rust   | 2.05   | 1.08× |
| **Zap**| **2.16** | 1.14× |
| OCaml  | 3.13   | 1.65× |
| Elixir | 23.52  | 12.4× |

### binarytrees (N = 21)

| lang   | mean s | notes                       |
|--------|--------|-----------------------------|
| OCaml  | 1.06   |                             |
| Zig    | 3.39   |                             |
| Elixir | 5.26   |                             |
| C      | 7.45   |                             |
| Go     | 7.66   |                             |
| Rust   | 8.15   | `Box<Tree>`, no bumpalo     |
| **Zap**| —      | OOM-killed at ~45 s (this brief's blocker) |

The bench harness is at `~/projects/lang-benches/`. JSON results
under `results/`, rendered HTML at `results/index.html`. The most
recent commit in that repo wires Zap into nbody and mandelbrot
fully and excludes Zap from binarytrees with a documented note
pointing here.

---

## End of brief

The agent's deliverable should be:

1. Pick one of the strategies in §11 (or a hybrid) and explain why.
2. List concrete file edits with line numbers (relative to the index
   in §12 / §9), in order of dependency.
3. List the Zig-fork-side additions, if any. Each `extern "c" fn`
   binding's name and shape.
4. Write a test plan: which existing tests should still pass, which
   new tests to add, what the binary-trees N=21 success criterion
   is (output diff against C, RSS bound, wall-clock plausibility
   range).
5. Flag any of the seven research questions where the agent's
   answer is uncertain enough that a follow-up implementation pass
   should re-investigate.

The expected scope is somewhere between 200 and 800 lines of code
across `src/runtime.zig`, `src/escape_lattice.zig`,
`src/arc_optimizer.zig`, `src/generalized_escape.zig`, and
`src/zir_builder.zig`. Possibly one or two extern bindings on the
fork side. No fork-side Sema changes expected.
