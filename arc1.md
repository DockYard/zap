# Making the IR the Single Source of Truth for ARC: A Deep Investigation for Zap

## TL;DR

- **Adopt the strict invariant.** Every ARC retain or release that the compiled Zap program executes at runtime must correspond 1:1 to a `.retain` / `.release` IR instruction. This is the only architecture that scales — it is the design Swift's OSSA SIL, Lean 4's IR, and Koka's Core all converge on, and it is the only one whose soundness can be mechanically verified by a compact, dataflow-driven IR verifier rather than by per-instruction code review.
- **Use a small set of typed-flavored IR ops.** A flavored `.retain { kind, value }` and `.release { kind: .release | .free | .reset, value }` family (modeled on Swift's `strong_retain`/`strong_release`/`destroy_value` and Lean's `inc`/`dec`/`del`/`reset`/`reuse`) is the optimization-friendly sweet spot. Type-dispatch alone is too implicit; per-op intrinsics balloon the surface area.
- **Phase the refactor: Class A (retain) → Class B (release/free/reset) → Class C (reuse).** Keep `arc_drop_insertion` as the IR-level oracle, strengthen the verifier to require per-path retain/release balance and ban any ZIR-level retain/release call outside canonical IR-instruction handlers, and re-derive `arc_managed_locals` from the IR rather than from heuristic seeding.

## Key Findings

The bug that motivates this report — `.field_get` of an indirect-storage recursive struct field emitting `retainAnyOpt` at ZIR level without an IR-visible retain, which causes `arc_drop_insertion` to never seed the local as ARC-managed and so never emit a matching release — is not a one-off implementation slip. It is the predictable symptom of a *class* of architectural bug that every production RC compiler has had to engineer its way out of. The shared lesson from Swift, Lean 4, Koka, Roc, Nim, and Lobster is the same: when the IR is the single source of truth for retain/release, the verifier can statically detect leaks and use-after-frees, the optimizer can move and elide ARC operations safely, and *no* ARC operation can be silently emitted by a lowering rule that some downstream pass forgot about. When the IR is *not* the source of truth, soundness becomes an unstated, unverified, and constantly drifting global property that depends on every backend handler agreeing — a state Swift explicitly engineered out of its compiler in the 2018–2020 OSSA migration, and one Lean 4 and Koka avoided from day one because they took the academic Perceus / Counting Immutable Beans designs literally.

The clearest evidence comes from Swift's documentation. From `docs/SIL/Ownership.md` on `main`, an Owned value is "consumed exactly once along all paths through a function by either a destroy_value (actually destroying the value) or by a consuming instruction that rebinds the value in some manner (e.x.: apply, casts, store)." The doc continues: "We require that each such value is consumed exactly once along all program paths. The IR verifier will flag values that are not consumed along a path as a leak and any double consumes as use-after-frees." That is exactly the invariant Zap's `arc_drop_insertion` should be enforcing — and exactly the invariant the binarytrees bug violates.

The remainder of this report defends that recommendation in detail, surveys how the comparable systems are architected, and gives a per-IR-op recommendation table, a verifier-invariant checklist, a phased implementation plan, and a treatment of every secondary question.

## State of the Art

### Swift / SIL OSSA — the canonical "strict" architecture

Swift's Intermediate Language went through three generations of ARC representation, and the trajectory is itself the strongest argument for the strict invariant. In the original SIL (pre-2018), `strong_retain` and `strong_release` were SIL instructions, but they were emitted naively by SILGen and then aggressively cleaned up by the LLVM-style ARC optimizer. The relevant docs explicitly say: "After lowering OSSA, retain and release operations are never implicit in SIL and always must be explicitly performed where needed. Retains and releases on the value may be freely moved, and balancing retains and releases may be deleted, so long as an owning retain count is maintained for the uses of the value." (`docs/SIL/Instructions.md`, `swiftlang/swift`, `main` branch.)

In OSSA SIL — the Ownership SSA form introduced in Swift 5 and made the canonical entry point of all SILGen output thereafter — retain/release is replaced by `copy_value`, `destroy_value`, `begin_borrow`, and `end_borrow`. The doc states unambiguously: "By using these ownership invariants, SIL in OSSA form can be validated statically as not containing use after free errors or leaked memory. This allows the compiler at compile time to detect bugs in SILGen and optimization passes." (`docs/SIL/SIL.md`.) The verifier that performs this check lives in `lib/SIL/Verifier/LinearLifetimeChecker.cpp`, with the public API exposing `checkValue(value, consumingUses, nonConsumingUses, errorBuilder, leakingBlockCallback, nonConsumingUsesOutsideLifetimeCallback)`. The two classes of error it reports are exactly: a path from definition to function exit (or a dead-end block) without a consuming use ("leak"), and a use that is not within the live region defined by the value's consuming uses ("use-after-free / non-consuming use outside lifetime"). Reborrows are verified separately by `ReborrowVerifier.cpp`, memory-location lifetimes by `MemoryLifetimeVerifier.cpp`, and per-operand ownership constraints by `SILOwnershipVerifier.cpp`.

