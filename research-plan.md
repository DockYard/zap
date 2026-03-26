# Research Plan: Region-Based Lifetime Solver, SSA/Dataflow Escape Lattice, and Whole-Program Closure Optimization

## Executive Summary

This plan designs a production-quality, research-grade analysis pipeline for Zap
that unifies three capabilities into one coherent system:

1. **Full region-based / whole-function lifetime solver** — determines the
   minimal region (stack, caller, heap) for every value, using constraint-based
   inference over SSA form with non-lexical lifetimes
2. **Full SSA/dataflow escape lattice across all value shapes** — tracks escape
   state for every allocation site (closures, structs, tuples, lists, maps,
   opaque types) through control flow, phi merges, loops, and stores
3. **Full whole-program/global closure optimization** — lambda set
   specialization, defunctionalization, interprocedural escape summaries, and
   environment representation optimization across the entire program

The design draws on Tofte-Talpin region inference, Aiken's non-lexical region
placement, Rust's NLL/Polonius origin-based borrow checking, Swift's Ownership
SSA, Graal's partial escape analysis, Koka's Perceus reference counting with
reuse, Lobster's annotation-free ownership inference, and Go's interprocedural
escape analysis with parameter tags.

---

## 1. Current State Assessment

### What exists

The Zap compiler has important pieces of the prerequisite infrastructure, but
not yet the fully unified optimization substrate assumed by the rest of this
plan:

- **SSA-flavored IR** with blocks, phi nodes, closure instructions, and
  ownership/ARC-oriented operations
- **Ownership type system** with `shared`/`unique`/`borrowed` modes tracked
  through AST → TypeChecker → HIR → IR
- **ARC runtime** with `ArcHeader`, `Arc(T)`, retain/release primitives
- **Closure pipeline** with `make_closure`/`capture_get` in IR, `DynClosure` at
  runtime, free-variable analysis, capture ownership rules
- **Escape analysis subsystem** (`src/escape_analysis.zig`) with closure-centric
  lattice, block-edge reasoning, phi-based merge, interprocedural summaries,
  iterative fixpoint
- **Analysis-aware legacy Zig codegen** consuming closure summaries for closure
  environment choices

### Additional prerequisite gap

Before the research-heavy phases can land cleanly, Zap needs a **backend and IR
unification phase**:

- The active native path goes through `src/zir_backend.zig` and
  `src/zir_builder.zig`
- The richer closure-aware strategy selection currently lives in
  `src/codegen.zig`
- The plan below assumes one authoritative backend path and one authoritative
  ownership/closure/CFG model, but the current implementation still has a split
  between analysis and native lowering

### What is missing

Three major analysis gaps remain (as documented in `escape-analysis-plan.md`):

1. **No full region-based or whole-function borrow solver across all value
   kinds** — lifetime reasoning is use-site-driven and closure-centric, not
   constraint-based across the full function
2. **No full SSA/dataflow escape lattice across all storage/merge/control-flow
   shapes** — only closure environments are tracked; structs, tuples, lists,
   maps, and opaque allocations are not
3. **No full whole-program/global closure optimization pass** — closure
   optimization is local/syntactic, interprocedural summaries are
   closure-parameter-only

Additionally, from `gap-plan.md` and current implementation review:

4. No Perceus-style reuse/drop specialization
5. No borrowed parameter inference
6. No COW strategy for persistent data structures
7. No formalized ownership lattice join rules
8. No field-sensitive escape tracking
9. No ownership/consumption verifier analogous to Swift OSSA's verifier
10. No unified native backend path that consumes the full planned analysis

---

## 2. Theoretical Foundations

### 2.1 Region Inference (Tofte-Talpin)

The foundational algorithm extends Hindley-Milner type inference with region
variables. Every value-producing expression is annotated with a region variable
indicating where the value is stored. The algorithm generates typing constraints
augmented with region and effect variables, solves them via unification, and
places `letregion` constructs to make allocation/deallocation explicit.

**Key properties:**
- Fully automatic (no annotations)
- Sound (no dangling pointers)
- Complexity comparable to ML type inference
- Region polymorphism allows functions parameterized over region variables

**Limitation:** Pure Tofte-Talpin produces lexical regions (LIFO stack
discipline), causing region blowup where dead data persists because the
enclosing scope has not ended.

### 2.2 Non-Lexical Region Placement (Aiken, Fähndrich, Levien)

Relaxes the lexical constraint:

- **Late allocation:** regions allocated as late as possible
- **Early deallocation:** regions deallocated as early as possible
- Constraint-based: generates inclusion constraints on region lifetimes, solves
  via a graph-based algorithm in polynomial time

This is the key extension that makes region inference practical for imperative
languages. Combined with Rust's NLL insight (lifetimes as sets of CFG points),
it yields non-lexical lifetime analysis.

### 2.3 MLKit Refinement Pipeline

MLKit demonstrates the practical refinement stages needed:

1. **Region inference** — assign region variables to allocations
2. **Multiplicity inference** — determine if a region contains 0, 1, or ∞
   values (finite regions → stack words, infinite → heap pages)
3. **Storage mode analysis** — `attop` (preserve) vs `atbot` (reset/reuse) to
   prevent region blowup
4. **Region representation inference** — map abstract regions to concrete
   representations

### 2.4 Rust NLL / Polonius

**NLL:** Lifetimes are sets of CFG points. Constraint propagation grows lifetime
sets via DFS until all outlives constraints are satisfied. SCC optimization
merges equal lifetimes.

**Polonius:** Instead of tracking where a reference is *used* (lifetime), tracks
where it *came from* (origin/loan). Relations are formulated as Datalog rules.
An error occurs when a loan is invalidated while still live. More precise than
NLL for conditional borrows and lending iterators.

### 2.5 Swift Ownership SSA (OSSA)

Augments SSA with four ownership kinds: `owned`, `guaranteed`, `unowned`,
`none`. Every value has exactly one lifetime-ending use on each reachable path.
The OSSA verifier checks ownership constraints mechanically. RC Identity
analysis treats chains of instructions as equivalent for refcount purposes,
enabling aggressive retain/release elimination.

### 2.6 Graal Partial Escape Analysis

