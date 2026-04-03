# @unionInit Inside Branch Bodies Produces Void in ZIR

## Context

We are building a programming language called Zap that compiles to native binaries by lowering directly to Zig's ZIR (Zig Intermediate Representation) via a C-ABI library interface to a forked Zig 0.15.2 compiler. Zap does NOT generate Zig source text — it emits ZIR instructions programmatically through C-ABI function calls to a static library (`libzap_compiler.a`).

The Zig fork is at `~/projects/zig`. The Zap compiler is at `~/projects/zap`.

## The Feature

Zap has tagged unions:

```zap
pub union ParseResult {
  Ok :: String
  Error :: Atom
}

pub fn parse_number(input :: String) -> ParseResult {
  case input {
    "one" -> ParseResult.Ok("1")
    _ -> ParseResult.Error(:unknown)
  }
}
```

This compiles through: Zap source → Parser → Type Checker �� HIR → IR → ZIR (via C-ABI) → Zig Sema → LLVM → native binary.

## What Works

Functions that produce a SINGLE union variant compile and run correctly:

```zap
pub fn ok_result(input :: String) -> ParseResult {
  ParseResult.Ok(input)
}

pub fn err_result() -> ParseResult {
  ParseResult.Error(:unknown)
}
```

Both produce correct `@unionInit` ZIR instructions and pass Sema.

## What Fails

Functions with a `case` expression that produces DIFFERENT union variants in different branches fail:

```zap
pub fn parse_number(input :: String) -> ParseResult {
  case input {
    "one" -> ParseResult.Ok("1")
    _ -> ParseResult.Error(:unknown)
  }
}
```

Zig Sema error: `incompatible types: 'ParseResult' (union) and 'void'`

This means one branch of the case expression produces a `ParseResult` value and the other produces `void`.

## How the ZIR is Emitted

### Union Return Type Declaration

When a function returns a union type, we call `setUnionReturnType` on the fork's ZIR builder. This emits a `union_decl` extended instruction in the function's declaration value body (the ret_ty body). The `endFunction` method sees `union_ret_type_inst` is set and emits a 2-instruction ret_ty body: `[union_decl, break_inline(func, union_decl)]`.

This part works correctly — Sema accepts the union return type.

### @unionInit for Variant Construction

For `ParseResult.Ok("hello")`, we emit:

```
%N = ret_type          // yields the function's return type (ParseResult)
%M = str("Ok")         // field name as string literal
%K = str("hello")      // the payload value
%R = union_init(%N, %M, %K)  // @unionInit(ParseResult, "Ok", "hello")
```

The `ret_type` instruction is emitted ONCE at the start of the function body (with body_tracking ON), and its Ref is cached. All `@unionInit` instructions reference this cached Ref.

This works when the `@unionInit` is at the top level of the function body.

### Case Expression Branch Bodies

Zap's `case` expression compiles to ZIR using the `if_else_bodies` pattern:

1. The condition (string comparison) is emitted at the top level
2. `zir_builder_begin_capture()` is called — this disables body_tracking and redirects instructions to a capture buffer
3. The branch body instructions are emitted (including `@unionInit`)
4. `zir_builder_end_capture()` collects the captured instruction indices
5. `zir_builder_emit_if_else_bodies(condition, then_insts, then_result, else_insts, else_result)` creates the branching ZIR

### The Problem

When `@unionInit` is emitted INSIDE a captured branch body:

1. `zir_builder_emit_union_init(union_type_ref, field_name, value)` is called
2. Inside the fork's `emit_union_init`, it calls `body.addStr(field_name)` which emits a `str` instruction
3. Then `body.addUnionInit(type_ref, str_ref, value_ref)` emits the `union_init` instruction
4. Both instructions go into the capture buffer (body_tracking is OFF, non_body_capture is set)

The `union_type_ref` references a `ret_type` instruction that was emitted in the MAIN function body (body_tracking was ON). Branch body instructions CAN reference outer scope instructions in ZIR — this is normal.

But Sema reports that one branch produces `ParseResult` (the union type) while the other produces `void`. This suggests that the `@unionInit` inside the captured branch body either:

- Fails to produce a value (returns void)
- Produces the wrong type
- Isn't properly recognized as a `union_init` instruction by Sema

## Key Files

