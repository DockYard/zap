# Generics & Protocols Implementation Plan

## Goal

Add parametric polymorphism (generics) and protocol-based dispatch to Zap so that `Enum.map` works on `[String]`, `[Float]`, `%{String => i64}`, and any user-defined collection — not just `[i64]`.

## What Exists Today

The compiler already has significant infrastructure for generics:

- **Type variables** (`TypeVarId`) and substitution maps for Hindley-Milner inference (`types.zig:12-13, 496-570`)
- **`AppliedType`** struct for generic type instantiation (`types.zig:132-135`)
- **`MonomorphRegistry`** to track and deduplicate generic function specializations (`types.zig:682-888`)
- **Type parameters** in `TypeDecl` and `OpaqueDecl` AST nodes (`ast.zig:145-162`)
- **`TypeNameExpr.args`** already supports type arguments in the AST (`ast.zig:857-861`)
- **Unification algorithm** with occurs check (`types.zig:496-570`)
- **`monomorphize.zig`** — a monomorphization pass that creates specialized function copies

What's missing:
- Generic type parameters on **function declarations** (only type declarations have them)
- Protocol/trait declarations
- Protocol implementation blocks
- Protocol constraint resolution at call sites
- Lowering monomorphized protocol calls to ZIR

## Design

### Syntax

**Generic functions** — type variables are implicitly introduced by lowercase type names in signatures:

```zap
pub fn identity(x :: a) -> a {
  x
}

pub fn map(list :: [a], f :: (a -> b)) -> [b] {
  # ...
}
```

Lowercase type names (`a`, `b`, `element`, `key`, `value`) that don't resolve to a known type are inferred as type parameters. This matches Haskell/Elixir convention and avoids Rust-style `<T>` angle bracket syntax.

**Protocol declarations:**

```zap
protocol Enumerable(element :: type) {
  fn reduce(self, acc :: b, f :: (element, b -> b)) -> b
}
```

- `protocol` is a new keyword
- `element :: type` declares a type parameter (the associated type for what the collection yields)
- `self` is an implicit first parameter referring to the implementing type
- Functions can introduce their own type variables (`b`)

**Protocol implementations:**

```zap
impl Enumerable(a) for [a] {
  fn reduce(self, acc :: b, f :: (a, b -> b)) -> b {
    case self {
      [] -> acc
      [head | tail] -> reduce(tail, f.(head, acc), f)
    }
  }
}

impl Enumerable({k, v}) for %{k => v} {
  fn reduce(self, acc :: b, f :: ({k, v}, b -> b)) -> b {
    :zig.map_reduce(self, acc, f)
  }
}
```

- `impl Protocol(TypeArgs) for ConcreteType` syntax
- The implementing type can itself be generic (`[a]`, `%{k => v}`)
- Implementation functions must match the protocol's signature

**Using protocols in function signatures:**

```zap
pub fn map(coll :: Enumerable(a), f :: (a -> b)) -> [b] {
  Enumerable.reduce(coll, [], fn(elem, acc) {
    List.append(acc, f.(elem))
  })
}
```

When a parameter type is a protocol name, the compiler resolves the concrete implementation at each call site and monomorphizes.

### Compilation Strategy: Monomorphization

All protocol dispatch is resolved at compile time via monomorphization. No vtables, no dictionary passing, no runtime dispatch.

When the compiler sees:
```zap
Enum.map([1, 2, 3], fn(x) { x * 2 })
```

It knows:
1. `coll` has type `[i64]`
2. `Enumerable(a) for [a]` matches with `a = i64`
3. `Enum.map` is monomorphized to `Enum.map__list_i64_i64`
4. `Enumerable.reduce` calls within are resolved to the `[a]` impl, also monomorphized

This produces zero-overhead native code — direct function calls, no indirection.

For `Enum.map(%{"a" => 1, "b" => 2}, fn({k, v}) { v })`:
1. `coll` has type `%{String => i64}`
2. `Enumerable({k, v}) for %{k => v}` matches with `k = String, v = i64`
3. Different monomorphized version generated

### ZIR Lowering

Monomorphized functions lower to Zig's ZIR as concrete, non-generic functions. Each instantiation becomes a separate ZIR function with mangled name:

```
Enum__map__list_i64__fn_i64_i64  →  ZIR function with [i64] list ops
Enum__map__map_String_i64__fn_...  →  ZIR function with map iterator ops
```

This maps cleanly to how Zig handles comptime generics internally — each instantiation is a fully concrete function body.

## Implementation Order

### Phase 1: Generic Functions (no protocols yet)

Make `Enum.map([String], fn(s) { ... })` work by allowing type variables in function signatures.