Control-flow-sensitive analysis that tracks "virtual objects" (unallocated
compiler-internal representations). Objects are materialized only on branches
where they actually escape. At merge points, virtual object states are
reconciled. Up to 58.5% reduction in allocated memory, 33% performance
improvement. This is the state of the art for escape analysis.

### 2.7 Koka Perceus / Lean Reuse

Precise reference counting that inserts `dup`/`drop` only where ownership
changes. **Reuse analysis** pairs pattern-match deconstruction with same-size
construction to enable in-place mutation when RC=1. **Drop specialization**
generates per-constructor drop code. Achieves "garbage-free" execution and the
FBIP (Functional But In-Place) paradigm.

### 2.8 Go Interprocedural Escape Analysis

Graph-based approach with derefs-weighted edges. Field-insensitive,
flow-insensitive, but interprocedural via parameter tags encoding how each
parameter escapes. Recent MEA2 work (OOPSLA 2024) adds field sensitivity and
points-to calculation, reducing heap allocations by up to 25.7%.

### 2.9 Lobster Ownership Inference

Infers ownership without annotations. The compiler picks a single owner for
each allocation; all other uses are borrows. Functions are ownership-specialized
per call site. Achieves ~95% RC elimination at compile time.

---

## 3. Design: Unified Escape/Lifetime/Region Lattice

### 3.1 Product Lattice

The analysis tracks a product of three lattice dimensions for every SSA value:

```
ValueState = EscapeState × RegionMembership × OwnershipState
```

Each dimension is a finite-height lattice with well-defined join/meet operations,
guaranteeing convergence of fixpoint iteration.

### 3.2 Escape Lattice

Generalizes the current closure-only lattice to all value shapes. Uses a
six-element lattice inspired by Choi et al. and Graal PEA:

```zig
pub const EscapeState = enum(u4) {
    /// Value is never allocated (dead code, scalar-replaced, or eliminated).
    bottom = 0,

    /// Value never leaves the instruction that creates it.
    /// Candidate for scalar replacement (Graal-style).
    no_escape = 1,

    /// Value is used only within the creating block.
    /// Candidate for stack allocation at block scope.
    block_local = 2,

    /// Value is used across blocks but does not escape the function.
    /// Candidate for stack allocation at function scope.
    function_local = 3,

    /// Value is passed as an argument to a callee but the callee's summary
    /// proves it does not retain/store/return it.
    /// Candidate for caller-region or stack allocation with callee cooperation.
    arg_escape_safe = 4,

    /// Value is passed to a callee with no safe summary, or stored in
    /// a heap-reachable location, or returned from the function.
    /// Must be heap-allocated with ARC.
    global_escape = 5,
};
```

**Join rules (least upper bound):**

```
bottom ⊔ x            = x
no_escape ⊔ block_local     = block_local
no_escape ⊔ function_local  = function_local
block_local ⊔ function_local = function_local
anything ⊔ global_escape    = global_escape
arg_escape_safe ⊔ function_local = function_local
arg_escape_safe ⊔ global_escape  = global_escape
```

**Lattice height:** 5 (bottom to global_escape). Guarantees convergence in at
most 5·|V| iterations where |V| is the number of SSA values. In practice,
convergence happens in 1–2 passes.

### 3.3 Region Membership

Assigns each value to a region. Regions form a tree ordered by containment
(inner regions have shorter lifetimes):

```zig
pub const RegionId = enum(u32) {
    /// The global/heap region. Values here live until ARC drops them.
    heap = 0,

    /// Function-scoped region. Deallocated at function return.
    /// Represented as stack frame space.
    function_frame = 1,

    /// Block-scoped regions. Identified by IR block index.
    /// Deallocated at block exit.
    _,
};
```

Each block in the IR introduces a potential region. The region membership lattice
is the powerset of CFG points (following Rust NLL), but simplified:

- A value's region is the **minimal enclosing scope** that contains all its uses
- Computed by finding the lowest common ancestor in the dominator tree of the
  value's definition and all its uses

**Outlives constraints:**

For every assignment `dst = src`, generate: `region(src) outlives region(dst)`.
For every return `return val`, generate: `region(val) outlives caller_region`.
For every phi `x = phi(a, b)`, generate: `region(x) = join(region(a), region(b))`.

### 3.4 Ownership State at Merge Points

Formalize the ownership lattice join rules (addressing Gap 12 from
`gap-plan.md`):

```
Ownership merge at phi nodes:

shared  ⊔ shared   = shared
unique  ⊔ unique   = unique   (if same binding; error if different bindings)
borrowed ⊔ borrowed = borrowed
unique  ⊔ shared   = shared   (implicit unique→shared conversion on merge)
borrowed ⊔ shared   = error    (cannot promote borrowed to owned at merge)
borrowed ⊔ unique   = error    (cannot promote borrowed to owned at merge)

Conversion rules:

unique  → shared    allowed (share operation, inserts retain)
unique  → borrowed  allowed (temporary borrow, source stays valid)
shared  → borrowed  allowed (temporary borrow of shared value)
borrowed → shared    forbidden (would require retain on non-owning ref)
borrowed → unique    forbidden (borrowed does not own)
shared  → unique    forbidden (shared may have aliases)
```

### 3.5 Field-Sensitive Tracking

Extend escape tracking to individual fields (addressing Gap 3 from
`gap-plan.md`). For composite types, track per-field escape state:

```zig
pub const FieldEscapeMap = struct {
    /// Per-field escape states. Index by field position.
    field_states: []EscapeState,

    /// Aggregate escape state (join of all field states).
    aggregate_state: EscapeState,
};
```

**Summarization rules for composite types:**
- Struct: each field tracked independently
- Tuple: each element tracked independently
- List/Map: all elements summarized to a single state (array element
  abstraction)
- Tagged union: each variant's payload tracked independently; the union's state
  is the join across variants at merge points
- Closure environment: each capture tracked independently

**Field dereference tracking (Go-style derefs):**
- `x.f = y` → field f of x's escape state joins with y's escape state
- `y = x.f` → y's escape state joins with field f of x's escape state
- `x.f = &y` → y's region must outlive x's region

### 3.6 Partial Escape Analysis (Graal-Inspired)

The analysis maintains **virtual object state** per control-flow branch:

```zig
pub const VirtualObject = struct {
    /// Allocation site that produced this object.
    alloc_site: AllocSiteId,

    /// Per-field values (SSA value IDs tracking current field contents).
    field_values: []const ir.LocalId,

    /// Whether this object has been materialized (actually allocated) on
    /// this branch.
    materialized: bool,
};
```

**Rules:**
1. At allocation: create a virtual object (not yet allocated)
2. At field store: update virtual object's field value
3. At field load: redirect to virtual object's tracked field value (scalar
   replacement)
4. At escape point: **materialize** — emit actual allocation + field stores
5. At merge: if both branches have same object virtual → merged virtual;
   if one has virtual and other has materialized → materialize on virtual side

**Effect:** Objects that escape on cold paths but not hot paths are only
allocated on the cold path. On the hot path, fields live in SSA registers
(scalar replacement).

---

## 4. Design: Region-Based Whole-Function Lifetime Solver

### 4.1 Architecture

The lifetime solver operates on the SSA IR after escape analysis and produces
region assignments for every allocation site and binding.

```
Input:  IR functions (SSA form with blocks, phis, explicit def-use)
        + EscapeState per SSA value
        + OwnershipState per SSA value
        + Call graph with interprocedural summaries

Output: RegionAssignment per allocation site
        AllocationStrategy per allocation site
        ARC operation placement (retain/release/reset/reuse sites)
        Borrow legality verdicts
```

### 4.2 Constraint Generation

Walk each IR function and generate constraints:

**Allocation constraints:**
```
For each allocation site S producing value V:
    region(V) = fresh_region(S)
    escape(V) = initial_escape(S)  // starts at no_escape
```

**Assignment constraints:**
```
For each instruction `dst = src`:
    region(src) ⊇ region(dst)    // src must outlive dst
    escape(dst) ⊔= escape(src)  // escape propagates forward
```

**Phi constraints:**
```
For each phi `x = phi(a, b, ...)`:
    region(x) = ⊔{region(a), region(b), ...}
    escape(x) = ⊔{escape(a), escape(b), ...}
    ownership(x) = ownership_join(ownership(a), ownership(b), ...)
```

**Call constraints (using interprocedural summaries):**
```
For each call `result = f(arg1, arg2, ...)`:
    For each arg_i:
        if summary(f).param[i].stores:
            escape(arg_i) ⊔= global_escape
        if summary(f).param[i].returns:
            escape(arg_i) ⊔= global_escape
        if summary(f).param[i].safe:
            escape(arg_i) ⊔= arg_escape_safe
        else:
            escape(arg_i) ⊔= global_escape  // conservative
    escape(result) = escape_from_summary(f, return_summary)
```

**Return constraints:**
```
For each `return val`:
    escape(val) ⊔= global_escape
    region(val) must outlive caller_region
```

**Store constraints (field/container stores):**
```
For each `container.field = val`:
    if escape(container) >= function_local:
        escape(val) ⊔= escape(container)
    region(val) must outlive region(container)
```

**Borrow constraints:**
```
For each borrowed reference `ref` to value `val`:
    region(ref) ⊆ region(val)  // ref must not outlive val
    val must not be moved while ref is live
```

### 4.3 Constraint Solving

**Algorithm:** Worklist-based fixpoint iteration over the SSA graph.

```
procedure SolveConstraints(function):
    // Initialize
    for each SSA value v:
        escape[v] = bottom
        region[v] = block_region(def_block(v))

    // Seed allocations
    for each allocation site s producing value v:
        escape[v] = no_escape
        add v to worklist

    // Seed parameters
    for each parameter p:
        escape[p] = from_caller_summary_or(function_local)
        add p to worklist

    // Seed returns
    for each return instruction returning v:
        escape[v] = global_escape
        add v to worklist

    // Iterate to fixpoint
    while worklist is not empty:
        v = worklist.pop()

        for each use u of v:
            new_escape = transfer(u, escape[v])
            if new_escape != escape[target(u)]:
                escape[target(u)] = escape[target(u)] ⊔ new_escape
                add target(u) to worklist

        for each phi containing v:
            new_escape = ⊔{escape[src] for src in phi.sources}
            if new_escape != escape[phi.dest]:
                escape[phi.dest] = new_escape
                add phi.dest to worklist

    // Compute regions from escape states
    for each SSA value v:
        region[v] = escape_to_region(escape[v], def_block(v))

    return (escape, region)
```

**Worklist ordering:** Reverse post-order of the dominator tree for forward
propagation. This processes definitions before uses, minimizing re-visits.

**Convergence:** The escape lattice has height 5. Each value's escape state can
increase at most 5 times. Total work is O(5·|E|) where |E| is the number of
SSA edges. In practice, convergence in 1–2 passes.

### 4.4 Region-to-Allocation Strategy Mapping

After solving, map escape states to concrete allocation decisions:

```zig
pub const AllocationStrategy = enum {
    /// Value never exists at runtime (eliminated or scalar-replaced).
    eliminated,

    /// Value lives in SSA registers (scalar replacement of aggregate).
    /// Fields decomposed into individual locals.
    scalar_replaced,

    /// Value lives on the stack in the creating block's frame.
    stack_block,

    /// Value lives on the stack in the function's frame.
    stack_function,

    /// Value lives in a caller-provided region (region-polymorphic).
    caller_region,

    /// Value lives on the heap with ARC management.
    heap_arc,
};

fn escapeToStrategy(escape: EscapeState, multiplicity: Multiplicity) AllocationStrategy {
    return switch (escape) {
        .bottom => .eliminated,
        .no_escape => if (multiplicity == .one) .scalar_replaced else .stack_block,
        .block_local => .stack_block,
        .function_local => .stack_function,
        .arg_escape_safe => .caller_region,
        .global_escape => .heap_arc,
    };
}
```

### 4.5 Multiplicity Inference (MLKit-Inspired)

Determine how many values each region contains:

```zig
pub const Multiplicity = enum {
    /// Region is never written to (dead allocation, can be eliminated).
    zero,

    /// Exactly one value stored (finite region → single stack slot).
    one,

    /// Multiple values stored (infinite region → needs dynamic allocation).
    many,
};
```

**Algorithm:** Count allocation sites per region. If a region has exactly one
allocation site and that site is not inside a loop, multiplicity is `one`.
Otherwise `many`. Zero if dead-code elimination removed all allocations.

