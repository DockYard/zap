# Research: Function Type Propagation Through Zap's Compilation Pipeline

## Problem Statement

Zap is a functional programming language that compiles to native code via Zig's compiler backend. Functions are first-class values — they can be passed as arguments, returned from functions, and stored in data structures. This works at the language level but breaks during code generation: **function-typed values become `void` when crossing struct boundaries in the generated ZIR**, causing 21 compilation errors in the test suite.

## Architecture Overview

Zap's compilation pipeline:

```
.zap source → Parse → Collect → Macro Expand → Desugar → Type Check → HIR → IR → ZIR → Zig Sema → LLVM → Native
```

The critical handoff is **IR → ZIR**. The IR (intermediate representation) is Zap's low-level SSA-like format. ZIR is Zig's internal representation that feeds into Zig's semantic analysis (Sema) and then LLVM codegen.

Zap uses a **forked Zig compiler** (`~/projects/zig`) that exposes ZIR construction via a C-ABI surface (`zir_api.zig`). The Zap compiler builds ZIR by calling C functions like `zir_builder_emit_call`, `zir_builder_emit_param`, `zir_builder_emit_decl_ref`, etc.

### Per-Struct Compilation

Each Zap struct (one per `.zap` file) is compiled independently through the pipeline, producing its own ZIR struct. Cross-struct references use `@import("StructName").function_name`. The Zig compiler links all structs together.

Example: `Enum.map([1,2,3], doubler)` in a test struct becomes:
```zig
// In Test_MyTest.zig (ZIR)
@import("Enum").map__2(list_ref, doubler_ref)
```

And inside the Enum struct:
```zig
// In Enum.zig (ZIR)
pub fn map__2(list: ListType, callback: anytype) ListType {
    return @import("zap_runtime").ListCell.mapFn(list, callback);
}
```

And in the runtime:
```zig
// In zap_runtime.zig
pub fn mapFn(list: ?*const ListCell, callback: anytype) ?*const ListCell {
    while (current) |cell| {
        result = cons(callback(cell.head), result);  // <-- ERROR: callback is void
    }
}
```

## The Bug

When `doubler` (a function reference) is passed from `Test_MyTest` → `Enum.map__2` → `ListCell.mapFn`, Zig's Sema sees the `callback` argument as `void` by the time it reaches `mapFn`. The error: `type 'void' not a function`.

### Why It Happens

The ZIR builder (`src/zir_builder.zig`) uses a `local_refs` hash map to track the ZIR instruction ref for each IR local variable. When emitting a function call's arguments, it looks up each argument's local ID:

```zig
// src/zir_builder.zig line 2181 (call_builtin handler)
for (cb.args) |arg| {
    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
    try args.append(self.allocator, ref);
}
```

If `refForValueLocal(arg)` fails (the local has no ZIR ref), it **silently falls back to `void_value`**. This pattern appears in ~20 places across the ZIR builder.

The lookup fails because function-typed values flow through the IR as opaque locals without type information. The IR's `LocalId` is just a `u32` — it carries no type. When the ZIR builder processes instructions like `make_closure` and `call_closure`, it tries to reconstruct the function reference, but this reconstruction fails in several scenarios.

### Scenarios Where It Fails

**1. Cross-struct function references in Enum callbacks:**
```zap
# test/for_comprehension_test.zap
doubled = for x <- [1, 2, 3] { x * 2 }
```
Desugars to a call to `Enum.map` with an anonymous callback. The callback is a `make_closure` with 0 captures. The ZIR builder emits `decl_ref("__for_0")` for the anonymous function. But when this ref crosses into the Enum struct via `@import`, Zig can't resolve it because `__for_0` is private to the test struct.

