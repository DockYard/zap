# Plan: Ownership-Typed ARC Integration

## Goal

Keep Zap's existing ARC runtime as the execution substrate, but make ownership a
first-class concern in the compiler so ARC decisions are driven by static facts
 instead of best-effort runtime behavior.

The current implementation already has:

- a concrete ARC runtime in `src/runtime.zig`
- placeholder ownership instructions in `src/ir.zig`
- ZIR emission hooks for ARC-related instructions in `src/zir_builder.zig`

What it does not yet have is the crucial middle layer:

- ownership-aware types
- ownership-aware binding analysis
- ownership-aware HIR/IR lowering

This plan fills that gap.

## Non-Goals

- Do not replace ARC with a borrow checker-only model
- Do not redesign the runtime before the compiler can express ownership facts
- Do not begin with aggressive optimization passes
- Do not rely on the future spec; this plan is scoped to the current
  implementation and current code layout

## Current Assessment

### Runtime

`src/runtime.zig` already provides:

- `ArcHeader`
- `Arc(T)`
- `ArcRuntime.allocAny`
- `ArcRuntime.freeAny`
- `ArcRuntime.retainAny`
- `ArcRuntime.refCountAny`

This is a real ARC model, but it is runtime-oriented and alias-friendly.

### Type system

`src/types.zig` currently models:

- primitives
- tuples/lists/maps
- structs/unions/enums
- functions
- parametric/applied types
- opaque types

It does not currently model:

- uniqueness
- linearity
- affine consumption
- borrow scopes
- ownership/effect qualifiers

### IR / lowering

`src/ir.zig` defines `alloc_owned`, `retain`, and `release`, but these are not
yet backed by a strong ownership analysis pipeline.

`src/zir_builder.zig` contains emission paths for these instructions, but they
currently look more like groundwork than the output of a complete ownership
discipline.

## Architecture Direction

The right shape is:

1. enrich the type system with ownership modes
2. enforce ownership in type checking and binding analysis
3. preserve ownership facts into HIR and IR
4. use those facts to emit ARC operations intentionally
5. keep runtime ARC as the shared-value fallback

The compiler, not the runtime, should become the source of ownership truth.

## Ownership Model

Start with a deliberately small ownership lattice.

### Ownership modes

- `shared` — normal ARC-managed aliasable value
- `unique` — single-owner value that may be moved/consumed
- `borrowed` — temporary non-owning view that cannot outlive its source

This is enough to unlock meaningful compiler decisions without requiring a full
Rust-style borrow checker on day one.

### Core rules

- `shared` values may be copied/aliased freely; ARC handles lifetime
- `unique` values may not be implicitly duplicated
- consuming a `unique` value invalidates the source binding
- a `unique` value may be converted to `shared` explicitly or when required by
  a context that needs aliasable ownership
- `borrowed` values may not escape their valid scope
- returning a `borrowed` value as owned/shared is illegal

## Implementation Sequence

### Phase 1: Add ownership metadata to types

#### Files

- `src/types.zig`

#### Work

Add ownership metadata to the type layer so ownership becomes part of typing,
not an afterthought in codegen.

Recommended structure:

```zig
pub const Ownership = enum {
    shared,
    unique,
    borrowed,
};

pub const QualifiedType = struct {
    type_id: TypeId,
    ownership: Ownership = .shared,
};
```

Then thread this through at least:

- function parameter types
- function return types
- local/binding typing
- opaque/runtime-managed values

Do not try to retrofit every container field immediately if that slows the
 initial integration too much. The first win is ownership on bindings and call
 boundaries.

#### Why here first

Without ownership in the type layer, later phases have no principled input.

### Phase 2: Extend AST/type-expression support

#### Files

- `src/ast.zig`
- `src/parser.zig`

#### Work

Create a place in syntax and AST to carry ownership qualifiers.

Two acceptable rollout options:

1. **Internal-first**
   - extend AST/type nodes with ownership fields
   - allow parser defaults to `.shared`
   - do not expose full source syntax immediately

2. **User-visible syntax**
   - add explicit ownership qualifiers in type expressions
   - parse them into the new AST fields

For the minimum viable implementation, internal-first is enough as long as the
 AST can represent ownership.

#### Needed AST changes

- add ownership to type-expression nodes or wrappers
- ensure function params/results can carry ownership
- preserve source spans for ownership diagnostics

### Phase 3: Add ownership state to type checking

#### Files

- `src/types.zig`
- potentially `src/scope.zig` if binding metadata needs extension

#### Work

Upgrade `TypeChecker` from shape/type validation into ownership validation.

Add binding-state tracking such as:

```zig
const BindingOwnershipState = enum {
    available,
    moved,
    borrowed,
};
```

Track for each binding:

- declared/inferred ownership
- whether it has been consumed
- whether it is currently borrowed
- whether a use requires retain/share/consume semantics

#### New checks

- using a moved `unique` binding is an error
- passing a `unique` binding to a consuming parameter invalidates it
- copying a `unique` binding into two live aliases is an error unless it is
  explicitly shared
- borrowed values cannot escape through return, closure capture, or longer-lived
  storage
- function compatibility must compare ownership as well as type shape

#### Diagnostics

Add specific errors such as:

- `value moved here`
- `unique value used after move`
- `borrowed value escapes scope`
- `cannot implicitly alias unique value`

This phase is the real semantic heart of the feature.

### Phase 4: Preserve ownership in HIR

#### Files

- `src/hir.zig`

#### Work

HIR expressions and bindings need to remember ownership semantics so IR does not
 have to reconstruct them.

Add ownership-aware metadata to:

