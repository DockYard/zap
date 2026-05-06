# Zap: Phase 6 redux — ownership-typed IR implementation plan

> **Companion to** `docs/k-nucleotide-rss-gap-phase6-struggles.md` (the
> diagnosis brief) and the deep research report that motivated this
> plan. Read both first if unfamiliar with the 8-attempt Phase 6
> saga, the borrowing semantics of Map runtime APIs, the existing
> caller-side `share_value` + post-call `release` discipline, or the
> precedents in Swift OSSA, Lean 4 borrowed references,
> Koka/Perceus, and Roc.

---

## 0. North star

The k-nucleotide RSS gap is **not** a runtime data-structure bug, a
runtime ABI bug, or a missing-deep-release bug. It is a **compiler
ownership-modeling bug**. The IR overloads "local" to mean owned,
borrowed alias, copy of an owner, pattern-bound alias, call-result
binding, and aggregate projection — and the drop-insertion pass,
return-source elision, and consume-mode optimization all conflate
those distinct meanings.

The 11 substrate commits landed across attempts 6.2a-6.9 each
patched a symptom of this overloading. Each patch surfaced one more
symptom because the underlying ownership model is unsound. The flag
flip cannot land safely until the IR distinguishes ownership at the
level a compiler-enforceable verifier can validate.

This plan replaces the Phase 6 milestone (a one-line flag flip) with
a focused, TDD-driven redesign of Zap's IR ownership layer:

1. **Borrowed-by-default formal parameters.** Callee scope-exit drops
   skip parameters. This single change is predicted to make the
   simplest `Map.has_key(m, 0)` reproducer stop segfaulting under
   the flip, because today's caller-side `share_value` + post-call
   `release` ABI already implements borrow semantics — the missing
   piece is callee-side respect for that ABI.
2. **Split aliasing into `borrow_value` and `copy_value`.** Today's
   `local_get` is overloaded; Phases 6.7-6.8 oscillated between "no
   retain" and "always retain" because each form is correct for one
   alias use and wrong for the other. Splitting the operation makes
   the semantics explicit at the IR level.
3. **Owned vs borrowed vs trivial classification on every ARC value
   site.** Drop insertion only destroys *owned* values. Borrowed
   values cannot be destroyed, cannot escape the function, and
   cannot be stored into owned data without an explicit
   `copy_value`.
4. **An ownership verifier** that runs after IR construction and
   before `arc_drop_insertion`. It rejects programs where an owned
   value is destroyed twice, an owned value is leaked, a borrowed
   value is destroyed, or a borrowed value escapes its scope.
5. **Recurse verifier and drop insertion through ALL nested
   instruction streams** — `optional_dispatch.nil_instrs`/
   `struct_instrs`, `switch_return.cases[].body_instrs`,
   `union_switch_return.cases[].body_instrs`,
   `try_call_named.handler_instrs`/`success_instrs`,
   `guard_block.body`, `error_catch` paths.
6. **Only after 1-5 land**: flip `.map` in `isArcManagedTypeId` /
   `IrBuilder.isArcManagedType`. The flag flip becomes the
   non-event it was always supposed to be.

Once the ownership model is verifier-backed, consume-mode and reuse
optimizations can be reintroduced as separate phases — exactly the
sequencing Koka uses (precise RC first, reuse layered on top).

The substrate work from attempts 6.2a-6.9 is preserved where
correct (the runtime substrate, the escape-analysis fix, the
tail-call rewriter, the live_before_ret exposure). What changes is
how ownership is represented and validated at the IR boundary.

Success means k-nucleotide drops from 7.57 GiB peak RSS to a target
< 500 MiB (stretch < 200 MiB) at a runtime in the 0.5-1.5s range,
while 724/724 unit + 104/104 zir-test stay green and all 3 CLBG
benchmark ports remain byte-exact, and `zap run doc` completes in
bounded time.

---

## 1. Design principles (non-negotiable)

These principles encode the lessons from the 8 prior attempts plus
the precedent literature (Swift OSSA, Lean 4 borrowed refs,
Koka/Perceus, Rust NLL/Polonius, Roc, Clojure transients).

**1.1 Ownership is a property of values and conventions, not locals.**
Every ARC value site (param, local binding, call result, aggregate
arm result, capture, return value) carries an explicit ownership
class: `owned`, `borrowed`, or `trivial`. The IR must make this
visible enough that a one-pass verifier can check it.

**1.2 Formal parameters of ARC type are borrowed by default.** The
caller already does the necessary retain (`share_value`) and release
(post-call `release`); the callee borrows the value within its
function body. **The callee-side scope-exit drop must skip
parameters.** This is the single change that explains the simplest
read-only reproducer's failure: drop insertion treats parameters as
owned and destroys them on return.

**1.3 Consuming convention is opt-in via callee metadata, not
inferred globally from liveness.** Today's arc_liveness marks any
last-use share as a consume site; this is unsound for borrowing
callees. A function declares its parameter conventions; the IR's
share lowering and drop insertion read them. Phase 6.9 already
gated consume-mode entirely off — it stays off until per-callee
metadata is in place. A future phase can enable consume for
explicitly consuming callees only.

**1.4 Aliasing splits into borrow vs copy.** A `local_get(d, source=m)`
that produces an alias to be passed to a borrowing call is a
**borrow** — no retain on `d`, no destroy on `d` at scope exit.
A `local_get(d, source=m)` that produces an independent owner is a
**copy** — retain on `d`, destroy on `d` at scope exit. These are
different IR operations.

**1.5 Returning a borrowed value requires `copy_value`.** A function
that returns one of its borrowed parameters (e.g., `pub fn id(m :: Map)
-> Map { m }`) must promote the borrow to ownership at the return
site. Otherwise the caller-side post-call release would destroy a
value the callee was lending out.

**1.6 Verifier-first.** Every ownership invariant is checked by a
dedicated pass. Counter-examples become test cases; verifier errors
become failing TDD tests. No symptom-patching that bypasses the
verifier.

**1.7 Recurse through all nested regions.** Every IR instruction
stream — top-level body, switch-return arms, union-switch-return
arms, optional_dispatch nil/struct streams, try_call success/handler
paths, guard_block body, error_catch — must participate in
ownership classification, drop insertion, and verification.

