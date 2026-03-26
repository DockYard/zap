# Gap Analysis: Zap Compiler Plans

## Sources Analyzed

### Internal Plans
- `arc-plan.md` — Ownership-Typed ARC Integration
- `escape-analysis-plan.md` — CFG/SSA-Based Closure Escape and Lifetime Analysis
- `closures.md` — Nested Defs and First-Class Closures
- `plan.md` — Self-Contained Binary plan
- `implementation-epic.md` — Build System epic
- `deferred/` — Deferred work items

### External Research
- **Swift**: SIL Ownership SSA, ARC optimization passes, ClosureLifetimeFixup,
  SE-0377 parameter ownership modifiers, SE-0390 noncopyable types
- **Koka/Perceus**: Garbage-free reference counting with reuse (PLDI 2021),
  drop-guided reuse (ICFP 2022), FBIP
- **Lean 4**: Counting Immutable Beans (IFL 2019), reset/reuse optimization,
  borrowed parameter inference
- **Lobster**: Compile-time ownership analysis (~95% RC elimination),
  function ownership specialization
- **Vale**: Generational references, region-based borrow checker
- **Rust**: NLL borrow checking, Polonius loan-based analysis
- **Academic**: Choi/Gupta/Serrano connection graphs, Tofte-Talpin region
  inference, Go MEA2 field-sensitive escape analysis (OOPSLA 2024)

---

## Gap 1: No Perceus-Style Reuse / Drop Specialization

### What the plans say

ARC optimization is deferred to "aggressive global ARC optimization passes"
(arc-plan.md). The escape analysis plan mentions ARC/capture optimization
(Phase 4) but only covers retain/release elimination for local closures.

### What state of the art shows

Koka's Perceus (PLDI 2021, distinguished paper) and Lean 4's "Counting
Immutable Beans" demonstrate that the single highest-impact ARC optimization
is **reuse analysis**. When a pattern match deconstructs a value and the same
branch constructs a new value of the same size, the memory can be reused
in-place if the deconstructed value is uniquely owned (RC=1). This enables
"Functional But In-Place" (FBIP) execution where purely functional code
performs destructive updates automatically.

Perceus also introduces **drop specialization**. Instead of a generic
destructor dispatch, the compiler generates specialized drop code for each
known constructor at pattern match sites, avoiding tag-based dispatch
overhead.

The Perceus algorithm inserts two operations with precision:
- `dup(x)` — delayed as late as possible (pushed to leaves)
- `drop(x)` — generated as soon as possible (right after binding becomes dead)

This guarantees the "garbage-free" property: at no point during evaluation
does a dead reference exist.

Lean's variant uses:
- `reset x` — if RC=1, make memory available for reuse; else decrement
- `reuse token` — at allocation, reuse reset memory if available; else fresh alloc

### The gap

Zap's plans have no mention of reuse tokens, drop-guided reuse, reset/reuse
operations, or FBIP. Given Zap's functional nature (immutable bindings,
persistent data structures, pattern matching), this is the single most
impactful optimization missing. Without it, every `case` expression that
deconstructs and reconstructs values will allocate fresh memory and free the
old.

### Recommendation

Add a phase between the current ARC plan's MVP and the deferred "aggressive
optimization passes":

