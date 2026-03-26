# Plan: Nested Defs and First-Class Closures

## Implementation Status

This plan is now implemented to the current compiler architecture level.

Completed:

- [x] nested local `def` is executable end-to-end for the non-capturing case
- [x] nested defs may be called locally
- [x] nested defs may be passed as function values
- [x] nested defs may be returned as function values
- [x] free-variable captures are analyzed during local-function lowering
- [x] capturing nested defs lower to explicit closure creation in HIR/IR
- [x] closure values lower through `make_closure` / `capture_get`
- [x] codegen emits closure invoke/release helpers and closure environments
- [x] direct local calls stay direct for non-capturing local defs
- [x] capturing local defs route through closure calls
- [x] unique captures move into closures
- [x] borrowed captures are rejected for escaping closures in the implemented checker paths
- [x] tests cover non-capturing and capturing nested-def use as local calls, passed values, and returned values

Still conservative by design:

- [x] no separate lambda syntax is needed; nested `def` is the canonical closure surface
- [ ] borrowed-capture reasoning is conservative rather than a full lifetime solver
- [ ] closure ARC/capture optimization is correctness-first, not yet a global optimization pass

## Goal

Turn Zap's existing nested `def` syntax into a real, first-class closure system.

The target model is:

- nested `def` inside function bodies is fully supported end-to-end
- nested defs may reference outer bindings and capture them
- captured nested defs become closure values
- closure values may be:
  - called locally
  - assigned to variables
  - passed as arguments
  - returned from functions when ownership rules allow it
- ownership/ARC rules apply to captured values just like ordinary parameters and
  bindings

This plan intentionally builds from the syntax Zap already has, rather than
introducing lambda syntax first.

## Current State

Today the compiler already has partial groundwork:

- parser accepts nested `def` as a statement in blocks
- collector hoists local defs into the enclosing block/function scope
- HIR records nested defs as `function_group` statements
- IR currently ignores those statements during lowering

That means nested defs are recognized structurally, but not yet implemented as
real executable local functions or closures.

## Desired User Model

### Local function without capture

```zap
defmodule Foo do
  def bar(x :: i64) :: i64 do
    def other(y :: i64) :: i64 do
      y * 10
    end

    other(123)
  end
end
```

This should compile and run as a true local function.

### Closure with shared capture

```zap
defmodule Foo do
  def bar(x :: i64) :: i64 do
    def add_x(y :: i64) :: i64 do
      x + y
    end

    add_x(10)
  end
end
```

`add_x/1` captures `x`.

### Closure passed as an argument

```zap
defmodule Foo do
  def apply(f :: (i64 -> i64), value :: i64) :: i64 do
    f(value)
  end

  def bar(x :: i64) :: i64 do
    def add_x(y :: i64) :: i64 do
      x + y
    end

    apply(add_x, 10)
  end
end
```

### Closure returned from a function

```zap
defmodule Foo do
  def make_adder(x :: i64) :: (i64 -> i64) do
    def add_x(y :: i64) :: i64 do
      x + y
    end

    add_x
  end
end
```

## Semantic Model

### 1. Nested def without free variables

If a nested def references no outer bindings, it behaves like a local function
value with no capture environment.

Implementation may optimize these into plain lifted functions.

### 2. Nested def with free variables

If a nested def references bindings from an enclosing scope, those bindings are
captures.

The compiler should lower this into:

- a lifted function body
- a closure environment struct/record
- a closure value containing:
  - function identity/code pointer
  - captured environment

### 3. Closure values are first-class

Closure values may be:

- called directly
- stored in locals
- passed to other functions
- returned from functions

### 4. Closure typing

Zap function types remain callable types, but closure construction must also
respect ownership of captures.

At minimum the implementation should distinguish:

- callable type shape: params + return type + ownership qualifiers
- capture environment ownership characteristics

## Ownership Rules For Closures

### Shared capture

If a closure captures only shared values:

- closure may itself be shared
- passing it around is allowed
- ARC may retain shared captured values as needed

Example:

```zap
def greet(name :: String) do
  def printer() do
    IO.puts(name)
  end

  printer
end
```

### Unique capture

If a closure captures a unique value:

- capture moves that value into the closure
- outer binding becomes unusable after closure creation
- the closure itself should be treated as consuming/unique unless explicitly
  shared later

Example:

