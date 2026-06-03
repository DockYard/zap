# Literal Context-Adoption — Perfecting Implicit Literal Typing (task #361)

## The feature

A bare **untyped numeric literal** adopts the numeric type its *context*
expects, range-checked. Concretely: when an expression is an untyped int/float
literal (not a typed value, not a typed binding) and the surrounding context
expects a specific numeric type the literal's value **fits**, the literal adopts
that type. If the value does **not** fit, the compiler reports a clear overflow
error — never a silent default and never widening the *context* to fit the
literal.

The discriminator is precise: **only the literal adopts.** A typed value or a
typed binding flowing into a narrower numeric slot is still a type error.
`takes_u8(5)` adopts `u8`; `n = 5; takes_u8(n)` still errors (`n` is a typed
`i64` value).

## Position map (empirically verified, `zig-out/bin/zap run`, ZAP_LIB_DIR=lib)

| Position | Example | Status before #361 |
|---|---|---|
| Default binding | `foo = 32` → i64, `f = 3.14` → f64 | WORKS |
| Struct field | `%Box{v: 5}`, field `v :: u8` | WORKS |
| Binary-op peer | `port == 8080`, `port :: u16` | WORKS (e173303) |
| Return position | `fn f() -> u8 { 5 }` | **WORKS** (task said unknown) |
| `if` result | `fn f(c) -> u8 { if c {5} else {9} }` | **WORKS** (task said unknown) |
| `case` result | `fn f(n) -> u8 { case n {0->5; _->9} }` | **WORKS** (task said unknown) |
| **Function argument** | `P.takes_u8(5)`, param `x :: u8` | **BROKEN** |
| **Nested call arg** | `P.takes_u8(P.id_u8(5))` | **BROKEN** |
| **Float argument** | `P.takes_f32(3.5)`, param `f32` | **BROKEN** |
| **List element (as arg)** | `L.count([5, 9, 200])`, param `[u8]` | **BROKEN** |
| **Map element (as arg)** | `M.take(%{k: 5})`, param `Map(Atom,u8)` | **BROKEN** |

Negative anchor (must keep erroring): typed binding into a narrower param —
`n = 5; takes_u8(n)` → `argument 1 expects 'u8', got 'i64'`.

**Every broken position surfaces through the SAME diagnostic** —
`reportArgumentTypeMismatchProvenance` / `reportArgumentTypeMismatch` in
`src/types.zig`, the "argument N expects `X`, got `Y`" / "argument type
mismatch" message. List/map elements fail because the element literals default
(`[i64]` / `%{Atom => i64}`) before the collection type is known, then the whole
collection fails to match the parameter's collection type.

## Why return/if/case already work, and args do not

The TypeChecker's return-type check (`src/types.zig:7263-7265`) already accepts
a tail integer literal for a declared non-i64 return type via
`exprTailIntegerLiteralCanSatisfyExpectedType`, which recurses through `if` and
`case` arms (`src/types.zig:2799-2816`). And the codegen lowers the literal
under the function's declared-return context, so the value is stored at the
declared width.

The **call-argument** path has neither piece wired:

1. **Type-check layer.** Each of the five arg-mismatch sites
   (`src/types.zig:8554, 8933, 8971, 9139, 9174`) gates purely on
   `callMatchCost(arg_type, expected) == null`. For a literal `arg_type` is
   already `I64`/`F64` (stamped by `inferExpr`, lines 6521-6522 / 7380-7381), so
   `callMatchCost(I64, U8)` returns null → mismatch. The existing
   `acceptsIntegerLiteralForExpectedType` (line 2785) is NOT consulted here.

2. **HIR/codegen layer.** `HirBuilder.buildExpr` stamps every int literal `I64`
   (engram: "Zap HIR int_lit default typing"). The call-arg propagation at
   `src/hir.zig:5788-5799` restamps an arg expr to its `expected_type` **only
   when `arg.expr.type_id == UNKNOWN`** — a literal is `I64`, not UNKNOWN, so it
   is skipped. The literal reaches codegen as `i64` and Zig Sema rejects the
   call.