#### 1.1 Parser — recognize type variables in function signatures

**File: `src/parser.zig`**

Currently, type annotations like `:: i64` resolve `i64` as a `TypeNameExpr`. A lowercase name like `a` would be parsed the same way — `TypeNameExpr { .name = "a", .args = &.{} }`.

The parser doesn't need to change. The distinction between concrete types and type variables is made during type checking, not parsing. A `TypeNameExpr` with name `a` is resolved as a type variable if it doesn't match any known type.

**No parser changes needed.**

#### 1.2 Type Checker — infer type variables from function signatures

**File: `src/types.zig`**

In `resolveTypeExpr()` (line 3220), when resolving a `TypeNameExpr`:
1. Look up the name in the type store and scope graph
2. If found → concrete type (existing behavior)
3. If **not found** and the name is lowercase → create a fresh type variable

Add a `type_var_scope: std.StringHashMap(TypeVarId)` to `TypeChecker` that maps type variable names to their IDs within the current function scope. This ensures `a` in parameter 1 and `a` in parameter 2 refer to the same type variable.

```zig
// In resolveTypeExpr, TypeExpr.name branch:
const name_str = self.interner.get(tn.name);
// Check if it's a known type
if (self.store.findTypeByName(name_str)) |tid| return tid;
// Check if it's a type variable (lowercase, not a known type)
if (name_str[0] >= 'a' and name_str[0] <= 'z') {
    if (self.type_var_scope.get(name_str)) |existing_var| {
        return self.store.addType(.{ .type_var = existing_var });
    }
    const fresh = self.store.freshVar();
    self.type_var_scope.put(name_str, fresh);
    return self.store.addType(.{ .type_var = fresh });
}
```

The `type_var_scope` is reset at the start of each function family's type check.

#### 1.3 Type Checker — unify type variables at call sites

When type-checking a call like `Enum.map(["hello", "world"], fn(s) { ... })`:
1. The callee's signature has type variables `a`, `b`
2. The argument `["hello", "world"]` has type `[String]`
3. Unify `[a]` with `[String]` → binds `a = String`
4. The callback `fn(s) { ... }` has inferred type `(String -> ?)` — unify with `(a -> b)` → confirms `a = String`, binds `b` to the callback's return type

The existing unification algorithm (`types.zig:496-570`) already handles this. The change is ensuring type variables from the callee's signature are instantiated fresh for each call site and unified with the argument types.

**Key change in `checkCallExpr()`**: Before checking args against params, instantiate fresh type variables for the callee's generic params. After checking, record the bindings in the `MonomorphRegistry`.

#### 1.4 Monomorphization — generate specialized copies

**File: `src/monomorphize.zig`**

The `MonomorphRegistry` already tracks instantiations. The monomorphization pass needs to:
1. For each instantiation, clone the function's AST/HIR/IR with type variables substituted
2. Generate a mangled name (e.g., `Enum__map__String_String`)
3. Replace call sites with calls to the specialized version