### Zig Fork (`~/projects/zig`)

- `src/zir_builder.zig`:
  - `addUnionInit(union_type, field_name, init_value)` — emits `union_init` ZIR instruction (line ~748)
  - `addRetType()` — emits `ret_type` instruction (line ~740)
  - `setUnionReturnType(names, types)` — declares union return type via `union_decl` (line ~1256)
  - `addSwitchBlock(operand, prongs)` — emits `switch_block` for `~>` error pipe (line ~1126)
  - `FuncBody.union_ret_type_inst` — tracks union_decl for `endFunction` ret_ty body

- `src/zir_api.zig`:
  - `zir_builder_emit_union_init(handle, type, name_ptr, name_len, value)` — C-ABI export (line ~1250)
  - `zir_builder_get_union_ret_type_ref(handle)` — emits `ret_type` and returns Ref (line ~1690)
  - `zir_builder_set_union_return_type(handle, names, lens, types, count)` — C-ABI export
  - `zir_builder_begin_capture` / `zir_builder_end_capture` — capture mechanism for branch bodies

### Zap Compiler (`~/projects/zap`)

- `src/zir_builder.zig`:
  - `emitInstruction(.union_init)` handler (line ~1975) — calls `zir_builder_emit_union_init`
  - `cached_union_ret_type_ref` field — the `ret_type` Ref cached at function start
  - Function emission (line ~634) — calls `setUnionReturnType` and caches `ret_type`
  - `emitInstruction(.case_break)` and case expression handling — uses `begin_capture`/`end_capture`

### Zig Sema (`~/projects/zig/src/Sema.zig`)

- `zirUnionInit` (line ~19286) — processes `union_init` ZIR instruction
- `analyzeBodyRuntimeBreak` — analyzes branch bodies
- `resolveAnalyzedBlock` — merges branch result types

## Capture Mechanism Details

The capture mechanism uses a global `capture_buf`:

```zig
// zir_api.zig
pub export fn zir_builder_begin_capture(handle) void {
    capture_buf.clearRetainingCapacity();
    body.body_tracking = false;
    body.non_body_capture = &capture_buf;
}

pub export fn zir_builder_end_capture(handle, out_len) [*]const u32 {
    body.body_tracking = true;
    body.non_body_capture = null;
    out_len.* = capture_buf.items.len;
    return capture_buf.items.ptr;
}
```

When body_tracking is false, `emitBodyInst` adds instruction indices to `non_body_capture` instead of `body_inst_indices`. This is how branch body instructions are collected for `if_else_bodies`.

## The `if_else_bodies` ZIR Pattern

The `if_else_bodies` instruction takes:
- condition Ref
- then_body: instruction indices + result Ref
- else_body: instruction indices + result Ref

Sema analyzes each body independently, then merges the result types. If `then_result` is ParseResult and `else_result` is void, Sema reports "incompatible types: union and void".

## What I've Verified

1. `@unionInit` at the function top level (body_tracking ON) → works
2. `ret_type` instruction at the function top level → works, correctly resolves to the union type
3. `@unionInit(cached_ret_type_ref, ...)` in branch body → produces "void" in one branch
4. The `union_init` ZIR instruction IS emitted (it's in the capture buffer)
5. The `str` instruction for the field name IS emitted alongside it
6. The `union_type_ref` correctly references the `ret_type` from the outer scope

## Hypothesis

The `@unionInit` instruction inside the captured branch body might not be producing a value that `if_else_bodies` can use as the branch result. The `then_result` Ref passed to `if_else_bodies` might not match the `union_init` instruction's output Ref.

Or: the `union_init` instruction might not be recognized as producing a value when it's inside a branch body context. The instruction IS in the capture buffer, but the result Ref passed to `if_else_bodies` might be wrong.

## What Would Help

1. Understanding exactly how `if_else_bodies` resolves branch result types — does it evaluate the result Ref independently of the body instructions?
2. Whether `@unionInit` inside a `condbr_inline` body (which `if_else_bodies` generates) can reference outer-scope `ret_type` instructions
3. Whether the issue is in how Sema's `analyzeBodyRuntimeBreak` handles `union_init` inside branch bodies
4. What the correct ZIR instruction sequence should be for a function that has an if-else where both branches produce `@unionInit` values with the same union type but different variants