**Effect:** Single-allocation regions become simple stack slots (no region
descriptor, no page list). This is the MLKit optimization that maps finite
regions to stack words.

### 4.6 Storage Mode Analysis (MLKit-Inspired)

For regions with multiplicity `many`, determine if the region can be reset:

- **`attop`:** Preserve existing values, add new one. Default.
- **`atbot`:** Reset the region (free all contents), then allocate. Applicable
  when all prior allocations in the region are dead at the new allocation point.

**Algorithm:** At each allocation site in a `many` region, check liveness of
all other values in the same region. If none are live, the allocation can use
`atbot` mode (reset + allocate). This is the primary mechanism for preventing
region blowup.

### 4.7 Borrow Legality

Using the solved region assignments, determine borrow legality:

```
A borrowed reference `ref` to value `val` is legal iff:
    1. region(ref) ⊆ region(val)  — ref does not outlive val
    2. val is not moved while ref is live
    3. ref does not cross a merge point where (2) cannot be proven

Specifically:
    - Borrowed capture in immediate-call closure: LEGAL
      (ref lifetime = call instruction, val lifetime ≥ enclosing block)
    - Borrowed capture in returned closure: ILLEGAL
      (ref would outlive val's function scope)
    - Borrowed capture in closure passed to known-safe callee: LEGAL
      (interprocedural summary proves callee does not retain)
    - Borrowed capture crossing loop boundary: ILLEGAL unless val is
      loop-invariant (defined before loop, not modified inside)
    - Borrowed value stored in escaping container: ILLEGAL
      (container's region outlives borrow scope)
```

---

## 5. Design: Whole-Program Closure Optimization

### 5.1 Lambda Set Specialization (Roc-Inspired Defunctionalization)

For a monomorphizing compiler like Zap, lambda set specialization is the most
aggressive closure optimization. It eliminates all indirect calls and heap
allocation for closure environments.

**Concept:** Track the set of possible closures at each call site in the type
system:

```
Function type: (i64 -> i64) -[[ add_x, mul_x ]]-
```

The lambda set `[[ add_x, mul_x ]]` enumerates every closure that could flow to
this call site. At codegen, the call becomes a switch on a tag:

```zig
switch (closure.tag) {
    .add_x => add_x_body(closure.env.add_x_captures, arg),
    .mul_x => mul_x_body(closure.env.mul_x_captures, arg),
}
```

**Benefits:**
- No function pointer dereference (direct calls only)
- No generic closure environment (per-closure-variant captures)
- Stack allocation for non-recursive lambda sets
- Enables further inlining and scalar replacement

**Algorithm:**
1. Build a call graph including closure flow
2. At each function-typed binding, compute the set of closures that may
   flow to it (0-CFA or 1-CFA control flow analysis)
3. Replace function types with lambda-set-annotated types
4. At each call site, emit a switch over the lambda set
5. For singleton lambda sets (only one possible closure), emit a direct call

**Complexity:** 0-CFA is cubic in program size. For Zap's target programs
(not megascale), this is acceptable. 1-CFA adds a constant factor per call
site depth.

### 5.2 Closure Environment Optimization Pipeline

For closures that cannot be defunctionalized (e.g., stored in heterogeneous
collections), optimize the environment representation:

```
Tier 0: Lambda Lifting (non-capturing)
    No closure needed. Nested def becomes a top-level function.
    Captures passed as extra parameters at call sites.

Tier 1: Immediate Invocation (call_local)
    No environment object. Captures forwarded directly as arguments
    to a lifted function. No heap allocation, no DynClosure.

Tier 2: Block-Local Closure (block_local)
    Flat environment struct on the stack. Captures stored as fields.
    Function pointer + stack env pointer passed to callees.
    Deallocated at block exit.

Tier 3: Function-Local Closure (function_local)
    Flat environment struct on the function's stack frame.
    Same as Tier 2 but lifetime extends to function return.

Tier 4: Escaping Closure (global_escape)
    Heap-allocated flat environment with ARC.
    Wrapped in DynClosure for generic callable interface.
    Retain on creation, release on last use.
```

**Flat vs linked environments:** Always use flat closures. Flat closures are:
- Space-safe (proven not to change asymptotic space complexity; Perconti &
  Ahmed, ICFP 2019)
- Single field lookup (no pointer chasing)
- Compatible with region analysis
- Used by MLKit and Roc

### 5.3 Interprocedural Closure Flow Analysis

Build the call graph including closure flow to enable whole-program optimization:

**Phase 1: Local call graph construction**
- Direct calls: add edge from caller to callee
- Closure calls: add edge from caller to all closures in the lambda set

**Phase 2: Closure flow propagation**
- For each function parameter of function type, track which closures may be
  passed (the lambda set)
- Propagate lambda sets through assignments, phis, returns
- At call sites, instantiate callee's parameter lambda sets with actual
  arguments

**Phase 3: Specialization decisions**
- Singleton lambda sets → direct call (no dispatch)
- Small lambda sets (2–4 closures) → switch dispatch
- Large lambda sets → DynClosure dispatch (fallback)
- Recursive lambda sets → DynClosure (cannot stack-allocate)

### 5.4 Contification (Kennedy)

When a closure is only ever called (never stored, passed, or returned), it can
be converted to a continuation — a direct jump rather than a call:

```
Before: let f = make_closure(body, captures); f(x)
After:  jump body_block(captures, x)
```

**Algorithm (Fluet and Weeks):** A function is contifiable if all its call sites
are dominated by a single return continuation. Build the dominator tree of the
call graph; contifiable functions are those whose callers all share a single
continuation point.

