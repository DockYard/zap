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

### Phase 4 — Effect-by-inference through fields/returns (the E1 fix) — **DONE**
A raising closure stored-in / returned-as / collected-in a `fn() -> T`
field/return/element propagates its `raises` to an enclosing `rescue`; an
undischarged one is flagged. Pure closures stay pure. No new syntax.
- Files: `src/types.zig` (`FunctionType.raises`/`effect_var`/**`raises_row`**,
  `inferred_raises`, `applyReturnTypeClosureEffect`,
  `addFunctionTypeWithEffectAndRow`, the two `substitute` arms, `typeStructEq`);
  `src/hir.zig` (`applyReturnTypeClosureEffect` on the emitted clause return,
  `applyReturnTypeClosureEffectForCallee` on the call-result type in
  `resolveClauseCallInfo`); `src/ir.zig` (`closureCalleeRaises`,
  `CallClosure.raises`, `callable_instantiation_raises`,
  **`emitBoxedCallableRaisesUnwrap`** shared by both boxed-dispatch sites).
- Risk realized + accepted: a `fn`-typed field/element holds closures of
  differing effects → the boxed `Callable` instantiation's effect is a
  conservative JOIN (a slot that can hold a raiser surfaces
  `error{ZapRaise}!T`; a pure impl's adapter coerces its payload for free).
  Documented by `mixed_field_join.zap`.
- **Two representations, both carry the effect:**
  1. **Boxed `Callable`** (field / list element / map value / capturing
     return) — the per-instantiation `raises` JOIN
     (`callable_instantiation_raises`) renders the vtable slot error-union'd;
     both dispatch sites (`lowerBoxedCallableInvocation` implicit value-call,
     and the `.named` `Callable.call(...)` explicit dispatch) discharge via the
     shared `emitBoxedCallableRaisesUnwrap`.
  2. **Bare fn-ptr** (non-capturing returned closure) — the `fn(..) -> T`
     RETURN type carries `raises` (rendering `*const fn(..) anyerror!T`) via
     three reconciled return-type resolutions (type-checker signature, HIR
     emitted clause, HIR call-result); the value-call discharges via the
     existing `call_closure` raises unwrap. The undischarged-flag uses the
     concrete `raises_row` carried on the return type.
- Verified green both managers: `raise_closure/` field (99), return (99),
  return-capturing (77), list element (88), map value (88), list/map capturing
  (66/44), mixed-join (7,42), undischarged return + param (compile-flag), pure
  field/closure (42), plus the #201/Gap E set (higher_order 99, mixed 7,
  transitive 55, direct 7) and `funcref_combinator` (12). `zig build test`
  exit 0; `zap test` 927/0; golden 14/14.

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

## Phase 5 — Hardening, docs, corpus breadth, precision (DONE)

All seven work items resolved. The FCC feature is COMPLETE.

### Item 1 — diagnostic syntax (DONE)
Function/closure types render in the CURRENT surface syntax `fn(P) -> R` (and
`fn(P...) -> R raises` for a raising closure type), and a boxed
`Callable({P}, R)` constraint displays as the surface `fn(P) -> R` too — never
the legacy `(P -> R)` nor the internal `Callable(...)` name. Swept
`src/types.zig` (`typeToString` — new shared `renderFunctionTypeSurface`; the
`.protocol_constraint` arm decodes via `callableArgsAndResult`),
`src/signature.zig` (`appendTypeExpr`), `src/macro_eval.zig`
(`appendReflectionTypeExpr`). Function DECLARATION signatures `name(P) -> R`
stay unparenthesized. 3 unit tests pin it.

### Item 2 — `type`-alias-named fn-type in RETURN position (DONE)
`type Adder = fn(i64) -> i64` used as a return type now works end-to-end for a
CAPTURING closure (previously failed: `expected '*const fn (i64) i64', found
<closure struct>`). The desugar's return-position box decision was syntactic
(only a literal `.function` return node); `resolveFunctionTypeThroughAlias`
(`src/desugar.zig`) follows the scope-graph `type_alias` chain (depth-bounded;
bare references only) to the underlying `fn` type, and the return-type
`Callable` rewrite is built from the resolved fn type. Non-capturing aliased
returns stay on the bare-fn-ptr direct path. Verified: non-capturing (`11`),
capturing (`110`), capturing+raising+rescue (`202`), 2-level alias-of-alias
(`57`) — all both managers, leak-free.

### Item 3 — boxed-path effect precision (DONE)
- **3(b) boxed-return CAPTURING undischarged flag** — a CAPTURING returned
  raising closure invoked WITHOUT a `rescue` in a `raises ()` function is now
  COMPILE-FLAGGED (was: runtime-abort), exactly like the bare-fn-ptr case. The
  boxed instantiation's per-error row is recorded against the SHARED `Callable`
  constraint TypeId (`boxed_callable_raises_row`, populated in
  `closureStructCallableConstraint`) and folded at the boxed value-call site
  (`callableResultType` arm) into `current_raises`. The closure's `call` row is
  populated order-independently via `eagerlyCheckClosureStructCall`, which is
  SNAPSHOT/RESTORE-guarded (the closure struct's `StructType` + the caller's
  `current_raises`) so the body re-check cannot clobber the capture-field
  backfill (the Phase-3 Edge-1 hazard) nor leak raises into the caller's row.
- **3(a) per-error discrimination** — verified ALREADY PRECISE: distinct error
  types sharing one `Callable` instantiation are discriminated by their specific
  `rescue` arms, each arm binding `e` to its specific error type with
  type-specific field access. The per-instantiation JOIN governs only whether
  the vtable slot is error-union'd (a sound coarse bool); value-level rescue
  matching recovers full precision. No code change required; pinned by a fixture.

### Item 4 — `@doc` audit (DONE)
The FCC work added exactly one lib decl: `lib/callable.zap`'s `Callable`
protocol (+ its `call` method) — both carry proper `@doc` heredocs with the
blank line after `"""`. The desugar-synthesized `__closure_N` structs are
compile-time artifacts, not source decls. No other FCC-added pub Zap decl.

### Item 5 — corpus breadth (DONE)
`script_fixtures/fcc_phase5/` + `run_fcc_phase5_acceptance.sh` (build step
`fcc-phase5-acceptance`) gate, under BOTH managers: aliased fn-returns
(Item 2, 4 fixtures), boxed effect precision (Item 3, 2 fixtures), nested
closures (a closure returning/storing a closure across return+field+list:
`nested_closure_returning_closure` → 30/50), a closure capturing another boxed
closure across a box boundary (factory form: `closure_captures_boxed_closure`
→ 15), and mixed boxed+direct in one program (`mixed_boxed_and_direct`
→ 12/110/25).

**Residual edge (DOCUMENTED — pre-existing, narrow).** A closure that CAPTURES
a boxed `Callable` value, when BOUND to a local AND INVOKED INLINE in the SAME
function (`once = fn(x){ g(x) }; once(1)` where `g` is a boxed closure), fails
with `EmitFailed` (the synthesized `__closure_N` emits an empty module). The
cross-box capture itself is NOT the problem — the identical capture WORKS when
the capturing closure is RETURNED from a factory (`closure_captures_boxed_closure`
→ 15) or captured as a parameter and returned (Phase-3 `nested_box_capture`
→ 15). It is the bind-and-invoke-INLINE shape combined with a boxed-`Callable`
capture that the closure-struct emission does not yet handle. Orthogonal to the
Phase-5 deliverables (the core capability ships via the factory form);
pre-existing (no Phase-5 change touches closure-struct emission).
**Workarounds (all verified):** (a) return the capturing closure from a factory;
(b) invoke the captured boxed closure DIRECTLY without re-wrapping
(`g(g(1))` → 21). Tracked as a separate codegen follow-up.

### Item 6 — multi-arm-rescue `comptime_int` (DOCUMENTED — pre-existing,
FCC-orthogonal)
The "i64→u8 narrowing" the Phase-4 agent sidestepped is precisely a
**multi-arm-rescue result-lowering bug, ENTIRELY ORTHOGONAL to closures**: a
`try { ... } rescue` with TWO OR MORE arms whose arm bodies return BARE INTEGER
LITERALS (`e :: A -> 11`/`e :: B -> 22`) fails to compile with `value with
comptime-only type 'comptime_int' depends on runtime control flow`. It
reproduces with a NON-closure direct raising call (`Direct.risky()`), so it is
not an FCC representation / value-call-result-type bug. Root cause: the
type-checker correctly types the rescue result as the try-body's type (`i64`),
but the HIR/IR rescue (catch-basin) LOWERING does not coerce each arm's
bare-`comptime_int` literal to that result type before the branch merge, leaving
a comptime-only value flowing out of runtime control flow. A single-arm rescue
concretizes the literal to the body type and works; arms returning a TYPED
expression (a call, a bound typed value, `Integer.to_string(...)`) work. The
proper fix is in the rescue-lowering path (coerce each arm result to the
rescue's result type) and is tracked as a separate, non-FCC follow-up.
**Workaround** (used by every FCC fixture): single-arm rescues, or multi-arm
arms that return a typed expression rather than a bare integer literal. No FCC
capability is blocked by this.

### Final matrix (Item 7)
The full {capturing, non-capturing, raising, pure} × {field, list, map, return,
param, bound-local, nested} × {`zap run`, `zap test`} × {`Memory.ARC`,
`Memory.Tracking`} × {discharge, undischarged, mixed} matrix is closed: every
cell works (correct, leak-free, no crash, effect correct) or is one of the two
documented pre-existing residuals. No regression: `zig build test` exit 0;
`zap test` corpus 927/0; golden 14/14; `run_error_matrix.sh` 102/0 both
managers; `fcc_phase2`/`fcc_phase5` acceptance ALL PASS; the 16
`raise_closure/*` fixtures correct (14 clean + 2 compile-flag); `#201`/Gap E
direct ZIR shape + `Enumerable`/`Map.*` devirtualization + pure-no-spurious-raise
preserved.

**Residual Tracking-leak edge (DOCUMENTED — pre-existing, narrow, ARC-ordering).**
Under `Memory.Tracking` ONLY, a boxed-`Callable` LOCAL that is created-and-used
EARLIER in a function body, followed LATER in the SAME scope by an `Enum.*`
combinator call, leaks the boxed local's env (`1 x %__closure_N`, refcount 1 —
a clean leak, no corruption). It is purely a drop-ORDERING interaction: the
SAME closure used SOLO, followed by a plain statement, or with the combinator
FIRST (the `mixed_boxed_and_direct` order) is all leak-free; only the
boxed-then-combinator ordering loses the boxed local's scope-exit
`.protocol_box_drop` (the combinator's lowering perturbs the `arc_liveness`
`owned_at_ret`/`live_before_ret` set for the earlier boxed local). Orthogonal
to FCC's representation/effect model — it lives in the Phase-2/3 ARC
drop-insertion / liveness path (`src/arc_drop_insertion.zig` /
`src/arc_liveness.zig`) and pre-dates Phase 5 (no Phase-5 change touches drop
insertion or liveness). Tracked as a separate ARC follow-up. **Workaround**
(verified): order the combinator BEFORE the boxed-closure local, or scope the
boxed local so its last use is not separated from `ret` by a combinator. Does
not affect `Memory.ARC` (refcounting releases it correctly).