**1.8 No compromise on correctness.** Per `~/projects/zap/CLAUDE.md`:
"every solution must be the correct, production-grade, long-term
fix — regardless of how difficult, expensive, or time-consuming it
is. If a proper fix requires deep architectural changes across
multiple files, that is the fix."

**1.9 No new ZIR opcodes.** Owned/borrowed semantics lower to
ordinary Zig calls into runtime helpers (`retainAny`, `releaseAny`).
The fork's C-ABI surface is sufficient.

**1.10 TDD with verifier.** Each phase introduces verifier
invariants whose violations are red tests. Phase progress is
measured by green tests + verifier-clean IR + benchmark byte-
exactness.

---

## 2. Architecture

### 2.1 New IR concepts

**`OwnershipClass`** enum:

```zig
pub const OwnershipClass = enum {
    /// Trivial value (i64, Bool, Atom, ...). No ARC operations.
    trivial,
    /// Owner of a refcount unit. Must be destroyed exactly once on
    /// every CFG path that reaches a function exit. Cannot be
    /// destroyed twice. Owners are produced by: function entry of
    /// owned-convention parameters, `copy_value` of any ARC value,
    /// return values of calls whose convention transfers
    /// ownership (e.g., Map.put returning a fresh cell), aggregate
    /// initializers (map_init, list_init, struct_init), and
    /// freshly-allocated values (local_init for ARC-managed types).
    owned,
    /// Borrowed reference scoped to a borrow region. Must NOT be
    /// destroyed within the region. Cannot escape the region into
    /// owned storage without an explicit `copy_value` to promote.
    /// Borrows are produced by: function entry of borrowed-
    /// convention parameters (the default), `borrow_value` of any
    /// owner, capture access in closures.
    borrowed,
};
```

**`ParamConvention`** on function signatures:

```zig
pub const ParamConvention = enum {
    /// The callee treats this parameter as a borrow scoped to the
    /// function body. Caller does retain+release around the call.
    /// Default for ARC-managed parameter types.
    borrowed,
    /// The callee takes ownership of the value. Caller does NOT
    /// retain or release; ownership transfers at the call site.
    /// Used only for explicitly-annotated consuming functions
    /// (e.g., a future `Map.put_consume` variant). Today: zero
    /// runtime functions use this.
    owned,
};
```

Stored per-parameter on every function signature in HIR + IR.

**`ResultConvention`** on function signatures:

```zig
pub const ResultConvention = enum {
    /// Callee returns an owner. Caller binds the returned value to
    /// an owned local. This is the default for non-trivial result
    /// types.
    owned,
    /// Callee returns a borrow. Currently unused; reserved for
    /// future "lifetime polymorphic" APIs. Default may stay owned
    /// indefinitely.
    borrowed,
};
```

**New IR instructions** (replace overloaded `local_get` and `release`):

```zig
/// Produce a borrow alias of an ARC-managed source. Result is
/// `borrowed`. No retain, no scope-exit destroy on `dest`. The
/// borrow is valid until the enclosing borrow scope ends.
borrow_value: BorrowValue,

/// Produce an independent owner. Emits a runtime retain on the
/// source's cell. Result is `owned`. Pairs with a scope-exit
/// `destroy_value` on `dest` (unless the value is consumed earlier
/// by a `move`, return, or call with owning convention).
copy_value: CopyValue,

/// Move ownership from `source` (which must be `owned`) to `dest`.
/// Source is dead after this point. No retain, no release. Result
/// is `owned`. Used for explicit move semantics — e.g., when the
/// IR knows a local's last use is being passed into a consuming
/// position.
move_value: MoveValue,

/// Destroy an owned value. Emits a runtime release. Source must be
/// `owned`. Source is dead after this point.
destroy_value: DestroyValue,

/// Mark the start of a borrow scope. Implicit in some IR shapes
/// (function entry, switch arm bodies); may be made explicit for
/// nested regions to simplify the verifier.
begin_borrow_scope: BorrowScope,

/// Mark the end of a borrow scope. All borrows produced within
/// the scope are dead after this point.
end_borrow_scope: BorrowScope,
```

**`Function` carries ownership metadata:**

```zig
pub const Function = struct {
    // existing fields...

    /// Per-parameter convention (`borrowed` default for ARC types,
    /// `trivial` for non-ARC).
    param_conventions: []const ParamConvention,
    /// Per-local ownership class. Indexed by LocalId.
    local_ownership: []const OwnershipClass,
    /// The result convention.
    result_convention: ResultConvention,
};
```

**Side: `local_hir_types`** (Phase 6.8 added this) is preserved.
The verifier consults it to find ARC-managed locals.

### 2.2 New passes

Pipeline placement:

```
HIR
  └─ src/monomorphize.zig
       └─ Specialized HIR
             └─ src/perceus.zig                  (existing reuse pass)
                  └─ src/arc_liveness.zig        (existing — last-use analysis)
                       └─ src/arc_ownership.zig  (NEW — classify and normalize ownership)
                            └─ src/arc_verifier.zig (NEW — check invariants; fail-fast)
                                 └─ src/arc_drop_insertion.zig (existing — emits destroy_value for owned)
                                      └─ src/escape_lattice.zig
                                           └─ src/zir_builder.zig
                                                └─ standard Zig ZIR
```

**`arc_ownership.zig`** — the normalization pass:
- Walks each function body.
- For each `local_get` (the existing overloaded form), decides whether it should become a `borrow_value` or a `copy_value` based on:
  - The dest's eventual usage (call arg → borrow if callee borrows, copy if callee consumes; field projection → copy; storage into another owned value → copy; return → copy if not return-source-elided).
  - The source's ownership class.
- Replaces overloaded `local_get` instructions with `borrow_value` / `copy_value`.
- Annotates each local with its ownership class.
- Inserts `copy_value` at return sites where a borrowed value (e.g., a parameter) is being returned.
- Removes the Phase 6.8 `emitLocalGet` retain entirely; that retain becomes a `copy_value` only when needed.