**2. Function references passed as callback parameters:**
```zap
# test/closure_test.zap
fn apply(value :: i64, callback :: (i64 -> i64)) -> i64 {
    callback(value)
}
assert(apply(41, add_one) == 42)
```
`add_one` is passed to `apply`. In the IR, this is `make_closure(dest=L5, function=add_one_id, captures=[])`. The ZIR builder emits `decl_ref("add_one__1")` and stores it in `local_refs[L5]`. Then `apply`'s body has `call_closure(callee=L1, args=[L0])` where L1 is the `callback` parameter. The parameter IS registered via `setLocal(1, param_ref)`, so L1 resolves. But the actual function pointer type is lost — Zig sees it as `anytype` and needs the callsite to provide the concrete type. When the concrete type comes from a cross-struct `@import`, the indirection loses the function-ness.

**3. Imported function identifiers:**
```zap
# test/import_test.zap
import Test.MultiStructHelper
assert(double(3) == 6)
```
`double` is used as a bare identifier. The ZIR builder emits `decl_ref("double")` but `double` isn't declared in `Test_ImportTest.zig` — it's in `Test_MultiStructHelper.zig`. The ZIR builder should emit `@import("Test_MultiStructHelper").double__1` instead.

## Current Type Representation

### IR Types (`src/ir.zig`)

The IR has a `ZigType` union that represents Zig types:
```zig
pub const ZigType = union(enum) {
    void,
    bool_type,
    i8, i16, i32, i64,
    u8, u16, u32, u64,
    usize, isize,
    f16, f32, f64,
    string,       // []const u8
    atom,         // u32
    list,         // ?*const ListCell
    map,          // MapType
    tuple: []const ZigType,
    struct_ref: []const u8,
    optional: *const ZigType,
    error_union: *const ZigType,
    // NO function type variant exists
};
```

**There is no `function` variant.** The IR cannot represent `*const fn(i64) i64` as a type. Function parameters with type annotation `(i64 -> i64)` get their Zap-level type checked, but this type is lost during IR lowering.

### IR Instructions

Function values flow through these IR instructions:
- `make_closure { dest: LocalId, function: FunctionId, captures: []LocalId }` — creates a function reference
- `call_closure { dest: LocalId, callee: LocalId, args: []LocalId }` — calls a function value
- `call { dest: LocalId, target: FunctionId, args: []LocalId }` — direct named call
- `call_builtin { dest: LocalId, name: []const u8, args: []LocalId }` — runtime function call (`:zig.Struct.function`)
- `local_set { dest: LocalId, source: LocalId }` — copy a local
- `local_get { dest: LocalId, source: LocalId }` — read a local

None of these carry type information on the locals. A `LocalId` is just a number.

### IR Parameters

```zig
pub const Param = struct {
    name: []const u8,
    type_expr: ZigType,    // <-- has the type, but no function variant
    default_value: ?*const DefaultValue = null,
};
```

When `callback :: (i64 -> i64)` is lowered to IR, `type_expr` becomes `ZigType.void` because there's no function variant. The type checker knows it's a function type, but this knowledge doesn't survive into the IR.

### ZIR Builder Type Mapping

```zig
// src/zir_builder.zig line 329
fn mapParamType(zig_type: ir.ZigType) u32 {
    return switch (zig_type) {
        .i64 => @intFromEnum(Zir.Inst.Ref.i64_type),
        .string => @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
        // ... other concrete types ...
        else => @intFromEnum(Zir.Inst.Ref.none), // anytype for unknown types
    };
}
```

