# Zap Ownership Model

> **Status: verified reference.** This document was written after a 4-angle audit
> (lexer, parser/AST, full `.zap` corpus sweep, and the inference data-path) plus
> live compile probes, *because an earlier informal description got it wrong* — it
> claimed Zap has "no ownership syntax." That is false. The correct picture is
> below, with `file:line` anchors so any claim here can be re-verified against the
> source. Don't lose this again.

## TL;DR

Zap has an **optional, opt-in ownership-annotation syntax** — the qualifiers
`shared` / `unique` / `borrowed` — writable on **parameter slots** and
**function-type param/return slots**. It is **enforced** (e.g. a `borrowed` value
that escapes is a *compile error*). It sits on top of a **full ownership-inference
system that is the idiomatic default**: the entire stdlib + test corpus
(361 `.zap` files) uses the annotation **zero** times, and the compiler infers
everything from types + dataflow when you omit it.

So two statements are both true and must be held together:
- **"You almost never write ownership in Zap"** — TRUE (inference is the norm; the corpus proves it).
- **"Zap has no ownership syntax"** — **FALSE** (the `shared`/`unique`/`borrowed` qualifiers exist and are enforced).

What Zap does **not** have: Rust-style `&`/`&mut` borrow operators, `move`, `mut`,
or lifetime ticks (`'a`). The ownership surface is keyword qualifiers, not sigils
or lifetimes. (The `&` token exists but is the **function-reference** sigil
`&Name/arity`, e.g. `root: &Cross.main/1` — not a borrow.)

## 1. The annotation syntax (optional, but real)

The three qualifiers are reserved keywords (`src/token.zig:58-60`, keyword table
`:238-240`): `shared`, `unique`, `borrowed`. The AST enum is
`ast.Ownership = enum { shared, unique, borrowed }` (`src/ast.zig:536-540`).

You may write a qualifier **after `::`, before the type**, in two places:

**Parameter slots** (`src/parser.zig:2121-2155`, `parseParam`):
```zap
pub fn id(x :: borrowed String) -> String { x }   # compile ERROR: borrowed value escapes via return
pub fn first(xs :: unique List(i64)) -> i64 { List.get(xs, 0) }
pub fn id(x :: shared String) -> String { x }      # shared is the default; compiles
```
The AST `Param` records both the qualifier and whether the user wrote it:
`ast.Param.ownership` + `ast.Param.ownership_explicit` (`src/ast.zig:542-549`).

**Function-type param/return slots** (`src/parser.zig:5558-5624`, qualifier helper
`parseOptionalOwnershipQualifier` at `:5669-5674`):
```zap
fn(borrowed String) -> unique T
```
stored on the `TypeExpr.function` variant as `param_ownerships` /
`return_ownership` (+ their `_explicit` flags, `src/ast.zig:1485-1489`).

**Where ownership is NOT writable** (these carry only a *type*, no ownership):
- plain bindings: `foo = 32`, `x = 5 :: u8` (`ast.Assignment` is `{pattern, value}`, `src/ast.zig:677-681`; value-ascription `42 :: i32` is `{expr, type_expr}`).
- struct fields: `name :: Type [= default]` (`ast.StructFieldDecl`, `src/ast.zig:417-422`).
- type expressions themselves: no `&T` / `mut T` / `own T` / `'a` production exists.
- attributes (`@doc` / `@code` / `@available_on` / `@target`) — docs/codes/capabilities/target, never ownership.

Parser tests that exercise the qualifiers live at `src/parser.zig:6253-6366`.

## 2. What each qualifier means (and what is enforced)

`HirBuilder.resolveParamOwnership` (`src/hir.zig`, ~`fn resolveParamOwnership`) is
the resolution rule: **an explicit qualifier is honored verbatim; when omitted, the
default `shared` is replaced by `defaultOwnershipForType(resolved_type)` — i.e.
inferred from the parameter's type.** So the annotation is an *override* on an
inference default.

- **`shared`** — the default. The value may be aliased/shared. When you don't
  annotate, the parameter's ownership is inferred from its type
  (`defaultOwnershipForType`) and refined by dataflow (§3).
- **`unique`** — the value is the sole owner (refcount would be 1). Declaring it
  lets the value be consumed/moved and mutated/reused in place without a copy.
- **`borrowed`** — the callee only *borrows*; the caller keeps ownership, so the
  value **must not escape**. This is enforced with compile-time diagnostics:
  - escape via return → `"borrowed value '<name>' cannot escape through return"` (`src/types.zig:7393`);
  - escape into aggregate storage (struct field / collection) → `"borrowed local must not escape into aggregate storage; promote via copy_value first"` (V3 invariant, `src/arc_verifier.zig:1029`, `src/arc_ownership.zig:4078`);
  - escape via a closure capture → `"closure with borrowed captures cannot escape via <ctx>"` (`src/types.zig:4626`).