The flavor question — whether retain ops should be a single `.retain` with type dispatch or a family — is also answered by Swift. SIL has `strong_retain`, `strong_release`, `unowned_retain`, `unowned_release`, `strong_retain_unowned`, `copy_unowned_value`, plus the OSSA-only `copy_value`, `destroy_value`, `begin_borrow`, `end_borrow`, `end_lifetime`, `extend_lifetime`, and `move_value [lexical]`. The reasoning is given in `docs/SIL.rst`: "The SIL type system also fully represents strength of reference. This is useful for several reasons: Type-safety: it is impossible to erroneously emit SIL that naively uses a @weak or @unowned reference as if it were a strong reference. Consistency: when a reference is kept in memory, instructions like copy_addr and destroy_addr implicitly carry the right semantics in the type of the address, rather than needing special variants or flags." The lesson: split by *ownership semantics* (strong/weak/unowned) but *not* by source-language type (class vs. struct vs. enum); let the type system on the operand carry that.

The ARC optimizer (`lib/Transforms/ObjCARC` for Objective-C interop, plus the SIL-level passes in `ARCCodeMotion.cpp`, `SILOptimizer/ARC/`) is fundamentally a retain/release pairing-and-motion engine: it does a top-down and bottom-up traversal pairing up retain and release operations so that "balancing retains and releases may be deleted, so long as an owning retain count is maintained for the uses of the value." This optimizer would be impossible to write correctly if some retains came from typed IR and others from late-emitted runtime calls; it requires every retain/release to be a first-class instruction.

### Lean 4 — `inc`, `dec`, `reset`, `reuse`, `del` as IR nodes

Lean 4's IR is the cleanest published instance of strict reference-counting-as-IR, and is the most directly relevant to Zap because Lean (like Zap) sits between a high-level functional source language and a low-level C/LLVM backend. The relevant file is `src/Lean/Compiler/IR/Basic.lean` in `leanprover/lean4`. Its module-level comment is explicit about the lineage: "Implements (extended) λPure and λRc proposed in the article 'Counting Immutable Beans', Sebastian Ullrich and Leonardo de Moura. The Lean to IR transformation produces λPure code, and this part is implemented in C++. The procedures described in the paper above are implemented in Lean."

The `FnBody` data type carries `inc`, `dec`, and `del` as first-class constructors:

```
| inc (x : VarId) (n : Nat) (c : Bool) (persistent : Bool) (b : FnBody)
| dec (x : VarId) (n : Nat) (c : Bool) (persistent : Bool) (b : FnBody)
| del (x : VarId) (b : FnBody)
```

`Expr` carries `reset`, `reuse`, and the projection family (`proj`, `uproj`, `sproj`). The pass order encoded in `Lean.IR.compile` is roughly: (1) `ToIR` (from Lean's high-level core) emitting λPure code; (2) `Borrow` performing parameter borrow inference; (3) `ResetReuse` inserting `reset`/`reuse` per the Counting Immutable Beans algorithm; (4) explicit RC insertion (the `inc`/`dec` insertion implementing the paper's `O−` operator); (5) `ExpandResetReuse` lowering `reuse x ctor …` either into in-place `set x i ws[i]` chains plus a `del y` (the fast path when `x` was unique) or into a fresh constructor (the slow path); (6) `EmitC` lowering the IR to C with calls to the runtime helpers `lean_inc`, `lean_dec`, `lean_dec_ref`, `lean_free`. The `ResetReuse.lean` comment is unambiguous about the ordering: "Remark: the `insertResetReuse` transformation is applied before we have inserted inc/dec instructions, and performed lower level optimizations that introduce the instructions release and set."

The `.retain { kind: .reset }` design idea Zap is considering is therefore *exactly* what Lean does. `reset` is its own IR node that decrements the reference counters of the components and, depending on uniqueness at runtime, either passes the storage on to a paired `reuse` or returns the special pointer value `BOX`. `reuse` is then either an in-place set or a fresh allocation. This separation is the architectural enabler for the "functional but in-place" (FBIP) programming pattern.

### Koka — Perceus, with `Dup` / `Drop` as Core nodes