**`arc_verifier.zig`** — the verifier:
- Runs after `arc_ownership.zig`, before `arc_drop_insertion.zig`.
- Walks every function and every nested instruction stream.
- For each owned local: track `defined → consumed` along all CFG paths. Reject if double-consume on any path or if any path reaches function exit without consume.
- For each borrowed local: track `defined → end_of_scope`. Reject if destroyed within the scope; reject if escaped (used after end_of_scope or stored into owned data).
- For each ARC parameter: ensure scope-exit drop is NOT emitted on it.
- Diagnostic: print the IR with ownership annotations on verifier failure (similar to Swift's OSSA verifier output).

**Updated `arc_drop_insertion.zig`** — emit destroys for owned only:
- Walks CFG. At every ret-equivalent terminator, for each ARC local L that is `owned` and live before the terminator, emit a `destroy_value{value=L}` instruction.
- For `borrowed` locals: never emit destroy.
- Recurses through ALL nested instruction streams (the bug from Phase 6.2b's choice to skip `optional_dispatch` is fixed).
- The Phase 5 return-source elision and Phase 6.2c retain-on-ret logic are subsumed: the ownership-typed IR makes both implicit.

### 2.3 Concrete callee-convention rules

Today every runtime function in `src/runtime.zig` is borrowing. The
ownership normalization pass must know this. Implementation:

- **All `:zig.X.Y(...)` builtins** map to a callee with all-borrowed
  ARC parameters and an owned result. This is hard-coded in
  `arc_ownership.zig` (or sourced from a small allowlist). When
  per-callee annotations are added later, the allowlist becomes
  driven by metadata rather than baked in.
- **All user-defined Zap functions** also default to all-borrowed
  parameters. This matches today's caller ABI (`share_value` +
  post-call release) which already implements borrow semantics.
- **`Map.put` / `Map.delete` / `Map.merge` returning fresh cells**
  produce `owned` result values. Their inputs are borrowed.
- **`Map.get` / `Map.has_key` / `Map.size`** return `trivial` results
  (V or Bool or i64). Their inputs are borrowed.

### 2.4 What stays from the existing substrate

- **The runtime substrate** (commit `07f56c7` and the HAMT depth/
  collision fixes). Untouched.
- **ARC instrumentation counters** (Phase 1, commit `dfd80ef`).
  Useful diagnostics throughout the redesign.
- **The Phase 1 microbench** (`src/test_reductions/persistent_map_tail_loop.zap`).
  Becomes a key ownership-correctness test.
- **`arc_liveness.zig` last-use analysis** (Phase 2).
  Repurposed: instead of producing consume sites blindly, its
  output now informs `arc_ownership.zig`'s borrow-vs-copy decisions.
- **`live_before_ret`** (Phase 6.2a). Used by drop insertion to
  enumerate which owned locals are live at each terminator.
- **`arc_drop_insertion.zig` skeleton** (Phase 6.2b). Modified to
  emit destroys for owned only; recursion extended through all
  nested streams.
- **The escape-analysis ARC fix** (Phase 6.5, commit `fcab310`).
  Untouched; ARC-managed types remain non-stack-eligible.
- **The tail-call rewriter past releases** (Phase 6.5, commit
  `f2c4a47`). Updated to walk past `destroy_value` (the new opcode)
  instead of the old `.release`.
- **`local_hir_types` side table** (Phase 6.8, commit `4a206b9`).
  Preserved; needed by the verifier.

### 2.5 What gets retired

- **Phase 6.7's `local_get` retain emission** in `lowerExpr`. Becomes
  a `copy_value` (the new explicit form) only when needed.
- **Phase 6.8's `emitLocalGet` helper.** Replaced by per-call-site
  decisions in `arc_ownership.zig`.
- **`arc_consumed_locals` set on `ZirDriver`.** Already gated off in
  Phase 6.4; can be removed entirely once the ownership pass owns
  consume decisions.
- **`arc_returned_locals`'s ad-hoc release suppression.** Subsumed
  by `arc_ownership.zig`'s correct classification of return-source
  locals as transferring ownership.
- **The Phase 5 return-source elision filter.** Subsumed by
  `arc_ownership.zig`'s `copy_value` insertion at return sites for
  borrowed values + skipping destroy on the moved-out owner for
  return-source locals.

This is intentional. The substrate accumulated patches; the new
design folds those patches into a single coherent model. Each
removal becomes a verifier-checked invariant: the verifier proves
the absence of leaks/double-frees that the patches were trying to
suppress.

---

## 3. Phased delivery

Each phase:
- Introduces failing tests *before* implementation (TDD).
- Has its own verifier invariants.
- Runs the full verification matrix at its gate.
- Is individually shippable: stopping mid-roadmap leaves the
  codebase in a coherent state.

Phases A-E are pure infrastructure — no observable behavior change
on the existing test workloads (since `.map` is still off). Phase F
is the milestone flip. Phase G is hardening + sanitizer CI.

### Phase A — ownership classification metadata + verifier framework

**Goal.** Add `OwnershipClass` and `ParamConvention` types, plumb
them through `Function` and HIR, populate with safe defaults, add
verifier scaffolding (no rules enforced yet).

**Files touched.**
- `src/ir.zig` — `OwnershipClass`, `ParamConvention`, `Function.param_conventions`, `Function.local_ownership`, `Function.result_convention`.
- `src/hir.zig` — propagate signatures with conventions through monomorphization.
- (New) `src/arc_ownership.zig` — module skeleton, default classifier (everything `trivial` until Phase B).
- (New) `src/arc_verifier.zig` — module skeleton, no rules yet.
- `src/compiler.zig` — wire passes between `arc_liveness` and `arc_drop_insertion`.

**Concrete changes.**

1. Add the enum types in `src/ir.zig`. Default `ParamConvention` to `borrowed` for ARC-managed param types, `trivial` for non-ARC.
2. Populate `Function.param_conventions` from HIR. For now, every ARC param gets `borrowed`.
3. Populate `Function.local_ownership` with `trivial` for non-ARC locals and a stub for ARC locals (filled in later phases).
4. Skeleton `arc_ownership.zig`: `pub fn classifyAndNormalize(allocator, function, ownership, type_store) !void` — runs but does nothing.
5. Skeleton `arc_verifier.zig`: `pub fn verify(allocator, function) !void` — runs but accepts everything.
6. `compiler.zig` wires: `arc_liveness → arc_ownership → arc_verifier → arc_drop_insertion → escape_lattice → zir_builder`.

**Tests.**
- Existing tests pass unchanged.
- New unit tests pin metadata propagation: a function with one ARC param has `param_conventions[0] == .borrowed`.

**Verification gate.**
- 724/724 unit + 104/104 zir-test pass.
- 3 benchmarks byte-exact.
- New metadata visible in IR dumps.

**Effort.** 2-3 days.

### Phase B — drop insertion skips parameters

**Goal.** Make drop insertion respect parameter convention. Borrowed
parameters never get a scope-exit destroy.

**Files touched.**
- `src/arc_drop_insertion.zig` — filter out parameter LocalIds when computing the per-terminator drop set.

**Concrete changes.**

1. At each ret-equivalent terminator, when iterating `live_before_ret`, exclude any LocalId that is a function parameter (lookup against `Function.param_conventions` — anything `borrowed` is excluded from drop).
2. Add TDD tests:
   - **The simplest reproducer**: a function `pub fn id(x :: T) -> T { x }` for some ARC type. Insert a temporary `.map` flag flip locally to test it; the drop insertion should NOT emit a destroy on the parameter.
   - **The Map.has_key reproducer**: with `.map` flagged, `Map.has_key(m, 0)` no longer fires a parameter destroy on the callee side.

**Verification gate.**
- 724/724 unit + 104/104 zir-test pass.
- 3 benchmarks byte-exact.
- The simplest reproducer (`Map.has_key(m, 0)`) compiles and runs without segfaulting *if* the flag is flipped locally.

This phase is the most important behavioral change. It's predicted
to fix the simplest reproducer crash by itself.

**Effort.** 1-2 days.

### Phase C — split `local_get` into `borrow_value` / `copy_value`

**Goal.** Replace the overloaded `local_get` with two explicit forms.
Each call site decides which to emit based on context.

**Files touched.**
- `src/ir.zig` — add `borrow_value` and `copy_value` instructions; deprecate `local_get` in favor of the two new forms (or keep `local_get` as an internal scratch and translate before zir_builder).
- `src/arc_ownership.zig` — implement the borrow/copy decision logic.
- `src/zir_builder.zig` — lower `borrow_value` (no retain, alias only) and `copy_value` (retain) appropriately.
- All 5 existing `local_get` emission sites (`src/ir.zig:3686, 3819, 4080, 4598, 5034` per the Phase 6.8 audit) — replace with calls to a new helper that produces `borrow_value` or `copy_value` based on context.

**Concrete changes.**

1. Add the two new IR instructions.
2. The `arc_ownership` pass walks each function and decides per `local_get`:
   - If the dest's only use is as a call argument to a borrowing-convention parameter → `borrow_value`.
   - If the dest is stored in another owned value (struct field, list element, etc.) → `copy_value`.
   - If the dest flows into a `ret` and the source is a parameter → `copy_value` (promote borrow to owned for return).
   - Default → `copy_value` (conservative; verifier may reject and prompt refinement).
3. Lower `borrow_value` in `zir_builder` to a plain assignment (no retain).
4. Lower `copy_value` in `zir_builder` to assignment + retain.
5. Phase 6.8's `emitLocalGet` retain becomes a no-op (it's a `borrow_value` if the use site borrows, or a `copy_value` if the use site copies). The decision moves into `arc_ownership`.