The annotation flows (via `resolveParamOwnership` → the call argument's `mode`,
`.share`/`.move`/`.borrow`) into how a **call argument** is lowered
(`share_value`/`move_value`/borrow, `src/ir.zig:13042-13223`).

## 3. The inference system (the idiomatic default)

When you don't annotate — which is everywhere in the corpus — the compiler infers
ownership. The IR-level classifications are **distinct fields** from the
`ast.Ownership` annotation and are produced purely by analysis:

- `OwnershipClass` = `.owned` / `.borrowed` / `.trivial` per local (`src/ir.zig:633`).
- `ParamConvention` per parameter (`src/ir.zig:663`); `ResultConvention` (`:681`).

These are **seeded from the parameter/local/return TYPE** then **refined by a
dataflow fixpoint** — never read from a user annotation:
- seeding: `computeParamConventions`/`computeLocalOwnership`/`computeResultConvention` (`src/ir.zig:10479/11907/11989`) delegate to `defaultParamConvention`/`defaultResultConvention` (`:3284/3311`), which are pure functions of the HIR `type_id` (an ARC-managed type ⇒ `.borrowed`/`.owned`, a scalar ⇒ `.trivial`). Note `ir.Param` (`:859-864`) has **no** ownership/convention field, so there is physically no slot to thread a user annotation through.
- refinement: `arc_param_convention.inferConventions` (`src/arc_param_convention.zig:112`, a conservative Koka-style borrow→owned fixpoint over self-recursion + last-use liveness); `arc_ownership.classifyAndNormalizeWithProgram` (`src/arc_ownership.zig:125`, seeds `local_ownership` from the conventions then a use-summary dataflow visitor); the `uniqueness_*` interprocedural fixpoint; `perceus` reuse analysis.

The full ownership/ARC pipeline: `arc_liveness` (last-use, consume/share sites,
move analysis) → `arc_ownership` (classify/normalize, borrow→consume) →
`arc_param_convention` (convention fixpoint, incl. per-call-path specialization) →
`uniqueness_*` (prove sole-owner) → `perceus` (cell reuse) → `arc_drop_insertion`
(insert releases/free-at-last-use) → `arc_materialize` (emit ops) →
`arc_verifier` (V1–V11 soundness, e.g. V11 catches a misclassified-`.trivial`
local that would leak).

**The corpus proof:** a sweep of 361 `.zap` files (`lib/`, `test/`,
`script_fixtures/`) + 19 docs found **zero** ownership annotations in actual code,
and `docs/proper-zap-code.md` states: *"The compiler infers ownership (shared,
unique, borrowed) automatically based on types and escape analysis. You do not
annotate ownership in Zap source code."* That guidance is correct as *idiom* — but
the syntax exists as an optional, enforced override, which is what this document
exists to record.

## 4. Capability-driven, manager-agnostic emission

The ownership analysis above runs **identically regardless of the selected memory
manager**. Only which memory operations get *materialized* changes, gated on the
manager's declared capability (`ReclamationModel`, `src/memory/elision.zig:28`) —
never on a manager name:

| `ReclamationModel` | Managers | Emission |
|---|---|---|
| `refcounted` | ARC | retain/release, free-at-zero, with release **elided** where last-use/uniqueness proves it safe |
| `bulk_or_never` | Arena, NoOp, Leak | **no** retain/release/free (bulk-reclaim at scope/process death, or never) |
| `individual_no_refcount` | Tracking | no refcount; static **free-at-last-use** (Perceus-without-refcount) + **clone-on-share** for second owners |
| `traced` | GC | codegen ≡ `bulk_or_never`; the conservative collector reclaims |

`arc_materialize` is the master switch. This is why the same source gets ARC,
arena, tracking, or GC behavior purely by manager selection — and the basis for
the planned BEAM-style per-process model, where each process picks its manager at
spawn time (monomorphized per manager).

## 5. Why it's sound

Zap values are immutable and built bottom-up, so the object graph is **always a
DAG** — no mutation means no way to form a reference cycle. Reference counting /
ownership is therefore sound **without a cycle detector** (which is exactly why the
error-system work removed one as provably dead). Everything above rests on this.

## 6. Re-verification anchors

If in doubt, re-check these:
- Syntax exists: `src/token.zig:58-60,238-240`; `src/ast.zig:536-549,1485-1489`; `src/parser.zig:2121-2155,5558-5624,5669-5674`; tests `:6253-6366`.
- Enforced: probe `fn id(x :: borrowed String) -> String { x }` → `borrowed value 'x' cannot escape through return` (`src/types.zig:7393`).
- Optional/inferred: `src/hir.zig` `resolveParamOwnership`; IR conventions seeded+refined at `src/ir.zig:3284/3311/10479/11907/11989` + `src/arc_param_convention.zig`/`src/arc_ownership.zig`; `ir.Param` (`:859-864`) has no ownership slot.
- Idiomatically unused: sweep `lib/ test/ script_fixtures/` for `:: borrowed`/`:: unique`/`:: shared` → only parser-test fixtures, no stdlib/corpus usage.
