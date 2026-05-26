# First-Class Closures as a `Callable` Protocol Existential — Implementation Plan

Status: **approved, in progress** (Scope A — full). Branch `feat/error-system-deflate`.

## Goal

Make closures genuine first-class values: returnable from functions, storable in
struct fields, collectable in heterogeneous lists, and **capturing** (closing over
immutable bindings that outlive the defining frame) — without compromising the
zero-overhead direct-call path that already exists.

## Design (settled)

A closure is **a value that implements a `Callable` protocol**. A `fn(A) -> B`-typed
value is a `Callable` **existential** (`ProtocolBox {data_ptr, vtable}`) — the same
machinery used for `cause :: Option(Error)`. `data_ptr` holds the captured
environment (ARC-managed via the vtable `__drop__`); `vtable.call` is the body.

**Arity is encoded as a brace-tuple** in the protocol's first type parameter:

```zap
pub protocol Callable(args, result) {
  fn call(self, args) -> result
}
```

| Surface (you write) | Desugars to |
|---|---|
| `fn() -> i64` | `Callable({}, i64)` |
| `fn(i64) -> i64` | `Callable({i64}, i64)` |
| `fn(i64, String) -> Bool` | `Callable({i64, String}, Bool)` |

Zap tuples are brace-delimited (`{i64, String}`), static-arity, zero-overhead
(`lib/tuple.zap`) — so no 1-tuple ambiguity (unlike Rust's `(A,)`), and the
pack/unpack at the call boundary is compile-time, optimized away on the direct path.

**Surface syntax** is already in place: `fn(A) -> B` type annotations (shipped) and
`fn(x :: A) -> B { body }` value literals. A closure literal **desugars** to a
compiler-generated struct (captures → fields) + `impl Callable({...}, R)` whose
`call` method is the body with named params rewritten to tuple slots
(`args.0`, `args.1`). This mirrors the existing `pub error` → `struct + impl Error`
desugaring (`src/desugar.zig` `desugarErrorDecl`). A call `f(x, y)` desugars to
`Callable.call(f, {x, y})`.

**Representation duality (the crux):**

- **Statically-known / non-escaping target** (the common case — incl. `#201`'s
  monomorphized higher-order calls and Gap E's non-capturing return/field closures):
  **direct call, no box, zero overhead** (devirtualized). The bare function pointer
  (`ZigType.function`) IS the devirtualized representation of `Callable`.
- **Escaping-with-captures or heterogeneous collection** (`[fn(i64) -> i64]`):
  **boxed `Callable` existential**, ARC-managed environment.
- **Escape analysis** (`src/escape_lattice.zig` / `src/analysis_pipeline.zig`)
  decides box-vs-direct. Non-capturing closures are always direct (a code pointer has
  no environment to manage).

**Effect (`raises`) by inference (no new syntax):** the closure's inferred `raises`
rides on its `Callable`/function type and propagates through field-store/field-load
and return positions, extending `#201`'s effect-variable inference so a raising
closure stored-in / returned-as a `fn() -> T` field/return contributes to the
enclosing function's `raises` row and is dischargeable by `rescue` (today it wrongly
aborts). Pure closures stay pure.

## Decisions (resolved)

1. **Scope A (full)** — all six phases; the clean single-model result.
2. **`type` aliases are the Phase-0 prerequisite** (small, de-risking; unblocks
   naming function types for clean return-position syntax).
3. **Bare function pointer is the devirtualized representation of `Callable`**
   (Option A — minimal churn, how Gap E already works) — not a separate type.
4. **`callCallableN` is RETAINED — the dispatch audit (Phase 3 close-out)
   corrected this.** It is NOT subsumed by the boxed `protocol_dispatch` path:
   `callCallableN` is the zero-overhead DEVIRTUALIZED capturing path for a
   parameter-derived closure whose runtime value is a bare fn-ptr OR a
   non-escaping `{call_fn, env}` STACK struct (comptime-discriminated in
   `runtime.zig`). `protocol_dispatch` only handles BOXED `Callable`
   existentials (escaping/heterogeneous/stored), which never reach
   `call_closure` (intercepted by `ir.lowerBoxedCallableInvocation`). Deleting
   `callCallableN` would force boxing of every non-escaping capturing callback
   and regress perf. Empirical reachability proof (per-branch ZAP_DISPATCH_TRACE
   counters across the full corpus + script fixtures + unit tests) confirmed all
   three named mechanisms (`isParamDerivedClosure`/`callCallableN`,
   `callee_is_bare_fn_value` Gap E, `closure_function_map`/`{call_fn,env}`
   destructure) are LIVE, each serving a distinct reachable representation. The
   ONLY genuinely-dead code found and removed was the unused `findClosureTarget`
   wrapper. The final 3-representation architecture is documented at the
   `call_closure` dispatch site in `src/zir_builder.zig`.

## Phases (dependency order 0 → 5)

### Phase 0 — `type` alias resolver (prerequisite, independently shippable)
`type Name = TypeExpr` and parameterized `type Name(t) = ...` must resolve/substitute.
Today `type Celsius = i64` resolves to `void`. The parser already produces
`ast.TypeDecl` and the collector registers `TypeKind.type_alias = td.body`
(`src/collector.zig`); the gap is purely in resolution.
- Files: `src/types.zig` (`resolveTypeExpr` `.name` arm — look up `type_alias`,
  recurse on body, apply `params → args` substitution for parameterized aliases),
  `src/resolver.zig`, `src/scope.zig`.
- Risks: recursive/cyclic aliases (cycle detection); shadowing builtins; an alias
  MUST resolve to the **same `TypeId`** as its expansion so it does not fork
  monomorphization specializations.
- Verify: `type Celsius = i64` → `I64`; `type Adder = fn(i64) -> i64` → same `TypeId`
  as the inline form; parameterized alias; cyclic alias errors cleanly.

### Phase 1 — `Callable` protocol + closure-literal desugaring (boxed path only)
Introduce `pub protocol Callable(args, result)` (stdlib), desugar closure literals to
`struct` + `impl Callable`, lower a `fn(A) -> B` slot to `.protocol_box("Callable")`,
make the **always-box** path work end-to-end (correctness first; devirtualization is
Phase 3).
- Files: `lib/callable.zap` (new); `src/desugar.zig` (mirror `desugarErrorDecl`);
  `src/ir.zig` (`maybeBoxAsProtocol`, `emitProtocolVTableInstance`);
  `src/zir_builder.zig` (`emitProtocolVTableSourceFile` / `...InstanceSourceFile` —
  verify a tuple-typed `args` param + body tuple destructuring).
- Risks: tuple param type in the vtable signature; empty-tuple `{}` for zero-arg
  (must be a zero-element tuple `TypeId`, distinct from `void`); deterministic
  capture-field ordering.
- Verify: capturing closure in a `[fn(i64) -> i64]` list (forces box), invoked. Both
  managers. Existing `test/closure_test.zap` + `raise_closure/*` stay green (still on
  the #201/Gap E paths at this phase — non-regression gate).

### Phase 2 — Captured-environment heap allocation + ARC under box
A boxed capturing closure's environment is heap-allocated, ARC-retained when shared,
released exactly once via the vtable `__drop__`, balanced under both managers; captured
ARC values inside the env (strings, structs, nested closures) deep-dropped correctly.
- Files: `src/runtime.zig` (`ProtocolBox`, `releaseProtocolBoxInner` /
  `retainProtocolBoxInner`); `src/arc_drop_insertion.zig`, `src/arc_liveness.zig`,
  `src/arc_ownership.zig` (box dest classified OWNED — `maybeBoxAsProtocol` already
  records the `protocol_constraint` HIR type); `src/zir_builder.zig` (vtable
  `__drop__`/`__retain__` adapters).
- Verify: capturing+escape leak-free under `-Dmemory=Memory.Tracking` (model on
  `script_fixtures/phase_4c_box_ownership_stress.zap`).

### Phase 3 — Devirtualization + unification of #201 / Gap E (the crux)
Statically-known/non-escaping calls keep zero-overhead direct calls; the `#201`
(`callCallableN` / lambda-set) and Gap E (bare-fn-ptr) paths become the
**direct/devirtualized specialization** of the one `Callable` model — not a fourth
parallel path. `make_closure` for an escaping captured closure emits
`box_as_protocol`(env) instead of the `{call_fn, env, env_release}` anon struct;
`callCallableN` and the ad-hoc struct are deleted once `protocol_dispatch` covers the
boxed case.
- Files: `src/zir_builder.zig` (`call_closure`, `make_closure`); `src/escape_lattice.zig`
  (`escapeToClosureTier`, `SpecializationDecision`, `LambdaSet`);
  `src/analysis_pipeline.zig` (`runClosureEnvironmentSemantics`, `findClosureEscape`);
  `src/monomorphize.zig` (`effect_var` specialization, closure-callee cloning);
  `src/ir.zig` (`CallClosure`, `closureCalleeIsMaterializedValue`).
- Risk: **highest.** Regressing `closure_test.zap`, the 7 `raise_closure/*`,
  `funcref_combinator.zap`. Bring-up scaffold (temporary toggle) acceptable, deleted
  before the phase lands. Enter ONLY with the full pre-Phase-3 corpus green.
- Verify: all prior corpus + the no-regression set keep their current direct-call shape
  (no boxing) for non-escaping cases, validated through the ZIR path (never
  generated-source strings). Bench: no perf regression on `#201` monomorphized calls.

### Phase 4 — Effect-by-inference through fields/returns (the E1 fix)
A raising closure stored-in / returned-as a `fn() -> T` field/return propagates its
`raises` to an enclosing `rescue`. Pure closures stay pure. No new syntax.
- Files: `src/types.zig` (`FunctionType.raises`/`effect_var`, `inferred_raises`,
  `unify`/`substitute` effect arms); `src/ir.zig` (`closureCalleeRaises`,
  `CallClosure.raises`); the `raise`/`rescue` discharge logic.
- Risk: a `fn`-typed field can hold closures with differing effects → the field's
  effect is a conservative join (may over-approximate); boxing erases the concrete
  impl, so `Callable.call` must surface `error{ZapRaise}!T` whenever the field type
  admits a raiser.
- Verify: new `raise_closure/` field/return fixtures + a pure-field negative; both
  managers.

### Phase 5 — Hardening, docs, corpus breadth
`type`-alias-named function types in return position; nested closures; closure
capturing a closure across a box boundary; mixed boxed + direct in one program;
`@doc` on all new pub Zap decls.
- Verify: full `zig build test` (≥1642/0) + `zap test` (894/0) green under both
  managers; golden corpus unchanged.

## Unification strategy (Phase 3, concretely)

Three current mechanisms collapse to one model with two specializations:

| Today | Becomes |
|---|---|
| Gap E `callee_is_bare_fn_value` → direct `call_ref` | devirtualized `Callable` (direct) |
| `#201` `isParamDerivedClosure` → `callCallableN` / lambda-set direct | devirtualized `Callable` (direct) |
| original `{call_fn, env, env_release}` struct destructure | boxed `Callable` existential |

A `fn(A) -> B` value's canonical type is `Callable({A}, B)`; the type checker tags a
**representation hint** from escape analysis: non-escaping → `ZigType.function`
(devirtualized direct call); escaping → `ZigType.protocol_box("Callable")` (dispatch
via the `call` slot). `FunctionType.raises`/`effect_var` ride into the `Callable` type
args on both. The monomorphizer's `effect_var` specialization is unchanged in spirit —
a higher-order callee still specializes per closure-argument effect; the change is only
that an escaping closure arg gets a boxed param.

## Escape analysis (box-vs-direct)

`runClosureEnvironmentSemantics` + `findClosureEscape` read the `EscapeState` lattice.
`global_escape + has_captures` → `ClosureEnvTier.escaping` → **box**. Everything else
(or no captures) → **direct/devirtualize**. Default is **boxed** for anything not
provably non-escaping (conservative correctness). Devirtualize when the `LambdaSet` is
a singleton or the call is contifiable AND captures don't escape (the existing
`SpecializationDecision.direct_call`/`.contified`/`.switch_dispatch`).

## ARC (captured-env ownership)

The boxed env struct is the `ProtocolBox` `data_ptr` inner; `box_as_protocol`
heap-allocates it and that allocation is the box's owning reference (no extra retain at
construction). Release via the vtable `__box_header__.drop` → `releaseProtocolBoxInner`
(env type's deep-walk). Share via `__box_header__.retain` → `retainProtocolBoxInner`,
stamped when the box is shared. `maybeBoxAsProtocol` already records the box dest's HIR
type as `protocol_constraint` so it's classified OWNED with a scope-exit drop — pure
reuse, no new ARC primitive.

## Test strategy

TDD throughout. Every fixture under both `Memory.ARC` and `-Dmemory=Memory.Tracking`
(the `run_error_matrix.sh` two-manager pattern). Hard no-regression gate:
`test/closure_test.zap`, all 7 `test/fixtures/raise_closure/*`,
`test/fixtures/raise_cross_fn/funcref_combinator.zap`, and the golden corpus.
`zig build test --zig-lib-dir /Users/bcardarella/projects/zig/lib` (≥1642/0) +
`zap test` (894/0) green. Validate through the ZIR path, never generated-Zig-source
strings. **NEVER `zig build zir-test`** (the user runs it). Fork changes allowed
(FOREGROUND rebuild, commit separately).

## Sequencing

0 → 1 → 2 → 3 → 4 → 5. Phases 0, 1+2, and 4 are independently green checkpoints.
Phase 3 is the make-or-break; enter only with the full pre-Phase-3 corpus green so any
regression is unambiguously attributable to the unification. Gap analysis + resolution
loop after each phase until clean before advancing.

## Phase 3 representation-matrix close-out (final edges)

The idiomatic factory/method-constructed forms unified across all positions ×
bodies × modes × managers (capturing and non-capturing). Three residual
construction-site edges remained and are now **all FIXED** (no documented
limitations — every cell is green):

### Edge 1 — capturing closure constructed INLINE in script `main`, stored into a boxed field
A capturing closure built inline in the top-level script `main` body and stored
into a `fn`-typed (boxed `Callable`) field failed with `EmitFailed`, while the
SAME closure built inside a factory METHOD worked.

**Root cause.** A synthesized `__closure_N` capture field is declared `any` (the
desugar cannot resolve a captured binding's type) and backfilled to the concrete
type at the closure's single construction site (`backfillClosureFieldType` in
`src/types.zig`, during `inferExpr` of the `%__closure_N{...}` literal).
Compilation is struct-by-struct (`compileStructsToPreFinalIr`) against a SHARED
`TypeStore`, and type registration re-runs on every struct's pass. When the
`__closure_N` module is itself type-checked AFTER the module that constructed it,
re-resolving the `any` annotation to `UNKNOWN` CLOBBERS the backfill — emitting an
`any`-field struct (no representation → `EmitFailed`). A closure built inline in
`main` always hits this because the synthesized `__closure_N` module is ordered
LAST (after `__ZapScriptMain`); a factory method is ordered after `__closure_N`,
so its backfill is never clobbered — which is why the method form worked.

**Fix** (`src/types.zig`, struct registration): when re-registering a
`__closure_N` struct, a capture field that resolves to `UNKNOWN` carries forward
any non-`UNKNOWN` type already recorded at this struct's `type_id` (the prior
backfill). The placeholder `any` annotation is never the source of truth for a
closure capture's type. Keyed precisely on the `__closure_` name — non-closure
structs are unaffected. This makes the backfill order-independent, so it
generalizes to ALL capturing-`main`-local boxed positions (field, list element,
map value, if-branch box). Fixture: `capturing_inline_main_field.zap` → `15`.