The existing `monomorphize.zig` has scaffolding for this but needs to be completed for function-level generics (currently it looks for type_var in params but doesn't do full AST cloning with substitution).

#### 1.5 Update Enum module with generic signatures

**File: `lib/enum.zap`**

Change all function signatures from monomorphic to generic:

```zap
# Before
pub fn map(list :: [i64], callback :: (i64 -> i64)) -> [i64]

# After
pub fn map(list :: [a], callback :: (a -> b)) -> [b]
```

Do this for all Enum functions: `map`, `filter`, `reject`, `reduce`, `each`, `find`, `any?`, `all?`, `count`, `sum`, `product`, `max`, `min`, `sort`, `take`, `drop`, `reverse`, `member?`, `at`, `empty?`, `concat`, `uniq`.

Some functions have natural constraints (e.g., `sum` only works on numeric types) — these can initially keep `i64` signatures and be generalized later when numeric protocols exist.

#### 1.6 Update List module

**File: `lib/list.zap`**

Same treatment — change `[i64]` to `[a]` where appropriate:

```zap
pub fn head(list :: [a]) -> a
pub fn tail(list :: [a]) -> [a]
pub fn append(list :: [a], item :: a) -> [a]
pub fn contains?(list :: [a], item :: a) -> Bool
```

### Phase 2: Protocol Declarations

#### 2.1 Parser — new `protocol` keyword and syntax

**File: `src/parser.zig`, `src/lexer.zig`, `src/token.zig`**

Add `protocol` and `impl` as reserved keywords. Parse protocol declarations:

```
protocol_decl = 'protocol' IDENTIFIER '(' type_params ')' '{' protocol_body '}'
protocol_body = (fn_signature)*
fn_signature  = 'fn' IDENTIFIER '(' params ')' '->' type_expr
```

And impl blocks:

```
impl_decl = 'impl' IDENTIFIER '(' type_args ')' 'for' type_expr '{' impl_body '}'
impl_body = (function_decl)*
```

AST nodes needed:

```zig
pub const ProtocolDecl = struct {
    meta: NodeMeta,
    name: StringId,
    type_params: []const TypeParam,
    functions: []const ProtocolFunction,
};

pub const ProtocolFunction = struct {
    meta: NodeMeta,
    name: StringId,
    params: []const Param,
    return_type: ?*const TypeExpr,
};

pub const ImplDecl = struct {
    meta: NodeMeta,
    protocol_name: StringId,
    type_args: []const *const TypeExpr,
    target_type: *const TypeExpr,
    functions: []const *const FunctionDecl,
};
```

Add to `ModuleItem`:
```zig
protocol: *const ProtocolDecl,
impl_block: *const ImplDecl,
```

#### 2.2 Collector — register protocols and impls

**File: `src/collector.zig`, `src/scope.zig`**

Add to `ScopeGraph`:
```zig
protocols: std.ArrayList(ProtocolEntry),
impls: std.ArrayList(ImplEntry),
```

Where:
```zig
pub const ProtocolEntry = struct {
    name: ast.StringId,
    scope_id: ScopeId,
    type_params: []const ast.TypeParam,
    functions: []const ProtocolFunctionSig,
};

pub const ProtocolFunctionSig = struct {
    name: ast.StringId,
    param_types: []const TypeId,
    return_type: TypeId,
};

pub const ImplEntry = struct {
    protocol_name: ast.StringId,
    type_args: []const TypeId,
    target_type: TypeId,
    function_families: []const FunctionFamilyId,
};
```

The collector walks `ModuleItem.protocol` and `ModuleItem.impl_block`, registers them in the scope graph.

#### 2.3 Type Checker — resolve protocol constraints

**File: `src/types.zig`**

When type-checking a function parameter typed as `Enumerable(a)`:
1. Look up `Enumerable` in the protocol registry
2. Create a **protocol constraint** on the parameter: "this type must have an impl of Enumerable"
3. At call sites, when the concrete type is known, look up the matching impl
4. If no impl found → type error: "type X does not implement Enumerable"

Add to `TypeChecker`:
```zig
protocol_constraints: std.ArrayList(ProtocolConstraint),

pub const ProtocolConstraint = struct {
    type_var: TypeVarId,
    protocol_name: ast.StringId,
    protocol_type_args: []const TypeId,
};
```

During unification, when a type variable with a protocol constraint is bound to a concrete type, verify the impl exists.

#### 2.4 Type Checker — resolve protocol function calls

When type-checking `Enumerable.reduce(coll, acc, f)`:
1. `coll` has a protocol constraint `Enumerable(a)`
2. Look up the concrete type of `coll` (resolved via unification)
3. Find the matching impl
4. Resolve `reduce` to the impl's function family
5. Record in MonomorphRegistry for monomorphization

### Phase 3: Monomorphization of Protocol Calls

#### 3.1 Expand monomorphize.zig

**File: `src/monomorphize.zig`**

For each call to a function with protocol-constrained parameters:
1. Resolve which impl satisfies the constraint
2. Clone the function body with:
   - Type variables substituted with concrete types
   - Protocol method calls replaced with impl method calls
3. Generate mangled name incorporating the concrete types

#### 3.2 HIR — protocol-aware lowering

**File: `src/hir.zig`**

The HIR builder needs to handle:
- `ProtocolDecl` → register protocol metadata (no code generation)
- `ImplDecl` → lower impl functions as regular functions with mangled names
- Protocol method calls → resolve to the concrete impl function

#### 3.3 IR — no special handling needed

Protocol dispatch is fully resolved by monomorphization before IR generation. The IR sees only concrete, non-generic functions. No changes to `src/ir.zig`.

#### 3.4 ZIR — no special handling needed

Same as IR — monomorphized functions lower to ZIR as concrete functions. No changes to `src/zir_builder.zig`.

### Phase 4: Standard Library Protocols

#### 4.1 Define Enumerable protocol

**File: `lib/enumerable.zap`**

```zap
pub module Enumerable {
  protocol Enumerable(element :: type) {
    fn reduce(self, acc :: b, f :: (element, b -> b)) -> b
  }
}
```

#### 4.2 Implement for List

**File: `lib/list.zap`**

```zap
impl Enumerable(a) for [a] {
  fn reduce(self, acc :: b, f :: (a, b -> b)) -> b {
    case self {
      [] -> acc
      [head | tail] -> reduce(tail, f.(head, acc), f)
    }
  }
}
```

#### 4.3 Implement for Map

**File: `lib/map.zap`**

```zap
impl Enumerable({k, v}) for %{k => v} {
  fn reduce(self, acc :: b, f :: ({k, v}, b -> b)) -> b {
    :zig.map_reduce(self, acc, f)
  }
}
```

#### 4.4 Rewrite Enum to use Enumerable

**File: `lib/enum.zap`**

```zap
pub module Enum {
  pub fn map(coll :: Enumerable(a), f :: (a -> b)) -> [b] {
    Enumerable.reduce(coll, [], fn(elem, acc) {
      List.append(acc, f.(elem))
    })
  }

  pub fn filter(coll :: Enumerable(a), pred :: (a -> Bool)) -> [a] {
    Enumerable.reduce(coll, [], fn(elem, acc) {
      if pred.(elem) { List.append(acc, elem) } else { acc }
    })
  }

  pub fn reduce(coll :: Enumerable(a), initial :: b, f :: (a, b -> b)) -> b {
    Enumerable.reduce(coll, initial, f)
  }

  pub fn each(coll :: Enumerable(a), f :: (a -> Nil)) -> Atom {
    Enumerable.reduce(coll, :ok, fn(elem, _acc) {
      f.(elem)
      :ok
    })
  }

  pub fn find(coll :: Enumerable(a), default :: a, pred :: (a -> Bool)) -> a {
    # Implementation using reduce with early-exit pattern
  }

  pub fn any?(coll :: Enumerable(a), pred :: (a -> Bool)) -> Bool {
    Enumerable.reduce(coll, false, fn(elem, acc) {
      if acc { true } else { pred.(elem) }
    })
  }

  pub fn all?(coll :: Enumerable(a), pred :: (a -> Bool)) -> Bool {
    Enumerable.reduce(coll, true, fn(elem, acc) {
      if acc { pred.(elem) } else { false }
    })
  }

  pub fn count(coll :: Enumerable(a), pred :: (a -> Bool)) -> i64 {
    Enumerable.reduce(coll, 0, fn(elem, acc) {
      if pred.(elem) { acc + 1 } else { acc }
    })
  }
}
```

### Phase 5: Future Protocols

Once the protocol system is in place, define additional protocols:

```zap
protocol Comparable(a :: type) {
  fn compare(self :: a, other :: a) -> Atom  # :lt, :eq, :gt
}

protocol Stringable {
  fn to_string(self) -> String
}

protocol Numeric {
  fn add(self, other :: Self) -> Self
  fn multiply(self, other :: Self) -> Self
  fn zero() -> Self
}
```

This enables:
- `Enum.sort` working on any `Comparable` type
- `IO.puts` accepting any `Stringable`
- `Enum.sum` working on any `Numeric`

## Testing Strategy

1. **Phase 1 tests:** Generic functions with `[String]`, `[Float]`, `[{String, i64}]`
2. **Phase 2 tests:** Protocol declaration and impl parsing
3. **Phase 3 tests:** Protocol dispatch resolution, monomorphization
4. **Phase 4 tests:** Full Enum over strings, maps, nested collections

```zap
# Phase 1 test
test("map over strings") {
  result = Enum.map(["hello", "world"], fn(s) { String.upcase(s) })
  assert(result == ["HELLO", "WORLD"])
}

# Phase 4 test
test("filter over map entries") {
  result = Enum.filter(%{"a" => 1, "b" => 2, "c" => 3}, fn({_k, v}) { v > 1 })
  assert(result == [{"b", 2}, {"c", 3}])
}
```

## Risk Assessment

- **Phase 1 (generics):** Medium risk. Most infrastructure exists. Main work is completing the monomorphization pass and updating type inference at call sites.
- **Phase 2 (protocol declarations):** Low risk. Parser/collector changes are mechanical.
- **Phase 3 (protocol dispatch):** High risk. Constraint resolution and impl lookup during type checking is the hardest part. Edge cases: overlapping impls, impl for generic types, protocol inheritance.
- **Phase 4 (stdlib rewrite):** Medium risk. Requires all previous phases to be solid. The `map_reduce` runtime primitive for maps needs to be added.

## Non-Goals

- **Dynamic dispatch / existential types** — all dispatch is monomorphized. No `dyn Enumerable` equivalent.
- **Protocol inheritance** — protocols are flat for now. No `protocol Orderable extends Comparable`.
- **Default implementations** — protocol functions must be implemented in every impl. No default bodies.
- **Conditional impls** — no `impl Stringable for [a] where a: Stringable`. Each impl is for a concrete shape.