- HIR expression nodes
- call arguments
- locals/bindings
- function signatures
- capture/closure metadata where ownership is relevant

Recommended additions:

```zig
pub const ValueMode = enum {
    share,
    move,
    borrow,
};
```

At call sites, each argument should record how it is being used.

#### Important code paths

- `buildExpr` call lowering in `src/hir.zig:1956`
- variable/local resolution in `src/hir.zig:1848`
- closure construction/captures if unique values can be captured

### Phase 5: Redesign ownership IR around semantics

#### Files

- `src/ir.zig`

#### Work

Revisit the existing ownership instructions so they reflect meaningful compiler
 decisions.

Current problems:

- `AllocOwned` is too weak — it carries only `type_name`
- `retain` and `release` exist, but do not obviously derive from a complete
  ownership analysis

Recommended IR direction:

- keep `retain`
- keep `release`
- add an explicit `move` or `consume` operation
- add an explicit `share` operation if needed to mark unique -> shared
- either remove `alloc_owned` or redesign it to carry the actual produced value

Example shape:

```zig
pub const Move = struct {
    dest: LocalId,
    source: LocalId,
};

pub const Share = struct {
    dest: LocalId,
    source: LocalId,
};
```

The key requirement is that IR should no longer be guessing about ownership.
It should encode already-proven decisions from type checking and HIR.

### Phase 6: Make ZIR emission ownership-aware

#### Files

- `src/zir_builder.zig`

#### Work

Once IR ownership is meaningful, lower it faithfully into executable ARC
 behavior.

Desired behavior:

- emit `retain` only when aliasing/shared ownership requires it
- emit `release` when the last relevant owner is dropped
- avoid retain/release pairs for values proven unique and simply moved
- preserve borrowed accesses as non-owning when the runtime representation
  allows it

#### Specific hotspots

- function emission and parameter handling in `src/zir_builder.zig:288`
- ownership instruction emission beginning near `src/zir_builder.zig:1540`

This phase should also fix the current mismatch where ownership ops look wired
up mechanically but not semantically.

### Phase 7: Keep runtime ARC simple, add only what typed ownership requires

#### Files

- `src/runtime.zig`

#### Work

Do not start here. Only adjust runtime once compiler-side ownership facts are
 real.

Likely runtime needs:

- keep `ArcHeader`, `Arc(T)`, and `ArcRuntime` as the shared-value substrate
- support explicit unique -> shared transitions if the runtime needs a helper
- keep non-owning borrowed access lightweight

Avoid major runtime redesign until the compiler proves the ownership model is
 stable.

## Minimum Viable Milestone

The first milestone should not try to solve every ownership problem.

### MVP scope

- ownership metadata exists in the type system
- function params/results can be marked `shared` / `unique` / `borrowed`
- `TypeChecker` rejects obvious unique-after-move errors
- HIR preserves move/share intent at call sites
- IR has meaningful `retain` / `release` / `move` semantics
- ZIR emission uses ownership facts to avoid unnecessary retains on unique moves

### Explicitly defer

- full lifetime inference
- deep field-level ownership on every container element
- advanced closure/borrow interaction if it slows the first milestone
- aggressive ARC optimization passes

## Code-Level Change Map

### `src/types.zig`

- add ownership enum/metadata
- extend function typing with ownership-qualified params/results
- add binding ownership state tracking in `TypeChecker`
- add diagnostics for move/borrow/alias violations

### `src/ast.zig`

- add ownership-carrying type expression support
- preserve span info for ownership syntax/diagnostics

### `src/parser.zig`

- parse ownership qualifiers if surfaced in syntax
- otherwise initialize AST ownership defaults consistently

### `src/hir.zig`

- preserve ownership/value-mode information on bindings and call arguments
- mark consuming vs sharing vs borrowing uses

### `src/ir.zig`

- redesign ownership instructions around actual semantics
- remove or strengthen placeholder instructions like `AllocOwned`

### `src/zir_builder.zig`

- lower ownership IR to real ARC operations
- avoid redundant retain/release on proven unique flows

### `src/runtime.zig`

- keep as execution substrate
- make only narrowly necessary support changes after compiler semantics are in
  place

## Test Strategy

### Type-checker tests

- unique value consumed once: ok
- unique value used after move: error
- unique value implicitly aliased: error
- borrowed value returned out of scope: error
- shared values copied freely: ok

### HIR / IR tests

- unique call arg lowers to move/consume path
- shared call arg lowers to retain/share path where needed
- borrowed arg does not trigger ownership transfer

### Runtime / integration tests

- ARC counts remain correct for shared values
- unique flows do not introduce extra retains
- builder/runtime compilation continues to work with ownership metadata present

## Recommended Order of Execution

1. `src/types.zig`
2. `src/ast.zig`
3. `src/parser.zig`
4. `src/hir.zig`
5. `src/ir.zig`
6. `src/zir_builder.zig`
7. `src/runtime.zig`

This order matters because ownership must become true in semantics before it
can become efficient in lowering.

## Success Criteria

Zap can claim meaningful ownership-typed ARC integration when all of the
following are true:

- the type system distinguishes shared, unique, and borrowed values
- the checker enforces move/borrow correctness
- HIR and IR preserve those semantics explicitly
- generated code emits ARC operations from proven ownership facts
- unique flows can avoid redundant retains/releases
- runtime ARC remains the fallback/shared mechanism, not the sole place where
  ownership exists

## Final Recommendation

Do not start from runtime ARC helpers. Start in the type system and make
ownership semantically real. Once that happens, the existing ARC runtime becomes
far more effective with relatively modest backend changes.
