# ZIR switch_block for Tagged Union Payload Extraction

## Problem

Zap's `~>` error pipe operator needs to switch on tagged union values and extract payloads. The ZIR `switch_block` instruction is the only correct way to do this — `field_val` on a full union is invalid, and `activeTag` + `if_else_bodies` can't extract payloads.

The `switch_block` implementation works for single-step error pipes but crashes for multi-step pipe chains due to ZIR instruction ordering constraints.

## What Works Today

Single-step `~>` compiles and runs through the full ZIR path:

```zap
pub fn try_parse(s :: String) -> String | Err(Atom) {
  s
}

pub fn run(s :: String) -> String {
  try_parse(s)
  ~> {
    _ -> "error"
  }
}
```

This generates a `switch_block` instruction with two prongs (Ok/Error), proper payload capture via the switch instruction's own Ref, and `break_inline` instructions that yield each prong's result.

## What Crashes

Multi-step pipe chains where intermediate steps are also fallible:

```zap
pub fn check_not_empty(input :: String) -> String | Err(Atom) { ... }
pub fn parse_number(input :: String) -> String | Err(Atom) { ... }
pub fn format_result(value :: String) -> String { ... }

pub fn validate_and_process(input :: String) -> String {
  check_not_empty(input)
  |> parse_number()
  |> format_result()
  ~> {
    :empty_input -> "Error: input was empty"
    :unknown_number -> "Error: not a valid number"
  }
}
```

This requires nested `union_switch` IR instructions — the outer switch handles `check_not_empty`'s result, and inside the Ok body, an inner switch handles `parse_number`'s result.

## Root Cause

Two interrelated ZIR constraints:

### 1. Enum Literal Item Ordering

ZIR `switch_block` prong items must be Refs to instructions emitted BEFORE the `switch_block` instruction. Sema resolves items by walking backwards from the switch to find the enum literal.

Currently, `emitUnionSwitch` calls `beginSwitchBlock` first (reserving the instruction index), then emits enum literals for each prong. This puts enum literals AFTER the switch in the instruction stream. Sema calls `resolveSwitchItemVal` on these forward-referencing Refs and gets null.

Moving `beginSwitchBlock` after the enum literals fixes the item resolution but changes the instruction index of the switch, which disrupts how the rest of the function body references it.

### 2. Global Capture Buffer

The ZIR builder uses a single global `capture_buf` for `begin_capture`/`end_capture`. Nested `union_switch` instructions (from multi-step pipe chains) call `begin_capture` for inner switch prong bodies while the outer capture is still active. This overwrites the outer capture buffer, corrupting the outer switch's prong body data.

Manual instruction tracking (via `set_body_tracking(false)` + `get_inst_count`) avoids the global buffer but doesn't solve the instruction ordering issue.

## Architecture Context

### Compilation Pipeline

```
Zap Source → Parser → Collector → Desugarer → TypeChecker → HIR → IR → ZIR → Zig Sema → LLVM → Binary
```

The error pipe flows through:
1. **Desugarer**: passes `error_pipe` AST through unchanged (no longer desugars to tuples)
2. **HIR Builder**: builds `ErrorPipeHir` with step info, detects fallible steps
3. **IR Builder**: lowers to nested `union_switch` instructions via `lowerErrorPipeChain`/`lowerErrorPipeRemainingSteps`
4. **ZIR Builder**: `emitUnionSwitch` → C-ABI calls to `beginSwitchBlock`/`finalizeSwitchBlock`
5. **Zig Fork**: builds `switch_block` ZIR instruction with `SwitchBlock` payload in extra array

### ZIR switch_block Layout (from Zig's AstGen)

```
Instruction: switch_block (pl_node)
Extra data:
  [+0] operand: Ref (the union value)
  [+1] bits: packed SwitchBlock.Bits {
    has_multi_cases: bool,
    special_prongs: SpecialProngs (3 bits),
    any_has_tag_capture: bool,
    any_non_inline_capture: bool,
    has_continue: bool,
    scalar_cases_len: u25,
  }
  Per scalar case:
    [N]   item: Ref (enum literal, must precede switch instruction)
    [N+1] ProngInfo: packed u32 { body_len: u28, capture: u2, is_inline: bool, has_tag_capture: bool }
    [N+2..N+1+body_len] instruction indices (body, ending with break_inline)
```

Payload capture: body instructions reference the `switch_block` instruction's own Ref. Sema maps this to the extracted payload via `inst_map[switch_block_inst]`.

### Zig Fork Files

- `~/projects/zig/src/zir_builder.zig`: `beginSwitchBlock`, `finalizeSwitchBlock`, `SwitchProng`, `setUnionReturnType`, `addUnionInit`
- `~/projects/zig/src/zir_api.zig`: C-ABI exports for all builder functions

### Zap Files

