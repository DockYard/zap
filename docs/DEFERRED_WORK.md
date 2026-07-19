# Deferred Work

This file tracks audit/refactor items that remain unresolved after the
Wave 4 cleanup pass. Each entry describes the issue, why it matters, what
a correct fix looks like, and what makes it costly enough that it was
deferred rather than landed in the same pass as the smaller items.

Each entry is self-contained: a fresh session can pick up any one of
them with only this document, the source tree, and the prior commit
history as context.

---

## Pre-existing bug — not yet fixed

### B1. For-comprehension over List/String fails at compile time

**Symptom.** A program like

```zap
pub fn sum([] :: [i64]) -> i64 { 0 }
pub fn sum([h | t] :: [i64]) -> i64 { h + sum(t) }

pub fn main() -> String {
  doubled = for x <- [1, 2, 3] { x * 2 }
  Kernel.inspect(sum(doubled))
  "done"
}
```

fails compilation with:

```
expected type 'T', found 'struct { u32, i64, T }'
note: T = ?*const zap_runtime.List(i64)
```

inside the desugared `__for_N` helper. The same shape with an explicit
intermediate (`res = Enumerable.next(state); case res { ... }`) and
explicit `state :: [i64]` annotation works. The auto-generated for-comp
helper relies on `inferred_signatures` for its parameter type and on
type-flow through the inline `case Enumerable.next(state) { ... }` —
something in that path drops the tuple decomposition and the recursive
call ends up passing the *whole* `next/1` tuple where the `[T]` tail
was expected.

**When this entered the codebase.** Predates this audit cycle —
introduced by commit `9ff3863 Type-driven for-comp dispatch via
Enumerable protocol`. It was *masked* because the integration test
harness was broken (`compileAndRun` ignored `cwd`, so every test in
`zir_integration_tests.zig` ran against the project root's `build.zap`,
which only knows `:test`/`:doc`). With that fixed in this pass, every
for-comp integration test now exercises the real bug.

**What's been ruled out.**

- Not a parser issue (the desugarer constructs the AST directly).
- Not a problem with `protocolDispatchStruct` itself — for the inline
  scrutinee it correctly resolves `Enumerable` → `List` based on the
  state's inferred type.
- Adding an intermediate `__next_call = Enumerable.next(state)`
  binding *changed* the error shape but didn't resolve it (reverted).