**Tests.**
- Linear: `let x = ...; f(x)` with `f` borrowing → emits `borrow_value`.
- Linear: `let x = ...; { y: x }` (struct init) → emits `copy_value`.
- Return: `pub fn id(x :: T) -> T { x }` → emits `copy_value` at the return site.
- Aliased reads: `Map.get(m, ...); Map.get(m, ...)` → both reads are `borrow_value`s, no double-decrement on `m`.

**Verification gate.**
- 724/724 unit + 104/104 zir-test pass.
- 3 benchmarks byte-exact.
- IR dump shows correct borrow/copy classification on the test cases.

**Effort.** 4-5 days.

### Phase D — borrow scopes through nested regions

**Goal.** Recurse drop insertion AND verifier through all nested
instruction streams. Today, `arc_drop_insertion.zig` explicitly does
NOT recurse into `optional_dispatch` (per Phase 6.2b's design
choice). This omission is a known suspect for the remaining segfault.

**Files touched.**
- `src/arc_drop_insertion.zig` — recurse into all nested streams.
- `src/arc_verifier.zig` — model borrow scopes for nested regions.

**Concrete changes.**

1. Identify every IR instruction with nested instruction streams:
   `if_expr.then_instrs`/`else_instrs`, `case_block.arms[].body_instrs`,
   `switch_literal.cases[].body_instrs`/`default_instrs`,
   `switch_return.cases[].body_instrs`/`default_instrs`,
   `union_switch.cases[].body_instrs`,
   `union_switch_return.cases[].body_instrs`,
   `optional_dispatch.nil_instrs`/`struct_instrs`,
   `try_call_named.handler_instrs`/`success_instrs`,
   `guard_block.body`,
   `error_catch` paths.
2. For each, drop insertion descends recursively. The terminator-to-
   live-before mapping must include nested-stream terminators.
3. The verifier walks borrow scopes through these regions: a borrow
   produced before a nested region must remain borrow-typed within
   the region (cannot be destroyed inside; cannot escape into owned
   storage inside).

**Tests.**
- A function that uses `optional_dispatch` and threads an ARC value
  through both arms. Both arms get correct ownership treatment.
- A function with a `switch_return` over an ARC scrutinee. Each arm
  borrows correctly.

**Verification gate.**
- 724/724 unit + 104/104 zir-test pass.
- 3 benchmarks byte-exact.
- Doc generator (`zap run doc --no-deps lib/string.zap`) completes
  without segfault. Doc gen exercises `optional_dispatch` and
  generic dispatch heavily; this is the canonical regression test.

**Effort.** 4-5 days.

### Phase E — verifier rules

**Goal.** Activate ownership invariants. Every IR program must
verify; verifier failures become test failures.

**Files touched.**
- `src/arc_verifier.zig` — implement invariant checks.

**Concrete changes.**