- `src/zir_builder.zig`: `emitUnionSwitch` — the function that needs fixing
- `src/ir.zig`: `lowerErrorPipeChain`, `lowerErrorPipeRemainingSteps` — generates nested `union_switch` IR
- `src/hir.zig`: `buildErrorPipe` — builds `ErrorPipeHir` from AST

## Proposed Solution

Add a new C-ABI function to the Zig fork that accepts enum literal strings directly in the `finalizeSwitchBlock` call, interning them into the switch payload rather than emitting separate body instructions. This eliminates the ordering constraint:

```zig
// New API: items are strings, not pre-emitted Refs
pub fn finalizeSwitchBlockWithItems(
    self: *FuncBody,
    inst_idx: u32,
    operand: Zir.Inst.Ref,
    prongs: []const SwitchProngWithItem,
) !Zir.Inst.Ref

pub const SwitchProngWithItem = struct {
    item_name: []const u8,       // variant name string (will be interned as enum_literal)
    has_capture: bool,
    body_insts: []const u32,
    body_result: Zir.Inst.Ref,
};
```

Inside `finalizeSwitchBlockWithItems`:
1. Emit each enum literal instruction BEFORE writing the SwitchBlock extra data
2. The enum literal instructions go into the builder's instruction stream at indices that precede the switch_block (which was reserved earlier by `beginSwitchBlock`)

Wait — the switch_block instruction was already reserved by `beginSwitchBlock`. Enum literals emitted afterward will have higher indices. The items must have LOWER indices than the switch.

The actual fix: **`beginSwitchBlock` must not reserve the instruction index immediately.** Instead:
1. `beginSwitchBlock` returns a builder handle (not an instruction index)
2. The caller emits enum literals and builds prong bodies
3. `finalizeSwitchBlock` emits the actual `switch_block` instruction (now AFTER the enum literals) and patches it

This requires restructuring the two-phase API:

```zig
pub fn beginSwitchBlockDeferred(self: *FuncBody) !SwitchBlockHandle {
    // Don't emit anything yet — just return a handle
    return .{ .operand = undefined, .prongs = .{} };
}

pub fn finalizeSwitchBlockDeferred(
    self: *FuncBody,
    handle: SwitchBlockHandle,
    operand: Zir.Inst.Ref,
    prongs: []const SwitchProngWithItem,
) !Zir.Inst.Ref {
    // 1. Emit enum literals (these get low instruction indices)
    // 2. Emit dbg_stmt
    // 3. Emit switch_block instruction (gets index AFTER enum literals)
    // 4. Emit break_inline instructions (get indices AFTER switch)
    // 5. Write SwitchBlock extra data
    // All in the correct order.
}
```

For nested switches, each level needs its own set of enum literals emitted before its switch_block. Since body instructions (including inner switches) are emitted between the outer switch's `begin` and `finalize`, the ordering is:

```
outer_enum_literal_Ok       (inst 50)
outer_enum_literal_Error    (inst 51)
outer_dbg_stmt              (inst 52)
outer_switch_block          (inst 53) — references items at 50, 51
  Ok body:
    call_named              (inst 54)
    inner_enum_literal_Ok   (inst 55)
    inner_enum_literal_Error(inst 56)
    inner_dbg_stmt          (inst 57)
    inner_switch_block      (inst 58) — references items at 55, 56
      Ok body: ...
      Error body: break_inline → inst 58
    outer_break_inline → inst 53
  Error body:
    outer_break_inline → inst 53
```

This ordering is achievable with the deferred API because each switch's enum literals are emitted just before its switch_block instruction, and body instructions (including inner switches) are emitted between the enum literals and the break.

For the global capture buffer issue: use the manual tracking approach (`set_body_tracking(false)` + `get_inst_count`) instead of `begin_capture`/`end_capture`. This avoids nesting conflicts entirely.

## Files to Modify

### Zig Fork (`~/projects/zig`)

- `src/zir_builder.zig`:
  - Replace `beginSwitchBlock`/`finalizeSwitchBlock` with deferred API
  - New `SwitchBlockHandle` struct
  - `finalizeSwitchBlockDeferred` emits enum literals + switch_block + breaks in correct order

- `src/zir_api.zig`:
  - Replace C-ABI exports with deferred API
  - Accept item names as strings in finalize call

### Zap (`~/projects/zap`)

- `src/zir_builder.zig`:
  - Update `emitUnionSwitch` to use deferred API
  - Remove `begin_capture`/`end_capture` usage — use manual tracking
  - Pass variant name strings to finalize (not pre-emitted Refs)

## Verification

1. Single-step `~>`: `parse(x) ~> { _ -> "error" }` — must compile and run
2. Single-step with pipe: `parse(x) |> transform() ~> { _ -> "error" }` — must compile and run
3. Multi-step fallible: `check(x) |> parse() |> fmt() ~> { ... }` — must compile and run
4. Function handler: `parse(x) ~> handle_error()` — must compile and run
5. Full error_pipe example — must compile and run
6. All existing `zig build test` tests — must pass
7. Zig fork builder test — must verify extra data layout