## The model machinery (the gold standard to generalize)

- **Struct-field adoption** — `HirBuilder.propagateExpectedTypeToDefault`
  (`src/hir.zig:8520-8563`): for an `int_lit` whose receiving field is a
  different integer type, restamp `mut.type_id = expected_type`. *Gap to fix
  while generalizing:* it is NOT range-checked and handles only `int_lit` (not
  `float_lit`).
- **Binary-op peer adoption** — `HirBuilder.unifyIntLiteralOperandType` +
  `classifyIntLiteralOperand` (`src/hir.zig:8590-8698`) and
  `AssignmentBinding.int_lit_source` (`src/hir.zig:500-521`): the precise
  untyped-literal-vs-typed-value discriminator (`type_id == I64` AND a tracked
  `int_lit_source`), range-checked via `TypeStore.intLiteralFitsInType`, with a
  clear overflow diagnostic. **This is the discriminator and range-check model
  to reuse.**
- **Type-check literal acceptance** — `acceptsIntegerLiteralForExpectedType` /
  `exprTailIntegerLiteralCanSatisfyExpectedType` (`src/types.zig:2785-2816`),
  already wired for struct-field defaults (4986, 5121), struct-init field
  (8053), and return position (7265).
- **Range check primitive** — `TypeStore.intLiteralFitsInType`
  (`src/types.zig:818-836`): signed/unsigned bit-width fit, rejects negative
  into unsigned. Float fit is value-domain (a float literal fits any float
  type).
- **Overload-cost surface (DELICATE)** — `TypeStore.callMatchCost`
  (`src/types.zig:985`, used by HIR overload selection) and
  `TypeChecker.callMatchCost` (`src/types.zig:3382`). `wideningCost`
  (`src/types.zig:841`) deliberately forbids uN→iM cross-signedness (e173303).
  **Overload SELECTION must stay byte-identical for existing code** — the
  e173303 lesson: a naive `callMatchCost` change broke `FieldDefaultTest` and
  the corpus. Literal-adoption must be applied as a *diagnostic-suppression +
  restamp* layered ON TOP of the existing cost, NOT by loosening the cost
  function (which would change which overload is chosen).

## The unified rule

When an argument/element expression is an **untyped numeric literal** — AST
`.int_literal` (whose inferred type is the default `I64`) or `.float_literal`
(default `F64`), recursively including literals at list/map element positions —
and the expected type is a *concrete* numeric type (an `.int` for an int
literal; an `.int` or `.float` for a context that wants a different float
width), the literal **adopts** the expected type iff its value fits
(`intLiteralFitsInType` for ints; value-domain fit for floats). If it does not
fit → overflow diagnostic. A typed value (anything that is not literally an
int/float literal AST node) never adopts.

## Implementation seam, per position

### Args (the core gap) — TWO layers

1. **Type-check (`src/types.zig`).** Add a single predicate
   `argLiteralAdoptsExpectedType(arg, arg_type, expected)`: true when `arg` is
   an untyped numeric literal AST node (int/float, including element literals of
   a list/map literal whose expected type is the corresponding collection type)
   whose value fits `expected`. Guard each of the five arg-mismatch sites:
   suppress the diagnostic when the predicate holds; emit a *range* overflow
   diagnostic when the arg IS such a literal but does NOT fit. This reuses the
   exact `acceptsIntegerLiteralForExpectedType` spirit but adds range-checking +
   float support, and is layered after `callMatchCost` (overload selection is
   untouched).

2. **HIR/codegen (`src/hir.zig`).** Extend the call-arg propagation
   (`src/hir.zig:5788-5799`) so an untyped-literal arg (int_lit typed `I64`,
   float_lit typed `F64`) adopts `arg.expected_type` when that expected type is a
   concrete numeric type and the value fits — restamping the literal's
   `type_id`. Reuse the `propagateExpectedTypeToDefault` restamp, generalized to
   (a) range-check and (b) float literals, and made to recurse into list/map
   element literals. CRITICAL: gate on the literal being genuinely untyped —
   never restamp a `local_get`/typed value.