1. Implement these invariants:
   - **Owned values are destroyed exactly once on every CFG path.**
     Use bitset dataflow: at every terminator, every owned value
     that is in `live_before_ret` MUST have a `destroy_value` after
     it. Conversely, no owned value may be destroyed twice along
     any path.
   - **Borrowed values are never destroyed.** No `destroy_value`
     instruction may target a borrowed local.
   - **Borrows do not escape their region.** A borrowed value
     stored into an aggregate (`struct_init`, `list_init`,
     `map_init`, `tuple_init`) must be promoted via `copy_value`
     first.
   - **Function parameters of borrowed convention are not
     destroyed.** Already enforced by Phase B's filter; verifier
     double-checks.
   - **Return values match result convention.** A function
     declared to return owned must return an owned value (verified
     at every `ret` instruction).

2. Verifier output: when an invariant fails, emit a clear
   diagnostic with file:line, the offending instruction, the
   ownership class, and a one-line description of the violated
   rule.

3. The verifier is invoked from `compiler.zig` after `arc_ownership`
   classification and before `arc_drop_insertion`.

**Tests.**
- Negative tests: hand-construct IR that violates each invariant.
  Verifier rejects with specific error.
- Positive tests: every existing zir-test program must verify clean.
- The simplest reproducer (`Map.has_key(m, 0)`) verifies clean
  under the local flag flip.

**Verification gate.**
- 724/724 unit + 104/104 zir-test pass.
- 3 benchmarks byte-exact.
- Verifier accepts all currently-shipping IR.
- Verifier rejects every hand-crafted negative case.

**Effort.** 4-5 days.

### Phase F — flip `.map` and verify the milestone

**Goal.** This is the moment of truth. With Phases A-E in place, the
flag flip is genuinely a one-line change.

**Files touched.**
- `src/ir.zig:1019` (`isArcManagedTypeId`) and `:4768` (`IrBuilder.isArcManagedType`) — extend to include `.map`.

**Verification gate (the project milestone).**

- 724+ unit + 104+ zir-test pass.
- 3 benchmark ports byte-exact:
  - `cd ~/projects/lang-benches/k-nucleotide && rm -rf zap-out zap.lock .zap-cache && ~/projects/zap/zig-out/bin/zap build k_nucleotide && diff <(./zap-out/bin/k_nucleotide < input.fasta) expected.txt` empty
  - same for fannkuch-redux 10 and spectral-norm 5500
- **k-nucleotide peak RSS**: `/usr/bin/time -l ./zap-out/bin/k_nucleotide < input.fasta > /dev/null`. **TARGET: < 500 MiB. Stretch: < 200 MiB.**
- **k-nucleotide runtime**: target ≤ 1.5s.
- **spectral-norm runtime**: must stay within 5% of current ~165ms baseline.
- **Map microbench under `ZAP_ARC_STATS=1`**: pool high-water-mark bounded (not 100k+).
- **`zap run doc`** completes (`zap doc --no-deps`) within 60 seconds on full stdlib.

If anything fails: do NOT commit. Diagnose. The verifier from
Phase E should produce a precise error pointing at the failing
invariant. The fix lands in the appropriate prior phase (or a new
Phase E.x) — never as a Phase F bypass.

**Effort.** 1 day if Phases A-E are correct.

### Phase G — sanitizer CI + fuzzing harness

**Goal.** Mechanically catch ownership regressions in CI.

**Files touched.**
- (New) `.github/workflows/sanitizers.yml` (or equivalent) — Linux runners with AddressSanitizer + LeakSanitizer build of the Zap compiler and runtime.
- (New) `tools/arc_fuzz/` — a libFuzzer-based fuzzer for randomly-generated Zap programs that exercise ARC operations.
- `Makefile` / `build.zig` — sanitizer build targets.

**Concrete changes.**

1. Linux CI job that builds Zap with `-fsanitize=address,leak`,
   runs the test suite + benchmarks, and fails on any ASan/LSan
   report.
2. A small libFuzzer harness that:
   - Generates random Zap programs using ARC types (Map, List,
     String).
   - Compiles them.
   - Runs the compiled binary under sanitizers.
   - Reduces crash-producing inputs.
3. Continuous fuzzing schedule: fuzzer runs nightly on a Linux
   runner, accumulates a corpus, escalates new crashes to issues.

**Verification gate.**
- ASan/LSan CI green on the existing test matrix.
- Fuzzer baseline run finds no new ownership crashes after 1 hour.

**Effort.** 3-5 days.

### Phase H — re-enable consume optimization (deferred, optional)

**Goal.** Reintroduce consume-mode for callees that genuinely
consume their parameters. Today no such callee exists, so this
phase is a stub until per-callee metadata is added.

**Files touched.**
- `src/arc_ownership.zig` — read per-callee parameter conventions.
- `src/runtime.zig` (potentially) — declare convention metadata for
  builtins.
- `src/zir_builder.zig` — lower `move_value` for consume-mode args.

**Concrete changes.**

1. Define a way for runtime builtins to declare consuming params.
   The simplest: an allowlist in `arc_ownership.zig` that names
   consuming builtins. Today the list is empty.
2. When `arc_ownership` sees a call to a consuming-convention
   parameter, emit `move_value` instead of `borrow_value` /
   `copy_value`. The source is dead after the call.
3. The verifier confirms: no use of source after `move_value`; no
   destroy of source.
4. Optional: a future `Map.put_consume` runtime variant that
   actually consumes its first argument. The Zap-side stdlib could
   pick the consume variant when liveness analysis determines
   consume is safe (per the original Perceus design). But this is
   strictly a perf optimization layered on top of correctness.

**Verification gate.**
- All prior gates.
- Microbench: `arc_consumes_total > 0` only when an explicitly
  consuming callee is invoked.

**Effort.** 5-7 days when actually pursued; otherwise indefinitely
deferred.

---

## 4. Iteration workflow — three loops

The 8-attempt Phase 6 saga consumed agent runs of 1-3 hours each
because every iteration ran the full `zig build zir-test` (~6-7
minutes) and a full benchmark sweep. That's the wrong default for
inner-loop dev work. This plan mandates a three-loop discipline.

### 4.1 Inner loop: per-edit (~15-30 seconds)