1. Add `reset` / `reuse` IR instructions (following Lean's model)
2. At pattern match sites, pair deconstructed values with same-size
   constructions in each branch
3. When the deconstructed value is `unique` (or RC=1 at runtime), reuse
   memory in-place
4. Add drop specialization: at match sites where the constructor tag is
   known, generate specialized drop code that handles known fields directly
   instead of dispatching through a generic destructor

This composes naturally with the existing ownership model: `unique` values
get static reuse; `shared` values get a runtime RC=1 check.

### Relevant IR additions

```zig
pub const Reset = struct {
    dest: LocalId,   // reuse token
    source: LocalId, // value being deconstructed
};

pub const ReuseAlloc = struct {
    dest: LocalId,
    token: LocalId,       // from Reset; null means fresh alloc
    size: u32,
    constructor_tag: u32,
};
```

### Key references

- Reinking, Xie, de Moura, Leijen. "Perceus: Garbage Free Reference
  Counting with Reuse." PLDI 2021.
- Lorenzen, Leijen. "Reference Counting with Frame Limited Reuse." ICFP 2022.
- Ullrich, de Moura. "Counting Immutable Beans." IFL 2019.

---

## Gap 2: No Borrowed Parameter Inference

### What the plans say

The ownership model requires explicit `shared` / `unique` / `borrowed`
annotations on function parameters (arc-plan.md Phase 2). The default is
`shared`.

### What state of the art shows

Both Lean 4 and Koka **automatically infer** whether parameters should be
borrowed or owned. Lean's heuristic: a parameter should be owned if it
participates in a `reset` operation or is passed to an owned parameter;
otherwise it should be borrowed. This eliminates RC operations at call
boundaries — no need to retain before calling just to release afterward.

Swift's SE-0377 introduced `borrowing` / `consuming` conventions, defaulting
to borrowing for most parameters (consuming only for initializers/setters).

Lobster creates **ownership-specialized versions** of functions for different
callers, achieving ~95% RC elimination.

### The gap

Zap defaults everything to `shared` (ARC-managed, aliasable) unless
explicitly annotated. This means every function call on non-primitive values
will emit retain/release pairs. Users must manually annotate `borrowed` to
avoid this — but most programmers will not. The plans have no inference pass.

### Recommendation

After the ownership type checker is stable, add a borrow inference pass:

1. Walk the call graph bottom-up
2. For each parameter, check if the function body only reads it (never
   stores, returns, or passes to an owned parameter)
3. If so, mark it `borrowed` automatically
4. This is a conservative, sound optimization that runs after type checking

### Algorithm sketch

```
for each function F in reverse topological order:
    for each parameter P of F:
        if P is used in a reset/reuse operation:
            mark P as owned
        else if P is passed to a function G where G's corresponding param is owned:
            mark P as owned
        else:
            mark P as borrowed
```

### Key references

- Ullrich, de Moura. "Counting Immutable Beans." IFL 2019. §4: Borrowing.
- Lorenzen. "Optimizing Reference Counting with Borrowing." Master's thesis.
- Swift SE-0377: Parameter Ownership Modifiers.

---

## Gap 3: Escape Analysis Does Not Cover Non-Closure Values

### What the plans say

The escape analysis plan is titled "CFG/SSA-Based **Closure** Escape and
Lifetime Analysis" and is explicitly scoped to closures. The deferred items
include "full SSA/dataflow escape lattice across all storage/merge/
control-flow shapes, not just closure-centric paths."

### What state of the art shows

Go's escape analysis (improved in OOPSLA 2024 with MEA2) applies to **all
heap-allocated values**, not just closures. MEA2's field-sensitive escape
analysis reduces heap allocation sites by 7.9% on average (up to 25.7%).
The JVM's partial escape analysis enables scalar replacement of non-escaping
aggregates. Swift's SIL applies escape analysis to all reference types.

### The gap

Zap allocates structs, tuples, lists, and maps on the heap via ARC. The
escape analysis plan only reasons about closure environments. A struct
created inside a function and never returned could be stack-allocated or
scalar-replaced, but the current plan has no mechanism for this.

### Recommendation

Generalize the `ValueLifetime` lattice in `escape_analysis.zig` to track all
heap-allocated values, not just closure environments. The `AllocationStrategy`
enum should apply to any allocation site:

- `stack` — value does not escape, allocate on stack
- `scalar_replace` — value does not escape and fields are accessed
  individually; decompose into registers/locals
- `heap` — value escapes, use ARC

### Extended analysis output

```zig
pub const AllocSiteSummary = struct {
    site_id: AllocSiteId,
    escape: ValueEscape,
    strategy: AllocationStrategy,
    type_id: TypeId,
};

pub const ValueEscape = enum {
    no_escape,        // never leaves function
    arg_escape,       // passed as argument but callee proven safe
    return_escape,    // returned from function
    store_escape,     // stored in heap-reachable location
    unknown_escape,   // conservative fallback
};

pub const AllocationStrategy = enum {
    stack,
    scalar_replace,
    heap,
};
```

### Key references

- Lu, Xu, Nie, Shen, Liu. "MEA2: a Lightweight Field-Sensitive Escape
  Analysis with Points-to Calculation for Go." OOPSLA 2024.
- Choi, Gupta, Serrano. "Escape Analysis for Java." OOPSLA 1999.
- Stadler, Würthinger, Mössenböck. "Partial Escape Analysis and Scalar
  Replacement for Java." CGO 2014.

---

## Gap 4: No COW (Copy-on-Write) Strategy for Persistent Data Structures

### What the plans say

The spec mentions "persistent data structures" (spec.md §2.8). The runtime
has `ArcRuntime` with retain/release. The plans mention nothing about COW.

### What state of the art shows

Swift's `isKnownUniquelyReferenced` check enables efficient COW: when a data
structure is uniquely owned (RC=1), mutations happen in-place; when shared,
a copy is made first. This is critical for collections.

Lean's `reset/reuse` is effectively COW for pattern-match-constructed values.

Koka's FBIP provides the same benefit through the Perceus framework: if the
reference count is 1, the `fip` annotation guarantees fully in-place
operation with zero allocation.

### The gap

Zap's functional model with immutable bindings means "updating" a data
structure always creates a new one. Without COW, operations like "add an
element to a list" or "update a field in a struct" always copy the entire
structure. The plans mention HAMT for `ZapMap` but there is no general COW
strategy for the common case.

### Recommendation

Add a COW optimization phase that works with the ownership system:

1. For `unique` values, mutation operations (field update, list append) can
   modify in-place statically (the compiler knows there is exactly one owner)
2. For `shared` values, emit a runtime uniqueness check:
   ```
   if refcount(x) == 1:
       mutate x in place
   else:
       copy x, mutate copy
   ```
3. This composes with reuse analysis (Gap 1): the uniqueness check at a
   `case` site feeds into the reuse token

### Runtime addition

```zig
pub fn isUnique(ptr: anytype) bool {
    const header = ArcHeader.fromPtr(ptr);
    return header.ref_count == 1;
}
```

### Key references

- Swift COW: `isKnownUniquelyReferenced` → `Builtin.isUnique` → `IsUniqueInst`.
- Ullrich, de Moura. "Counting Immutable Beans." IFL 2019. §3: Reset/Reuse.

---

## Gap 5: Closure Environment Representation Underspecified for ZIR

### What the plans say

The closures plan (Phase 6) says to "emit a struct type per closure
environment" and "emit a callable wrapper that accepts env + params." The
escape analysis plan specifies allocation strategies (`none_direct_call`,
`stack_env`, `local_env`, `heap_env`).

### What the current implementation shows

Closures crossing the runtime boundary use `zap_runtime.DynClosure` and
calls go through `zap_runtime.invokeDynClosure`. But ZIR does not have
native closure/environment instructions — it operates at a higher semantic
level.

### The gap

The plans do not address **how** closure environments get emitted through ZIR
to Zig's Sema. ZIR is untyped and has no built-in closure support. The plan
says "emit a struct type per closure environment" but does not specify:

- How to emit a struct type definition through the C-ABI builder (no
  `zir_builder_emit_struct_type` exists)
- How to handle the function pointer + environment tuple in ZIR terms
- How stack-allocated environments interact with Zig's stack frame model
- Whether `DynClosure` can be optimized away in the ZIR path

### Recommendation

Design the ZIR-level closure representation per allocation strategy:

**`none_direct_call`** (immediate invocation, no captures escape):
- Lambda-lift: pass captures as extra parameters to the lifted function
- Emit a direct call with the extra arguments
- No environment struct needed
- This is the most important case — it covers `Enum.map(list, fn)` patterns

**`stack_env` / `local_env`** (closure does not escape function):
- Emit an anonymous struct local in ZIR (using `alloc` + field stores)
- Pass struct pointer as first arg to the lifted function body
- The struct lives on the Zig stack frame — no heap allocation
- Like Swift's `partial_apply [on_stack]`

**`heap_env`** (closure escapes):
- Emit struct via `@import("zap_runtime").ArcRuntime.allocAny`
- Store captures as struct fields
- Wrap in `DynClosure` for generic callable interface
- Retain on creation, release on last use

**C-ABI builder needs:**
- `zir_builder_emit_struct_type(handle, field_types, field_count) -> TypeRef`
  for defining per-closure environment types
- Or: use `struct_init_anon` (already handled at zir_builder.zig line 803)
  with anonymous struct types, avoiding the need for named type definitions

### Key references

- Swift SIL: `partial_apply`, `partial_apply [on_stack]`, `thin_to_thick_function`.
- Swift `ClosureLifetimeFixup.cpp`: converts escaping closures to
  `partial_apply [stack]` with borrowed arguments when safe.

---

## Gap 6: No Interprocedural Ownership Summary System

### What the plans say

The escape analysis plan mentions "Interprocedural closure summaries" as
Phase 5 and "Whole-program/global optimization" as Phase 6, both deferred.

### What state of the art shows

Swift maintains per-function **effect summaries** in SIL that encode whether
a function retains/stores/returns its arguments. Rust's Polonius
reformulated borrow checking as a type system enabling modular reasoning.
Koka's Perceus operates per-function with interprocedural borrow annotations.

### The gap

Without interprocedural summaries, every function call is a black box. The
compiler must conservatively assume any function might retain, store, or
return its arguments. This means:

- `borrowed` parameters cannot be passed to any function unless the callee
  is proven safe
- Closure values passed as arguments must always be treated as escaping
- RC operations cannot be eliminated at call boundaries

The plans defer this entirely, but it blocks the effectiveness of Phases 1–4
of the escape analysis plan. A function like `Enum.map(list, fn)` cannot
accept a borrowed closure without interprocedural information.

### Recommendation

Implement lightweight function summaries earlier (during escape analysis
Phase 2 or 3, not Phase 5):

```zig
pub const ParamSummary = struct {
    stores: bool,          // parameter stored in heap-reachable location
    returns: bool,         // parameter returned from function
    passes_unknown: bool,  // parameter passed to a callee with no summary
    used_in_reset: bool,   // parameter used in reset/reuse (needs ownership)
};

pub const FunctionSummary = struct {
    param_summaries: []const ParamSummary,
    may_diverge: bool,
};
```

Propagate summaries bottom-up through the call graph. For recursive
functions, use a fixpoint iteration starting from the conservative
assumption (all true) and refining.

### Key references

- Swift SIL: function effect summaries, `@_effects` attribute.
- Whaley, Rinard. "Compositional Pointer and Escape Analysis for Java
  Programs." OOPSLA 1999.

---

## Gap 7: No Cycle Detection Strategy for ARC

### What the plans say

The ARC plan says "keep runtime ARC as the shared-value fallback" and the
runtime uses standard reference counting. No mention of cycles.

### What state of the art shows

Reference counting cannot reclaim reference cycles.

- **Swift**: uses `weak` and `unowned` references that do not increment the
  strong count, plus Instruments leak detection
- **Koka/Perceus**: formally garbage-free only for cycle-free programs; the
  team explicitly punts on cycles
- **Lobster**: ownership model prevents most cycles statically (non-escaping
  function values, single-owner rule)
- **Python**: backup cycle-detecting GC alongside RC

### The gap

Zap's functional model with immutable bindings makes accidental cycles
unlikely but not impossible. Mutual recursion through closures or circular
data structures in maps/lists could create cycles. The plans do not address
this.

### Recommendation

Add an explicit position on cycles. Three options:

**Option A — Argue structural prevention (recommended for now):**
Document that Zap's ownership model prevents cycles by construction:
- `unique` values cannot be aliased, so no cycle through unique paths
- `shared` values in a purely functional language with immutable bindings
  cannot form cycles because a value cannot reference a binding created
  after itself
- Closures capturing `shared` values create a DAG, not a cycle, because
  capture happens at closure creation time

This argument holds for Zap's current feature set but should be revisited
if mutable bindings or mutable references are ever added.

**Option B — Add `weak` reference support:**
As a future phase, add `weak` ownership mode for references that should not
prevent deallocation. This is Swift's approach.

**Option C — Debug-mode cycle detector:**
Add a development-only backup tracing GC or leak detector that runs at
program exit and reports unreachable reference cycles.

---

## Gap 8: Build System Has No Incremental Compilation Model

### What the plans say

The implementation epic (Phase 6) describes artifact caching based on hashing
all source files + manifest. But this is all-or-nothing: if any source file
changes, the entire project recompiles.

### What state of the art shows

Zig itself has a sophisticated incremental compilation model (per-function
Sema caching). Rust uses a query-based incremental system. Go recompiles at
the package level.

### The gap

For a project with many `.zap` files, recompiling everything on every change
will be slow. The plans describe file-level dependency graphs (Phase 5) but
do not use them for incremental compilation — only for concatenation ordering.

### Recommendation

Acceptable for v1. Explicitly call out as a known limitation with a path
forward:

- Phase 5's `DependencyGraph` already tracks which modules depend on which
- Future: cache per-module ZIR and only re-lower modules whose transitive
  dependencies changed
- The ZIR injection model enables this: inject unchanged modules' cached ZIR
  alongside fresh ZIR for changed modules

---

## Gap 9: No Error Recovery in the Ownership Checker

### What the plans say

The arc-plan specifies diagnostics like "value moved here", "unique value
used after move", etc. The closures plan specifies borrowed-capture escape
errors.

### What state of the art shows

Rust's borrow checker continues checking after finding an error, reporting
multiple ownership violations in a single compilation pass. Swift's OSSA
verifier similarly reports all violations. This is critical for developer
experience — if the checker stops at the first error, fixing ownership issues
becomes a painful one-at-a-time iteration.

### The gap

The current error model is "errors collected, not thrown" with
`{message, span}` structs. But the ownership checker's design does not
explicitly address whether it continues after finding a moved value. The
`BindingOwnershipState` tracking could easily stop being accurate after the
first error if not designed for recovery.

### Recommendation

Design the ownership checker for error recovery from the start:

```zig
const BindingOwnershipState = enum {
    available,
    moved,
    borrowed,
    error_recovery,  // <-- new: binding had an error, continue checking
};
```

After detecting a move violation:
1. Mark the binding as `error_recovery`
2. Treat `error_recovery` as "available" for the purpose of continued
   checking (to avoid cascading errors)
3. Continue checking the rest of the function
4. Report all violations, not just the first

---

## Gap 10: No Strategy for Generic/Parametric Types with Ownership

### What the plans say

The arc-plan adds ownership to function parameters and return types. The spec
mentions parametric types (§4.1). Neither addresses how ownership interacts
with generics.

### What state of the art shows

- **Swift**: `~Copyable` protocol constrains generic parameters
- **Rust**: lifetime parameters thread through generic types
- **Lean**: infers ownership for generic functions based on usage
- **Mojo**: non-trivial copies are compile-time errors; explicit `.copy()`

### The gap

Consider `def identity(x :: T) :: T do x end`. What is the ownership of `x`?
If `T` is `unique`, `x` should be moved. If `T` is `shared`, `x` should be
shared. The plans do not address ownership-polymorphic functions.

### Recommendation

Three options (decide post-MVP):

**Option A — Monomorphize:**
Create separate specializations for `identity<unique T>` and
`identity<shared T>`. Simple but can cause code bloat.

**Option B — Ownership-parameterize:**
Allow `def identity(x :: own T) :: own T` where `own` is an ownership
variable. More complex but avoids bloat.

**Option C — Default and annotate (recommended for now):**
Default to the most permissive ownership (`shared`) in generic contexts.
Require explicit annotation for `unique` / `borrowed` generic parameters.
This is the simplest approach and matches how most functional languages
handle polymorphism initially.

---

## Gap 11: OOM Linker Bug Blocks ZIR Backend Progress

### What the current state shows

The ZIR backend hits `OutOfMemory` during MachO linking (documented in
`deferred/memory-oom.md`). The OOM occurs during `libSystem.tbd` parsing.
Extensive investigation (page_allocator fix, thread pool capping, allocator
changes) has not resolved it. System has plenty of RAM — the OOM is spurious.

### The gap

This is not a plan gap but an **execution blocker**. The entire ZIR backend
pipeline — including all ownership-typed ARC codegen, closure environment
emission, and escape-analysis-driven optimization — cannot be end-to-end
tested until this is resolved.

### Recommendation

Most promising uninvestigated paths:

1. **`link_libc = false`** — determine if TBD parsing is the specific culprit
2. **Minimal Zig program** through the same Compilation API (not ZIR
   injection) to isolate whether the issue is injection-specific
3. **Linux/ELF target** to rule out macOS-specific MachO linker issues
4. **LLD** instead of Zig's self-hosted MachO linker
5. **Log inside `MachO.flush()`** in the fork to pinpoint the failing
   allocation

---

## Gap 12: No Formalization of the Ownership Lattice Join Rules

### What the plans say

The escape analysis plan specifies join rules like
`no_escape + returned → returned` and `borrow_local + escaping → illegal`.
The arc-plan describes three ownership modes. Neither formalizes the full
lattice algebra.

### What state of the art shows

- **Swift OSSA**: formal ownership algebra with precise rules for forwarding,
  merging, and converting between ownership kinds
- **Perceus**: formalized in a linear resource calculus where every value must
  be used exactly once
- **Polonius**: formalized as a set of Datalog rules

### The gap

Without a formal lattice, edge cases in the ownership checker and escape
analysis will produce inconsistent results. For example:

- What happens when a `unique` value is assigned in one branch and a `shared`
  value in the other? What is the ownership of the phi?
- Can a `borrowed` value be promoted to `shared` by retaining it?
- What is the join of `unique` and `borrowed` at a merge point?

### Recommendation

Define the ownership lattice formally:

```
Ownership join rules at control-flow merge points:

shared  ⊔ shared   = shared
unique  ⊔ unique   = error (two live unique aliases)
borrowed ⊔ borrowed = borrowed
unique  ⊔ shared   = shared (implicit unique→shared conversion)
borrowed ⊔ shared   = error (cannot promote borrowed to owned)
borrowed ⊔ unique   = error (cannot promote borrowed to owned)

Subtyping rules:

unique  <: shared   (unique can be used where shared is expected)
borrowed <: shared   (borrowed can be read where shared is read)
shared  ≮: unique   (shared cannot become unique)
borrowed ≮: unique   (borrowed cannot become unique)
unique  ≮: borrowed (unique is not a borrow — it is ownership)
shared  ≮: borrowed (shared is not a borrow — it carries RC weight)

Conversion rules:

unique  → shared   allowed (explicit share, increments RC)
unique  → borrowed allowed (temporary borrow, source stays valid)
shared  → borrowed allowed (temporary borrow of shared value)
borrowed → shared   forbidden (would require retain on non-owning ref)
borrowed → unique   forbidden (borrowed does not own)
shared  → unique   forbidden (shared may have aliases)
```

---

## Priority Ranking

| Priority | Gap | Impact | Effort |
|----------|-----|--------|--------|
| **Critical** | #11 OOM linker bug | Blocks all ZIR testing | Unknown |
| **High** | #1 Perceus reuse | Largest perf win for functional code | Medium |
| **High** | #2 Borrow inference | Eliminates most RC at call sites | Low–Medium |
| **High** | #12 Lattice formalization | Prevents correctness bugs | Low |
| **High** | #9 Error recovery | Developer experience | Low |
| **Medium** | #5 ZIR closure repr | Blocks closure codegen | Medium |
| **Medium** | #6 Interprocedural summaries | Enables escape analysis | Medium |
| **Medium** | #7 Cycle detection | Correctness for edge cases | Low (design) |
| **Medium** | #3 General escape analysis | Stack alloc for non-closures | Medium–High |
| **Low** | #4 COW strategy | Perf for collection updates | Medium |
| **Low** | #8 Incremental compilation | Build speed at scale | High (defer) |
| **Low** | #10 Generics + ownership | Needed for generic libraries | Medium (defer) |

---

## Cross-Cutting Theme: The Perceus/Lean Pipeline as a Template

Multiple independent language efforts have converged on the same insight:
static ownership analysis can eliminate the vast majority of reference
counting operations. Lobster eliminates ~95%. Perceus/Koka achieves
"garbage-free" (zero unnecessary operations). Lean's reset/reuse with borrow
inference approaches imperative performance.

For Zap, the most impactful adoption path is:

1. Start from explicit control flow (IR with blocks and phi — already exists)
2. Insert precise `retain` / `release` based on liveness analysis (Gap 2)
3. Apply reuse analysis to pair pattern matches with same-size constructors (Gap 1)
4. Use drop specialization to avoid generic destructor dispatch (Gap 1)
5. Infer borrowed vs owned parameters to eliminate RC at call boundaries (Gap 2)
6. Use reset/reuse tokens for in-place mutation when RC=1 (Gap 1 + Gap 4)

This is a well-understood path with published algorithms, formal proofs, and
production implementations in Koka and Lean.