Unknown types (including function types) map to `none` (Zig's `anytype`). This is actually correct for parameters — `anytype` accepts function pointers. The problem isn't the parameter declaration; it's that the **argument value** at the call site becomes void.

## The Type Store

The type checker (`src/types.zig`) has a rich type representation that DOES include function types:

```zig
pub const Type = union(enum) {
    int: struct { signed: bool, bits: u8 },
    float: struct { bits: u8 },
    bool_type,
    string,
    atom,
    nil,
    tuple: []const TypeId,
    list: TypeId,
    map: struct { key: TypeId, value: TypeId },
    function: struct {
        params: []const TypeId,
        return_type: TypeId,
    },
    // ...
};
```

The `TypeStore` resolves and unifies types during type checking. After type checking, the HIR (High-level IR) carries resolved `TypeId` on every expression. But during HIR → IR lowering, function types are lost because `ir.ZigType` has no function variant.

## What the Fix Requires

### 1. Add Function Type to IR

```zig
// In ir.ZigType, add:
function: struct {
    param_types: []const ZigType,
    return_type: *const ZigType,
},
```

### 2. Preserve Function Types During IR Lowering

In `src/ir.zig`'s `IrBuilder`, when lowering a HIR expression with a function type, map it to the new `ZigType.function` variant instead of `void`.

### 3. Emit Function Pointer Types in ZIR

In `src/zir_builder.zig`, when encountering a `ZigType.function`:
- For parameters: emit `*const fn(param_types...) return_type` instead of `anytype`
- For `make_closure` with 0 captures: emit a typed `decl_ref` 
- For cross-struct calls: ensure the function ref type survives the `@import` boundary

### 4. Fix Cross-Struct Import Resolution

When a local's value comes from another struct (via `import` or cross-struct function call), the ZIR builder should emit `@import("SourceStruct").function_name` instead of `decl_ref("function_name")`.

The `import` resolution logic exists for function CALLS (see `emitCrossStructCall` in zir_builder.zig) but not for function VALUES passed as arguments.

## Key Files

| File | Role |
|------|------|
| `src/types.zig` | Type checker with full function type support (TypeStore, Type union) |
| `src/hir.zig` | HIR with TypeId annotations on every expression |
| `src/ir.zig` | IR with ZigType (missing function variant), IrBuilder |
| `src/zir_builder.zig` | ZIR emission, local_refs tracking, cross-struct routing |
| `src/compiler.zig` | Pipeline orchestration, per-struct compilation |
| `src/runtime.zig` | Runtime with ListCell.mapFn etc. (where the errors manifest) |
| `lib/enum.zap` | Enum.map etc. — intermediate struct between caller and runtime |
| `test/closure_test.zap` | Tests for function-as-value patterns |
| `test/for_comprehension_test.zap` | Tests for desugared for loops with callbacks |
| `test/import_test.zap` | Tests for cross-struct bare identifier imports |

## Current Error Manifest

21 errors when running `zap test`:

| Count | Struct | Error | Root Cause |
|-------|--------|-------|------------|
| 2 | Test_ClosureTest | `type 'void' not a function` | Function ref passed to `apply()` becomes void |
| 8 | Test_ForComprehensionTest | `expected ListCell, found void` | For loop callback becomes void |
| 9 | zap_runtime | `type 'void' not a function` | mapFn/filterFn/reduceFn etc. receive void callbacks |
| 2 | Test_ImportTest | `undeclared identifier` | Bare imported names not resolved to @import |

## Relevant Zig Concepts

- **ZIR (Zig IR)**: Zig's intermediate representation before semantic analysis. Instruction-based, SSA-like. Each struct produces its own ZIR.
- **Sema**: Zig's semantic analyzer that type-checks ZIR and produces AIR (Analysis IR). This is where the `void not a function` errors occur.
- **`anytype`**: Zig's comptime-polymorphic parameter type. Functions with `anytype` params are monomorphized at each call site. The runtime's `mapFn(list, callback: anytype)` relies on this.
- **`@import`**: Zig's struct system. Each Zap struct becomes a Zig struct. Cross-struct references use `@import("StructName").symbol`.
- **`decl_ref`**: ZIR instruction that references a declaration by name within the current struct's namespace.
- **Function pointers**: In Zig, `*const fn(i64) i64` is a concrete type. Function values in Zap should compile to this.

## Constraints

- The Zig fork's C-ABI surface (`zir_api.zig`) already supports emitting function types via `zir_builder_emit_param` with type refs, `zir_builder_emit_decl_ref` for function references, and `zir_builder_emit_call_ref` for indirect calls.
- The fix must work for both same-struct and cross-struct function references.
- Anonymous functions (lambdas) with 0 captures should work the same as named function references.
- Closures with captures use a different mechanism (environment struct) and are partially working — the 0-capture case is the broken one.
- All changes must be in the Zap compiler (`~/projects/zap/src/`), not in the Zig fork.