Every code change must validate against this loop before
considering the next change:

1. **Unit tests** (`zig build test --summary all`) — runs the 724
   colocated unit tests in ~10 seconds. The bulk of ARC correctness
   is checked here: hand-construct IR, run `arc_liveness` /
   `arc_ownership` / `arc_verifier` passes, assert on data
   structures. Phase 2 added 7 colocated tests; Phase 6.2b added 6;
   Phase 6.2c added 4. This phase plan adds dozens more — every
   ownership invariant, every classifier decision, every nested-
   region case. **Unit tests are the primary correctness signal.**

2. **Verifier output on the canonical reproducers.** When the
   verifier from Phase E is active, run it against:
   - `src/test_reductions/persistent_map_tail_loop.zap` (Phase 1
     microbench — the leak signal).
   - The simplest read-only `Map.has_key(m, 0)` reproducer.
   - The two-aliased-reads reproducer.
   No need to compile to a binary — the verifier accepts or rejects
   the IR directly.

3. **Standalone reproducer probe** (when binary behavior is
   genuinely needed):
   - Build the `zap` binary ONCE at the start of a phase:
     `zig build install -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`
     (~30-60s).
   - Then iterate by compiling tiny `/tmp/probe-N/lib/probe.zap`
     files: `~/projects/zap/zig-out/bin/zap build probe` (~5-10s).
   - Run with `ZAP_ARC_STATS=1` to see retain/release counts and
     pool HWM directly.

4. **DO NOT run `zig build zir-test`** in the inner loop. It's 30×
   slower than unit tests and exercises the same code paths the
   unit tests already cover.

5. **DO NOT run `zig build install` repeatedly** unless the inner-
   loop step actually needs a fresh `zap` binary. Compiler-internal
   tests use `zig build test` only.

### 4.2 Mid loop: per-feature (~60-120 seconds)

When a feature is locally complete and ready for a commit candidate:

1. **Filtered zir-test for the phase's specific feature.** Use the
   test runner's filter argument:
   ```sh
   zig build zir-test --summary all -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a -- "ARC"
   ```
   Each phase has 2-5 dedicated zir-tests; filter to those during
   dev. Runs in ~30-60 seconds vs the full suite's 6-7 minutes.

2. **Microbench RSS check.** Run the Phase 1 microbench:
   ```sh
   ZAP_ARC_STATS=1 ./zap-out/bin/probe < /dev/null
   ```
   on a small N (say 1000 iterations). Verify pool HWM is bounded
   under the new ownership discipline. This is the canonical signal
   that the leak is closed.

3. **Doc-runner spot check** for phases D-F (which touch nested
   regions and the flag flip):
   ```sh
   zap doc --no-deps lib/string.zap
   ```
   Should complete in seconds. If it hangs or crashes, that's a
   regression in CTFE/doc-gen ownership handling.

### 4.3 Outer loop: per-phase-commit gate (~30-60 seconds)

Run only at the phase-commit boundary. **The full `zig build
zir-test` is NOT in this loop.** It runs only at major-milestone
gates (§4.3.5).