**Effect:** Eliminates closure allocation, function call overhead, and enables
further optimization (the continuation's code is now inline with the caller).

---

## 6. Design: Interprocedural Analysis System

### 6.1 Function Summaries

Each function produces a summary consumed by callers:

```zig
pub const FunctionSummary = struct {
    /// Per-parameter escape summary.
    param_summaries: []const ParamSummary,

    /// How the return value relates to parameters.
    return_summary: ReturnSummary,

    /// Whether the function may diverge (loop forever, panic).
    may_diverge: bool,

    /// Lambda sets for function-typed parameters (which closures may be
    /// passed to each parameter).
    param_lambda_sets: []const LambdaSet,
};

pub const ParamSummary = struct {
    /// Parameter escapes to the heap (stored in global/static, stored in
    /// escaping container).
    escapes_to_heap: bool,

    /// Parameter is returned (directly or transitively through a container).
    returned: bool,

    /// Parameter is passed to another function without a safe summary.
    passed_to_unknown: bool,

    /// Parameter is used in a reset/reuse operation (needs ownership).
    used_in_reset: bool,

    /// Parameter is only read (never stored, returned, or passed unsafely).
    /// If true, the parameter can be borrowed.
    read_only: bool,

    /// Dereference depth at which the parameter escapes (Go-style).
    /// 0 = the value itself escapes; 1 = a value pointed to by it escapes; etc.
    escape_deref_depth: i8,
};

pub const ReturnSummary = struct {
    /// Which parameter indices flow to the return value.
    /// Empty if return is a fresh allocation or constant.
    param_sources: []const u32,

    /// Whether the return value is a fresh allocation.
    fresh_alloc: bool,
};
```

### 6.2 Summary Computation

**Algorithm:** Bottom-up over the call graph (reverse topological order).

```
procedure ComputeSummaries(call_graph):
    // Compute SCCs for recursive function groups
    sccs = tarjan_scc(call_graph)

    for each scc in reverse topological order of scc_dag:
        if scc is a single non-recursive function:
            summary[f] = analyze_function(f)
        else:
            // Recursive group: fixpoint iteration
            for each f in scc:
                summary[f] = conservative_summary(f)
            repeat:
                changed = false
                for each f in scc:
                    new_summary = analyze_function(f)
                    if new_summary != summary[f]:
                        summary[f] = new_summary
                        changed = true
            until not changed
```

**Conservative summary:** All parameters escape, may diverge, no read-only
parameters. This is the initial assumption for recursive groups before
refinement.

### 6.3 Borrowed Parameter Inference (Lean/Koka-Inspired)

After summaries are computed, infer which parameters should be borrowed:

```
procedure InferBorrowedParams(call_graph):
    for each function f in reverse topological order:
        for each parameter p of f:
            if summary[f].param[p].read_only
               and not summary[f].param[p].used_in_reset:
                mark p as borrowed (no retain/release at call site)
            else:
                mark p as owned (retain on entry, release on exit)
```

**Effect:** Eliminates retain/release pairs at call boundaries for parameters
that are only read. Lean and Lobster report this eliminates the majority of
RC operations.

### 6.4 Whole-Program Lambda Set Computation

```
procedure ComputeLambdaSets(program):
    // Phase 1: Collect all closure creation sites
    for each function f:
        for each make_closure(dest, func_id, captures):
            lambda_defs[func_id] = captures_type(captures)

    // Phase 2: Forward propagation of lambda sets
    // (0-CFA: flow-insensitive, context-insensitive)
    worklist = all function-typed bindings
    for each binding b:
        lambda_set[b] = {} // empty set

    for each make_closure(dest, func_id, _):
        lambda_set[dest] ∪= {func_id}
        add dest to worklist

    while worklist is not empty:
        b = worklist.pop()
        for each use u of b:
            if u is assignment `dst = b`:
                if lambda_set[b] ⊄ lambda_set[dst]:
                    lambda_set[dst] ∪= lambda_set[b]
                    add dst to worklist
            if u is call `f(... b ...)` at position i:
                if lambda_set[b] ⊄ param_lambda_set[f][i]:
                    param_lambda_set[f][i] ∪= lambda_set[b]
                    add all uses of param[f][i] to worklist
            if u is return:
                caller_return_set ∪= lambda_set[b]
            if u is phi:
                phi_result_set ∪= lambda_set[b]

    // Phase 3: Specialization decisions
    for each call site calling through function-typed value b:
        if |lambda_set[b]| == 0: unreachable (dead code)
        if |lambda_set[b]| == 1: direct_call(the_single_closure)
        if |lambda_set[b]| <= SWITCH_THRESHOLD: switch_dispatch(lambda_set[b])
        else: dyn_closure_dispatch(b)
```

`SWITCH_THRESHOLD` should be tunable; 4–8 is typical based on CPU branch
prediction characteristics.

---

## 7. Design: Perceus Integration (Reuse Analysis and Drop Specialization)

### 7.1 Reuse Analysis

Pair pattern-match deconstructions with same-size constructions:

```zig
pub const ResetOp = struct {
    /// Reuse token destination.
    dest: LocalId,
    /// Value being deconstructed.
    source: LocalId,
    /// Type being deconstructed (for size/layout info).
    source_type: TypeId,
};

pub const ReuseAllocOp = struct {
    /// Allocated value destination.
    dest: LocalId,
    /// Reuse token from a prior Reset (null → fresh allocation).
    token: ?LocalId,
    /// Constructor tag for tagged unions.
    constructor_tag: u32,
    /// Type being constructed.
    dest_type: TypeId,
};
```

**Algorithm:**
1. At each pattern match site, identify the deconstructed value
2. In each branch, identify constructions of the same type/size
3. If the deconstructed value is unique (or RC=1 at runtime), insert
   `reset` before deconstruction and `reuse_alloc` at construction
4. The `reset` instruction: if RC=1, make memory available for reuse and
   return a reuse token; if RC>1, decrement RC and return null token
5. The `reuse_alloc` instruction: if token is non-null, reuse memory;
   otherwise allocate fresh

### 7.2 Drop Specialization

At pattern match sites where the constructor tag is known, generate specialized
drop code:

```
Instead of: generic_drop(value)  // dispatches on tag at runtime

Generate:   switch (value.tag) {
                .cons => { drop(value.head); drop(value.tail); free(value); }
                .nil  => { free(value); }
            }
```

**Effect:** Avoids tag-based dispatch overhead in the destructor. For deeply
nested data structures, this compounds.

### 7.3 FBIP (Functional But In-Place)

The combination of reuse analysis + drop specialization + borrowed parameter
inference enables FBIP: purely functional code that performs in-place mutation
when values are uniquely owned. Example:

```zap
def map(list, f) do
  case list do
    [] -> []
    [head | tail] -> [f(head) | map(tail, f)]
  end
end
```

With Perceus: if `list` has RC=1, the `[head | tail]` deconstruction produces a
reuse token. The `[f(head) | map(tail, f)]` construction reuses it. The list
nodes are mutated in-place. Zero allocation.

---

## 8. Design: Data Structures and API

### 8.1 Core Analysis Context

```zig
pub const AnalysisContext = struct {
    /// Per-SSA-value escape state (indexed by LocalId).
    escape_states: std.AutoArrayHashMap(ir.LocalId, EscapeState),

    /// Per-SSA-value region assignment.
    region_assignments: std.AutoArrayHashMap(ir.LocalId, RegionId),

    /// Per-allocation-site summary.
    alloc_summaries: std.AutoArrayHashMap(AllocSiteId, AllocSiteSummary),

    /// Per-function interprocedural summary.
    function_summaries: std.AutoArrayHashMap(ir.FunctionId, FunctionSummary),

    /// Lambda sets per function-typed binding.
    lambda_sets: std.AutoArrayHashMap(ir.LocalId, LambdaSet),

    /// Virtual object states for partial escape analysis (per block).
    virtual_objects: std.AutoArrayHashMap(BlockVirtualKey, VirtualObject),

    /// Field escape maps for composite types.
    field_escapes: std.AutoArrayHashMap(ir.LocalId, FieldEscapeMap),

    /// Borrow legality verdicts.
    borrow_verdicts: std.AutoArrayHashMap(BorrowSiteId, BorrowVerdict),

    /// Reuse pairs (pattern match site → construction site).
    reuse_pairs: std.AutoArrayHashMap(MatchSiteId, ReusePair),

    /// Allocation strategy decisions.
    alloc_strategies: std.AutoArrayHashMap(AllocSiteId, AllocationStrategy),

    /// ARC operation placement.
    arc_ops: std.ArrayList(ArcOperation),
};
```

### 8.2 Allocation Site Summary

```zig
pub const AllocSiteSummary = struct {
    site_id: AllocSiteId,
    type_id: TypeId,
    escape: EscapeState,
    region: RegionId,
    multiplicity: Multiplicity,
    storage_mode: StorageMode,
    strategy: AllocationStrategy,
    field_escape: ?FieldEscapeMap,
    reuse_token: ?LocalId,
};
```

### 8.3 Borrow Verdict

```zig
pub const BorrowVerdict = union(enum) {
    legal: struct {
        reason: BorrowLegalReason,
    },
    illegal: struct {
        reason: BorrowIllegalReason,
        escape_path: ?EscapePath,
    },
};

pub const BorrowLegalReason = enum {
    immediate_call,
    block_local_closure,
    known_safe_callee,
    loop_invariant,
};

pub const BorrowIllegalReason = enum {
    returned_from_function,
    stored_in_escaping_container,
    passed_to_unknown_callee,
    crosses_loop_boundary,
    crosses_merge_with_moved_source,
};
```

### 8.4 ARC Operation

```zig
pub const ArcOperation = struct {
    kind: enum {
        retain,
        release,
        reset,          // Perceus: if RC=1, reuse token; else release
        reuse_alloc,    // Perceus: if token, reuse; else fresh alloc
        move,           // ownership transfer, no RC change
        share,          // unique → shared, inserts retain
    },
    value: ir.LocalId,
    insertion_point: InsertionPoint,
    reason: ArcReason,
};
```

---

## 9. Implementation Phases

### Phase 0: IR and Backend Unification

**Goal:** Establish one authoritative optimization substrate before adding more
advanced analyses.

**Work:**
- Choose the authoritative backend path for native compilation and make all new
  optimization work target it
- Align `src/escape_analysis.zig`, `src/codegen.zig`, `src/zir_builder.zig`,
  and `src/zir_backend.zig` on one closure/runtime representation strategy
- Audit which IR control-flow forms are actually generated and supported
- Add an ownership/consumption verification pass over IR so later ARC and
  borrow optimizations are checked by invariant rather than convention
- Make analysis results available to the active native backend, not only the
  legacy Zig emission path

**Files:** `src/compiler.zig`, `src/ir.zig`, `src/codegen.zig`,
`src/zir_builder.zig`, `src/zir_backend.zig`

**Success criteria:**
- One backend path is treated as canonical for optimization work
- Closure allocation strategy is represented consistently across analysis and
  native lowering
- Unsupported CFG/SSA forms are either implemented or removed from the design
- Ownership verification catches invalid consume/borrow flows before codegen

### Phase 1: Generalized Escape Analysis Foundation

**Goal:** Extend the existing `escape_analysis.zig` from closure-only to all
value shapes, but keep v1 deliberately simpler than full Graal-style PEA.

**Work:**
- Extend `EscapeState` lattice to the six-element version defined above
- Track escape state for all allocation sites (struct creation, tuple creation,
  list construction, map construction, closure creation, opaque allocation)
- Implement field-sensitive tracking for structs and tuples
- Use array-element summarization for lists and maps
- Produce alloc-site summaries first; defer full virtual-object PEA until the
  generalized lattice is stable
- Wire up the generalized analysis to produce `AllocSiteSummary` per allocation

**Files:** `src/escape_analysis.zig`, `src/ir.zig`

**Success criteria:**
- All allocation sites have escape classifications
- Struct/tuple allocations that don't escape are identified for stack promotion
- Tests cover: struct no-escape, struct field-escape, tuple escape through
  return, list element escape, closure environment escape

### Phase 2: Ownership Legality and Borrow Solver

**Goal:** Replace use-site and closure-special-case reasoning with a
whole-function ownership/borrow legality pass over CFG-aware IR.

**Work:**
- Define consume/borrow/forwarding semantics for IR instructions
- Implement ownership join rules at merges and phi nodes
- Build CFG-aware borrow legality checking for loops, merges, and closure
  capture boundaries
- Produce borrow legality verdicts and ownership diagnostics from analysis
- Add the verifier needed by later ARC and region work

**Files:** `src/escape_analysis.zig`, `src/ir.zig`, `src/types.zig`

**Success criteria:**
- Borrowed references are proven legal/illegal with precise diagnostics
- Ownership merges behave predictably at phi nodes and control-flow joins
- Tests cover: borrowed capture immediate call (legal), borrowed capture
  returned (illegal), borrowed value across merge, move while borrowed, and
  loop-carried borrow legality

### Phase 3: Interprocedural Summary System

**Goal:** Compute and propagate function summaries for escape and ownership.

**Work:**
- Implement bottom-up summary computation over call graph
- Handle recursive functions with fixpoint iteration over SCCs
- Encode parameter escape behavior (stores, returns, read-only, deref depth)
- Encode return value sources
- Implement borrowed parameter inference
- Apply summaries at call sites during intraprocedural analysis

**Files:** `src/escape_analysis.zig`, `src/ir.zig` (summary storage)

**Success criteria:**
- Functions that only read parameters are inferred as borrowing
- Closures passed to known-safe callees are classified as `arg_escape_safe`
- Recursive function groups converge to stable summaries
- Tests cover: `map(list, fn)` where fn is borrowed (no retain/release),
  parameter stored in returned struct (global_escape), recursive accumulator
  with borrowed parameter

### Phase 4: Region Representation and Allocation Strategy

**Goal:** Add region-like allocation decisions only after escape and ownership
facts are trustworthy.

**Work:**
- Implement constraint generation for outlives and region membership
- Solve non-lexical lifetime/region constraints using CFG-aware sets, not only
  dominator-tree LCA heuristics
- Implement multiplicity inference per region
- Implement storage-mode analysis (`attop`/`atbot`)
- Map escape states and ownership facts to concrete allocation strategies

**Files:** `src/escape_analysis.zig` or new `src/lifetime_solver.zig`

**Success criteria:**
- Non-escaping values get stack or caller-region assignments where justified
- Region assignments are stable across loops and merge points
- Multiplicity correctly identifies single-allocation regions
- Tests cover: value live across loop, value dead before next iteration,
  caller-safe argument region, and merge-induced promotion

### Phase 5: Closure Environment Representation Tiers

**Goal:** Make closure lowering consistent and analysis-driven on the canonical
native backend.

**Work:**
- Tier 0 (lambda lifting): non-capturing defs as top-level functions
- Tier 1 (immediate invocation): captures forwarded as arguments
- Tier 2 (block-local): flat env struct on stack, block-scoped
- Tier 3 (function-local): flat env struct on stack, function-scoped
- Tier 4 (escaping): heap-allocated flat env with ARC + DynClosure wrapper
- Select tier based on escape analysis and ownership results
- Implement per-tier lowering through the canonical backend path

**Files:** `src/codegen.zig`, `src/zir_builder.zig`, `src/runtime.zig`

**Success criteria:**
- Non-capturing nested def emits no closure environment
- Immediate-call closure emits no environment struct
- Block-local closure uses stack allocation
- Escaping closure uses heap + DynClosure
- The native backend and analysis agree on closure representation decisions

### Phase 6: Whole-Program Lambda Set Specialization

**Goal:** Implement closure flow analysis and lambda set specialization.

**Work:**
- Implement 0-CFA closure flow analysis (propagate lambda sets through the
  whole program)
- Annotate function-typed bindings with their lambda sets
- Implement specialization decisions (singleton → direct, small → switch,
  large → DynClosure)
- Implement closure environment layout per lambda set variant
- Implement contification for call-only closures
- Add code-size and compile-time heuristics for when specialization is allowed
- Wire lambda set info into the canonical backend

**Files:** `src/escape_analysis.zig`, `src/ir.zig`, `src/codegen.zig`,
`src/zir_builder.zig`

**Success criteria:**
- Singleton lambda sets produce direct calls (no DynClosure)
- Small lambda sets produce switch dispatch
- Contified closures become jumps
- Non-escaping closure environments are stack-allocated
- Tests cover: single-target higher-order call (direct), two-target
  higher-order call (switch), closure only used in immediate call (contified),
  closure stored in collection (DynClosure fallback)

### Phase 7: ARC Optimization Pass

**Goal:** Use verified ownership facts to minimize ARC operations.

**Work:**
- Eliminate redundant retain/release pairs where ownership is proven
- Hoist retain/release out of loops where possible (RC identity analysis)
- Use borrowed parameter inference to skip retain/release at call boundaries
- Use escape analysis to skip ARC for stack-allocated values
- Implement COW optimization: `is_unique` check before mutation

**Files:** `src/ir.zig` (new optimization pass), `src/codegen.zig`,
`src/zir_builder.zig`

**Success criteria:**
- No retain/release on stack-allocated values
- No retain/release at call sites for borrowed parameters
- Unique value flows have zero ARC overhead
- Loop-carried shared values hoist retain out of loop
- Tests verify ARC operation counts in generated code

### Phase 8: Perceus Reuse and Drop Specialization

**Goal:** Implement reuse analysis, reset/reuse operations, and drop
specialization.

**Work:**
- Add `reset` and `reuse_alloc` IR instructions
- Implement reuse pair detection at pattern match sites
- Implement drop specialization per known constructor
- Integrate with ownership: unique values get static reuse, shared values get
  runtime RC=1 check
- Wire through the canonical backend

**Files:** `src/ir.zig`, `src/escape_analysis.zig`, `src/codegen.zig`,
`src/zir_builder.zig`, `src/runtime.zig`

**Success criteria:**
- Pattern match + reconstruct on unique value reuses memory in-place
- Drop of known constructor avoids tag dispatch
- Functional list map with unique list allocates zero new nodes
- Tests cover: list map reuse, tree rebalance reuse, non-matching sizes
  (no reuse), shared value (runtime check)

### Phase 9: Integration and Validation

**Goal:** Wire everything together and validate end-to-end.

**Work:**
- Integration tests covering all allocation strategies
- Benchmark suite: list map, tree rebalance, closure-heavy patterns, struct
  construction/access patterns
- Verify correctness: no use-after-free, no double-free, no leaked allocations
- Verify performance: compare allocation counts and RC operation counts against
  baseline
- Diagnostic quality: verify precise error messages for borrow violations

**Files:** `src/integration_tests.zig`

---

## 10. Comparison with Prior Art

| Feature | Zap (This Plan) | Rust | Swift | Go | Koka | Lobster |
|---------|-----------------|------|-------|-----|------|---------|
| Escape analysis scope | All values | Borrow checker | All refs | All values | N/A (precise RC) | All values |
| Field sensitivity | Yes | N/A (ownership) | Partial | No (MEA2: Yes) | N/A | No |
| Flow sensitivity | Yes (PEA) | Yes (NLL) | Yes (OSSA) | No | N/A | Yes |
| Region inference | Yes | Yes (lifetimes) | No | No | No | No |
| Annotations required | None (inferred) | Yes (lifetimes) | Partial | None | None | None |
| Closure optimization | Lambda sets | Monomorphization | Devirtualization | Escape-based | N/A | Specialization |
| Reuse analysis | Yes (Perceus) | No | No | No | Yes | No |
| ARC optimization | Full pipeline | N/A (no RC) | Yes (OSSA) | N/A (GC) | Yes (Perceus) | Yes (~95%) |
| Interprocedural | Summaries | Trait bounds | SIL effects | Param tags | Per-function | Per-function |

---

## 11. Risk Assessment

### Compile-time cost

The full pipeline (escape analysis + region solving + lambda set computation +
reuse analysis) adds multiple passes. Mitigations:
- Finite-height lattices guarantee fast convergence
- Sparse SSA analysis avoids per-CFG-point work
- Lambda set computation is per-program (amortized)
- Each phase can be independently benchmarked and optimized

### Precision vs. performance tradeoff

Partial escape analysis and field-sensitive tracking add complexity. Mitigations:
- Start with field-insensitive for v1, add field sensitivity as a refinement
- PEA can be gated behind an optimization level flag
- Conservative fallback (heap + ARC) is always correct

### Interaction with existing code

The analysis must integrate with the existing ownership type checker, HIR/IR
pipeline, and codegen. Mitigations:
- Analysis results are consumed read-only by downstream phases
- Existing correctness checks remain; analysis results only unlock optimizations
- Phased rollout allows validation at each step

---

## 12. References

### Region Inference
- Tofte, Talpin. "Region-Based Memory Management." Information and Computation 132(2), 1997.
- Tofte, Birkedal. "A Region Inference Algorithm." TOPLAS 1998.
- Tofte, Birkedal. "A Constraint-Based Region Inference Algorithm." TCS 2000.
- Birkedal, Tofte, Vejlstrup. "From Region Inference to von Neumann Machines via Region Representation Inference." POPL 1996.
- Hallenberg, Elsman, Tofte. "Combining Region Inference and Garbage Collection." PLDI 2002.
- Aiken, Fähndrich, Levien. "Better Static Memory Management: Improving Region-Based Analysis of Higher-Order Languages." PLDI 1995.
- Gay, Aiken. "Language Support for Regions." PLDI 2001.
- Grossman et al. "Region-Based Memory Management in Cyclone." PLDI 2002.
- Henglein, Makholm, Niss. "Effect Types and Region-based Memory Management." In Advanced Topics in Types and Programming Languages, MIT Press 2005.

### Escape Analysis
- Choi, Gupta, Serrano. "Escape Analysis for Java." OOPSLA 1999.
- Blanchet. "Escape Analysis for Java: Theory and Practice." OOPSLA 1999.
- Whaley, Rinard. "Compositional Pointer and Escape Analysis for Java Programs." OOPSLA 1999.
- Kotzmann, Mössenböck. "Escape Analysis in the Context of Dynamic Compilation and Deoptimization." VEE 2005.
- Stadler, Würthinger, Mössenböck. "Partial Escape Analysis and Scalar Replacement for Java." CGO 2014.
- Lu, Xu, Nie, Shen, Liu. "MEA2: a Lightweight Field-Sensitive Escape Analysis with Points-to Calculation for Go." OOPSLA 2024.

### Lifetime and Borrow Checking
- Rust NLL RFC 2094. https://rust-lang.github.io/rfcs/2094-nll.html
- Polonius. https://github.com/rust-lang/polonius
- Matsakis. "Polonius Revisited." https://smallcultfollowing.com/babysteps/blog/2023/09/22/polonius-part-1/

### Ownership SSA and ARC Optimization
- Swift SIL Ownership. https://github.com/swiftlang/swift/blob/main/docs/SIL/Ownership.md
- Swift ARC Optimization. https://apple-swift.readthedocs.io/en/latest/ARCOptimization.html
- Swift SE-0377: Parameter Ownership Modifiers.
- Swift SE-0390: Noncopyable Types.

### Reference Counting Optimization
- Reinking, Xie, de Moura, Leijen. "Perceus: Garbage Free Reference Counting with Reuse." PLDI 2021.
- Lorenzen, Leijen. "Reference Counting with Frame Limited Reuse." ICFP 2022.
- Ullrich, de Moura. "Counting Immutable Beans: Reference Counting Optimized for Purely Functional Programming." IFL 2019.

### Closure Optimization
- Reynolds. "Definitional Interpreters for Higher-Order Programming Languages." 1972.
- Kennedy. "Compiling with Continuations, Continued." ICFP 2007.
- Fluet, Weeks. "Contification Using Dominators." ICFP 2001.
- Downen et al. "Lambda Set Specialization." PLDI 2023.
- Perconti, Ahmed. "Closure Conversion is Safe for Space." ICFP 2019.

### Dataflow and Abstract Interpretation
- Cytron, Ferrante, Rosen, Wegman, Zadeck. "Efficiently Computing Static Single Assignment Form and the Control Dependence Graph." TOPLAS 1991.
- Kam, Ullman. "Monotone Data Flow Analysis Frameworks." Acta Informatica 1977.
- Cousot, Cousot. "Abstract Interpretation: A Unified Lattice Model for Static Analysis of Programs by Construction or Approximation of Fixpoints." POPL 1977.
- Reps, Horwitz, Sagiv. "Precise Interprocedural Dataflow Analysis via Graph Reachability." POPL 1995.
- Lemerre. "SSA Translation Is an Abstract Interpretation." POPL 2023.

### Language Implementations
- Lobster Memory Management. https://aardappel.github.io/lobster/memory_management.html
- Vale Generational References. https://verdagon.dev/blog/generational-references
- Mojo Ownership. https://docs.modular.com/mojo/manual/values/ownership/
- Go Escape Analysis. https://go.dev/src/cmd/compile/internal/escape/escape.go
- MLKit. https://elsman.com/mlkit/papers