```zap
def make_closer(handle :: unique Handle) do
  def closer() do
    File.close(handle)
  end

  closer
end
```

### Borrowed capture

Borrowed captures are the dangerous case.

Recommended rule:

- allow borrowed captures only for non-escaping closures used immediately in a
  syntactically obvious local context
- reject returning, storing, or passing a closure that captures borrowed values
- reject any closure capture whose lifetime cannot be proven to stay within the
  borrow scope

Conservative first implementation:

- borrowed capture in any escaping closure is an error
- local immediate invocation may be allowed later as an optimization

Example that should be rejected:

```zap
def bad(handle :: borrowed Handle) do
  def f() do
    inspect(handle)
  end

  f
end
```

## API Contract Impact

Closures passed as arguments should preserve function ownership contracts.

For example:

```zap
def apply(f :: (borrowed Handle -> String), h :: Handle) :: String do
  f(h)
end
```

The closure value passed into `apply/2` must accept a borrowed `Handle`.

The closure's captures then add extra constraints:

- if the closure captures shared values, ordinary sharing works
- if it captures unique values, the closure may itself need to be moved
- if it captures borrowed values, it should not escape beyond the borrow scope

## Implementation Plan

### Phase 1: Make nested defs real local functions

#### Files

- `src/collector.zig`
- `src/types.zig`
- `src/hir.zig`
- `src/ir.zig`

#### Work

Implement nested defs end-to-end even before capture support.

Required changes:

- ensure local function families are collected in the correct enclosing function
  or block scope
- type-check nested defs in function-local scopes using the same family
  resolution path as top-level defs
- stop dropping HIR `function_group` statements in IR lowering
- lift nested defs into IR/program function lists so local calls resolve and
  execute

Success criteria:

- nested def with no captures compiles and runs
- direct local call to nested def works
- passing a non-capturing nested def as a function value works

### Phase 2: Add free-variable analysis for nested defs

#### Files

- `src/collector.zig`
- `src/scope.zig`
- `src/hir.zig`

#### Work

Add a capture analysis pass for nested defs.

For each nested function:

- collect all referenced bindings
- subtract locals/params declared within the nested function
- remaining bindings are captures

Store this explicitly in HIR.

Recommended HIR additions:

```zig
pub const Capture = struct {
    name: ast.StringId,
    binding_id: scope_mod.BindingId,
    type_id: TypeId,
    ownership: types_mod.Ownership,
};
```

And attach captures to the lowered function group or closure creation node.

Success criteria:

- a nested function that references outer bindings has an explicit capture list
  in HIR

### Phase 3: Introduce closure creation in HIR

#### Files

- `src/hir.zig`

#### Work

When a nested def is referenced as a value, produce a closure-creation HIR node
instead of pretending it is just a named top-level function.

Two important cases:

- direct call in same scope:
  - may compile either as a direct local function call or closure call
- value position:
  - must produce an actual closure value if captures exist

Recommended HIR behavior:

- non-capturing nested def in value position may degrade to a plain function ref
- capturing nested def in value position must become `closure_create`

Success criteria:

- nested defs used as values become explicit HIR closure values

### Phase 4: Type-check capture ownership

#### Files

- `src/types.zig`

#### Work

Add ownership rules for captures.

Required rules:

- capturing a shared value is allowed
- capturing a unique value moves it into the closure
- outer binding becomes moved/unusable afterward
- capturing a borrowed value is allowed only if the closure is proven non-escaping
  (or reject all borrowed captures initially)

Also add escape checks for closures:

- returned closures
- closures passed to other functions
- closures stored in longer-lived bindings

Minimum viable rule:

- if closure has borrowed captures and is returned/passed/stored, error

Success criteria:

- use-after-capture on unique values is rejected
- borrowed-capture escaping closures are rejected

### Phase 5: Add closure environment representation in IR

#### Files

- `src/ir.zig`

#### Work

Lower closure creation to explicit closure environment semantics.

Recommended IR additions:

```zig
pub const MakeClosure = struct {
    dest: LocalId,
    function: FunctionId,
    captures: []const LocalId,
    capture_modes: []const ValueMode,
};

pub const CaptureGet = struct {
    dest: LocalId,
    index: u32,
};
```

Requirements:

- closure creation must distinguish moved/shared/borrowed captures
- closure body must access captures through explicit capture loads
- local direct call and closure call remain distinct IR operations