- Inferring a list type for the cons expression
  (`list_cons_expr`'s `type_id` from head/tail) didn't help and
  caused other regressions (reverted).

**What the fix likely needs.**

The decision-tree pattern compiler in `hir.zig`
(`compileConstructorColumn` / `stripColumnAndRecurse` /
`compileTupleCheck`) needs to be re-checked for how
`element_scrutinee_ids` flow into the bind nodes for
`{:cont, x, __next_state}` when the enclosing scrutinee is a *call
expression* rather than a `var_ref`. The IR's `lowerDecisionTreeForCase`
resolves bind sources via `scrutinee_map` keyed by the original
scrutinee IDs; it's plausible that a call-scrutinee gets ID `0` and the
tuple element scrutinees collide with the recursive call argument ID,
causing the bind for `__next_state` to resolve back to the entire
tuple local rather than slot 2.

A debug-print of `(scrutinee_map.entries, decision_tree)` for both the
working manual form and the desugar-generated form, on the same input,
would isolate where they diverge.

**Code touched by partial attempts.**

- `src/desugar.zig` — `desugarForEnumerable` (intermediate-variable
  attempt, reverted)
- `src/hir.zig` — `list_cons_expr` type inference (reverted)
- `src/zir_builder.zig` — list/map call_builtin element type encoding
  (kept; helps other typed dispatch cases but doesn't fix this bug)

---

## Architectural refactors — multi-day work

### A1. Two-track pipeline unification

**Files.** `src/compiler.zig` (`compileForCtfe` lines ~525–785,
`compileStructByStruct` lines ~1023–1141, `collectAllFromUnits` lines
~410–520).

**What's duplicated.** Both paths share the same conceptual frontend —
attribute substitution → macro expansion → desugar → re-collect —
implemented inline in two places with subtly different diagnostic
plumbing (one uses `diag_engine`, one uses `ctx.diag_engine`). Per-step
helper functions exist (`runAttributeSubstitution`, `runTypeCheck`,
`runHirBuild`, `compileSingleStructHir`) but the *orchestration* of
those steps is duplicated.

**What's intentionally divergent.**

- `compileForCtfe` runs a *second* type-check pass after CTFE
  evaluation (lines 738–742); the per-struct path doesn't.
- `compileStructByStruct` *intentionally* skips `checkUnusedBindings`
  (compiler.zig:1018–1024) due to false positives in shared-scope-graph
  mode.
- Three CTFE evaluator entry points exist
  (`evaluateStructAttributesInOrder`,
  `evaluateComputedAttributes`,
  `evaluateComputedAttributesForStruct`) that each duplicate ~50 lines
  of interpreter setup.

**What the fix looks like.**

Define a `Pipeline` struct holding the shared state
(`alloc`, `ctx`, `options`, progress reporter, diagnostic engine) and
expose its phases as methods (`runSubstitute`, `runMacroExpand`,
`runDesugar`, `runReCollect`). Each entry point assembles the phases
it needs in order, including the divergent ones (the second
type-check, the unused-binding skip). Diagnostic plumbing collapses
into a single helper that knows how to route through the engine.

**Why deferred.** This is a low-level refactor of code that's
working today, with intentional divergences that cannot be
mechanically extracted. Doing it correctly requires repeated
build-and-integration-test cycles (each ~30 minutes), and a misstep
silently breaks compilation. Best done with a working integration
test green-light to verify.

---

### A2. Single AST visitor

**Files.** All passes that walk the AST: `src/desugar.zig`,
`src/attr_substitute.zig`, `src/macro.zig`, `src/resolver.zig`,
`src/types.zig`, `src/hir.zig`, `src/monomorphize.zig`,
`src/interprocedural.zig`, plus smaller walkers in `src/ctfe.zig` and
`src/ast_data.zig`.

**What's duplicated.** Every pass has its own exhaustive `switch
(expr.*)` over every AST variant. Adding a new AST shape (e.g. the
`tuple_index_get` / `list_index_get` / `list_head_get` / `list_tail_get`
/ `map_value_get` variants added in this audit cycle for assignment
destructuring) requires touching every walker — an easy place to miss
one and silently corrupt analysis.

**What's intentionally divergent.** Each pass carries pass-specific
state that the walker maintains:

- `resolver.zig` walks while maintaining a scope stack.
- `types.zig` walks while propagating a current type-var scope and
  binding ownerships.
- `hir.zig` walks while maintaining several binding lists (tuple,
  struct, list, list-cons, binary, map, case, assignment).
- `monomorphize.zig` walks twice: once to collect specializations,
  once to rewrite call sites.

**What the fix looks like.** A generic `AstVisitor(Context)` that
accepts a context type and a `visit_*` method per AST variant, with
default implementations that recurse into children. Each pass becomes
a thin `Context` implementation that overrides only the variants it
cares about. Default behaviour stays in the visitor itself, so adding
a new AST variant only needs a single update to the visitor.

**Why deferred.** This is a foundational refactor that touches every
pass's correctness. The visitor needs to preserve the order of
traversal that each pass implicitly relies on (some passes mutate
shared state during the walk, e.g. resolver's scope stack). Getting
this wrong silently produces stale type info, missed bindings, or
wrong-arity HIR. Needs careful per-pass verification with the
integration test suite.

---

### A3. Move Zest test framework into Zap macros

**Files.** `lib/zest/case.zap` (already in Zap), `src/macro_eval.zig`
(`build_test_fns` and `build_test_fn` Zig-side builtins), and
`src/runtime.zig` (`Zest` struct holding test/assertion counters).

**What's hardcoded.** The `describe` and `test` macros in
`lib/zest/case.zap` expand by calling `build_test_fns(...)` /
`build_test_fn(...)`, which are *compile-time builtins* implemented in
Zig (`macro_eval.zig`). They construct AST function declarations
representing the `test_<name>` functions wrapped in
`begin_test`/`end_test`/`print_result` tracking calls. The runtime-side
`Zest` struct holds mutable counters because Zap doesn't have native
mutable global state.

**What the fix looks like.**

1. Extend the Zap macro system with comptime primitives for
   constructing function declarations from quoted bodies. Currently
   macros can build expressions but not full function decls.
2. Once the macro system can build function decls, rewrite
   `build_test_fns` and `build_test_fn` as actual Zap macros in
   `lib/zest/case.zap`.
3. Decide whether the test counter state moves to a Zap struct
   (would need a mutable-cell primitive in Zap) or stays as
   `:zig.Zest.*` runtime calls. Likely the counters stay in Zig but
   the orchestration moves into Zap.

**Why deferred.** Step 1 is a language-level feature design — what's
the surface for "construct a function declaration from a name and a
quoted body" in Zap? — not a refactor. Doing it without a design
discussion would lock in shape decisions that are hard to walk back.
The downstream steps depend on step 1.

---

### A4. Hardcoded library names cleanup

**Files.** Per the audit, ~17 string literals across 11 files. The
remaining concentrated names:

- `"Kernel"` in `discovery.zig`, `collector.zig`, `compiler.zig`,
  `desugar.zig` — auto-import bootstrapping.
- `"List"`, `"Map"`, `"Range"`, `"String"` in `types.zig`, `hir.zig`,
  `monomorphize.zig`, `zir_builder.zig`, `ir.zig` — type primitives,
  dispatch decisions, runtime cell mapping.
- `"Enumerable"`, `"Concatenable"`, `"Membership"`, `"Updatable"` —
  protocol names looked up by literal compare.
- `"Zest"` in `runtime.zig` and `zir_builder.zig` — test framework
  state and re-export logic.
- `"Inspect"` / `"to_string"` in `desugar.zig` and `resolver.zig` —
  string interpolation conversion.
- `"Ok"` / `"Error"` variant names in `types.zig` and `zir_builder.zig`
  — `~>` operator's tagged-union default.
- `"Prelude"`, `"ArcRuntime"`, `"BinaryHelpers"`, `"BuilderRuntime"` in
  `zir_builder.zig` — runtime sub-namespace routing.

**What the fix looks like (per category).**

- *Auto-imports*: move the list to a project-level config or a
  `lib/.zap-prelude` manifest; resolve via the manifest at discovery
  time instead of a Zig-side constant.
- *Type primitives*: register Zap structs with the compiler via
  attributes (e.g. `@native_type = "List"`) rather than literal
  compare, so the compiler's runtime-cell dispatch reads from the
  attribute table.
- *Protocol names*: protocol dispatch already goes through the scope
  graph; the remaining literal compares are in places that pre-date the
  scope-graph protocol registration. Replace with
  `graph.findProtocol(name_id)` lookups.
- *Operator-special variants* (`Ok`, `Error`): make `~>` look up the
  catch-basin variant names from the scrutinee's union type rather than
  hardcoding `Ok`/`Error`.
- *Runtime sub-namespaces*: these legitimately name parts of the
  runtime layout. The right move is to consolidate them into a single
  `runtime.namespaces` registry with a name → struct-path table,
  removing the per-call-site literal.

**Why deferred.** Each category is a small change in isolation, but
the categories share dependencies (e.g. removing `"List"` requires the
attribute-driven type-primitive registration to land first). Doing
them safely needs the integration test suite green and a per-category
plan.

---

## Doneness summary

The Tier 1 critical-correctness work (the C1–C19 audit findings) is
complete. The Wave 3 dead-code and helper-consolidation cleanup is
complete. The Wave 4 deferred items that can be done as
self-contained changes (Enumerable for String, the three new
protocols, the fork's source-location fix, the debug-allocator
sentinel fix, the integration-test infrastructure repairs) are
complete. What remains in this file are items whose correct fix
either requires a language-level feature, a multi-day refactor with
verification cycles, or coordinated changes across multiple
categories that share an unresolved design question.