1. `zig build test --summary all` — full unit test suite (~10s).
2. **Filtered zir-test for the phase's feature** (~30-60s):
   ```sh
   zig build zir-test -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a -- "ARC"
   ```
   (or "ownership", "borrow", "Map", etc. — whichever filter
   captures the phase's feature). NOT the full suite.
3. Microbench under `ZAP_ARC_STATS=1` for HWM assertion (~5s).
4. Doc-runner spot check on a small file (~10s).

**Hard rule: only commit when this matrix is green.** No WIP
commits. No "I'll fix it in the next commit" deferrals.

### 4.3.5 Major-milestone gate: per-phase-F-and-G commit (~10-15 min)

The full `zig build zir-test --summary all` and full benchmark
sweep run **only at Phase F (the flag flip) and Phase G (CI
hardening)** commits — and ONCE per commit, at the very end.

For Phases A-E, the outer-loop gate above is sufficient. If a
Phase A-E change accidentally breaks a non-ARC zir-test, that
breakage is caught at the Phase F gate (where the full sweep
finally runs) and fixed there. This is acceptable because:

- Phase A-E changes are scoped to ARC infrastructure (new files,
  new metadata, new instructions). They don't touch the broader
  IR semantics that non-ARC tests exercise.
- The unit test suite (729+ tests) covers the IR layer's other
  semantics extensively.
- Filtered zir-test for the phase's feature catches regressions
  in the area being changed.
- The cost of running full zir-test 6 times (once per phase A-F
  commit) is ~36-42 minutes. The cost of running it ONCE at the
  Phase F gate is ~6-7 minutes. The difference compounds across
  attempts.

If a non-ARC zir-test breaks during Phase A-E, that's diagnosed
at Phase F as a single regression. This trades a small risk of
late-discovered breakage for a large savings in iteration time.

### 4.4 Practical agent-prompt conventions

When launching subagents for individual phases:

- **Specify the iteration discipline in the prompt.** Tell the agent:
  > "Inner loop: `zig build test` + reproducer probe + verifier
  > output. Outer-loop commit gate: unit tests + FILTERED zir-test
  > for the phase's feature only. **DO NOT run `zig build zir-test`
  > without a filter argument** — full zir-test runs ONLY at the
  > Phase F flag-flip milestone and the Phase G CI commit. Until
  > then, filtered zir-test (`-- "ARC"` or similar) is the gate."

- **Pre-build zap once per phase.** The prompt should include:
  > "Build the zap binary at the start of the phase. Iterate against
  > `/tmp/probe-N/lib/probe.zap` reproducers using that binary. Do
  > not rebuild zap unless the IR layer itself has changed."

- **Specify time budget per loop.** Inner loop should take seconds,
  not minutes. If the inner loop is slow, the agent should diagnose
  why (likely an unintended `zig build install` or `zig build
  zir-test`) and fix the workflow before continuing.

- **No `lldb` in batch mode.** Multiple prior attempts wasted hours
  on hung `lldb -batch`. Use printf instrumentation in
  `src/runtime.zig` and dump stderr.

- **Hard stop on slow builds.** If any single command runs > 10
  minutes, kill it and investigate. Long builds are usually a sign
  of something wrong (cached state, missing flag, recompilation
  loop).

Following these conventions cuts per-attempt time from ~3 hours to
~30-60 minutes, and total Phase A-F time from a 20-hour saga to
~3-5 weeks of focused work as the §9 estimate predicts.

---

## 5. Verification matrix

A consolidated table of "what must be true at each phase-commit gate"
(outer loop, §4.3):

| Phase | Unit tests | zir-test | Microbench | k-nuc RSS | byte-exact | verifier |
|-------|-----------:|----------|------------|----------:|------------|----------|
| A | 729+ | filtered (~30s) | unchanged | 7.57 GiB | yes | scaffolded |
| B | 729+ | filtered (~30s) | unchanged (`.map` off) | 7.57 GiB | yes | scaffolded |
| C | 729+ | filtered (~30s) | unchanged | 7.57 GiB | yes | scaffolded |
| D | 729+ | filtered (~30s) | unchanged | 7.57 GiB | yes | scaffolded |
| E | 729+ | filtered (~30s) | unchanged | 7.57 GiB | yes | **active** |
| F | 729+ | **full (~6 min, ONCE)** | **bounded** | **< 500 MiB** | **yes** | active |
| G | 729+ | full (~6 min, ONCE) | bounded | < 500 MiB | yes | active + ASan/LSan + fuzz |

"Filtered" = `zig build zir-test -- "ARC"` or similar — runs only
the tests matching the phase's feature. "Full" = the entire
zir-test suite. Full zir-test runs ONLY at Phase F and Phase G
commit gates.

Phase F is the milestone for the project's primary goal; phase G is
hardening so this stays correct under expansion.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------:|-------:|------------|
| The verifier rejects existing `.opaque_type` workloads (DynClosure, etc.) | Medium | Medium | Phase E activates the verifier; if it rejects existing programs, that's a previously-hidden bug. Fix the offending IR site. The verifier is the SOLUTION, not the problem. |
| Borrow/copy decision in Phase C is wrong for some pattern | Medium | Medium | TDD: every shape gets a test. The verifier catches misclassifications. Default to `copy_value` (conservative — extra retain/release pair) when unsure. |
| `optional_dispatch` recursion in Phase D surfaces deeper IR bugs | Medium | Medium | Each surfaced bug becomes a test case. Land per-bug sub-commits within Phase D. |
| Verifier compile-time overhead is large | Low | Low | The verifier is bitset dataflow over ARC locals only. Zap functions are small; total work is small. Profile at Phase E gate. |
| `Map.put`'s borrowing-callee design conflicts with a future consume optimization | Low (deferred) | Low | Phase H handles this with explicit per-callee metadata. The current borrowing API stays correct under all the prior phases. |
| Doc generator (`zap run doc`) hits a code path that the verifier hasn't validated | Medium | High | Phase D explicitly tests doc gen. Phase E's verifier runs on doc-gen IR; failures become tests. |
| Sanitizer CI catches a UAF the verifier missed | Medium | Medium | The verifier is meant to be sound for the invariants it checks but isn't claimed to catch every memory bug. Sanitizers are the safety net; their failures point at gaps in the verifier (Phase E refinement). |
| The 8 prior attempts have left commit history littered with patches that the new design subsumes | Low | Low | The substrate work is preserved where correct; only the ad-hoc consume / return-elision logic gets replaced. Each retired piece becomes a verifier-checked invariant. |
| Future concurrency may invalidate single-threaded ARC assumptions | Low (deferred) | Low | Atomic ArcHeader is already in place. Per-type pools are threadlocal today; concurrency would require pool migration, but that's an orthogonal redesign. |

---

## 7. Concrete file-level change list

| File | A | B | C | D | E | F | G |
|------|---|---|---|---|---|---|---|
| `src/ir.zig` | + ownership types, `Function` fields | — | + `borrow_value`, `copy_value` instructions | — | — | flag flip | — |
| `src/hir.zig` | + propagate param conventions | — | — | — | — | — | — |
| `src/monomorphize.zig` | + propagate per-instantiation conventions | — | — | — | — | — | — |
| `src/compiler.zig` | + wire new passes | — | — | — | — | — | — |
| (new) `src/arc_ownership.zig` | scaffold | — | implement classifier | — | — | — | per-callee metadata read |
| (new) `src/arc_verifier.zig` | scaffold | — | — | — | implement invariants | — | — |
| `src/arc_drop_insertion.zig` | — | filter parameters | — | recurse nested streams | use `destroy_value` | — | — |
| `src/zir_builder.zig` | — | — | lower `borrow_value` / `copy_value` | — | — | — | — |
| `src/runtime.zig` | — | — | — | — | — | unit test for releaseFieldChildAny on Map field | — |
| `src/perceus.zig` | — | — | — | — | — | — | — |
| `src/escape_lattice.zig` | — | — | — | — | — | — | — |
| `src/test_reductions/` | — | + reproducer tests | + borrow/copy tests | + nested-region tests | + verifier negative tests | — | — |
| `src/zir_integration_tests.zig` | + scaffold tests | + reproducer | + borrow/copy E2E | + doc-gen E2E | + verifier E2E | + RSS assertion | + sanitizer fuzz |
| (new) `tools/arc_fuzz/` | — | — | — | — | — | — | scaffold |
| `.github/workflows/sanitizers.yml` (or equivalent) | — | — | — | — | — | — | scaffold |

The Zig fork (`~/projects/zig`) does NOT need any changes. Owned/
borrowed semantics lower through standard Zig.

---

## 8. What is explicitly out of scope

- **Reuse analysis** (Lean 4 / Perceus phase-2). Optional optimization on top of correctness. Phase H+ at earliest.
- **Borrow inference** (Morphic-style). Bigger type-system commitment than this plan.
- **Linear types in user-facing Zap.** Ownership is a compiler-internal property; users see persistent values. No Zap-language `@consume` or `@borrow` annotations.
- **Cycle collection.** Persistent immutable Maps cannot form cycles. Out of scope until Zap allows ARC-managed cycles (which it doesn't today).
- **Concurrent ARC.** Zap is single-threaded; the existing atomic `ArcHeader` is sufficient. Deferred until concurrency is added.
- **CHAMP / canonical-layout HAMT** in the runtime. Possibly worth a phase H+ if RSS doesn't hit < 200 MiB after Phase F.
- **Transient / mutable-builder Map.** Phase H+ candidate; not a correctness fix.
- **`MMap` mutable-map primitive.** Forbidden by `CLAUDE.md`'s no-workarounds rule. Persistent Map with correct ARC is the design.

---

## 9. Open questions to resolve during implementation

These are not blockers — they get answered in flight:

1. **Where exactly does the IR currently emit `local_get` for pattern-binding sites?** Phase 6.8 audit identified 5 sites. Are there others surfaced by Phase D's nested-region recursion?
2. **Does `escape_lattice.zig` interact with the new ownership classification?** Likely orthogonal — escape is "stack vs heap"; ownership is "destroy responsibility." Profile at Phase D gate.
3. **What's the verifier's diagnostic format?** Recommend Swift-OSSA style: print the IR with ownership annotations + arrow at the offending instruction. Adopt at Phase E.
4. **How does CTFE interact with ownership?** CTFE evaluates IR at compile time. Does it need its own ownership semantics, or does it run on already-verified IR? Phase D should pin this.
5. **Are there per-callee conventions worth landing in Phase A** (rather than deferring to Phase H)? Likely no — every callee today is borrowing. But check Phase 6.8's `local_hir_types` table for any annotated calls.
6. **Should the verifier run in release builds or only debug?** Recommend always-on in debug + CI; off in release (or as a sampled assertion). Phase E decision.

Each is resolved by code-reading + targeted tests.

---

## 10. Effort and timeline

A single competent compiler engineer, working focused, lands phases
A-F in **17-25 engineer-days**:

| Phase | Effort (days) |
|-------|--------------:|
| A. Ownership metadata + verifier scaffold | 2-3 |
| B. Drop insertion skips parameters | 1-2 |
| C. Split `local_get` into borrow/copy | 4-5 |
| D. Recurse through nested regions | 4-5 |
| E. Verifier invariants | 4-5 |
| F. Flip `.map` flag | 1 |
| **Subtotal (correctness)** | **16-21** |
| G. Sanitizer CI + fuzzer | 3-5 |
| H. Consume optimization (optional) | 5-7 (deferred) |

Add 20-30% buffer for the surface area discovered during Phases C
and D. Realistic delivery for Phases A-F: **3-5 weeks of focused
time**. Phase G adds another week. Phase H is optional.

Compare to the prior 8-attempt saga: each attempt spent 1-3 hours of
agent time, accumulated 11 commits of substrate work, and never
reached the milestone. A coherent ownership-first design lands in
fewer total commits (probably 6-10) and reaches the milestone with
mathematical confidence rather than empirical guessing.

**The §4 iteration discipline is load-bearing for these estimates.**
The prior saga's per-attempt cost was dominated by `zig build
zir-test` (6-7 minutes) and full benchmark sweeps run on every
edit. If a per-phase agent runs the full zir-test 10 times in an
attempt, that's an hour just on test orchestration. With the
inner-loop discipline (unit tests + reproducer probe + verifier
output), that same iteration count drops to under 5 minutes total.
The phase effort numbers above assume the inner-loop discipline is
followed.

---

## 11. Final landing criteria

This plan is complete when:

1. `git log` shows the seven phase commits (A-G), each with passing tests.
2. `zig build test --summary all` reports `724+/724+ tests passed`.
3. `zig build zir-test --summary all -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a` reports `~115+/115+ tests passed` (current 104 + ~10 new).
4. `cd ~/projects/lang-benches/k-nucleotide && diff <(./zap-out/bin/k_nucleotide < input.fasta) expected.txt` reports no diff.
5. `/usr/bin/time -l ./zap-out/bin/k_nucleotide < input.fasta > /dev/null` reports peak RSS < 500 MiB (target < 200 MiB).
6. fannkuch-redux and spectral-norm byte-exact + within 5% of pre-flip runtimes.
7. `zap run doc` (full stdlib) completes in bounded time.
8. ASan/LSan CI is green on the existing test suite.
9. The verifier is active and runs on every compilation in debug builds.
10. `docs/k-nucleotide-rss-gap-research-brief.md`, `docs/k-nucleotide-rss-gap-implementation-plan.md`, and this document get a "completed" note appended pointing at the relevant commits.

The persistent-Map perf path is then fundamentally correct, and the
compiler enforces ownership invariants statically. The 8-attempt
Phase 6 saga ends with a verifier-backed model that prevents this
class of bug from recurring.

---

## Appendix: comparison to the 8-attempt saga

| Prior attempt | Substrate landed | What it lacked |
|---|---|---|
| 6.0 (no commit) | — | Scope-exit drops |
| 6.2a-c (3 commits) | live_before_ret, drop insertion, retain-on-ret | Aware that parameters are borrowed |
| 6.3 (reverted) | — | Consume-mode doesn't help borrowing callees |
| 6.4 (1 commit) | Consume-mode skip retain only | Still no parameter handling |
| 6.5 (3 commits) | Escape fix, tail-call rewriter, alias gate | Aliasing semantics still ambiguous |
| 6.7 (1 commit) | local_get retain (one site) | Only covered named-assignment path |
| 6.8 (1 commit) | local_get retain (all 5 sites) | Doesn't distinguish borrow from copy |
| 6.9 (1 commit) | Consume-mode gated entirely | Parameters still treated as owned |
| 6.10 (interrupted) | — | (was investigating drop-suppression filter; secondary suspect) |

Each attempt patched a symptom of the underlying ownership-
overloading bug. The new plan addresses the bug class itself,
making each prior fix either redundant (subsumed by the verifier) or
preserved as an invariant the verifier checks.

---

## End of plan

The deliverable from executing this plan is:

- A coherent ownership model in IR that distinguishes owned, borrowed, and trivial values.
- A verifier that proves the absence of double-free, leak, and use-after-free for ARC values.
- Bounded peak RSS for k-nucleotide and any other persistent-map workload.
- A foundation for future consume-mode and reuse optimizations (Phase H+) that build on a sound base rather than racing it.
- An end to the 8-attempt Phase 6 saga, with the milestone landed and the substrate retired into verifier-checked invariants.