### Edge 2 — non-capturing closure as a generic-type-var param default that unifies to `Callable`
`Map.get(map, key, default :: value)` with a closure-literal `default`, where
`value` unifies to `Callable({i64}, i64)`: the closure was not boxed (a bare
fn-ptr was passed where a `ProtocolBox` is expected).

**Root cause.** The box decision is syntactic (desugar, PRE-unification), so it
cannot observe that `value` resolves to `Callable`. The concrete-`fn`-typed-param
case already boxes via the crux/monomorphizer (`boxedCallableRepresentationForParam`),
but a bare generic type-variable param has no `effect_var` function type to key on.

**Fix** (`src/desugar.zig`): a closure-literal call argument boxes when the callee
parameter it flows into is a bare GENERIC TYPE-VARIABLE annotation (`.name` /
`.variable`) rather than a `fn(A) -> R` function type. A closure value can only
inhabit such a slot by boxing into a `Callable` existential (it cannot inhabit a
concrete non-function type), so this is sound and pre-unification-safe. The callee
param annotation is resolved via the scope graph (`calleeParamTypeAnnotation`); a
`fn`-typed combinator callback (`Enum.map`'s `fn(element) -> mapped`) keeps the
direct #201/Gap E path (its annotation is `.function` — never boxed; verified no
`__closure_` synthesis for combinator args). Fixture:
`generic_default_callable.zap` → `100`. (Capturing-closure-as-generic-default also
works — the boxed-slot flag boxes regardless of capture.)

### Edge 3 — nested closure capturing the OUTER closure's capture, inline in `main`
`fn(x) { adder = fn(y) { y + n }; adder(x) }` where `n` is the outer closure's
capture, inline in `main`. **Already green on entry** (closed by the factory-form
Gap-1/3 fixes); promoted as `nested_capture_inline_main.zap` → `13`. Triple-nested
capture inline in `main` also verified. No further work required.

### Non-regression (load-bearing invariants preserved)
- `Enum.*` / `Map.*` over non-closure types keep devirtualizing — no V11/Z9101
  (Edge 2's fix keys on the param annotation SHAPE, not protocol membership).
- The `#201` / Gap E direct ZIR shape is preserved: a combinator/`fn`-typed-param
  closure argument synthesizes NO `__closure_N` (stays a bare fn-ptr).
- `Callable`-specific changes are keyed precisely on the `__closure_` name (Edge 1)
  and the `.function`-vs-generic param annotation (Edge 2).
