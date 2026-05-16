# Zap Compiler Codegen Blockers — Research Brief

> This document provides complete context for a deep research agent investigating how to fix three specific codegen blockers in the Zap programming language and its Zig compiler fork. The reader is assumed to have zero prior knowledge of Zap, the Zig fork, or how they fit together. Read top-to-bottom; the technical detail in §6 only makes sense with the architecture context from §1–§5.
>
> **Status note (post-research):** §6 originally proposed a naive "auto-rewrite recursive `T` to `?*T`" for Blocker 2 and "heap-promote byref state, keep `musttail` over heap pointer" for Blocker 3. Both have been refined. Blocker 2's correct fix is **storage-strategy metadata that breaks the layout cycle without changing source semantics** — source nullability stays source-driven; only the runtime layout indirects. Blocker 3's correct fix is **IR-level loopification of self-tail-recursion**, sidestepping `musttail` entirely; heap-promotion remains a documented fallback. Blocker 1's fix is a **streaming per-field-body API** in the fork, not a tagged-union encoding. The `## Recommended Solution Architecture` section near the end of §6 contains the refined designs; the original "what was tried" notes earlier in §6 are preserved for context.

---

## Table of Contents

1. [What Is Zap](#1-what-is-zap)
2. [Project Layout & Toolchain](#2-project-layout--toolchain)
3. [Compilation Pipeline](#3-compilation-pipeline)
4. [The Zig Fork and C-ABI Boundary](#4-the-zig-fork-and-c-abi-boundary)
5. [Key Concepts](#5-key-concepts)
6. [The Three Blockers](#6-the-three-blockers)
6.5. [Recommended Solution Architecture (refined)](#65-recommended-solution-architecture-refined)
7. [Recently Landed Fixes (Context)](#7-recently-landed-fixes-context)
8. [Constraints on Solutions](#8-constraints-on-solutions)
9. [Research Questions](#9-research-questions)
10. [Appendix: Reference Files & Line Numbers](#10-appendix-reference-files--line-numbers)

---

## 1. What Is Zap

Zap is a general-purpose functional programming language that compiles to native binaries. It takes the developer experience of Elixir — pattern matching, pipe operators, algebraic types, macros — and strips away the runtime overhead. No VM, no garbage collector, no interpreter. Zap code compiles directly to machine code via LLVM.

**Core philosophy** (from the project's `CLAUDE.md`):

- **Features are implemented in Zap code**, not hardcoded in the compiler. The compiler is a general-purpose tool that knows nothing about specific Zap structs (IO, String, Math, etc.). Standard library functions, macros, test frameworks, and DSLs are all written in `.zap` source files.
- **The compiler only handles language primitives**: parsing, type system, ZIR emission, and a small set of runtime primitives that physically cannot be expressed in Zap (stdout, memory allocation, OS argv).
- **No workarounds or hacks.** Every solution must be the correct, production-grade, long-term fix.

**Technical identity:**

- Functional language with immutable data structures
- Pattern matching with multiple function clauses and guards
- Macro system with `quote`/`unquote` for AST transformation
- Compiles through Zig's ZIR (Zig Intermediate Representation) into LLVM
- Currently arena-only allocator (no free during program execution; freed on exit)
- Single native binary output (~187 MB; statically links LLVM 20 + Zig stdlib + Zap runtime)
- Built on a fork of Zig 0.16.0 maintained by DockYard

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

Several Zap properties matter for the blockers below:

- **One primary struct per file.** The file's path determines the struct's name (`zap/list.zap` ↔ `pub struct Zap.List`). Field-only "data" structs are allowed alongside the primary.
- **All values are immutable.** There is no assignment; "rebinding" `x = x + 1` is silently a no-op against an existing binding (this is a separate Zap design choice and not under discussion here).
- **All loops are recursion.** There is no `while` / `for` / `loop` construct; iteration is expressed as tail-recursive function clauses. The compiler emits `tail_call` IR for the recursive site, which lowers to LLVM `musttail`.
- **Multi-clause function dispatch.** `pub fn loop(0 :: i64) -> i64 { 0 }` and `pub fn loop(n :: i64) -> i64 { loop(n - 1) }` are two clauses of one function. The IR builder synthesizes a dispatcher that pattern-matches on the parameters.

---

## 2. Project Layout & Toolchain

There are two Git repositories on the local machine:

```
~/projects/zap/    — the Zap compiler and language (this is "Zap")
~/projects/zig/    — a fork of upstream Zig 0.16.0 ("the fork")
```

Plus a third helper repository for bootstrapping:

```
~/projects/zig-bootstrap/  — pre-built LLVM static libraries used to build the fork
```

Within the Zap repo, what matters for these blockers:

```
~/projects/zap/
├── build.zig             — Zap build script
├── build.zig.zon         — Zap version manifest
├── CLAUDE.md             — project rules / philosophy
├── docs/                 — design docs (you are here)
├── lib/                  — Zap stdlib, written in Zap (.zap files)
├── examples/             — runnable example projects
├── src/                  — Zap COMPILER, written in Zig
│   ├── parser.zig        — tokenizer + parser → ast.zig nodes
│   ├── ast.zig           — AST type definitions
│   ├── collector.zig     — symbol collection / scope graph
│   ├── desugar.zig       — AST→AST rewrites (pipes, macros, etc.)
│   ├── hir.zig           — High-level IR (HIR), pattern-match decision trees
│   ├── ir.zig            — Lower IR layer between HIR and ZIR
│   ├── zir_builder.zig   — Drives ZIR construction via fork's C-ABI
│   ├── runtime.zig       — Zap stdlib runtime functions (called from .zap via :zig.X)
│   ├── compiler.zig      — Pipeline orchestration
│   └── main.zig          — CLI entrypoint
└── zap-deps/             — pre-built libzap_compiler.a + LLVM static libs per arch
```

Within the Zig fork, what matters for these blockers:

```
~/projects/zig/
├── src/zir_builder.zig   — Builder + FuncBody types; ZIR construction primitives
├── src/zir_api.zig       — C-ABI exports (called from Zap's src/zir_builder.zig)
├── src/Sema.zig          — semantic analyzer; consumes ZIR, produces AIR
├── src/codegen/llvm/
│   ├── FuncGen.zig       — AIR → LLVM IR translation
│   └── ...               — backend-specific lowering (calling convention, ABI)
└── lib/std/zig/Zir.zig   — ZIR encoding (instruction tags, refs, payloads)
```

**Toolchain specifics on the test machine:**

- Apple M4 (AArch64), macOS 26.2, 8 MB default thread stack
- `clang` 17, `rustc` 1.91, upstream `zig` 0.16.0 (asdf)
- The Zap binary at `~/projects/zap/zig-out/bin/zap` is ~187 MB and statically links the entire fork's compiler frontend (Sema + LLVM codegen)

The fork's build produces `libzap_compiler.a` (~430 MB) which Zap's `build.zig` links against. The fork is its own standalone compiler that can also be built into a real `zig` binary, but Zap doesn't use it that way — it only uses the fork's library form.

---

## 3. Compilation Pipeline

When the user runs `zap build my_project`, the following happens:

```
.zap source files
    │
    ▼
[Parser] (src/parser.zig)
    │
    ▼ AST (src/ast.zig)
    │
    ▼
[Collector] (src/collector.zig) — builds scope graph, attribute attachment
    │
    ▼
[Macro expander] (src/macro.zig) — runs macros; some macros call back into compiled Zap via CTFE
    │
    ▼
[Desugar] (src/desugar.zig) — rewrites pipes, sigils, for-comprehensions, etc.
    │
    ▼
[Type checker] (src/types.zig) — Hindley-Milner-ish inference + nominal struct types
    │
    ▼
[HIR builder] (src/hir.zig) — pattern-match decision trees, function family resolution
    │
    ▼
[IR builder] (src/ir.zig) — explicit instruction stream; tail-call rewrite happens here
    │
    ▼
[ZIR builder] (src/zir_builder.zig) ───► C-ABI ───► [Fork's Builder] (~/projects/zig/src/zir_builder.zig)
    │                                                       │
    │                                                       ▼ ZIR (in-memory bytes)
    │                                                       │
    │                                                       ▼
    │                                              [Fork's Sema] (~/projects/zig/src/Sema.zig)
    │                                                       │
    │                                                       ▼ AIR (analyzed IR)
    │                                                       │
    │                                                       ▼
    │                                              [Fork's LLVM codegen] (~/projects/zig/src/codegen/llvm/)
    │                                                       │
    │                                                       ▼ LLVM IR → object files
    └───────────────────────────────────────────────────────►
                                                            │
                                                            ▼
                                                       [LLD] → native binary
```

The Zap-side pipeline ends at "emit ZIR via C-ABI." The Zig fork takes that ZIR through Sema, AIR, and LLVM codegen.

---

## 4. The Zig Fork and C-ABI Boundary

### What is ZIR?

**Zig Intermediate Representation (ZIR)** is the fork's language-internal representation of source code, sitting between parsing and Sema (semantic analysis). Conceptually it's like SSA but with rich semantic information attached — type expressions, comptime evaluation, scope information, etc. ZIR is what Zig's compiler frontend operates on; Sema reduces it to AIR (Analyzed IR), and the LLVM backend lowers AIR to LLVM IR.

ZIR instructions are stored as a flat array (`tags[]`, `data[]`, `extra[]`). Each instruction has a tag (e.g., `int`, `add`, `decl_val`, `struct_init`, `break_inline`) and inline data. Instructions are referenced by `Zir.Inst.Ref`, an enum where values 0..123 are *named* refs (static type refs like `i64_type`, `bool_type`, `void_type`, plus singleton values like `void_value`, `null_value`) and 124+ are instruction indices offset by `Ref.static_len`.

```zig
// ~/projects/zig/lib/std/zig/Zir.zig
pub const Ref = enum(u32) {
    u0_type,        // discriminant 0
    i0_type,        // discriminant 1
    u1_type,        // ...
    i64_type,
    f64_type,
    bool_type,
    // ... 123 named refs total ...
    pub const static_len = 124;
    _,              // anything ≥ 124 is an instruction index + static_len
};

pub fn instRef(index: u32) Zir.Inst.Ref {
    return @enumFromInt(static_len + index);
}
```

### How Zap drives ZIR construction

The fork exports a C-ABI surface from `~/projects/zig/src/zir_api.zig`. Zap's `src/zir_builder.zig` declares `extern "c"` bindings and calls into them. Examples:

```zig
// in Zap (src/zir_builder.zig)
extern "c" fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, value: i64) u32;
extern "c" fn zir_builder_emit_call(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, args: [*]const u32, args_len: u32) u32;
extern "c" fn zir_builder_set_root_fields(handle: ?*ZirBuilderHandle, name_ptrs: [*]const [*]const u8, name_lens: [*]const u32, type_refs: [*]const u32, count: u32) i32;
```

Each export takes a builder handle, parameters as primitives or pointer/length pairs, and returns either a `Zir.Inst.Ref` (as `u32`, with `0xFFFFFFFF` meaning error) or a status code.

### Body context: the `Builder` vs `FuncBody` distinction

In the fork's `~/projects/zig/src/zir_builder.zig`:

- **`Builder`** is the top-level ZIR construction context. It owns the global instruction tables (`tags[]`, `data[]`, `extra[]`, `string_bytes[]`).
- **`FuncBody`** wraps `Builder` for instructions that belong to a function body. It tracks `body_inst_indices` (instructions in the current body) and `non_body_capture` (a separate "capture list" for instructions emitted while body tracking is paused — used for guard blocks and other captured contexts).

Most ZIR-emitting C-ABI exports require an active `FuncBody`:

```zig
// ~/projects/zig/src/zir_api.zig
pub export fn zir_builder_emit_decl_val(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const body = b.active_body orelse return 0xFFFFFFFF;  // ← requires active body
    const name = name_ptr[0..name_len];
    const ref = body.addDeclVal(name) catch return 0xFFFFFFFF;
    return @intFromEnum(ref);
}
```

The `body.addDeclVal` path emits the instruction *and* appends its index to `body_inst_indices` (or to `non_body_capture` if the body is in capture mode). This matters because **Sema processes ZIR per-block; instructions that aren't in any block are not analyzed and trying to reference them produces "attempt to use null value" panics from `sema.inst_map.get(i).?`**.

### What `setRootFields` does

The Zap struct emission path eventually calls `zir_builder_set_root_fields` to attach fields to the file's root `struct_decl` (instruction index 0, hard-pinned by the fork — see comment block at `~/projects/zap/src/zir_builder.zig:1064-1070`).

```zig
// ~/projects/zig/src/zir_builder.zig (Builder, ~line 116)
pub fn setRootFields(
    self: *Builder,
    field_names: []const []const u8,
    field_type_refs: []const Zir.Inst.Ref,   // ← one Ref per field
) !void {
    // stores field_names + field_type_refs, used later in finalize()
}
```

In `finalize()` (~line 500), each field's stored `Zir.Inst.Ref` is wrapped in a 1-instruction `break_inline` that produces the field's type. The break_inline is emitted at the very end of the global instruction stream, with `block_inst = 0` (the struct_decl placeholder). Sema later analyzes each `break_inline` body in the struct_decl's evaluation context (which is the file's namespace).

```zig
// ~/projects/zig/src/zir_builder.zig (Builder.finalize, ~line 510-528)
for (type_refs) |type_ref| {
    const brk_payload_idx: u32 = @intCast(self.extra.items.len);
    try self.extra.append(self.gpa, @bitCast(@as(i32, std.math.maxInt(i32))));
    try self.extra.append(self.gpa, 0);  // block_inst = 0 (struct_decl)

    const brk_inst = try self.addInst(
        .break_inline,
        encodeBreak(type_ref, brk_payload_idx),
    );
    root_field_type_insts.appendAssumeCapacity(brk_inst);
}

// ... later, when laying out the StructDecl payload ...

// field type body lengths (one per field; each body is a single break_inline instruction).
for (0..self.root_fields_len) |_| {
    try self.extra.append(self.gpa, 1);   // ← hardcoded to 1
}

// field bodies — one break_inline inst index per field.
for (root_field_type_insts.items) |brk_inst| {
    try self.extra.append(self.gpa, brk_inst);
}
```

Two things to internalize:

1. The `type_ref` operand of each `break_inline` must be either a *named* ref (static type, no body needed — e.g., `Zir.Inst.Ref.i64_type`) or a Ref that Sema can resolve in the struct_decl's evaluation context.
2. The body length per field is *hardcoded to 1 instruction*. To embed multiple instructions in a field's type body (e.g., a `decl_val` followed by something that consumes it), this hardcoding has to change.

These two facts are central to **Blocker 1**.

---

## 5. Key Concepts

### Zap's `ZigType` representation

Zap's IR layer (`src/ir.zig`) carries types as a tagged union:

```zig
// src/ir.zig (~line 847)
pub const ZigType = union(enum) {
    void,
    bool_type,
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    f16, f32, f64, f80, f128,
    usize, isize,
    string,                              // []const u8 slice
    atom,                                // u32 interned-string id
    nil,                                 // Zig void/optional
    term,                                // runtime-tagged value (heterogeneous container element)
    tuple: []const ZigType,
    list: *const ZigType,                // generic list of T
    map: MapType,                        // generic map K → V
    struct_ref: []const u8,              // nominal struct ("Body", "Zap.Manifest")
    function: FnType,
    tagged_union: []const u8,            // currently variants are unit-only
    optional: *const ZigType,
    ptr: *const ZigType,
    never,                               // noreturn
    any,                                 // anytype escape hatch
    pub const MapType = struct { key: *const ZigType, value: *const ZigType };
    pub const FnType  = struct { params: []const ZigType, return_type: *const ZigType };
};
```

Function parameters and closure captures already carry `ZigType` in their `type_expr` field. **Struct fields, however, currently carry a stringified type**:

```zig
// src/ir.zig (~line 40)
pub const StructFieldDef = struct {
    name: []const u8,
    type_expr: []const u8,             // ← lossy! "Body" or "[]i64" as a string
    default_value: ?DefaultValue = null,
};
```

The stringification lives in `zigTypeToStr` / `typeIdToZigTypeStrWithStore` (~line 5628 and ~5663 of `src/ir.zig`). Round-tripping through a string drops the structured information needed by the ZIR builder.

### `mapTypeNameToRef`: the source of the `u0` bug

When emitting struct fields, the ZIR builder calls a helper that maps the stringified field type to a `Zir.Inst.Ref`:

```zig
// src/zir_builder.zig (~line 1228, EXACT current code)
fn mapTypeNameToRef(_: *const ZirDriver, type_name: []const u8) u32 {
    if (std.mem.eql(u8, type_name, "[]const u8")) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type);
    if (std.mem.eql(u8, type_name, "bool")) return @intFromEnum(Zir.Inst.Ref.bool_type);
    if (std.mem.eql(u8, type_name, "i64")) return @intFromEnum(Zir.Inst.Ref.i64_type);
    // ... only primitive scalars by string match ...
    if (std.mem.eql(u8, type_name, "void")) return @intFromEnum(Zir.Inst.Ref.void_type);
    return 0;  // void fallback ← LIE: 0 is u0_type, not void_type
}
```

The comment says "void fallback" but **`Zir.Inst.Ref` discriminant 0 is `u0_type`** (the empty zero-bit type), not `void_type`. Anything not in the switch (any nominal struct, list, map, tuple, term, function, …) falls through and silently produces `u0_type`. Sema then sees the field declared as `u0` and a struct literal trying to populate it produces `expected type 'u0', found 'X'`.

### Multi-clause function dispatch and capture/body tracking

When Zap sees:

```zap
pub fn loop(0 :: i64, acc :: i64) -> i64 { acc }
pub fn loop(n :: i64, acc :: i64) -> i64 { loop(n - 1, acc + 1) }
```

…it groups them into a `FunctionGroup` with two clauses and lowers them as **a single dispatcher function** in the IR. For pattern-matched dispatch, it builds a decision tree and lowers each clause body inside a **`guard_block`** IR instruction.

When lowering `guard_block` to ZIR, Zap calls `beginCapture()` / `endCapture()` (`src/zir_builder.zig:609-618`). Inside capture, instructions go to `non_body_capture` instead of `body_inst_indices`. The guard block's body Sema later analyzes is built from the captured instructions, *not* the surrounding function body.

This becomes critical when `addStructInitTyped` (in the fork) emits per-field `struct_init_field_type` instructions: if those go through raw `addInst` (no body tracking) while the surrounding `struct_init` is body-tracked, Sema sees a `struct_init` referencing field-type instructions that aren't in the captured body's instruction list, and the frontend has historically fallen back to `struct_init_anon` to dodge the broken ZIR. That fallback loses the nominal struct's identity (Zap's `%State{...}` becomes the anonymous `Loop__2__struct_NNNN`), which is what blocked multi-clause + struct-param recursion **before** the recently-landed fix (see §7).

### The `tail_call` IR instruction and LLVM `musttail`

Zap's IR has an explicit `tail_call` instruction generated by `rewriteTailCalls` in `src/ir.zig`. The ZIR builder lowers it to a regular call with the `always_tail` modifier:

```zig
// src/zir_builder.zig (~line 4151, the .tail_call case in IR translation)
.tail_call => |tc| {
    zir_builder_set_call_modifier(self.handle, 4); // 4 = always_tail
    // ... emit call ...
    const call_ref = zir_builder_emit_call(self.handle, tail_name.ptr, ...);
    if (zir_builder_emit_ret(self.handle, call_ref) != 0) { ... }
},
```

Modifier 4 maps to `std.builtin.CallModifier.always_tail` in Sema (`~/projects/zig/src/Sema.zig:7167`), which becomes AIR `.call_always_tail`, which becomes LLVM `musttail` in `~/projects/zig/src/codegen/llvm/FuncGen.zig:830`.

LLVM's `musttail` requires:

1. Caller and callee have identical calling conventions
2. Identical signatures (including ABI-affecting attributes like `byval`, `sret`)
3. **No references to the caller's stack frame survive the tail jump**

That third constraint interacts disastrously with how Zig's default `.auto` (fastcc-like) calling convention handles structs — see Blocker 3.

---

## 6. The Three Blockers

Each blocker is presented with: (a) a minimal reproducer, (b) the observed failure, (c) the root cause as best understood, (d) what was tried, (e) why each attempt failed, (f) what's needed for a real fix.

### Blocker 1: Non-primitive struct field types lower to `u0`

#### Reproducer

```zap
// /tmp/divtest/divtest.zap
pub struct Body {
  x :: f64
}

pub struct Bodies {
  sun :: Body
}

pub struct Divtest {
  pub fn main(_args :: [String]) -> u8 {
    bodies = %Bodies{sun: %Body{x: 42.0}}
    sx = bodies.sun.x
    IO.puts(Float.to_string(sx))
    0
  }
}
```

```zap
// /tmp/divtest/build.zap
pub struct Divtest.Builder {
  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
    %Zap.Manifest{
      name: "divtest", version: "0.0.1", kind: :bin,
      root: &Divtest.main/1,
      paths: ["./*.zap"],
      deps: [{:zap_stdlib, {:path, "/Users/bcardarella/projects/zap/lib"}}]
    }
  }
}
```

Build with: `cd /tmp/divtest && rm -rf zap-out .zap-cache && zap run divtest`

#### Observed failure

```
.zap-cache/divtest.zig/divtest.zig:1:1: error: expected type 'u0', found 'Body'
.zap-cache/zap_structs/Body.zig:1:1: note: struct declared here
```

Same error pattern with any non-primitive field type: `[i64]`, `[Tree]`, `%{Atom => i64}`, `Body`, `Tree` (self-reference), tuples.

#### Root cause

The chain:

1. `IrBuilder.buildProgram` walks the type store and produces `StructFieldDef` records (`src/ir.zig:1262-1283`), stringifying each field's type via `typeIdToZigTypeStrWithStore`.
2. `StructFieldDef.type_expr` is `[]const u8` (`src/ir.zig:40-44`).
3. `ZirDriver.emitNestedTypeDecl` and `ZirDriver.emitRootFields` (`src/zir_builder.zig:1019-1095`) feed each field's stringified type into `mapTypeNameToRef`.
4. `mapTypeNameToRef` only matches primitive scalar names. Anything else falls through to `return 0` (line 1255).
5. `Zir.Inst.Ref` discriminant 0 is `u0_type`. The fork's `setRootFields` `@enumFromInt(type_refs[i])` trusts the caller, lands `u0_type` in the field decl.
6. Sema later sees a struct literal trying to assign a `Body` (or `[]i64`, etc.) into a `u0` field and rejects it.

**Function and closure parameter types do NOT have this bug** — they go through `emitImportedTypeRef` (`src/zir_builder.zig:685-743`), which already handles the full `ZigType` vocabulary (`.struct_ref`, `.list`, `.map`, `.tuple`, etc.). The bug is specific to struct *field* types because (a) they get stringified before reaching the ZIR builder and (b) the helper they ultimately reach (`mapTypeNameToRef`) only handles primitives.

#### What was tried

**Attempt 1** — replace `mapTypeNameToRef(field.type_expr)` with `emitImportedTypeRef(field.type_expr)` (after also changing `StructFieldDef.type_expr` to `ZigType`).

**Why it failed**: `emitImportedTypeRef` calls `zir_builder_emit_*` functions (e.g., `zir_builder_emit_field_val`, `zir_builder_emit_call_ref`, `zir_builder_emit_typeof`) — every one of these requires an active function body (`b.active_body orelse return 0xFFFFFFFF`). The struct field decl path runs *outside any active body*. The call returned `error_ref`, which the caller propagated as `error.EmitFailed`, surfacing as the bare "Error: compilation failed" with no diagnostic until the catch handler was patched to print the error name.

**Attempt 2** — add a new C-ABI export `zir_builder_emit_decl_val_unbound` that emits `decl_val` directly via `Builder.addInst` (no `FuncBody` required), use its returned Ref as the field type ref.

```zig
// experimental, since reverted, in ~/projects/zig/src/zir_api.zig
pub export fn zir_builder_emit_decl_val_unbound(
    handle: ?*ZirBuilderHandle,
    name_ptr: [*]const u8,
    name_len: u32,
) callconv(.c) u32 {
    const b = getBuilder(handle) orelse return 0xFFFFFFFF;
    const name = name_ptr[0..name_len];
    const start = b.internString(name) catch return 0xFFFFFFFF;
    const idx = b.addInst(.decl_val, zir_builder.Builder.encodeStrTok(start, .zero)) catch return 0xFFFFFFFF;
    return @intFromEnum(zir_builder.Builder.instRef(idx));
}
```

**Why it failed**: Sema panics with `attempt to use null value` at `sema.inst_map.get(i).?`. The decl_val instruction was emitted at the global level, outside any block. Sema processes instructions block-by-block, populating `inst_map` per block. When processing the field's `break_inline` body, Sema tried to resolve the operand (the decl_val Ref), looked it up in the current block's `inst_map`, and found nothing — the decl_val was never analyzed in this block because it's not part of this block. Failed at runtime with a stack trace ending in `Sema.zig:2038: return sema.inst_map.get(i).?`.

#### What a real fix looks like

The decl_val (or equivalent) instruction needs to be **inside the field's own type body** — *not* at file scope, *not* in any function body, but in the per-field body that `finalize` synthesizes. Sema processes each field type body as its own analysis block; instructions emitted there get added to the block's `inst_map` and can be safely referenced.

This requires:

1. **Extend `setRootFields`** to accept richer per-field information. Two viable encodings:
   - **(a)** A parallel array of "field type kinds" — each entry is a tagged union of `{ static_ref: Zir.Inst.Ref }`, `{ decl_val_name: []const u8 }`, or `{ body: []const Inst }` (most general).
   - **(b)** A per-field-call API: `zir_builder_set_root_field(handle, field_idx, name, kind, payload)` then `zir_builder_finalize_root_fields(handle)`.
2. **Modify `finalize`** to emit a multi-instruction body per field where needed:
   ```zig
   for each field:
       if field.kind == .static_ref:
           emit break_inline(operand=ref, block=struct_decl_idx_0)
           body = [break_inline]
       elif field.kind == .decl_val_name:
           dv_idx  = addInst(.decl_val, encodeStrTok(intern(name), .zero))
           brk_idx = addInst(.break_inline, encodeBreak(instRef(dv_idx), payload))
           body = [dv_idx, brk_idx]
       elif field.kind == .body:
           emit each instruction in the body in order
           body = those instruction indices
   ```
3. **Update Zap-side**: change `StructFieldDef.type_expr` from `[]const u8` to `ZigType`, switch `emitNestedTypeDecl` / `emitRootFields` to emit the right kind based on the `ZigType` shape.

For complex types like `[Tree]` the body would be a short multi-instruction
sequence matching the current `emitImportedTypeRef` path: emit the runtime
`List(Tree)` cell reference, fetch its `empty` function, call it, then emit
`typeof` on the empty-list value. The same logic, just plumbed through the new
multi-instruction path.

#### Estimated effort

~150-300 lines: API extension + `finalize` rework in the fork, plus call-site update in Zap. Tests: `/tmp/divtest` reproducer above, plus variants for `[i64]` and `%{Atom=>i64}`.

---

### Blocker 2: Recursive value-typed self-references blow up Zig's "infinite size" check

#### Reproducer (will only become reachable AFTER Blocker 1 is fixed)

```zap
pub struct Tree {
  left :: Tree
  right :: Tree
}
```

#### Expected failure (post-Blocker-1)

Once Blocker 1 lets the field type lower to a real `Tree` ref, Zig's struct-layout check rejects the type with "struct type has infinite size" — a `Tree` value contains two `Tree` values directly, infinitely.

#### Root cause

Value-typed self-reference in any struct-of-value language (C, Zig, Rust) requires indirection. Rust's `Box<Tree>`, OCaml's tagged-union default of pointer-chasing, C's `struct Tree { struct Tree *left; }` all do the same thing: the recursive child is a pointer, not an inlined value.

Zap doesn't currently expose `*T` or `?*T` as user syntax. Users write `Tree`. The compiler must auto-promote.

#### What needs to happen

At the HIR layer (or ir layer):

1. Compute strongly-connected components over the struct dependency graph (which struct's fields reference which other structs).
2. For any struct whose fields transitively reach back to the struct itself, mark those self-referential fields.
3. Lower marked fields' types from `T` to `?*T` (optional pointer to T) at the type level.
4. At construction sites (`%Tree{ left: subtree, right: subtree }`):
   - Heap-allocate each recursive child via the runtime arena.
   - Wrap in `?*T` (Some-pointer for the value, `null` for absent children).
5. At access sites (`tree.left.value`):
   - Auto-deref the optional pointer.
   - For pattern matching, bind variables to the deref'd value.

The arena allocator is already in place (`src/runtime.zig`). Existing struct construction goes through `emitAlloc` in some paths (see `src/zir_builder.zig:4621-4645`); this just generalizes that behavior to be triggered by self-reference detection rather than by explicit ARC reuse pairs.

#### Estimated effort

~150-300 lines, mostly in `src/hir.zig` (SCC detection + field marking) and `src/zir_builder.zig` (alloc + store at construction, deref at access). Patterns: most invasive to get right is `case tree { %Tree{left: l} -> ... }` where `l` should bind to the deref'd subtree, not the optional pointer.

---

### Blocker 3: TCO doesn't work for byref-shaped state (n-body at scale)

#### Reproducer

```zap
pub struct State {
  a :: f64
  b :: f64
  // ... many more f64 fields ...
}

pub struct Loop {
  pub fn run(state :: State, n :: i64) -> State {
    if n == 0 {
      state
    } else {
      Loop.run(advance(state), n - 1)
    }
  }
}
```

For any deep recursion (n ≥ ~22000 on macOS's 8 MB default stack), this segfaults.

The pattern-match form (would TCO if it could):

```zap
pub fn run(state :: State, 0 :: i64) -> State { state }
pub fn run(state :: State, n :: i64) -> State {
  Loop.run(advance(state), n - 1)
}
```

Before the recently-landed Fix 3 (see §7), this used to compile-fail with `LLVM ERROR: failed to perform tail call elimination on a call site marked musttail`. Now it compiles; but the byref-guard intentionally **doesn't** emit `tail_call` for byref signatures, so the recursion just builds a real stack frame each iteration. Same segfault outcome at depth ≥ ~22k.

#### Root cause

Under Zig's default `.auto` (fastcc-like) calling convention, structs are classified as `byref` for any non-zero size:

```zig
// ~/projects/zig/src/codegen/llvm/FuncGen.zig:7223 (isByRef predicate, paraphrased)
fn isByRef(ty: Type, ...) bool {
    // ...
    if (ty.is(.@"struct") and ty.abiSize() > 0) return true;
    // ...
}
```

`firstParamSRet` has a similar rule at line ~6916: if the return type is byref, the function takes an extra implicit `sret` parameter (a pointer to a caller-allocated buffer where the callee writes the result).

For `Loop.run(state :: State, n :: i64) -> State`:

- `state` is passed as `*State` pointer (byref) — pointing to a caller-frame alloca.
- The return type `State` is returned via `sret` — pointing to a fresh caller-frame alloca for the result.

When the function tail-calls itself, both pointers would have to survive the tail jump:
- The new `state` alloca for `advance(state)` lives in the caller's frame.
- The recursive call's `sret` buffer also lives in the caller's frame.

LLVM's `musttail` guarantees no caller-frame references survive the call — the entire caller frame must be torn down before the jump. With byref/sret pointers escaping into the call, LLVM IR validation rejects with "failed to perform tail call elimination on a call site marked musttail."

Primitive-only recursion works fine because no caller-frame allocas are involved — the args ride in registers and the return rides in registers (or the implicit `inreg` SSE slot for `f64`).

#### Three plausible fix paths

**Option A — Heap-promote the recursion state at the IR level (Zap-side, recommended)**

Detect in `src/ir.zig`:

- A function is tail-recursive (already detected in `rewriteTailCalls`).
- One or more parameters are byref-shape (struct, tuple, list, map, …).
- The function is "shape-stable" — every clause's params have identical nominal types.

Transform into an entry/inner pair:

```zap
// before:
fn run(state :: State, n :: i64) -> State {
  if n == 0 { state }
  else { run(advance(state), n - 1) }
}

// after (compiler-synthesized):
fn run_inner(state_ptr :: *State, n :: i64) -> State {
  if n == 0 {
    state_ptr.*
  } else {
    state_ptr.* = advance(state_ptr.*)
    run_inner(state_ptr, n - 1)        // ← scalar pointer, musttail safe
  }
}
fn run(initial :: State, n :: i64) -> State {
  state_ptr = arena.create(State, initial)
  run_inner(state_ptr, n)
}
```

Now the recursive call passes a `*State` (scalar pointer, fits in a register) and `i64` — both register-passable, no caller-frame escape, `musttail` succeeds. One heap allocation per outer call, negligible vs. the TCO win.

The mutation `state_ptr.* = advance(state_ptr.*)` is internal to the synthesized inner function. Source-level Zap remains immutable; the user's program semantics are preserved.

**Option B — Teach Zig fastcc to pass small HFAs in registers (Zig fork ABI work)**

The AArch64 PCS (Procedure Call Standard) defines homogeneous floating aggregates (HFAs): structs containing up to 4 floats of the same type pass in registers V0–V3. Zig's fastcc currently doesn't apply this rule and falls back to byref for any non-zero struct.

Modifying `~/projects/zig/src/codegen/llvm/FuncGen.zig`:

- `isByRef`: add HFA detection — if the struct is an HFA of ≤ 4 floats (or extend to integers), return false.
- `firstParamSRet`: same.
- The call-emission path needs to pack/unpack the registers when an HFA is split.
- `musttail` would then succeed because both sides agree on register-packed signatures.

This benefits every Zig user, not just Zap. It's the principled answer for upstream Zig long-term but a heavy commitment with extensive testing requirements.

**Option C — Add explicit iteration constructs to Zap**

A new keyword (`loop n times`, `repeat n`, `for_each_index N`) that compiles directly to a Zig `while` (LLVM `br` + phi) rather than desugaring to a tail-recursive function. Bypasses the `musttail` issue entirely for the common "do this N times" pattern.

Conflicts with Zap's "everything is recursion" design philosophy and would need language-design sign-off. Solves the immediate problem (n-body) but leaves general byref-tail-call-recursion broken.

#### Estimated effort

- **Option A**: ~400-500 lines Zap, no fork changes.
- **Option B**: ~500-1000 lines Zig fork, large test surface, affects all of Zig.
- **Option C**: ~300-500 lines Zap, but breaks the design invariant.

---

## 6.5 Recommended Solution Architecture (refined)

§6 captured what was tried during initial investigation. After deep external research, the designs below refine those recommendations. **The implementation should follow these, not the per-blocker "what needs to happen" sketches above.**

### Blocker 1 — streaming per-field-body API (NOT tagged-union encoding)

The fork's `Builder.setRootFields(names, type_refs)` is replaced with a **streaming inline-body recorder** so Zap can reuse its existing `emitImportedTypeRef` logic (which already handles every `ZigType` variant in body context) without re-encoding the type algebra over the C-ABI.

C-ABI surface:

```c
// Begin recording the type body for one field. Pushes a new
// active body onto Builder so that subsequent zir_builder_emit_*
// calls capture into this field's body instead of the (absent)
// function body. Returns 0 on success, -1 on error.
zir_builder_begin_root_field_type_body(handle, name_ptr, name_len) -> i32;

// Finish the current root field type body. final_ref is the Ref
// the body produces (the type expression's result). Pops the
// active body. Returns 0 on success, -1 on error.
zir_builder_end_root_field_type_body(handle, final_ref) -> i32;
```

`Builder` storage changes from a parallel `(names[], type_refs[])` to:

```zig
pub const RootField = struct {
    name: []const u8,
    body: union(enum) {
        // common case: primitive scalar / named ref. finalize() emits
        // a 1-instruction `break_inline operand=ref` body, identical
        // to today's behavior.
        static_ref: Zir.Inst.Ref,
        // multi-instruction body. finalize() copies these instruction
        // indices into the field's body trailer, then appends a
        // `break_inline operand=final_ref`. body length = inst_count + 1.
        recorded: struct {
            instructions: []const u32,
            final_ref: Zir.Inst.Ref,
        },
    },
};
root_fields: []RootField,
```

`finalize()` (`~/projects/zig/src/zir_builder.zig:500-612`) iterates root_fields. For each field's body it emits all recorded instructions in order, then a `break_inline` whose operand is `final_ref`, then writes the body length (`recorded.instructions.len + 1` or `1` for static_ref) and body inst indices into the StructDecl payload trailer. The hardcoded `body_lengths[i] = 1` at line ~580 becomes per-field.

Zap-side (`src/ir.zig`, `src/zir_builder.zig`):

- `StructFieldDef.type_expr` becomes `ZigType` (already proven safe earlier).
- `emitNestedTypeDecl` and `emitRootFields` for each field call `begin_root_field_type_body(name)`, then dispatch on the `ZigType` shape to a body-context emitter — primitive → `mapReturnType` → `end_root_field_type_body(static_ref)`; struct_ref / list / map / tuple → reuse the **same `emitImportedTypeRef` helper that's already used for parameters**, taking its returned Ref and passing it to `end_root_field_type_body`.
- The tagged-union path through `mapClosureEnvFieldTypeRef` becomes consistent with this once tagged unions with payloads are in scope (out of scope for this fix; current unit-only unions still resolve to `u32_type`).

### Blocker 2 — storage-strategy metadata, NOT auto-`?*T`

The original recommendation (auto-rewrite recursive `T` field to `?*T`) conflates two distinct concerns. The correct design separates them:

- **Layout recursion** is broken by internal indirection (a hidden pointer that the user never sees).
- **Source nullability** stays exactly as written. If the user wrote `Tree`, the field semantically holds a `Tree`. If they wrote `?Tree`, it semantically holds an optional.
- **Inhabitation** (does the type have a finite base case?) becomes its own diagnostic.

Pattern matching binds source-level values, not storage-level pointers. `case node { %Tree{left: l} -> ... }` binds `l` as a `Tree`. The auto-deref happens at codegen, not in the source semantics.

Implementation:

1. After type checking (in `src/types.zig` or an early HIR pre-pass), compute SCCs over the nominal-struct dependency graph. A field's type belongs to the same SCC as the enclosing struct iff the field type transitively reaches back to the enclosing struct.
2. For each field in a recursive SCC, attach a `storage` annotation:
   - `direct`: non-recursive field, lower as value type (current behavior).
   - `indirect`: recursive field, lower the runtime layout as `*T` (or `?*T` if the source field is itself optional). This is invisible at the source level.
3. Lower at IR/ZIR codegen:
   - **Construction** (`%Tree{left: x, right: y}`) — for `indirect` fields, heap-allocate via the runtime arena and store the pointer.
   - **Field access** (`tree.left`) — for `indirect` fields, auto-deref. Pattern matching re-uses the same auto-deref to bind source-level values.
4. **Diagnostics**: if a struct's SCC has no reachable non-recursive base case (every constructor requires another instance of itself transitively), emit a clear error: "this recursive type has no finite base case; consider an optional child or a tagged-union leaf constructor." Today's "infinite size" message lands far from the actual user mistake.

This mirrors how Rust requires explicit `Box<T>` (no auto-`Option`), Crystal requires explicit pointers, and OCaml's uniform boxed runtime makes recursive types natural without changing source meaning. None of these languages collapse "indirect storage" with "potentially absent."

### Blocker 3 — IR-level loopification (primary), heap-promotion (fallback)

Replace the original heap-promotion-as-primary recommendation with **loopification as primary**. Loopification has zero hot-path allocation and bypasses LLVM `musttail` legality entirely.

The dispatcher Zap already synthesizes for multi-clause functions (the decision-tree in `src/ir.zig:1712-1764`) is the natural loop entry. A self-tail call that lands back at the same dispatcher is a recurrence — instead of emitting a `tail_call` IR instruction, emit slot updates and a branch back to the dispatcher's entry.

Implementation in `src/ir.zig`:

1. After `rewriteTailCalls` runs, scan the function. If every detected tail call is to the same function (self-recursion only) AND every clause's parameters have shape-stable types (same `ZigType` at each position across all clauses), the function is a **loopification candidate**.
2. For each loopification candidate, allocate parameter slots at the function's entry (one per parameter; either as a Zig stack alloca for register-shaped types or as one block of memory for byref-shaped types).
3. At the dispatcher's entry, emit `param_set` from the actual entry params into slots.
4. Replace each `tail_call` with: store new arg values into slots, then `br dispatcher_entry`.
5. Each clause body's local references to the function's parameters now read from slots, not from the function entry. Existing `param_get` instructions get rewritten to `slot_get`.
6. The dispatcher's entry block becomes the loop header. Slots act as loop-carrying state; LLVM's mem2reg lifts them into phi nodes for register-shaped state, or keeps them as stack allocas for byref state. Either way, no recursive call survives.

For functions that don't fit loopification (mutual recursion across families, escape-analysis failure), fall back to the documented heap-promotion design from the original §6.

This completely removes Zap's dependency on LLVM `musttail` for byref state. The Fix C byref-guard in `rewriteTailCalls` (already shipped) is the correctness floor; loopification is the perf upgrade that makes byref-state recursion bounded-stack.

---

## 7. Recently Landed Fixes (Context)

These fixes shipped during the investigation. They unblock the *compile path* but not the runtime/scale path. Including them so the research agent doesn't waste time re-investigating already-fixed bugs.

### Status update (later session)

Three additional fixes landed after the original brief was written:

- **Blocker 1 fully resolved** (fork: `8352916bdb`, Zap: `3b3eec9`). Streaming per-field-body API in the fork; Zap migrated to `ZigType` field types and routes non-primitive field types through `emitImportedTypeRef` in body context. The `Body { x :: f64, ... }` + `Bodies { sun :: Body, jupiter :: Body }` hierarchy now compiles and runs end-to-end. Verified with a `pair_dist(bs.sun, bs.jupiter) -> f64` function that crosses struct boundaries and returns a primitive.

- **Blocker 2 substantial progress** — five commits across the fork (`7c5d77c5e8`) and Zap (`f175a43`, `714554d`, `d629878`). What's working end-to-end as of this session:
  - Storage-strategy detection (self-recursion via `zigTypeReachesStruct`).
  - Indirect-field type lowering (`?T` → `?*const T`, `T` → `*const T`) via the streaming root-field-body API.
  - Two-pass type-checker registration so `pub struct Tree { left :: Tree | nil }` resolves the recursive `Tree` correctly.
  - Construction codegen: `%Tree{left: subtree}` heap-promotes the subtree value (`alloc + store + make_ptr_const`) and Zig coerces `*const Tree` to the `?*const Tree` field. `nil` short-circuits the promotion.
  - Reading non-recursive fields of a recursive struct: `t.value` works (Zig auto-derefs through pointers transparently for direct-storage fields).
  - Multi-clause recursive functions returning a recursive type: `make(0)` / `make(d)` building trees of arbitrary depth.
  - Verified: `pub struct Tree { value :: i64, left :: Tree | nil, right :: Tree | nil }` plus a `make(d :: i64)` tree-builder compiles and runs end-to-end.

  **Field-access auto-deref shipped** (Zap: `591a9ed`). `FieldGet` IR now
  carries the receiver's struct nominal name (resolved via
  `IrBuilder.structTypeForFieldReceiver`); the ZIR builder consults
  `FieldStorage` and emits the inverse of `heapPromoteForIndirectField` —
  `load` for `*const T`, or an `if (ptr) |p| @as(?T, p.*) else null`
  branch for `?*const T`. Verified with `t.left == nil`, passing an
  indirect field directly into a `?T` parameter, and `t.left != nil`
  predicates. Three new tests in `test/struct_test.zap` lock in the
  read shape.

  **Still open for full binary-trees benchmark**:
  - Pattern matching on `?Tree` for the `case t.left { nil -> A; l -> B }`
    shape: bare bind `l ->` keeps source-level `?T` (Elixir semantics).
    Either typed-bind narrowing (`l :: Tree -> ...`) or struct-destructure
    (`%Tree{} = l ->`) needs to be wired through the pattern compiler so
    `B` sees `l` as `Tree` and the recursive call type-checks.
  - Multi-clause dispatch on `count(nil)` vs `count(t :: Tree)` —
    dispatcher must unify the param type to `?Tree` (the union) and emit a
    null check, not compare `Tree` to null.
  - Uninhabited-recursive-type diagnostics (a struct in a recursion cycle
    whose every constructor requires another instance).
  - Mutual-recursion via SCC analysis (today's walker only detects
    self-recursion; documented inline in `zigTypeReachesStruct`).

- **Blocker 3 still open**. Loopification is the right primary path per the refined recommendations (§6.5). Implementation sketch: wrap function bodies in a ZIR `loop` block, allocate stack slots for each parameter, redirect `param_get` to slot loads, replace each `tail_call` IR instruction with slot-update + `repeat`. This bypasses LLVM `musttail` entirely so byref-shaped state runs bounded-stack. Estimated scope: 300-500 lines in `src/ir.zig` + `src/zir_builder.zig`. Not started.

The byref-guard from earlier (Fix C) remains in place as the correctness floor — it stops `musttail` from being marked on byref signatures so the compile path stays clean even without loopification.

### Fix A — `struct_init_field_type` body tracking (in fork)

Commit `7234629... zir_builder: body-track struct_init_field_type instructions` on branch `zap-zir-library-0.16` of `~/projects/zig`.

**Was**: `addStructInitTyped` (at `~/projects/zig/src/zir_builder.zig:2294-2337`) emitted per-field `struct_init_field_type` instructions via raw `b.addInst(...)`, bypassing body-tracking. Inside captured guard-block bodies (multi-clause function dispatch arms), those instructions floated free of the captured body's instruction list. The Zap frontend worked around it with `capture_depth == 0` guards that fell back to `struct_init_anon`, losing nominal struct identity.

**Fix**: Added a sibling helper `emitBodyInstIdx` that returns the raw `u32` instruction index (needed by the surrounding `struct_init` payload) but does the same body/capture tracking as `emitBodyInst`. Routed `struct_init_field_type` emission through it.

### Fix B — drop `capture_depth` band-aids (in Zap)

Commit `3c22147 fix: drop capture_depth band-aids around struct_init_typed` on `~/projects/zap`.

**Was**: Three places in `src/zir_builder.zig` (~lines 4587, 4627, 4652) gated `struct_init_typed` on `current_function_is_closure and capture_depth == 0`, falling back to `struct_init_anon` in captured contexts. With Fix A, this is no longer necessary.

**Fix**: Removed the `capture_depth == 0` half of each guard. The closure-related half stays — closures genuinely can't resolve struct-level decl_val refs from inside their environment.

### Fix C — TCO byref guard (in Zap)

Commit `50de586 fix: gate tail-call rewrite on by-value parameter types` on `~/projects/zap`.

**Was**: `rewriteTailCalls` in `src/ir.zig` produced `tail_call` IR for any tail-position call, including those with byref-shaped parameters. The ZIR builder lowered every `tail_call` to LLVM `musttail`, which then failed during LLVM's tail-call-elimination pass for byref signatures.

**Fix**: Added `isTcoSafeType(t: ZigType)` and `isTcoEligible(params, return_type)` predicates. `rewriteTailCalls` bails out without rewriting when any parameter type or the return type is byref. The recursion stays as `call_named + ret`, which LLVM treats as a normal call. No TCO, but compiles cleanly. Three new tests cover the predicate, the byref-guarded case, and the still-rewritten primitive case.

This is what makes Blocker 3 a "scale" problem rather than a "compiles" problem today.

---

## 8. Constraints on Solutions

- **No workarounds or hacks.** From the project's `CLAUDE.md`: "Every solution must be the correct, production-grade, long-term fix — regardless of how difficult, expensive, or time-consuming it is."
- **Features in Zap, not in the compiler.** Anything that *can* be implemented in Zap source (`lib/*.zap`) MUST be. The compiler is a general tool that doesn't know about specific Zap structs.
- **Test coverage required.** TDD: write failing tests first, implement the minimum to pass, then verify the entire test suite (`zig build test` in both repos, plus `zap test` in the Zap repo, plus all 24 example projects).
- **Zap test suite**: 810 tests in the Zap repo (`./zig-out/bin/zap test`).
- **Zig fork test suite**: 671 tests (`zig build test`). Both must stay green.
- **All 24 examples** in `~/projects/zap/examples/` must continue to compile and produce expected output.
- **Backwards-compatibility hacks are forbidden.** When refactoring, fully commit to the new approach. Remove old code entirely.
- **One struct per file.** When adding new structs (e.g., for a new IR pass), each goes in its own file matching the path.
- **macOS thread-stack ceiling is 8 MB.** Solutions that work only on Linux (where `ulimit -s unlimited` is available) are not acceptable.

---

## 9. Research Questions

The agent should investigate, and produce a recommended approach with concrete implementation guidance for, each of:

### Q1: Multi-instruction per-field type bodies in `setRootFields`

- What is the minimal API change to `~/projects/zig/src/zir_builder.zig` (`Builder.setRootFields` and `Builder.finalize`) and `~/projects/zig/src/zir_api.zig` to support per-field type bodies of variable length?
- Should the API accept a tagged union per field, a parallel array of "kinds" + payloads, or a streaming per-field-call API?
- How does Sema actually evaluate each field type body — what scope does it process them in, and what existing Sema test cases (in the fork's test suite, look in `~/projects/zig/test/`) exercise the multi-instruction-field-body path?
- Is there an existing struct_decl emission path in upstream Zig that already produces multi-instruction field bodies? If so, what does its ZIR layout look like — find and quote a concrete example.
- Estimate exact line counts and which files need to change.
- Provide a worked-out example of the ZIR encoding for a struct with one nominal field (`pub struct Bodies { sun :: Body }`) post-fix.

### Q2: Self-referential struct field auto-promotion

- What's the cleanest place in Zap's pipeline (`src/hir.zig`? `src/types.zig`? `src/ir.zig`?) to detect self-referential struct fields and rewrite them?
- How should pattern matching interact with auto-`?*T`-promoted fields? For example, `case node { %Tree{left: l} -> ... }` — is `l` the optional pointer, the deref'd `Tree` value, or a smart binding that auto-derefs?
- What's the runtime memory model — does the construction `%Tree{left: x, right: y}` allocate `x` and `y` on the heap, or are they expected to already be heap pointers?
- Are there existing precedents in similar functional-with-pointer-types systems (OCaml, Rust, Crystal) for how this auto-lowering should be presented in error messages?
- How does Atomic Reference Counting (ARC, Zap's memory model) play with auto-promoted optional pointers?

### Q3: TCO for byref-shaped recursion state

- For Option A (heap-promote in IR): work out the exact IR transformation. What detection is needed in `src/ir.zig` `rewriteTailCalls` to identify candidates? What does the rewritten IR look like?
- For Option B (Zig fastcc HFA): is there an existing PR/issue/discussion in upstream Zig about HFA support in fastcc? Look at https://github.com/ziglang/zig and search for "HFA", "homogeneous floating aggregate", "fastcc struct args."
- For Option B specifically: how does Rust handle the equivalent case in their codegen — they target the same AArch64 ABI but seem to TCO `Box<State>`-shaped state without issue. Is it heap promotion at MIR level or fastcc differences?
- Which option does the research agent recommend as the primary path, and what's the engineering cost/benefit tradeoff?
- For Option A: what failure modes exist? E.g., what if a multi-clause function has *some* clauses that mutate state and others that don't — can heap promotion still apply uniformly?
- For Option A: how does this interact with Zap's ARC model? Does the heap-promoted state need ARC tracking, or is it private to the recursive function and can be skipped?

### Q4: Cross-cutting concerns

- Do the proposed fixes interact with existing closure-environment lowering (`src/zir_builder.zig:910-1008`)? Closures heap-allocate their environment; do the patterns generalize?
- Does the existing `@native_type` machinery (List, Map, Range, String — runtime-tagged types in `src/runtime.zig`) provide a template for how Tree-style heap-indirected user types should work?
- Are there ZIR primitives in the fork that Zap's frontend isn't currently using which would simplify any of these fixes? Look at `~/projects/zig/lib/std/zig/Zir.zig` for the full instruction tag list.

---

## 10. Appendix: Reference Files & Line Numbers

### Zap repo (`~/projects/zap`)

- `src/ir.zig:40-44` — `StructFieldDef` (the type to refactor for Blocker 1)
- `src/ir.zig:847-896` — `ZigType` tagged union (the structured type to migrate to)
- `src/ir.zig:1262-1283` — where `StructFieldDef` is currently populated with stringified types
- `src/ir.zig:1984-2090` — `rewriteTailCalls` (Blocker 3 site)
- `src/ir.zig:1994-2042` — `isTcoSafeType` and `isTcoEligible` (Fix C; the new byref guard)
- `src/zir_builder.zig:685-743` — `emitImportedTypeRef` (works in body context only — ref but don't reuse for field types)
- `src/zir_builder.zig:915-932` — `mapClosureEnvFieldTypeRef` (similar pattern, also primitive-only)
- `src/zir_builder.zig:1019-1095` — `emitNestedTypeDecl` and `emitRootFields` (Blocker 1 call sites)
- `src/zir_builder.zig:1178-1222` — `emitStructTypeRef` (for struct refs in body context)
- `src/zir_builder.zig:1235-1256` — `mapTypeNameToRef` (the buggy primitive-only mapper, the source of `u0`)
- `src/zir_builder.zig:4151-4177` — `tail_call` lowering (sets musttail call modifier)
- `src/zir_builder.zig:4584-4680` — three `struct_init` emit paths (post-Fix-B; band-aids removed)
- `src/runtime.zig` — Zap stdlib runtime functions and arena allocator
- `examples/` — 24 working examples for regression testing
- `lib/zap/manifest.zap` — example of a field-only struct that "works" today only because it's never `struct_init_typed`'d (hides the `u0` field types)

### Zig fork (`~/projects/zig`, branch `zap-zir-library-0.16`)

- `src/zir_builder.zig:49-50` — `Builder.root_field_names` and `root_field_type_refs` (current per-field state)
- `src/zir_builder.zig:116-158` — `Builder.setRootFields` (Blocker 1: the API to extend)
- `src/zir_builder.zig:171-181` — `Builder.instRef` and `Builder.addInst`
- `src/zir_builder.zig:500-612` — `Builder.finalize` (the per-field break_inline emission; Blocker 1: the body-length 1 hardcoding is at line ~580, the body-instruction trailer is at ~587)
- `src/zir_builder.zig:1218-1240` — `FuncBody.emitBodyInst` and `emitBodyInstVoid`
- `src/zir_builder.zig:2294-2337` — `addStructInitTyped` (post-Fix-A; uses body tracking for field-type instructions)
- `src/zir_api.zig:1138-1163` — `zir_builder_set_root_fields` C-ABI export (the surface that Zap consumes)
- `src/zir_api.zig:2554-2564` — `zir_builder_emit_decl_val` (the body-bound version)
- `src/Sema.zig:2038` — `sema.inst_map.get(i).?` (the assertion that fails when an instruction isn't in any analyzed block)
- `src/Sema.zig:7167` — call modifier 4 → `always_tail` mapping
- `src/codegen/llvm/FuncGen.zig:830` — AIR `.call_always_tail` → LLVM `musttail`
- `src/codegen/llvm/FuncGen.zig:6916` — `firstParamSRet` (Blocker 3 ABI rule)
- `src/codegen/llvm/FuncGen.zig:7223` — `isByRef` (Blocker 3 ABI rule)
- `lib/std/zig/Zir.zig:2226` — `Zir.Inst.Ref` enum (discriminant 0 is `u0_type` — the source of the silent bug in `mapTypeNameToRef`)

### Build commands

To rebuild the fork's libzap_compiler.a after changes:

```sh
cd ~/projects/zig
zig build lib \
  --search-prefix ~/projects/zig-bootstrap/out/host \
  --search-prefix /tmp/zap-build-prefix \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

(`/tmp/zap-build-prefix/lib` should contain `libz.a` and `libzstd.a` symlinked from `~/projects/zap/zap-deps/aarch64-macos-none/llvm-libs/`.)

To rebuild Zap pointing at the new .a:

```sh
cd ~/projects/zap
zig build \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=$HOME/projects/zap/zap-deps/aarch64-macos-none/llvm-libs
```

To run the regression suite:

```sh
# Zig-level tests in the Zap repo
cd ~/projects/zap && zig build test --summary all   # expects 671/671

# Zap-level tests
./zig-out/bin/zap test                              # expects 810/810

# All examples
for d in examples/*/; do
  name=$(basename "$d")
  (cd "$d" && rm -rf zap-out .zap-cache && timeout 30 ../../zig-out/bin/zap run "$name" >/dev/null 2>&1; echo "$name: exit=$?")
done
```

---

## End of brief

The agent's deliverable should be a written analysis covering all four research questions with file-and-line precision, recommended approaches for each blocker (preferring the most cost-effective principled fix, not workarounds), and concrete implementation sketches that someone could turn into PRs against `~/projects/zig` and `~/projects/zap` without further investigation. Where the agent's recommendation differs from this document's suggestions, the agent should explain why.