### Return / if / case

Already works end-to-end. The remaining hardening: the type-check acceptance
(`acceptsIntegerLiteralForExpectedType`) is not range-checked, so `fn f() -> u8
{ 9999 }` is wrongly accepted at type-check (codegen then rejects far from the
source). Fold range-checking into the shared predicate so the overflow error is
reported at the Zap source, in-band with the other positions.

### List / Map element

Covered by the same arg-layer change once element literals recurse: a
`[5, 9, 200]` arg against `[u8]` makes each element literal adopt `u8`. The
element restamp also makes the HIR `list_init`/`map_init` element types correct.

## Range-checking + negatives

Every adoption is range-checked. Int fit via `intLiteralFitsInType` (rejects
negative-into-unsigned, e173303-consistent). Float literal fits any float type
(value-domain). Overflow → a clear in-band Zap diagnostic at the literal's span,
naming the value and the target type.

## Final implemented position set (post gap-analysis)

All verified via `script_fixtures/run_literal_adoption_acceptance.sh` (19
positive + 3 negative checks) and runtime probes:

| Position | Example | Layer(s) touched |
|---|---|---|
| Function argument (int) | `P.takes_u8(5)` | type-check + HIR |
| Function argument (float) | `P.takes_f32(3.5)` | type-check + HIR + IR float context |
| Nested-call argument | `P.takes_u8(P.id_u8(5))` | type-check + HIR |
| List element (incl. nested) | `L.count([5, 9, 200])`, `[[5],[200]]` | type-check + HIR (recursive) |
| Tuple element | `take({5, 200})` | type-check + HIR |
| Map value AND key | `M.take(%{5 => 9})` | type-check + HIR |
| `if`/`case`/`block` in arg | `take(if c {5} else {9})` | type-check + HIR (arm recursion) |
| Return (int + float) | `fn f() -> u8 {5}`, `-> f32 {2.5}` | type-check + HIR tail + IR/ZIR float |
| `if`/`case` return (int + float) | `-> f32 { if c {1.5} else {2.5} }` | type-check + HIR tail + IR/ZIR float |
| Negated literal → signed | `takes_i8(-5)`, `[-5,100,-128]` | type-check + HIR (outer-only restamp) |
| Struct field default / init | `port :: u16 = 8080`, `%Box{v:5}` | type-check + HIR (range-checked) |

Negative anchors (still error, verified): out-of-range literal (overflow
diagnostic), typed binding into narrower param (`n = 5; takes_u8(n)`),
negative literal into unsigned (`takes_u8(-5)`), float literal into int param
(`takes_u8(3.5)`), int literal into String. Overload selection is byte-
identical for all existing code (`callMatchCost`/`wideningCost` untouched).

### Two unification refactors landed during gap analysis
* The int-only `acceptsIntegerLiteralForExpectedType` /
  `exprTailIntegerLiteralCanSatisfyExpectedType` now delegate to the single
  float-aware, range-checked, control-flow-recursive `classifyArgLiteralAdoption`
  (the redundant tail-recursion helpers were removed). One predicate now governs
  every type-check position.
* The IR `float_lit` lowering gained `expectedConcreteFloatType` (the analog of
  `expectedConcreteIntegerType`) and the ZIR `const_float` handler gained the
  case-result `f64` fallback the `const_int` handler already had — closing the
  `comptime_float` control-flow gap symmetrically with int.

## Risk + checkpoint

The delicate surface is the shared overload-cost path. The design keeps
`callMatchCost`/`wideningCost` byte-identical and adds adoption as a
suppress-and-restamp layer, so overload SELECTION for existing code cannot
change. Verification anchor after each position-class: native `zap test`
942/0 + 1366 assertions, golden 14/14, host `zig build test` exit 0, V8 +
runtime-os + target-cap gates. Args-position alone is a shippable increment.
