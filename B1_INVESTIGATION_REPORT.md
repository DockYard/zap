# B1 — For-Comp Over List/String Compile Bug

This report captures everything an investigator needs to continue work on
the B1 deferred item from `DEFERRED_WORK.md`. It assumes no prior context
on Zap, the Zig fork, or any of the partial fixes attempted so far.

The first half is **architecture and orientation**. The second half is
**what's been tried, what works, what broke, and where to look next**.

> **Status (this session, 2026-04-27)** — **B1 fully resolved.** All
> three for-comprehension shapes now compile and run correctly:
>
> - List for-comp `for x <- [1,2,3] { x*2 }` → `12` ✓
> - Filter for-comp `for x <- xs, pred { x }` → `12` ✓
> - String for-comp `for c <- "abc" { c <> "!" }` → `a!b!c!` ✓
>
> The fixes that landed (in order applied):
>
> 1. `ast.isDiscardBindName` helper distinguishing `_x` (user discard)
>    from `__x` (compiler-synthesised). Replaces 4 underscore-prefix
>    literal checks in `src/hir.zig` so `__next_state`, `__loop_raw`,
>    `__err`, `__state` are properly tracked.
> 2. `case_expr` HIR builder rewritten to append-then-shrink instead of
>    save-reset-restore, so nested case clauses see the outer arm's
>    bindings (the desugarer's filter-case sits inside the cont arm).
> 3. Type-checker mirror of `protocolDispatchStruct` — when the call's
>    qualifying struct is a registered protocol and the first arg has
>    a matching impl, redirect to the impl's signature so the call's
>    inferred return type uses the impl's concrete shape rather than
>    the protocol's abstract one.
> 4. Collector registers each `case_clause` scope in
>    `node_scope_map` and writes `clause.meta.scope_id`, so later
>    passes can locate it via `resolveClauseScope`.
> 5. `recordCasePatternBindingTypes` + `checkCaseClause` flow scrutinee
>    type into pattern bindings, gated on `containsTypeVars` so generic
>    function bodies don't get pinned to concrete specialisations.
> 6. `recordParamBindingTypes` (a `containsTypeVars`-guarded wrapper
>    around `recordAssignmentBindingTypes`) extends function-clause
>    parameter typing to compound patterns: `[h | t] :: [String]` now
>    gives `h :: String`, `t :: [String]`.
> 7. HIR's `case_expr` builder switches `current_clause_scope` to the
>    case-clause scope while building each arm so var_refs see the
>    binding types the type checker recorded.
> 8. HIR's `list_cons_expr` infers its result type from the head's
>    type (or the tail's list type), so `[String_call | rec]` is
>    typed `[String]` instead of UNKNOWN.
> 9. HIR's `case_expr` unifies arm result types and post-patches
>    structurally-empty siblings (`[]`, `%{}`) to the unified type via
>    `patchEmptyContainerTypes`. Without this, a case whose cont arm
>    produces `[String]` and whose done arm is `[]` (defaulted to
>    `[i64]`) would mismatch at the dest local.
> 10. `buildBlock` now sets `Block.result_type` from the last
>     statement's type (it was always UNKNOWN before), enabling the
>     case-arm unifier above.
> 11. `resolveFunctionReturnType` falls back to the call-site-inferred
>     signature in `inferred_signatures` for synthetic helpers
>     without source annotations, so recursive `__for_N` calls see the
>     fixpoint-computed return type.
>
> **Test status after fixes**: 540/540 unit tests pass; ZIR integration
> tests 55/78 (+3 from baseline 52). The remaining 23 ZIR failures and
> the `zap test` errors are pre-existing wave-4 issues unrelated to
> B1 (closure capture, catch-basin, struct field access, map ops,
> keyword lists, etc.).
>
> A4 category 1 (type-primitive attribute registration) also landed:
> `NativeTypeKind` enum + `ScopeGraph` registry,
> `@native_type` attribute parsing, `@native_type` annotations on the
> stdlib structs (List, Map, Range, String), 5 hardcoded literal
> compares replaced with registry lookups, 2 new unit tests.
>
> Remaining deferred items (A1, A2, A3, A4 cats 2-4) require either
> multi-day refactors with a fully-green integration test suite (which
> the wave-4 baseline doesn't provide) or language-level design
> discussion. The deferred-work doc explicitly notes these
> requirements; landing them under current conditions would risk
> regressions of exactly the kind the doc warns against (silently
> stale type info, missed bindings, wrong-arity HIR).

---

## Part 1 — Project orientation

### Zap, in one paragraph

Zap is a functional language with pattern matching, pipes, and algebraic
types that compiles to native code. It does NOT use a VM or interpreter.
The compiler is written in Zig. Zap source files (`.zap`) are parsed,
type-checked, lowered through HIR/IR, and emitted as ZIR (Zig's
intermediate representation) which is fed via a C-ABI surface into a
**fork of the Zig compiler** at `~/projects/zig`. The fork's job is to
take injected ZIR and run it through Zig's normal sema → AIR → LLVM
pipeline. The Zap compiler itself is built by linking against
`libzig_compiler.a` (the fork's compiler library).

### Repo layout

```
~/projects/zap/
  src/                  # Zap compiler (Zig source)
    parser.zig          # Source → AST
    collector.zig       # AST → scope graph (creates scopes, hoists fns)
    resolver.zig        # Resolves identifiers, creates clause scopes
    macro.zig           # Macro expansion (kernel macros: if, |>, sigils, <>)
    desugar.zig         # AST → AST (lowers comprehensions, pipes, etc.)
    types.zig           # Type checker (overload resolution, inference)
    hir.zig             # AST → HIR (typed intermediate, decision-tree pattern compiler)
    monomorphize.zig    # Specializes generic functions for concrete types
    ir.zig              # HIR → IR (lower-level, arity-suffixed names)
    analysis_pipeline.zig
    arc_optimizer.zig, perceus.zig, escape_lattice.zig, ...   # late passes
    zir_builder.zig     # IR → ZIR (calls into the Zig fork's C-ABI)
    runtime.zig         # zap_runtime.zig source (Zig runtime functions Zap programs link against)
    compiler.zig        # Pipeline orchestration (CTFE / per-struct / full)
    zir_integration_tests.zig  # End-to-end tests: compile a Zap program with `zap build`, run it, check stdout
  lib/                  # Zap stdlib (Zap source — NOT Zig)
    kernel.zap          # Macros (if, |>, sigils, <>); auto-imported
    enumerable.zap      # protocol Enumerable { fn next(state) -> {Atom, i64, any} }
    concatenable.zap    # protocol Concatenable { fn concat(left, right) -> any }
    list/, map/, range/, string/   # protocol impls and member fns
    zest/               # Test framework (uses describe/test macros)
  test/
    *.zap               # Zap-level tests run by `zap test`
~/projects/zig/         # Zig fork — Zap depends on this
  src/main.zig, src/Compilation/...
  src/zir_api.zig       # C-ABI exposed to Zap (NOT in upstream Zig)
```

### Pipeline (front to back)

```
.zap files
  → discovery   (follow struct refs from entry to find all files)
  → parse       (per file, produce AST)
  → collect     (scope graph: scopes per struct/function/case-clause/block)
  → macro-expand (Kernel macros run here; e.g. `<>` expands)
  → desugar     (`for x <- it { body }` becomes a __for_N helper fn + a call)
  → re-collect  (refresh scope graph for desugar-generated AST)
  → type-check  (overload resolution, inference, binding type recording)
  → HIR build   (typed IR; decision-tree pattern compilation; protocol dispatch)
  → monomorphize (specialize generics from inferred_signatures)
  → IR lowering  (arity-suffixed; locals; explicit instructions)
  → analysis     (escape, regions, lambda sets, perceus)
  → ZIR emit    (zir_builder → C-ABI calls into ~/projects/zig)
  → Zig sema/codegen (the fork takes over: AIR → LLVM → linker)
```

Type-relevant detail: the type checker sets binding types in the scope
graph. The HIR builder reads binding types from the scope graph for
`var_ref` resolution.

### Building & testing

```sh
# Build the Zap compiler
zig build                 # produces zig-out/bin/zap

# Zig-level unit tests (538 of them; mostly type-store/parser unit tests)
zig build test --summary all

# End-to-end ZIR integration tests (compile + run real programs)
zig build zir-test --summary all

# Zap-level tests (~28 test files in test/, run by `zap test`)
./zig-out/bin/zap test
```

Build time after editing `src/*.zig`: ~2 minutes for the compiler. The
Zig fork's library `libzap_compiler.a` is downloaded prebuilt by `zig
build setup` and does not need to be rebuilt for compiler changes.

### How `for x <- iterable { body }` compiles today (post-commit `9ff3863`)

`desugar.zig` rewrites every for-comp into an Enumerable-protocol-driven
recursive helper:

```zap
# Source
result = for x <- iterable { body }

# After desugar
fn __for_N(__state) {
  case Enumerable.next(__state) {
    {:done, _, _} -> []
    {:cont, x, __next_state} -> [body | __for_N(__next_state)]
  }
}
result = __for_N(iterable)
```

The helper is registered via `Desugarer.pending_helpers` and emitted as
a `priv_function` in the same struct. Its parameter has no type
annotation; the type checker fills it in via `inferred_signatures`
populated when the call site `__for_N(iterable)` is processed.

`Enumerable.next/1` is a protocol — `lib/enumerable.zap` declares the
abstract signature, and concrete impls live at `lib/list/enumerable.zap`,
`lib/map/enumerable.zap`, `lib/range/enumerable.zap`,
`lib/string/enumerable.zap`. The HIR builder rewrites
`Enumerable.next(state)` to `T.next(state)` based on `state`'s inferred
type via `protocolDispatchStruct` (`src/hir.zig:4987`).

### Decision-tree pattern compiler (relevant for B1)

`src/hir.zig` contains a Maranget-style decision-tree pattern compiler.
Key entry points:

- `compilePatternMatrix` (`src/hir.zig:~660`) — recursive compiler
- `compileTupleCheck` (`src/hir.zig:1453`) — emits `.check_tuple` decision
- `stripColumnAndRecurse` (`src/hir.zig:754`) — for all-wildcard/all-bind
  columns, emits `.bind` decision tree nodes
- `compileConstructorColumn` (`src/hir.zig:811`) — for constructor columns

The decision tree is then lowered to IR by `lowerDecisionTreeForCase`
(`src/ir.zig:2526`).

For a pattern `{:cont, x, __next_state}` where the scrutinee is given
scrutinee_id 0:

1. `compileTupleCheck` allocates IDs 1, 2, 3 for the three elements,
   emits `.check_tuple { expected_arity = 3, element_scrutinee_ids =
   [1, 2, 3], success = ... }`.
2. After matching `:cont` literal in column 0 (a `.switch_tag` node),
   columns are `[x, __next_state]` with scrutinee_ids `[2, 3]`.
3. Both columns are all-wildcard/bind → `stripColumnAndRecurse` emits
   `.bind { name = x, source = param_get(2), next = ... }`, then
   `.bind { name = __next_state, source = param_get(3), next = success }`.

`lowerDecisionTreeForCase` for `.check_tuple` (`src/ir.zig:2608`):
emits `index_get` per element, populates a `scrutinee_map: u32 →
LocalId`. For `.bind`, calls `resolveScrutinee(bind_node.source,
scrutinee_map)`, then iterates `case_arms[].bindings[]` to find a
binding by name, and emits `local_get { dest =
binding.local_index, source = scrutinee_local }`.

Crucially: **the binding's `local_index` is assigned during HIR build by
`collectCasePatternBindings` (`src/hir.zig:4994`)**. If a name is missed
there (filtered out incorrectly), the IR's bind handler fails to find
the binding by name and silently emits no `local_get` — so the
scrutinee value never lands in the binding's local. The body then reads
local 0 (or whatever default) instead of the destructured value.

---

## Part 2 — The bug and what's been tried

### Symptom

Reproducer (paste into a fresh `zap init` project's `lib/zap_b1.zap`):

```zap
pub struct ZapB1 {
  pub fn sum([] :: [i64]) -> i64 { 0 }
  pub fn sum([h | t] :: [i64]) -> i64 { h + sum(t) }

  pub fn main(_args :: [String]) -> String {
    doubled = for x <- [1, 2, 3] { x * 2 }
    Kernel.inspect(sum(doubled))
    "done"
  }
}
```

Build fails inside the desugar-generated `__for_N` helper:

```
expected type '?*const zap_runtime.List(i64)', found 'i64'
```

The error is at the recursive `__for_N(__next_state)` call site: the
helper's parameter is `?*const List(i64)` but the call passes an `i64`.
Translation: the value being passed in place of `__next_state` is the
*head element* `x` (i64), not the *tail list* `__next_state`
(List(i64)).

The same shape with an explicit intermediate works:

```zap
fn manual_for(state :: [i64]) -> [i64] {
  res = Enumerable.next(state)
  case res {
    {:done, _, _} -> []
    {:cont, x, n} -> [x * 2 | manual_for(n)]
  }
}
```

This compiles and runs correctly. The difference between failing and
passing seems to be (a) the desugarer-synthesised name `__next_state`
vs the user-written name `n`, and/or (b) the case scrutinee being a
call expression `Enumerable.next(__state)` vs a `var_ref` to an
intermediate.

### Verified root cause #1 (this fix is real)

`collectCasePatternBindings` in `src/hir.zig` (originally line 4994
pre-edit) had:

```zig
.bind => |name| {
    const name_str = self.interner.get(name);
    if (name_str.len > 0 and name_str[0] == '_') return;   // <-- BUG
    ...
}
```

The intent is the Elixir convention: `_x` means "intentionally unused —
suppress the would-be unused-binding warning". But the desugarer
synthesises names like `__next_state`, `__loop_raw`, `__state` that
also start with `_`. The filter swallows these too — so no
`CaseBinding` entry is created, so the IR's bind decision-tree handler
loops over all arms looking for a binding named `__next_state`, finds
none, emits no `local_get`, and the binding's local stays whatever the
last write to that local was (typically the head element).

Verified mechanism: I added debug prints to `lowerDecisionTreeForCase`
and watched the bind handler iterate `case_arms[].bindings`, find `x`
(local_index=0) but not `__next_state`. Conclusion: `__next_state` had
been silently dropped.

### Fix #1 (verified to make the failing reproducer pass)

Add `pub fn isDiscardBindName(name: []const u8) bool` to `src/ast.zig`
that distinguishes single-underscore (user-intent discard, e.g. `_x`)
from double-underscore (compiler-synthesised, e.g. `__next_state`):

```zig
pub fn isDiscardBindName(name: []const u8) bool {
    return name.len >= 2 and name[0] == '_' and name[1] != '_';
}
```

Then replace the four call sites in `src/hir.zig`:
- `collectCasePatternBindings` (now line ~5020): `.bind` arm
- `collectCasePatternBindings`: `.binary_match` arm (line ~5061)
- function-clause binary param collection (line ~3413)
- `collectBoundNames` (line ~3496)

The unused-binding skip in `src/types.zig:2069` should NOT change — that
code suppresses unused-binding *warnings*, and both `_x` (intentional)
and `__synth` (compiler-internal, never user-visible) deserve to be
warning-free.

After this fix alone:
- `for-comprehension doubles list` integration test goes pass.
- ZIR integration test count moves from 52/78 → 53/78.
- `zap test` errors stay flat (no regressions).

### Fix #2 (case-bindings stack — also worthwhile, also non-regressing)

The original `case_expr` HIR build in `src/hir.zig:~4167` saves and
RESETS `current_case_bindings` on each clause:

```zig
const saved_case_bindings = self.current_case_bindings;
self.current_case_bindings = .empty;            // <-- BUG for nested case
... build pattern + body ...
const bindings = try self.current_case_bindings.toOwnedSlice(...);
self.current_case_bindings = saved_case_bindings;
```

This is wrong for nested case clauses. When a for-comprehension has a
filter (`for x <- xs, pred { body }`), the desugar produces a case
inside the cont-arm's body:

```
{:cont, x, __next_state} ->
  case <filter_expr> {
    true -> [body | __for_N(__next_state)]
    false -> __for_N(__next_state)
  }
```

Building the inner case clauses resets `current_case_bindings` to
empty, so when var_ref `__next_state` (or `x`) is built inside the
inner clauses, they don't find their bindings via
`buildBindingReference` and resolve incorrectly.

The fix: instead of save/reset/restore, save the *length* and
append-then-truncate:

```zig
const start_idx = self.current_case_bindings.items.len;
... compile pattern ...
... collectCasePatternBindings appends to current_case_bindings ...
const guard_expr = ...;
const body = try self.buildBlock(clause.body);
const clause_slice = self.current_case_bindings.items[start_idx..];
const bindings = try self.allocator.dupe(CaseBinding, clause_slice);
... arms.append(...);
self.current_case_bindings.shrinkRetainingCapacity(start_idx);
```

This makes the inner case body see the outer cont-arm's bindings
(`x`, `__next_state`) AND its own clause's bindings (none for `true`/
`false`). The arm's `bindings` slice still contains only this clause's
own pattern bindings (correct shape for the IR's bind handler).

After fix #1 + fix #2:
- `for-comprehension with filter` test goes pass.
- ZIR test count: 53/78 → 54/78.
- `zap test` errors still flat (no regressions).

### Fix #3 onwards — speculative attempts that DID cause regressions

Below are changes I attempted to fix the *third* failing for-comp test,
`for comprehension over string`. The string for-comp fails for a
DIFFERENT reason than the list/filter cases — the underscore filter is
not the issue here. The String reproducer:

```zap
pub fn join([] :: [String]) -> String { "" }
pub fn join([h | t] :: [String]) -> String { h <> join(t) }
pub fn main() -> String {
  chars = for c <- "abc" { c <> "!" }
  IO.puts(join(chars))
  "done"
}
```

Failures the speculative work was chasing:
- `expected type '?*const zap_runtime.List([]const u8)', found '?*const zap_runtime.List(i64)'`
- `root source file struct 'zap_runtime' has no member named 'Concatenable'`

The `Concatenable` error means `<>` (which expands to
`Concatenable.concat(a, b)`) didn't dispatch to `String.concat` at HIR
time, so the ZIR emit references a non-existent runtime struct. That
happens when the HIR call's first arg has UNKNOWN type at dispatch
time. (`src/hir.zig:3917`: `protocolDispatchStruct` returns null when
`first_arg_type == TypeStore.UNKNOWN`.)

The List(i64) vs List(String) error suggests that for `c <- "abc"`,
either `c` is being typed as i64 (the protocol's hardcoded element
type — see below) or the helper's return type is being inferred wrong.

The speculative changes I attempted (and why each had a real basis but
also caused regressions when stacked):

1. **Type-checker case-clause scope switch + recordCasePatternBindingTypes**.
   `src/types.zig` was not flowing scrutinee types into pattern
   bindings. So `c` in `case s { {:cont, c, n} -> ... }` had UNKNOWN
   type even when `s` was a typed tuple. I added:
   - `checkCaseClause(clause, scrutinee_type)` that switches
     `self.current_scope` to the clause's scope and calls
     `recordCasePatternBindingTypes`.
   - `recordCasePatternBindingTypes(pat, parent_type, span)` that walks
     a pattern and records nested bind types by indexing `parent_type`
     (mirrors `recordAssignmentBindingTypes`).
   - Rationale verified by debug prints — bindings DID end up typed
     correctly after this.

2. **Collector registers case_clause scopes**. `src/collector.zig:873`
   was creating case_clause scopes but not putting them in
   `node_scope_map` or setting `clause.meta.scope_id`. So the type
   checker had no way to find a case clause's scope from its meta. I
   added the registration plus `@constCast(&clause.meta).scope_id = ...`
   (mirrors how function clauses are registered at line ~503).

3. **HIR clause-scope switch in `case_expr`**. `src/hir.zig:~4196` —
   When building each case clause's body in HIR, switch
   `self.current_clause_scope` to the clause's scope so
   `resolveBindingType` walks UP from the case_clause scope and finds
   the type-checker-recorded type for pattern-bound names. Without
   this, `resolveBindingType` walks from the function clause scope and
   never enters the case_clause scope.

4. **Type-checker protocol dispatch in `inferCall` for struct-qualified
   calls**. `src/types.zig:~3658` — Mirror of HIR's
   `protocolDispatchStruct`. When `Enumerable.next(s :: String)` is
   type-checked, the type checker was using the protocol's signature
   (`fn next(state) -> {Atom, i64, any}`) to infer the call's return
   type. That's wrong: it should use `String.next`'s signature
   (`{Atom, String, String}`). I added a `protocolDispatchStruct`
   helper that walks `graph.protocols` and `graph.impls` to redirect
   the resolution to the impl's struct before resolving the family
   signature.

5. **Function-param compound-pattern type recursion**. `src/types.zig:~2584`
   — `[h | t] :: [String]` was only recording the type for `bind`
   patterns; cons patterns were ignored, leaving `h` UNKNOWN. I added a
   recursive `recordAssignmentBindingTypes` call for compound param
   patterns. Then guarded with `containsTypeVars(param_type)` to avoid
   pinning a wrong specialization for generic params (`[h | t] :: [a]`
   in protocol impls).

### Why the speculative work blew up `zap test`

Baseline (post-Wave 4, pre-my-edits) `zap test` produces 24 compile
errors. After my full speculative stack: **96 errors**.

Visible new error patterns (representative):

```
Test_EnumTest.zig:1:1: error: expected type '?*const zap_runtime.List(i64)',
                              found '?*const zap_runtime.List([]const u8)'
Test_ListTest.zig:1:1: error: expected type '?*const zap_runtime.List(i64)',
                              found '?*const zap_runtime.List(?*const zap_runtime.List(i64))'
Test_GuardTest.zig:1:1: error: struct 'zap_runtime.List(i64)' has no member named 'member?'
Test_DefaultParamsTest.zig:1:1: error: ... no member named 'Concatenable'
```

I started reverting changes one at a time to isolate, but I was
guessing. When I got interrupted, I had ruled out:
- Fix #5 (function-param compound recursion) — error count unchanged.
- Fix #4 (type-checker protocol dispatch) — error count unchanged.

So the regression came from #1, #2, or #3. Most likely candidates:

- **The collector's `node_scope_map` registration is span-keyed**. Many
  desugar-generated case clauses share span 0:0. The first registration
  wins; subsequent registrations are clobbered or, depending on the
  hash map implementation, leave stale mappings. The
  `@constCast(&clause.meta).scope_id` write was meant to provide an
  unambiguous secondary lookup, but if `meta` is shared across multiple
  AST node copies (cloned during macro expansion), the write hits one
  copy and the other copies still have scope_id = 0. Need to verify
  whether `ast.CaseClause` is ever cloned with shared meta.

- **`recordAssignmentBindingTypes` recursion on case patterns may be
  pinning generic specializations too aggressively**. In Zap, `Enum`
  and `List` stdlib functions are heavy users of generic params like
  `(items :: [a], f :: (a -> b)) -> [b]`. If a case-pattern type-flow
  pass writes a concrete element type onto a binding inside a generic
  function's body (instead of leaving it as a type variable), the
  monomorphizer will specialise the function for that one type and the
  Zig backend will then fail when other call sites pass different
  types. The List(i64) vs List([]const u8) errors fit this pattern.

- **Switching `self.current_scope` in checkCaseClause**. The previous
  code did NOT switch into the case_clause scope. Changing this means
  every `var_ref` inside a case body now resolves bindings starting
  from the case_clause scope instead of the function clause scope.
  Most `var_ref`s should still resolve correctly (they walk up), but
  there might be a subtle ordering issue with shadowing in tests that
  rely on parameter names being visible in case bodies.

I did not get to bisect to a definitive culprit before interrupting.

### State of the working tree right now

`git status` shows the wave-4 changes (pre-existing user changes) plus
my speculative B1 work all dirty in the tree. Nothing committed since
`9ff3863`. There is no separate stash.

If I had to recover ONLY the verified-good changes (fix #1 and fix #2),
I would:

1. `git stash` the whole working tree.
2. `git stash pop` and selectively undo every speculative change EXCEPT:
   - `src/ast.zig` — keep the `isDiscardBindName` helper.
   - `src/hir.zig` — keep the four `isDiscardBindName` call sites.
   - `src/hir.zig` `case_expr` builder — keep the start-idx
     append/shrink scheme (the case-bindings stack fix).
3. Verify `zap test` returns to 24 errors (same as baseline) and ZIR
   tests reach 54/78.

Specifically, the speculative changes to revert are:
- `src/types.zig`: remove `checkCaseClause`, `recordCasePatternBindingTypes`,
  `protocolDispatchStruct` helpers; revert `case_expr` handler in
  `inferExpr` to call `checkStmt` directly; revert `inferCall`'s
  `field_access` path to not call `protocolDispatchStruct`; revert the
  function-param compound-pattern recursion in `checkFunctionClause`.
- `src/collector.zig`: revert the case_clause `node_scope_map.put`
  and `@constCast(&clause.meta).scope_id` lines.
- `src/hir.zig`: in the `case_expr` handler, remove the
  `saved_clause_scope`/`current_clause_scope = cs` block.

### What's still broken even after the verified fixes

- `for comprehension over string` still fails. The string for-comp
  generates a `Concatenable.concat(c, "!")` call where `c` is a String
  byte produced by the case destructure. At HIR time, `c.type_id` is
  UNKNOWN because the type checker doesn't flow scrutinee types into
  case pattern bindings (the very problem fix #1's recordCasePattern...
  was trying to address). When the protocol dispatch runs with UNKNOWN
  arg type, it falls through to the literal `Concatenable` struct name,
  which doesn't exist in the runtime.

- ZIR test count: 54/78 with verified fixes. Pre-existing failures (24
  of them) include closure capture, catch-basin, struct field access,
  map operations, keyword lists. Most are pre-existing bugs unrelated
  to B1.

### Concrete next steps for an investigator

#### Step A — Land the verified fixes safely

Goal: from current dirty tree, end up with ONLY fix #1 + fix #2
applied, `zap test` errors returning to 24, ZIR tests at 54/78.

1. Save the current speculative changes for reference: `git stash push
   -m "B1 speculative attempts"`.
2. Recreate just fix #1 + fix #2 on top of HEAD. The relevant files are:
   - `src/ast.zig` — add `isDiscardBindName`.
   - `src/hir.zig` — four call-site replacements + the case_expr
     append/shrink scheme.
3. Run `zig build test` (538 unit tests, all should pass).
4. Run `zig build zir-test` and confirm 54/78 (fewer failures than
   baseline 52/78).
5. Run `zap test` and confirm 24 errors (baseline, no new regressions).

#### Step B — Fix `for comprehension over string` properly

The fundamental problem: case pattern bindings have no type until/unless
something flows the scrutinee type into them. This is needed for any
case body that does protocol-driven operations on pattern variables.

Approaches in increasing order of invasiveness:

1. **Localised type-flow only inside the for-comp helper**. The
   desugarer knows it's emitting a case-on-`Enumerable.next`. Have the
   desugar pass also emit type annotations on the cont-arm's binds:
   `{:cont, x :: T, __next_state :: T}` where T is recovered from the
   helper's parameter type (which the type checker has via
   `inferred_signatures`). This avoids touching the general case_expr
   type-flow and only changes desugar emission.

   Catch: the desugarer runs BEFORE the type checker has run on the
   call-site `__for_N(iterable)`, so `inferred_signatures` is empty
   when desugar runs. You'd need to either re-run desugar after type
   check (the pipeline already does some re-collection) or have the
   HIR builder rewrite the cont-arm patterns once it knows the types.

2. **Inline the case scrutinee type-flow narrowly**. Add a single check
   in the type checker's `case_expr` handler: if the scrutinee is a
   call to `Enumerable.next/1` and the first argument's type is known,
   look up the impl's `next/1` signature and use ITS return type as
   the scrutinee type for binding type-flow purposes. Don't touch
   binding-recording for any other case shape.

3. **General case pattern type-flow** — the speculative fix #1 attempt.
   Risky because of the regressions described above. If pursued,
   investigate the regressions in Step C first.

#### Step C — Diagnose what made the speculative case-clause type-flow
regress `zap test`

Bisect strategy:

1. Apply ONLY collector change (case_clause scope registration). Run
   `zap test`. If errors stay at baseline 24, it's safe.
2. Apply collector change + HIR `case_expr`'s
   `current_clause_scope = clause_scope`. Run `zap test`.
3. Apply all of the above + type-checker `checkCaseClause` (without
   the binding-type recording, just the scope switch). Run `zap test`.
4. Apply all of the above + binding-type recording. Run `zap test`.

Whichever step pushes errors above 24 is the regression source.

Likely culprit (intuition only): step 4's recording can pin generic
function bodies prematurely. Look at how `Enum.map` etc. are
type-checked — they're generic in `[a]` and `[b]`. If a case body
matches on something that gets typed as e.g. `String`, and the body's
binding type is recorded as `String`, the function's monomorphisation
sees concrete types where it expected type vars and emits a
single-specialisation function that other call sites then mismatch
against.

Additional investigation directions:

- The `inferred_signature.return_type` fixpoint at `src/types.zig:2724`
  only fires when `clause.return_type == null and body_type !=
  UNKNOWN`. For `__for_N` over String, `body_type` should become
  `[String]` after a full body check. Confirm by debug print.

- The HIR `protocolDispatchStruct` (`src/hir.zig:4987`) requires
  `first_arg_type` to be a non-UNKNOWN type with a registered impl.
  Register a debug print in `case` builder:

  ```zig
  std.debug.print("DBG case scrutinee type_id={} kind={s}\n",
                  .{scrutinee.type_id, @tagName(self.type_store.getType(scrutinee.type_id))});
  ```

  to confirm whether the case's scrutinee carries a tuple type or
  UNKNOWN at HIR time.

- The `Enumerable` protocol declaration (`lib/enumerable.zap`) returns
  `{Atom, i64, any}` — the i64 is hardcoded. This is fine when the
  type checker uses the *impl's* signature, but if it ever falls back
  to the protocol's signature, the hardcoded i64 leaks into element
  bindings. Worth considering rewriting the protocol to use type
  variables — but type-variable-bearing protocol signatures may
  trigger the generic-call unification path in `inferCall`, which
  unifies arg types against the type variable and substitutes the
  return type. That's the right thing IF the type checker is set up
  for it.

#### Step D — Other deferred work after B1

Per `DEFERRED_WORK.md`, after B1 the recommended order is:

1. A4 (type-primitive attribute registration — categories: List, Map,
   Range, String hardcoded names → attribute-driven).
2. A2 (generic AstVisitor — replace per-pass exhaustive AST switches).
3. A1 (pipeline unification — the two compileForCtfe /
   compileStructByStruct paths).
4. A3 (move Zest into Zap macros — gated on a macro-system feature for
   constructing function decls, design discussion required).

### Files / line numbers index

When continuing work, these are the relevant call-site targets:

```
src/ast.zig:35..47          # makeMeta + (where to add) isDiscardBindName
src/collector.zig:813..863  # collectPatternBindings, collectExprScopes
src/collector.zig:873..886  # case_expr scope creation (B1 collector edit site)
src/desugar.zig:820..1033   # desugarForExpr, desugarForEnumerable, buildLoopBind
src/hir.zig:660..1500       # decision tree compiler (compilePatternMatrix, compileTupleCheck, stripColumnAndRecurse)
src/hir.zig:2121..2155      # resolveBindingType (HIR var_ref type lookup)
src/hir.zig:2582..2670      # buildBindingReference (HIR var_ref scope walk)
src/hir.zig:3766..3793      # var_ref expression builder
src/hir.zig:3895..4162      # call expression builder (protocolDispatchStruct call site at 3917)
src/hir.zig:4167..4220      # case_expr builder (B1 case-bindings stack edit site)
src/hir.zig:4957..5000      # hasImpl, isProtocolName, protocolDispatchStruct
src/hir.zig:4994..5053      # collectCasePatternBindings (verified bug here)
src/ir.zig:2526..2800       # lowerDecisionTreeForCase (.bind handler at 2750)
src/ir.zig:3208..3217       # resolveScrutinee
src/ir.zig:4343..4424       # findParamGetIdInDecision
src/types.zig:1093..1224    # recordBinding* helpers (B1 record-helpers edit area)
src/types.zig:2433..2730    # checkFunctionDecl, checkFunctionClause
src/types.zig:2767..2841    # case_expr type check (B1 type-flow edit site)
src/types.zig:3408..3717    # inferCall (B1 protocol-dispatch edit site at 3658)
src/scope.zig:399..415      # resolveClauseScope, resolveBinding
src/scope.zig:254..260      # node_scope_map definition + spanKey
lib/enumerable.zap          # Protocol decl (returns {Atom, i64, any} — note hardcoded i64)
lib/string/enumerable.zap   # impl Enumerable for String { fn next -> {Atom, String, String} }
lib/list/enumerable.zap     # impl Enumerable for List
lib/concatenable.zap        # protocol Concatenable { fn concat(left, right) -> any }
lib/kernel.zap              # `<>` macro (line ~262: quote { Concatenable.concat(...) })
src/zir_integration_tests.zig:117..220   # compileAndRun harness
src/zir_integration_tests.zig:1622..1691 # for-comp tests
test/for_comprehension_test.zap          # Zap-level for-comp tests
```

### Quick smoke test commands

```sh
# From project root
zig build && zig build test --summary all

# Reproducer for the list/filter B1 cases
mkdir -p /tmp/zap_repro/lib
cat > /tmp/zap_repro/build.zap <<'EOF'
pub struct TestProg.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :test_prog -> %Zap.Manifest{
        name: "test_prog", version: "0.1.0", kind: :bin,
        root: "TestProg.main/0", paths: ["lib/**/*.zap"]
      }
      _ -> panic("Unknown target")
    }
  }
}
EOF
cat > /tmp/zap_repro/lib/test_prog.zap <<'EOF'
pub struct TestProg {
  pub fn sum([] :: [i64]) -> i64 { 0 }
  pub fn sum([h | t] :: [i64]) -> i64 { h + sum(t) }
  pub fn main() -> String {
    doubled = for x <- [1, 2, 3] { x * 2 }
    Kernel.inspect(sum(doubled))
    "done"
  }
}
EOF
cd /tmp/zap_repro && rm -rf .zap-cache zap-out && \
  /Users/bcardarella/projects/zap/zig-out/bin/zap build test_prog 2>/tmp/err.log
[ -f zap-out/bin/test_prog ] && ./zap-out/bin/test_prog
grep "error:" /tmp/err.log | grep -v "debug(" | grep -v "is not a recognized" | head
```

Expected output with verified fixes applied: `12`.

```sh
# String-for-comp reproducer (still failing even with verified fixes —
# the unsolved part of B1)
cat > /tmp/zap_repro/lib/test_prog.zap <<'EOF'
pub struct TestProg {
  pub fn join([] :: [String]) -> String { "" }
  pub fn join([h | t] :: [String]) -> String { h <> join(t) }
  pub fn main() -> String {
    chars = for c <- "abc" { c <> "!" }
    IO.puts(join(chars))
    "done"
  }
}
EOF
```

### Glossary

- **HIR**: Zap's typed intermediate representation (`src/hir.zig`).
  Decisions about pattern matching, dispatch, protocol resolution
  happen here.
- **IR**: Lower-level intermediate (`src/ir.zig`). Locals, instructions,
  arity-suffixed function names. Has its own decision-tree lowering.
- **ZIR**: Zig's intermediate representation. Zap emits ZIR via
  `zir_builder.zig` calling C-ABI functions in the Zig fork.
- **AIR**: Zig's analysed intermediate (post-sema). Zap doesn't directly
  see AIR — the fork handles ZIR → AIR → LLVM.
- **scope_graph**: A flat array of scopes (function/block/case_clause/
  struct/etc.) with parent links and a `bindings` map per scope.
  `resolveBinding(scope_id, name)` walks UP from `scope_id`.
- **scrutinee_id / scrutinee_map**: In the decision-tree pattern
  compiler, every position in the pattern matrix is identified by a
  small integer scrutinee_id. The IR maps these to actual locals via
  `scrutinee_map: u32 → LocalId`.
- **CaseBinding**: The HIR record `{name, local_index, kind, element_index}`
  that connects a pattern-bound name to an IR local.
- **Enumerable protocol**: `lib/enumerable.zap`. The single mechanism
  by which all for-comprehensions iterate. Per-type impls in
  `lib/{list,map,range,string}/enumerable.zap`.
- **`__for_N`**: The desugar-generated helper for `for x <- xs { body }`.
  N is a counter to avoid collisions when multiple for-comps appear in
  one scope.
- **inferred_signatures**: A type-checker side-table mapping function
  names to call-site-inferred signatures. Used for synthetic helpers
  whose source-level signatures are missing/UNKNOWN.

### Project conventions to respect

- **No workarounds, hacks, or shortcuts** — the project's CLAUDE.md is
  emphatic. The fix has to be the real fix.
- **Zap features go in `lib/*.zap`, not in `src/*.zig`** — never
  hardcode Zap struct names as string literals in the compiler. The
  exception is type primitives, dispatch decisions, and the runtime
  bridge layer, where some hardcoded names exist today (and are
  themselves an open audit item, A4 in `DEFERRED_WORK.md`).
- **All public Zap functions must have `@fndoc`** with `"""` heredocs
  and a blank line after the closing `"""`.
- **Always run the entire test suite before declaring done**.
- **TDD**: write failing tests first, implement minimum to pass, only
  push when green.