Success criteria:

- IR no longer ignores closure creation/capture semantics

### Phase 6: Lower closure environments through codegen/ZIR/runtime

#### Files

- `src/codegen.zig`
- `src/zir_builder.zig`
- `src/runtime.zig`

#### Work

Represent closure environments in generated code.

One practical design:

- emit a struct type per closure environment
- emit a callable wrapper that accepts env + params
- represent closure value as env plus function reference

Ownership behavior:

- shared captures retain on closure creation and release on closure destruction
- unique captures move into the environment without extra retains
- borrowed captures remain non-owning and are only valid for proven
  non-escaping/local cases

Success criteria:

- capturing closures execute correctly
- ARC behavior is correct for shared captured opaque values

### Phase 7: Add closure passing and returning

#### Files

- `src/types.zig`
- `src/hir.zig`
- `src/ir.zig`
- `src/codegen.zig`

#### Work

Support closures as first-class values across API boundaries.

This includes:

- passing closure values to function parameters
- returning closure values
- storing closure values in locals
- using function-type compatibility checks on closure values

Key ownership rule:

- closure value ownership is derived from capture ownership

Recommended policy:

- all-shared captures -> closure is shareable
- any unique capture -> closure is unique by default
- any borrowed capture -> closure cannot escape unless proven safe

Success criteria:

- closure values can be passed and returned correctly
- ownership diagnostics fire when illegal escaping/moves happen

### Phase 8: Optimize non-capturing nested defs

#### Files

- `src/hir.zig`
- `src/ir.zig`

#### Work

Avoid closure env allocation for nested defs that have no captures.

Possible optimization:

- lower to lifted direct function reference
- call directly without environment construction

This is important for keeping nested-def ergonomics cheap when no real closure is
needed.

## Syntax Decisions

No new lambda syntax is required for this plan.

Nested `def` is the canonical closure form in Zap.

If lambda syntax is ever added later, it should be treated only as sugar over
the same closure pipeline rather than as a separate feature model.

## Type System Work

### Function type ownership

Already implemented:

- parameter ownership qualifiers
- return ownership qualifiers

Needed for closures:

- closure value compatibility with function types
- closure environment ownership classification

### Escape classification

Add a checker notion of closure escape sites:

- returned from function
- assigned to non-temporary binding
- passed as argument

This lets borrowed capture rules stay conservative and sound.

## ARC Strategy For Closures

### Shared captures

- retain at closure creation
- release when closure env is dropped

### Unique captures

- move into env
- no extra retain on capture
- outer binding becomes moved

### Borrowed captures

- no ARC ops
- only valid for non-escaping closure cases

## Test Plan

### Parser / AST

- nested defs parse in function bodies
- `unique` / `borrowed` param ownership parse correctly
- function-type ownership annotations parse correctly

### Type checker

- non-capturing nested def can be called
- capturing shared value is allowed
- capturing unique value moves outer binding
- using unique after capture is an error
- escaping closure with borrowed capture is an error
- returning borrowed capture is an error

### HIR

- nested defs produce function groups in local scope
- capturing nested defs produce explicit closure-create nodes
- capture ownership/value mode is preserved

### IR

- closure creation emits explicit capture env instructions
- non-capturing nested defs optimize to direct function reference/call where
  possible
- unique capture lowers to move semantics
- shared capture lowers to share/retain semantics
- borrowed capture lowers without ARC ops

### Integration

- direct local nested def call executes correctly
- closure passed as argument executes correctly
- closure returned from function executes correctly
- shared captured opaque values retain/release correctly
- unique captured opaque values avoid unnecessary retain/release

## Recommended Implementation Order

1. make nested defs executable without capture support
2. add free-variable capture analysis
3. add HIR closure-create nodes
4. add checker ownership rules for captures and escape
5. add IR capture environment semantics
6. add codegen/ZIR/runtime closure env lowering
7. support passing/returning closure values
8. optimize non-capturing local defs

## Final Recommendation

The right way to implement closures in Zap is to use nested `def` as the
canonical closure form, make captures explicit in the compiler, and let
ownership determine whether closure values are shared, moved, or forbidden to
escape.

That gives Zap:

- a consistent user model
- strong API contracts
- ownership-aware closure safety
- ARC behavior driven by semantics rather than guesswork
