# Generics Implementation: Current Status & Blocking Issue

## What is Zap

Zap is a statically-typed functional programming language that compiles to native code. It has Elixir-like syntax (pattern matching, pipes, modules) but compiles through Zig's compiler backend. The compilation pipeline is:

```
Parse → Collect → Macro Expand → Desugar → Type Check → HIR → Monomorphize → IR → ZIR → Zig Sema → LLVM → Native
```

Key architectural facts:
- Source files are `.zap` files, each containing one module
- All modules share one **scope graph** (symbol table) built during collection
- The compiler has a **StringInterner** shared across all modules
- Modules are compiled in dependency order
- The test framework uses macros (`describe`, `test`) that expand into function declarations

## What We're Building

Parametric polymorphism (generics) so that collection functions like `List.head`, `Enum.map`, etc. work with any element type, not just `i64`.

### Example of what works today (intra-module generics)

```zap
pub struct Test.FunctionTest {
  # This function is generic — `element` is a type variable
  fn identity(x :: element) -> element {
    x
  }

  # These tests pass — monomorphized to identity__i64, identity__Bool, identity__String
  test("integer") { assert(identity(42) == 42) }
  test("bool")    { assert(identity(true) == true) }
  test("string")  { assert(identity("hello") == "hello") }
}
```

This works end-to-end: 446 tests pass, 478 assertions.

### What we're trying to make work (cross-module generics)

```zap
# In lib/list.zap
pub struct List {
  pub fn head(list :: [element]) -> element {
    :zig.ListCell.getHead(list)
  }
}

# In test/enum_test.zap
pub struct Test.EnumTest {
  test("map doubles values") {
    result = Enum.map([1, 2, 3], double)
    assert(List.head(result) == 2)    # ← This call needs cross-module monomorphization
  }
}
```

## What Works

The following pieces are implemented and working:

1. **Type variable scoping** (`src/types.zig`): Lowercase type names in function signatures (like `element`) become type variables. Same name within a clause = same TypeVarId. TypeChecker has a `type_var_scope: StringHashMap(TypeId)` cleared per clause.

2. **Call-site unification** (`src/types.zig`): When calling a generic function, argument types are unified against parameter types via Hindley-Milner unification. The resolved substitution is applied to the return type.

3. **Monomorphization** (`src/monomorphize.zig`): Full pipeline — detect generic function groups, scan all call sites, unify arg types, create specialized copies with mangled names (`identity__i64`), rewrite call targets from original → specialized via pointer-identity mapping.

4. **IR generic skip** (`src/ir.zig`): Generic functions (containing type_var in params/return) are skipped during IR building (emit empty stub to preserve ID ordering). Only monomorphized copies are compiled.

5. **Shared TypeStore** (`src/types.zig`, `src/compiler.zig`): All modules share one TypeStore (InternPool pattern). TypeIds are globally consistent. Structural deduplication in `addType` prevents identical types from getting different IDs.

6. **Globally-unique function group IDs** (`src/compiler.zig`): Each module's HIR builder starts group IDs at an offset, so group IDs don't collide when modules are merged for whole-program monomorphization.

7. **Whole-program monomorphization** (`src/compiler.zig`): The compilation pipeline does:
   - Phase 1: Compile all modules to HIR (shared TypeStore)
   - Phase 2: Merge all HIR modules
   - Phase 3: Run monomorphization across all modules
   - Phase 4: Compile each module's HIR to IR

8. **Cross-module named call resolution** (`src/monomorphize.zig`): The monomorphizer resolves `.named` cross-module calls (e.g., `List.head` called from `Test.ListTest`) by searching the merged HIR for the target module/function. Creates specializations and rewrites `.named` → `.direct`.

9. **Per-module specialization placement**: Each calling module gets its own copy of the specialization (keyed by module index in dedup hash) so `call_direct` resolves within the module's own IR.