Koka's Perceus pass — Alex Reinking, Ningning Xie, Leonardo de Moura, and Daan Leijen, "Perceus: Garbage Free Reference Counting with Reuse," PLDI '21 (42nd ACM SIGPLAN International Conference on Programming Language Design and Implementation, June 20–25, 2021, Virtual, Canada; ACM, pp. 96–111; DOI 10.1145/3453483.3454032; awarded ACM SIGPLAN Distinguished Paper) — emits *precise* reference counting, defined formally on a linear resource calculus λ₁ as a syntax-directed translation that "delays a dup operation to come as late as possible, pushing them out to the leaves of a derivation; and we generate a drop operation as soon as possible, right after a binding." The compiler structure mirrors the formalism: the type-checked Core flows through `Core.CTail` (tail-call-modulo-cons), `Core.Borrowed` (parameter borrow inference), `Backend.C.Parc` (Perceus — inserts `Dup`/`Drop` Core nodes), `Backend.C.ParcReuse` (inserts `@reuse` and drop-reuse), `Backend.C.ParcReuseSpec` (reuse specialization), `Backend.C.Box`, and finally `Backend.C.FromCore`, which emits C with 1:1 calls to the runtime helpers `kk_dup`, `kk_drop`, `kk_drop_reuse`, `kk_reuse`. Critically, `Dup`/`Drop` exist *as IR nodes in Core* throughout the pipeline; the C backend does not generate ARC calls from any other path. (Koka's exact Haskell encoding may either be dedicated `Expr` constructors or applications of distinguished primitive variables `nameDup`/`nameDrop` — both encodings are observed in published Koka code dumps and both are functionally equivalent for the IR-as-source-of-truth invariant.)

The Koka book prints the post-Perceus internal Core for a red-black-tree fold verbatim: `if unique(t) then { drop(k); free(t) } else { dup(l); dup(r) }`. Note three things: (1) `drop` and `dup` are first-class, (2) `free` is a separate operation (this is Zap's Class B `freeAny`), and (3) the optimization that picks between `drop`/`free` vs. `dup`/`dup` is an IR-to-IR rewrite, not a code-generation decision.

Unlike Swift, Koka does not have a *separate* IR verifier pass: soundness is a property of the algorithm proven on paper (Theorem 4: "Perceus is precise and garbage free"). This is a design choice, not an oversight — and it is one Zap should *not* copy, because Zap is not a paper-bounded research compiler and its IR is being maintained by humans modifying it in ways the original soundness proof never covered. The binarytrees bug is exhibit A of why a verifier is necessary in practice.

### Counting Immutable Beans — the original Lean instructions

Ullrich and de Moura's "Counting Immutable Beans: Reference Counting Optimized for Purely Functional Programming" (IFL '19, September 25–27, 2019, Singapore; ACM ISBN 978-1-4503-7562-7/19/09; DOI 10.1145/3412932.3412935) defines the exact instruction set Lean 4 implements. The grammar extension is:

```
F ∈ FnBody ::= … | inc x; F | dec x; F | let y = reset x; F | let y = reuse x in ctor_i y; F
```

The reference counters of live values are always positive; `dec(x)` either decrements or, if the count would reach zero, transitively decrements components and frees. `reset x` checks `isShared(x)` at runtime and either returns `BOX` (shared, fall back to fresh allocation) or returns `x` after decrementing component refcounts (unique, available for reuse). This is the design Zap should adopt for Class B: `reset` is a separate IR op from plain `release` because its dataflow shape is different — its result feeds a paired `reuse`.

### Roc — Perceus-derived

Roc adopts the same model. The Utrecht University student thesis "Reference Counting with Reuse in Roc" (studenttheses.uu.nl/handle/20.500.12932/44634) compares Counting Immutable Beans to an extended Perceus with drop-guided reuse implemented in Roc, with the same `Dup`/`Drop` nodes and the same `reset`/`reuse` pair. Roc's compile-time uniqueness analysis adds a wrinkle (some values are statically known unique and need no RC), but the IR shape is the same. Roc's approach to the recursive-tree case is: cycles are ruled out at language design time because direct mutation is not a primitive ("Roc's automatic reference counting neither pays for runtime cycle collection nor memory leaks from cycles, because the language's lack of direct mutation primitives lets it rule out reference cycles at language design time"). This is relevant for Zap if Zap permits cycles (it does not, similar to Roc/Lean/Koka).

### Nim ARC/ORC — strict, with cursor inference

Nim's ARC pass operates on the AST and inserts `=copy`, `=sink`, `=destroy`, `=trace`, and `=dup` hooks deterministically; ORC adds a constant-time-registration cycle collector. Notable detail: Araq has confirmed Nim's `--gc:arc` is essentially Lobster's algorithm. Nim performs cursor inference (a static analysis that elides RC operations on values whose lifetime is statically tied to a longer-lived owner) and move analysis on the *same IR* that the destructor-injection pass operates on. This is the key Nim insight Zap should absorb: the optimizer and the lowering operate on the *same* IR, with retain/release as first-class ops, and the optimizer's job is purely to elide redundant pairs — never to *insert* them, never to *omit* them, and never to discover them by reading runtime call sites.

### Lobster — compile-time RC with lifetime analysis

Lobster's homepage states verbatim: "Reference Counting with cycle detection at exit, 95% of reference count ops removed at compile time thanks to lifetime analysis" (strlen.com/lobster). The Lobster memory-management documentation (aardappel.github.io/lobster/memory_management.html) elaborates: "Using this analysis was able to remove around 95% of runtime reference count operations." The model: every value is reference counted, but a borrow checker plus lifetime analysis on the IR elides RC ops whose pairs would be balanced. The wider point — confirmed by Wouter van Oortmerssen's commentary — is that compile-time RC is only tractable when retain/release is an IR-level construct that the analyzer can move and remove. Lobster's algorithm is AST-based, and Wouter himself notes Rust moved to CFG-based (NLL) lifetime analysis precisely because AST-level analysis was limiting.

### Rust MIR — Drop terminators and drop elaboration

Rust does *not* use ARC for its primary memory management (it uses single ownership), but Rust's MIR `Drop` terminator and the drop-elaboration pass are the closest analogue to a "release IR op + a pass that conditionalizes it." From the Rust Compiler Development Guide: "During MIR building, Drop terminators are inserted in every place where a drop may occur. However, in this phase, the presence of these terminators does not guarantee that a destructor will run, as the target of the drop may be uninitialized. […] At a high level, this pass refines Drop to only run the destructor if the target is initialized." Drop elaboration uses a pair of dataflow analyses, `MaybeInitializedPlaces` and `MaybeUninitializedPlaces`, classifies each Drop as Static / Dead / Conditional / Open, and lowers Conditional drops with drop flags. This is the exact pattern Zap should use for its Class B specializations: emit `.release` IR uniformly, then run a pass that specializes each release into `release` / `free` / `reset` based on dataflow.

### MLIR Buffer Deallocation

For a non-RC contrast, MLIR's ownership-based buffer deallocation pass operates on `bufferization.dealloc` operations as first-class IR. The pass inserts dealloc operations at the end of each basic block with appropriate operands, and these are then optimized by `--buffer-deallocation-simplification` and `--canonicalize`. This is the same architectural shape: an IR-level memory-management op that downstream passes can move, simplify, and verify, rather than late-emitted runtime calls.

### LLVM ObjC ARC — IR intrinsics

Even at the LLVM level, ARC operations are intrinsics (`llvm.objc.retain`, `llvm.objc.release`, etc.) so the LLVM ARC optimizer in `lib/Transforms/ObjCARC` can pair, move, and eliminate them. The LLVM intrinsic-based design is forced because the ObjC ARC optimizer "does a top-down and a bottom-up traversal of the whole function to pair up retain and release instructions and remove them" — impossible to do correctly if retains were arbitrary `call` instructions that the optimizer might confuse with real function calls.

### Other systems briefly

- **Hylo / Val** uses mutable value semantics with no ARC at all, but its IR specification still enforces consume-once semantics via an ownership-tracking IR.
- **Vale** uses generational references: every owning reference has a generation counter, every non-owning reference carries a remembered generation, every dereference is a runtime equality check. No ARC in the Swift sense.
- **Pony** uses reference capabilities (`iso`, `trn`, `ref`, `val`, `box`, `tag`) plus an actor-local heap: ARC is per-actor (no atomics) and is driven by capability rules, not by IR-level retain/release.
- **Mojo** uses borrow/inout/owned argument conventions and explicit `^` transfer; under the hood, it is a strict ownership model with an IR-level lifetime that the compiler tracks.
- **C++ / Hylo / Cone** use moves/regions/arenas — orthogonal to the ARC question.

## Q1 Deep Dive — Strict vs. Centralized-Effect

### The two models

**Strict.** Every retain or release the program executes at runtime corresponds to a `.retain` or `.release` IR instruction. Runtime helpers always return borrowed references. Where Zap's ZIR-level `retainAnyOpt` is currently invoked from inside a runtime helper called by `.field_get`, the strict model splits this into two IR ops: `.field_get` (which returns a borrowed value), followed by an explicit `.retain` (which performs the retain count bump). `arc_drop_insertion` is then the single, authoritative emitter of `.release` ops, and it sees every retain.

**Centralized-effect.** Runtime helpers may retain/release internally, but every IR instruction's ARC effect is documented in a central function `arcEffectOf(instr)` that all analysis passes consult. `arc_drop_insertion` interprets the effect of `.field_get` as "produces a fresh +1 owner of the field," and emits a release on the result without there being a corresponding `.retain` in the IR.

### The recommendation: strict, with a narrow centralized-effect escape hatch

The strict model wins on every long-term axis:

1. **Verifiability.** Strict admits a simple, local IR verifier: for every `.retain` there must be a balancing `.release` reachable on every path; for every `.release` there must be a preceding `.retain` (or fresh allocation with rc=1) on every path. Both are linear-time dataflow checks on the IR. Centralized-effect requires the verifier to recompute `arcEffectOf` for every instruction and reason about *intra-runtime-call* effects — which is exactly the trust boundary that the binarytrees bug exploits.

2. **Optimization.** Every modern ARC optimizer (Swift OSSA's ARCCodeMotion, LLVM's ObjCARC, Lean's borrow inference + reuse, Koka's drop specialization) is a retain/release motion-and-pairing pass. These passes are mechanical when retains and releases are first-class IR ops; they are intractable when they are buried inside runtime calls. Centralized-effect forecloses on Perceus reuse, drop specialization, retain-release fusion, and escape-analysis-driven elision.

3. **Compositionality.** Strict is uniformly compositional: a new IR op added later need only declare its retain/release behavior by *emitting* retain/release IR ops, not by editing a global oracle table. Centralized-effect requires every new pass and every new IR op to update `arcEffectOf` consistently, which is the same fragility that produced the binarytrees bug in a different guise.

4. **Cost.** The 3000-line strict refactor is real but bounded; the 500-line centralized-effect change is cheaper *now* but compounds over time. Swift made exactly this trade in 2018–2020 (the OSSA migration was a multi-year, multi-thousand-line effort, and Apple judged it worth it specifically because the centralized-effect alternative was unmaintainable at scale).

The narrow escape hatch: for a few very well-defined runtime helpers whose retain/release behavior is invariant and whose result is *immediately consumed* by a user-visible op, it is acceptable to fold the retain/release into the helper *and* document the effect in `arcEffectOf`, *and* require the verifier to check the documented effect against the actual IR pattern. The standard for accepting an exception should be: (a) the effect is statically determinable by the type and op kind, (b) the verifier can simulate the effect and confirm balance, (c) there is a comment in the helper pointing at the verifier rule. This is the equivalent of Swift's `@guaranteed` parameter convention: a place where the IR records a *contract* about retain/release behavior even when the actual operations are not literally present.

### Per-op recommendation table

| IR op | Recommendation | Rationale |
|---|---|---|
| `.copy_value` | **Strict**: emit explicit `.retain` after | Maps to Swift's `copy_value`. Clearest semantics; enables CSE. |
| `.share_value` | **Strict**: explicit `.retain` | Same as `copy_value`. The "share" naming is misleading if it hides retain. |
| `.field_get` (direct) | **Strict**: `.field_get` returns borrowed, then `.retain` | This is *the* binarytrees bug. Borrowed-then-retain matches Swift `struct_extract` + `copy_value`. |
| `.field_get` (indirect, recursive) | **Strict** (mandatory): borrowed, then `.retain` | The exact bug case. Indirect storage must not be special-cased into a runtime helper. |
| `.list_get` | **Strict**: borrowed, then `.retain` | Audit immediately — likely a latent binarytrees-class bug. |
| `.map_get` | **Strict**: borrowed, then `.retain` | Same audit. |
| `.list_head`, `.list_tail` | **Strict**: borrowed, then `.retain` | Same. |
| `.struct_init` | **Centralized-effect, with explicit per-element `.retain`** | The struct itself has rc=1 from allocation; each ARC-typed field needs an explicit `.retain` of the source value. |
| `.list_init` | **Same** | Each element retain emitted explicitly. |
| `.map_init` | **Same** | Same. |
| `.move_value` | **Strict**: emits *no* retain/release; invalidates source | Source is dead post-move, verifier must enforce. |
| Function call (`.call`) | **Strict** with calling convention: caller emits `.retain` for `+1` (owned) args, callee emits `.release` | Mirror Swift's `@owned`/`@guaranteed` split. |
| Return | **Strict**: `+1` return = caller receives owner | Match call-site convention. |
| `.allocation` of fresh ARC object | **Implicit `+1`**: rc starts at 1, no explicit `.retain` | Consistent with Lean (`ctor` produces rc=1) and Swift (`alloc_ref` is +1). |

The pattern: every op whose *result* is a fresh ARC owner of an existing object emits a `.retain` (Strict). Every op whose result is a fresh ARC owner of a *newly allocated* object does not (the allocation already counts as +1). Every op that destroys an owner emits a `.release`.

## Q2 Deep Dive — `.retain` / `.release` IR Design

The two extremes are flavored variants (`.retain { kind: .transient | .persistent | .optional, value }`) versus a single `.retain { value }` with type dispatch in ZIR. Swift, Koka, and Lean all take a *middle path*: small flavor sets driven by *ownership/lifetime semantics*, not by source type.

Swift splits along ownership strength (strong/weak/unowned) plus optionality: `strong_retain`, `unowned_retain`, `strong_retain_unowned`, `copy_unowned_value`, plus the OSSA-only `copy_value`/`destroy_value` which subsume the strong-retain/release of regular references. The doc justifies this as type-safety plus consistency with the SIL type system.

Lean keeps it minimal: `inc` / `dec` / `del`, plus a `persistent : Bool` flag on `inc`/`dec` that marks values whose RC should not be touched (statically known persistent objects like top-level constants). Plus `n : Nat` for fused multiple inc/dec. Plus `c : Bool` indicating whether the inc must check for tagged pointers (boxed integers). This is *exactly* the flavored-variants design, with flavors chosen specifically to enable optimization (fusing repeated incs into `inc x 3`, eliding RC on persistent objects, eliding tag checks for non-tagged types).

**Recommendation for Zap.** Adopt a flavored design with three retain kinds (`.transient`, `.persistent`, `.optional`) and three release kinds (`.release`, `.free`, `.reset`). Add a fused-count parameter (`n : u32 = 1`) to enable the trivial peephole `retain x; retain x ⇒ retain x 2`. Crucially, the *flavor is a property of the IR op, not of the value's type*. Two reasons: (1) the same value may be retained as `.transient` in one place and `.persistent` in another (think a function-local cache of a global), so the flavor must travel on the op; (2) flavors are an analysis-result encoded into the IR — precisely the design Lean validates. Type-dispatch alone is too implicit and prevents the verifier from auditing what each retain is doing.

Optionality (`.optional`) deserves special attention. Swift handles this by having both `strong_retain` and a separate `unowned_retain` flavor, with the SIL type system tracking which is which. Zap's `retainAnyOpt` already encodes this distinction at the runtime level; promoting it into the IR as `.retain { kind: .optional }` is straightforward and keeps the verifier rule simple ("if the value is statically known non-null, optional retain may be lowered to a plain retain").

## Q5 Deep Dive — Class B (drop specializations) IR design

The current Zap design has `emitDropSpecializationsForCurrentInstr` and `emitPerceusResetForCase` consult `ArcOperation` records and emit `releaseAny`/`freeAny`/`resetAny` directly from ZIR. This is exactly the centralized-effect anti-pattern that the binarytrees bug demonstrates is unsound.

Lean's design is unambiguous: `dec`, `del`, and `reset` are first-class IR nodes, distinct ops with distinct dataflow. From `Basic.lean`: `dec` is a refcount decrement (with the persistent and tagged flags); `del` is an unconditional deletion (used by `ExpandResetReuse` after a `reuse` has consumed the storage); `reset` lives in `Expr` and produces a result that flows into a paired `reuse`. This is the design Zap should adopt.

**Recommendation.** Make Class B first-class IR:

```
.release { kind: .release | .free | .reset, value: LocalId }
```

with specific semantics:

- `.release` — decrement refcount; if zero, run destructor; standard ARC release.
- `.free` — unconditional free, used only when the refcount is statically known to be 1 at this point (analogous to Lean's `del` and Koka's `free`).
- `.reset` — Lean-style reset: at runtime, if rc=1 decrement component refcounts and yield the storage as reusable (paired with a future `.struct_init` with reuse_token); if rc>1, decrement and yield BOX. This *must* be a separate IR op because its result feeds into reuse.

The `arc_optimizer` pass becomes a *specialization* pass that rewrites generic `.release` IR ops into `.free` or `.reset` when dataflow proves they are safe — exactly analogous to Rust's drop elaboration classifying Drop terminators as Static / Dead / Conditional / Open. This keeps the source of truth in the IR while letting the optimizer specialize.

The rule for the verifier: `.release { kind: .reset, value: x }` must be paired with a downstream `.struct_init` (or `.list_init`, etc.) that consumes the reset's result as a `reuse_token`, on every path that reaches the release. This is checkable by SSA forward dataflow.

## Q7 Deep Dive — Verifier Strengthening

The candidate invariants are all valuable; here is how each maps to a verification technique and how it parallels Swift/Lean.

**Invariant 1: For every `.retain`, a balancing `.release` is reachable on every forward path.** This is the dual of Swift's "Owned values must be consumed exactly once on every path" and is checkable by linear-time forward dataflow on the SSA IR. The Swift `LinearLifetimeChecker.cpp` implements precisely this check, with the two error categories *leak* (no consumer reachable) and *use-after-consume* (consumer occurs after another consumer). For Zap: forward-walk the IR from each `.retain`, gather all `.release` ops on the same value, check that every path-suffix from the retain reaches at least one matching release before the function exit (or a panic / unwind). This is the most important invariant.

**Invariant 2: For every `.release`, a preceding `.retain` (or fresh allocation with rc=1) on every backward path.** Backward dataflow dual. Checks the binarytrees bug directly: if `.field_get` indirect-recursive emits a runtime retain but no IR `.retain`, the resulting `.release` (when one is eventually inserted) will have no preceding `.retain` and the verifier will reject. This is the architectural seatbelt that *forces* IR-as-source-of-truth.

**Invariant 3: ZIR audit — no retain/release runtime call appears outside canonical IR-instruction handlers.** Statically checkable as a grep-level audit of the ZIR backend: every emission of `swift_retain`/`retainAnyOpt`/`releaseAny`/`freeAny`/`resetAny` must be in a handler whose name matches `lower<IROpName>` for an IR op whose IR-level effect is `.retain` or `.release`. This is a cheap CI check and should be added as a hard gate. It is the moral equivalent of forbidding `call swift_retain` to appear in SILGen anywhere except inside `SILGenBuilder::createCopyValue`.

**Invariant 4: `arc_managed_locals` is exactly the set of locals that are source/dest of at least one ARC-affecting IR op.** Make this *derived*, not seeded. The set is a one-pass computation over the IR, and the verifier checks `arc_managed_locals == compute_from_ir()`. This eliminates seeding bugs (Q12) by construction.

**Additional invariants worth adopting from Swift:**

- For every consuming use of an owned value, it is the unique consumer on that path (Swift's "consumed exactly once").
- Borrow scopes (if Zap adopts them) are well-bracketed: `begin_borrow` and `end_borrow` form a properly nested scope with no consumes of the borrowed value inside.
- `extend_lifetime` semantics: a value is either consumed *or* has an explicit lifetime-extension marker on every path; useful when ARC ops are moved across debug locations.

What Lean's IR verifier checks: Lean does *not* have a separate ARC verifier in `src/Lean/Compiler/IR/`. Its only IR-level invariant is the linearity-like property in `Basic.lean`: "Since values of type struct and union are only used to return values, We assume they must be used/consumed 'linearly'." Soundness for `inc`/`dec`/`reset`/`reuse` is by construction (the algorithm is proven sound on paper). Zap should *not* copy this; Zap is being modified by humans without running a soundness-preserving rewrite proof, and the verifier is the primary defense.

The standard approach in industry is therefore: (1) a strong static verifier on every IR build (Swift's model), with (2) an algorithmic insertion pass whose individual rewrites are locally sound (Lean/Koka's model). Zap should adopt both layers.

## Q12 Deep Dive — `arc_managed_locals` seeding correctness audit

The binarytrees bug is a seeding bug: `.field_get` indirect-recursive was not flagged as "produces a fresh ARC owner," so its result was not added to `arc_managed_locals`, and `arc_drop_insertion` skipped it.

**The complete enumeration of IR ops whose dest produces a fresh ARC owner.** Any op whose result has an ARC-managed type and whose semantics include either (a) a fresh allocation, or (b) a copy of an existing managed pointer, or (c) a projection-with-retain, must seed. Enumerated:

- All allocation ops: `.struct_init`, `.list_init`, `.map_init`, `.string_init`, `.closure_init`, etc.
- All copy/share ops: `.copy_value`, `.share_value`.
- All projection-with-retain ops: `.field_get`, `.list_get`, `.map_get`, `.list_head`, `.list_tail`, `.tuple_get`, `.variant_payload_get`, etc. (where the field type is ARC-managed).
- All call return values where the callee returns `+1` (owned) by convention.
- All cast ops where the cast type is ARC-managed.
- All `phi`/SSA merges where any incoming value is ARC-managed.

**The seeding architecture should change.** Instead of seeding `arc_managed_locals` from a hand-maintained list and then hoping every op is covered, *derive* it from the IR. Concretely: define a single function `producesArcOwner(op) -> bool` that is the authoritative oracle, with a default of `true` for every op whose result type is ARC-managed *unless* the op explicitly opts out (a borrowed-projection like a future `.field_get_borrowed`). Make the default *safe* (over-seed rather than under-seed); under-seeding leaks (binarytrees), over-seeding adds redundant releases that the optimizer can eliminate.

Crucially, in the strict model, this question dissolves: every fresh ARC owner is *defined by* the presence of a `.retain` IR op (or an allocation op) producing it. `arc_managed_locals` is then *exactly* the set of `.retain`/`.allocation`-result locals, plus the locals threaded through them. There is no seeding heuristic at all; the IR is the seed.

This is why Q12 is downstream of Q1: adopting the strict model makes the seeding question trivially correct by construction. The latent class of binarytrees-style bugs in `.list_get`, `.map_get`, etc. should be audited *now* under the centralized-effect model (treat every projection of an ARC-managed type as seeding `arc_managed_locals`), and then dissolved permanently by the strict refactor.

## Brief Treatment of Q3, Q4, Q6, Q8, Q9, Q10, Q11, Q13, Q14

**Q3: `.move_value` semantics.** Move invalidates the source. The verifier must enforce that no use of the source occurs after the move on any path. Swift implements this via OSSA's "consumed exactly once" rule on `move_value`; Mojo via the `^` transfer operator and dataflow. Zap should mirror Swift: `.move_value` is a consuming use of source, defining a fresh owner at dest, and the linear-lifetime verifier flags any subsequent use of source. Recommended.

**Q4: Class C (Perceus reuse) — standalone or composite?** The standalone `.reuse_alloc` IR op (Lean's model) is preferable. Lean's `reset` produces a value (BOX or pointer) that flows into a `reuse` Expr; the `reuse` is then either a fresh ctor (slow path) or in-place sets (fast path). This separation is what enables the verifier to check that every `reset` is paired with a `reuse` on every path. The composite `.struct_init { reuse_token: Optional }` design conflates the reuse with the construction and makes the verifier rule harder to state. Recommendation: separate `.reset` (as part of Class B) and `.reuse_alloc` (as a separate op that takes a reuse-token result and either reuses or allocates fresh).

**Q6: Aggregate construction element retains.** Explicit per-element `.retain` is correct. This is what Swift's SILGen does (each operand to a `struct` instruction is retained explicitly via `copy_value`) and what Koka's Perceus does (each constructor argument receives an explicit `dup` in the inserted code). Implicit retain hides the operation from the verifier and the optimizer. Cost is one extra IR op per ARC-typed field at construction, which the optimizer can fuse with the source's existing `.retain` chain.

**Q8: Interaction with TCO and parameter convention promotion.** Zap should adopt Swift's `@owned`/`@guaranteed` calling-convention split. Tail calls under TCO must preserve the convention: a tail call passing an `@owned` argument is a transfer of ownership, no retain/release at the call site; a tail call passing `@guaranteed` requires the value to be live across the call but does not transfer ownership. Lean's borrow inference (`Borrow.lean`) is the closest analogue: it picks the convention per parameter to minimize total RC ops, then the IR carries the convention as an attribute on the `.call` op. The verifier checks the call's IR matches the callee's declared convention.

**Q9: Test migration strategy for ~819 existing tests.** Phase the refactor so that each phase preserves the existing tests' observable behavior (the program-level memory behavior). Class A (retain) refactor first; tests should pass unchanged. Then Class B (release/free/reset); tests still pass. Then Class C (reuse); some tests gain new in-place updates but observable output is the same. Add a verifier-pass test suite *before* starting any refactor, with golden IR for a few representative programs (binarytrees, a list map, a tree fold), and check the verifier-pass tests on every commit. Snapshot the IR for all existing tests after the verifier is in place; subsequent refactors require no IR-snapshot changes if the verifier passes.

**Q10: Performance impact.** Two effects: (a) the strict refactor adds explicit `.retain` IR ops whose runtime cost is one inc per op — but these are exactly the retains the runtime helpers were doing anyway, just exposed; net zero. (b) The verifier adds compile-time cost — a forward+backward dataflow per function, O(N) per pass, negligible at typical function sizes. (c) The optimizer becomes more powerful: peephole fusion, motion, and Perceus-style elision all become possible. Per the Counting Immutable Beans paper's own abstract (arXiv:1908.05647): "Our preliminary experimental results demonstrate our approach is competitive and often outperforms state-of-the-art compilers"; the Section 1 elaboration is "our new compiler produces competitive code that often outperforms the code generated by high-performance compilers such as ocamlopt and GHC." (The paper does not publish a single summary figure; the claim of outperformance is qualified as "preliminary" and benchmark-specific — for example, on `rbmap`, Lean is faster than all compared systems except OCaml.) The Perceus paper makes a parallel qualitative claim — the algorithm guarantees programs are "garbage free, where only live references are retained," and reuse analysis enables "guaranteed in-place updates at runtime" supporting the FBIP paradigm — without a single summary speedup figure. Recommendation for Zap: benchmark binarytrees, n-body, mandelbrot, knucleotide, and a tree-fold microbenchmark before and after each phase. Set thresholds: any phase that regresses performance >5% on any benchmark blocks until investigated.

**Q11: Phase ordering: A → B → C.** Class A (retain) first because it is the source of the binarytrees bug; fixing it eliminates the leak immediately. Class B (release/free/reset) second because it depends on Class A's IR-level retains being authoritative. Class C (reuse) third because reuse is an optimization on top of correct release/reset. This is also the order Lean's commit history followed (inc/dec first, then reset/reuse, then borrow inference).

**Q13: Should the refactor extend to the Zig fork?** Probably no. The IR contract is at the Zap-IR/ZIR boundary, not at the Zig boundary. The Zig fork's job is to lower ZIR to LLVM IR; ZIR is the surface that needs to expose ARC ops. Confirmed.

**Q14: Where to document the invariant?** Three places: (1) a top-level doc `docs/ARC.md` modeled on Swift's `docs/SIL/Ownership.md`, stating the invariant verbatim; (2) the verifier source itself (`arc_verifier.zig` — code is documentation); (3) a comment block on every IR op declaration in the IR definition file, matching Swift's `Instructions.md`. Cross-link all three.

## Recommended Phased Implementation Plan

**Phase 0 (1–2 weeks): Verifier scaffold and audit.** Implement the Q7 invariants 1, 2, 3, 4 as a verifier pass, but run in *warning-only* mode (collect violations, do not fail). Run on the existing test suite. Enumerate the violation classes; the binarytrees bug should appear immediately. Audit all `.list_get`, `.map_get`, `.list_head`, `.list_tail`, etc. for binarytrees-class issues using the verifier output (Q12).

**Phase 1 (3–4 weeks): Class A — strict retain refactor.** Lift every ZIR-level `retainAnyOpt` / `swift_retain`-equivalent call into an explicit `.retain` IR op emitted from `arc_drop_insertion` (or wherever the op-specific lowering lives). Update the per-op recommendation table from Q1. Switch the verifier to *fail* mode for invariants 1 and 3.

**Phase 2 (3–4 weeks): Class B — strict release/free/reset.** Replace `emitDropSpecializationsForCurrentInstr` with an IR-to-IR pass that rewrites generic `.release` into `.free` / `.reset` based on dataflow (analogous to Rust drop elaboration). Switch the verifier to fail mode for invariant 2 and the new pairing invariants for `.reset`/`.reuse_alloc`.

**Phase 3 (4–6 weeks): Class C — Perceus reuse.** Introduce `.reuse_alloc` as a standalone op. Implement reset/reuse insertion modeled on Lean's `ResetReuse.lean`. Add reuse specialization. Re-derive `arc_managed_locals` from the IR and remove all heuristic seeding code.

**Phase 4 (ongoing): Optimization opportunities.** Retain/release motion, fusion (`retain x; retain x ⇒ retain x 2`), borrow inference (Lean's algorithm) to eliminate redundant retain/release pairs across function calls.

## Risks, Open Questions, and What Could Go Wrong

The largest risk is the verifier rejecting code that is in fact correct because the verifier's invariants are too strong for some pattern Zap permits (e.g. control-flow-dependent ARC behavior, panics that escape ARC scopes, FFI boundaries). Swift hit exactly this and addressed it with `extend_lifetime`, `end_lifetime`, dead-end-block analysis, and operand-bundle-based ARC for ObjC interop. Zap should expect to add similar escape valves; the binarytrees lesson is that escape valves must be *named IR ops*, not ad-hoc emission paths.

A second risk is performance regression from un-elided explicit retains in hot loops. Mitigation: implement the optimizer's peephole fusion and motion passes early (in Phase 1), benchmark on every commit, and treat any regression on the standard benchmark suite as a blocking bug.

A third risk is test-suite churn. Mitigation: as in Q9, snapshot IR golden files before any refactor and gate the refactor on the verifier passing rather than on bit-identical IR output.

An open question is how to handle `Optional<T>` for ARC types. Swift handles this with explicit Optional-aware retain/release flavors; Lean handles it with the `c : Bool` flag on `inc`/`dec` indicating whether to check for tagged pointers. Zap's `retainAnyOpt` already encodes this and should be promoted to a flavor on `.retain`/`.release`.

A second open question is concurrency. Swift's ARC is atomic; Lean/Nim use thread-locality information to use non-atomic RC where safe. Zap should adopt Nim's model: a per-type or per-allocation flag indicating thread-local vs. atomic, with the IR carrying the flag and the verifier checking that thread-local values do not escape to other threads.

A third open question is FFI: when Zap calls into C, retains/releases on the boundary cannot be IR-level. The standard answer (Swift's): treat the FFI call as a black-box `apply` op with declared retain/release effects on its arguments and result, and require the IR around the call to materialize the implied retain/release as explicit ops. Document the convention; verify locally.

The single most important closing point: the binarytrees bug is the system *telling Zap* that the centralized-effect architecture has reached its limits. Every comparable production compiler reached the same point and made the same choice. The 3000-line refactor cost is bounded; the cost of the next binarytrees-class bug — found in production by a user's 12 GB RSS leak rather than in a benchmark — is unbounded.