10. **ListCell type variants** (`src/runtime.zig`): `ListCellOf(T)` generic runtime exists. `StringListCell`, `BoolListCell`, `FloatListCell`, `AtomListCell` pre-instantiated. IR builder rewrites `:zig.ListCell.*` → correct variant based on element type.

11. **HIR list literal type inference** (`src/hir.zig`): List literals like `[1, 2, 3]` now have `type_id = list(i64)` instead of UNKNOWN.

12. **Cross-module return type resolution** (`src/hir.zig`): `resolveFunctionReturnTypeInModule` resolves return types for module-qualified calls by searching the scope graph.

13. **Function body type checking** (`src/types.zig`): TypeChecker now traverses function bodies (not just signatures) to set binding types on assignment variables.

## The Blocking Issue

**When `List.head` is made generic (`[element]` instead of `[i64]`), 13 tests fail.** All failures are "expected 0 argument(s), found 1" — meaning the call hits the generic stub instead of a monomorphized specialization.

### Root cause

The monomorphization pass needs to know the concrete type of each argument to a generic function call. For calls like `List.head(result)` where `result` is a local variable, the argument's `type_id` in the HIR expression must be set correctly (e.g., `list(i64)`).

The `type_id` on a variable reference expression comes from the variable's **binding** in the scope graph. The binding's type is set by the **TypeChecker** when it processes the assignment `result = Enum.map([1, 2, 3], double)`. The TypeChecker infers `Enum.map(...)` returns `list(i64)` and stores this on the `result` binding.

**The problem**: The TypeChecker's `inferCall` for module-qualified calls like `Enum.map(...)` works correctly for SOME modules but returns `UNKNOWN` for others — specifically Test.EnumTest. The issue is in the TypeChecker's function body traversal.

### Detailed trace

1. `compileSingleModuleHir` creates a TypeChecker with the shared TypeStore
2. TypeChecker calls `checkProgram(desugared)` for the module's AST
3. `checkProgram` → `checkModule` → `checkFunctionDecl` for each function
4. `checkFunctionDecl` calls `checkFunctionClause` (checks param/return type annotations)
5. Then traverses the function body: `for (body) |stmt| { _ = self.checkStmt(stmt) catch {}; }`
6. `checkStmt(.assignment)` calls `inferExpr(assign.value)` on `Enum.map([1,2,3], double)`
7. `inferExpr` → `inferCall` → `field_access → module_ref` path
8. The module search finds the Enum module (confirmed by debug traces)
9. `resolveFamilySignature(Enum.scope_id, "map", 2)` finds the `map/2` signature (confirmed)
10. For Test.ForComprehensionTest: returns `list(i64)` (type 21) ✓
11. For Test.EnumTest: returns `UNKNOWN` (type 18) ✗

### The specific failure point

Inside the `if (fam_sig) |signature|` block, the code iterates call arguments and calls `try self.inferExpr(arg)` for each. For `Enum.map([1,2,3], double)`:
- Arg 1: `[1, 2, 3]` — a list literal, `inferExpr` returns `list(i64)` ✓
- Arg 2: `double` — a function reference (bare var_ref to a module-level function)

If `inferExpr(double)` throws an error (because `double` can't be resolved in the current scope during body traversal), the `try` propagates the error out of the for loop. The caller has `catch {}` which swallows the error. The binding type is never set.

### Why `double` might fail

`double` is a function defined at the module level of Test.EnumTest:
```zap
fn double(x :: i64) -> i64 { x * 2 }
```

During the body traversal in `checkFunctionDecl`, `self.current_scope` is set to the function clause's scope (e.g., the scope of `test_enum_module_map_doubles_values/0`). The `double` function is defined in the module scope, which is the PARENT of the clause scope. The scope chain should connect clause → module → prelude, so `double` should be resolvable.

But for MACRO-GENERATED functions (the `test` macro generates `pub fn test_xxx`), the scope chain might be broken. The macro-generated function's clause scope might not properly chain to the module scope, making module-level functions like `double` invisible.

### Why Test.ForComprehensionTest works but Test.EnumTest doesn't

Test.ForComprehensionTest uses anonymous functions: `Enum.map([1,2,3], fn(x :: i64) -> i64 { x * 2 })`. The anonymous function literal is a self-contained expression — `inferExpr` can fully infer its type without resolving any external names.

Test.EnumTest uses named function references: `Enum.map([1,2,3], double)`. This requires resolving `double` by name in the scope chain, which fails for macro-generated function scopes.

## Relevant Files

| File | Role |
|------|------|
| `src/types.zig` | TypeChecker, TypeStore, unification, type inference |
| `src/hir.zig` | HIR builder — builds HIR from desugared AST |
| `src/monomorphize.zig` | Monomorphization pass — specializes generic functions |
| `src/ir.zig` | IR builder — lowers HIR to IR, skips generic stubs |
| `src/compiler.zig` | Pipeline orchestration, shared TypeStore, whole-program mono |
| `src/scope.zig` | Scope graph — shared symbol table across all modules |
| `src/zir_builder.zig` | ZIR emission — lowers IR to Zig's ZIR for final compilation |
| `lib/list.zap` | List module (target for generic signatures) |
| `lib/enum.zap` | Enum module (higher-order functions over lists) |
| `test/enum_test.zap` | Test module that exercises Enum functions |

## Key Data Structures

### TypeStore (`src/types.zig:165`)
```
types: ArrayList(Type)       # Array of all types, indexed by TypeId (u32)
name_to_type: HashMap        # User type name → TypeId
next_var: TypeVarId           # Counter for fresh type variables
inferred_signatures: HashMap  # Cached inferred function signatures
```

TypeId is an index into the `types` array. Well-known types have fixed IDs: BOOL=0, STRING=1, ATOM=2, NIL=3, NEVER=4, I64=5, ..., UNKNOWN=18, ERROR=19.

### TypeChecker (`src/types.zig:930`)
```
store: *TypeStore              # Pointer to shared type store
type_var_scope: StringHashMap  # Maps type var names → TypeId per clause
current_scope: ?ScopeId        # Current scope for binding resolution
```

### HIR FunctionGroup (`src/hir.zig:43`)
```
id: u32                       # Globally unique group ID
name: StringId                # Function name
arity: u32
clauses: []Clause             # Function clauses with typed params
```

### HIR CallTarget (`src/hir.zig:250`)
```
direct: { function_group_id }   # Intra-module call by group ID
named: { module, name }         # Cross-module call by string names
dispatch: { function_group_id } # Pattern-match dispatch
builtin: []const u8             # :zig. bridge call
```

### MonomorphContext (`src/monomorphize.zig:147`)
```
generic_groups: HashMap(u32, *FunctionGroup)  # Group ID → generic function
specializations: HashMap(u64, u32)            # Dedup key → specialized group ID
call_rewrites: HashMap(u64, u32)              # Expr pointer → new group ID
current_scan_module_idx: ?usize               # Which module is being scanned
```

## What Needs to Happen

The `inferExpr` call for the function reference `double` (a bare `var_ref`) must NOT throw an error during body traversal. Either:

1. **Fix the scope chain** for macro-generated function scopes so module-level functions are visible during body traversal
2. **Make body traversal error-tolerant** for individual expressions (currently `try self.inferExpr(arg)` propagates errors that abort the entire call inference)
3. **Skip argument inference errors** and still return the function's declared return type

Option 2 is the most targeted fix: change the argument loop in `inferCall` to use `catch` instead of `try` so a single argument inference failure doesn't prevent the return type from being resolved.

## Test Results

- **446 tests, 0 failures** with `List.head(list :: [i64]) -> i64` (monomorphic)
- **446 - 13 = 433 tests pass** with `List.head(list :: [element]) -> element` (generic)
- The 13 failures are all from Test.EnumTest (12) and Test.ForComprehensionTest (1)
- All failures are "expected 0 argument(s), found 1" — the call hits the generic stub instead of a monomorphized specialization
