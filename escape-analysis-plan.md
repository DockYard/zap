# Plan: CFG/SSA-Based Closure Escape and Lifetime Analysis

## Goal

## Implementation Status

Implemented in the current compiler:

- [x] dedicated `src/escape_analysis.zig` analysis subsystem
- [x] closure escape lattice and value lifetime lattice scaffolding
- [x] closure-site summaries driving codegen decisions
- [x] block-edge escape reasoning across `branch`, `jump`, `cond_branch`
- [x] alias propagation for closure values through `local_get`, `local_set`, `move_value`, and `share_value`
- [x] `Phi`-based merge classification for closure escape and local lifetime propagation
- [x] local/block-level closure allocation strategies (`none_direct_call`, `local_env`, `stack_env`, `heap_env`)
- [x] interprocedural known-safe closure parameter summaries
- [x] iterative fixpoint refinement of those summaries
- [x] closure summaries now merge conservatively across multiple sites for the same closure function
- [x] analysis summaries are consumed by both checker legality and codegen allocation decisions
- [x] block-edge closure escape classification across branches/jumps/conditional branches
- [x] alias propagation for closure values through local get/set, move, and share operations
- [x] local lifetime propagation for closure values through aliases and phi joins
- [x] transitive known-safe closure passing through helper functions
- [x] borrowed-capture legality now consults analysis summaries in implemented pass/return/storage paths
- [x] checker integration where borrowed-capture legality consults escape analysis results in implemented pass/return paths
- [x] codegen integration using analysis results for wrapper and heap-env decisions

Still intentionally incomplete relative to the full long-range production vision:

- [ ] full region-based or whole-function borrow solver across all value kinds
- [ ] full SSA/dataflow escape lattice across all storage/merge/control-flow shapes, not just closure-centric paths
- [ ] full whole-program/global closure optimization pass

Build a production-quality analysis foundation that can drive all of the
following from one shared source of truth:

- borrowed-capture legality
- whole-function borrow/lifetime reasoning
- closure environment allocation strategy
- closure call specialization
- ARC/capture optimization
- later whole-program closure optimization

This plan replaces the current checker-local, use-site-driven heuristics with a
real control-flow and dataflow analysis layer.

## Why This Is Needed

The current implementation is good enough for correctness in many cases, but it
still has these architectural limitations:

- borrowed-capture checking is use-site oriented and partial
- closure optimization is local/syntactic, not analysis-driven
- there is no full SSA/dataflow escape lattice across merges, loops, and stored
  values

These are really one missing system, not three separate problems.

## Current State

Today the compiler already has important prerequisites:

- ownership-aware types and checker state in `src/types.zig`
- explicit closure/capture representation in `src/hir.zig`
- explicit closure/capture lowering in `src/ir.zig`
- `Phi` already exists in IR
- `DynClosure` already exists as the generic runtime callable representation

That means the next step should be an analysis layer, not another batch of
heuristics.

## Design Principle

Implement one shared analysis engine and let multiple compiler decisions depend
on it.

That shared engine should answer questions like:

- does this closure escape?
- is this value live beyond this block?
- can this borrowed capture stay within a valid region?
- does this closure need a heap env?
- can this closure call be specialized into a direct call?
- do these captures need ARC retains/releases?

## Architecture Overview

### New subsystem

Add a dedicated analysis subsystem:

- `src/escape_analysis.zig`

Optional split later if needed:

- `src/cfg.zig`
- `src/ssa.zig`
- `src/closure_analysis.zig`

But start with one file/module to keep the first production iteration coherent.

### Inputs

- HIR program/function groups
- IR program/functions/blocks
- ownership-qualified type info
- scope graph / binding identities

### Outputs

- per-binding escape classification
- per-closure escape classification
- per-capture lifetime legality
- per-closure allocation strategy
- per-call-site specialization eligibility
- per-capture ARC strategy

## Analysis Domains

### 1. Closure escape lattice

Replace the current `ClosureEscapeKind` with a richer lattice.

Recommended states:

```zig
pub const ClosureEscape = enum {
    no_escape,
    call_local,
    block_local,
    stored_local,
    passed_known_safe,
    passed_unknown,
    returned,
    stored_heap,
    merged_escape,
    unknown_escape,
};
```

Meaning:

- `no_escape` — closure never leaves immediate analysis point
- `call_local` — closure is created and immediately invoked
- `block_local` — closure survives within block but does not escape block
- `stored_local` — closure stored in local but not proven to escape beyond
  function/block
- `passed_known_safe` — passed to a callee proven not to retain/store it
- `passed_unknown` — passed to a callee with no safe summary
- `returned` — returned from current function
- `stored_heap` — stored in an aggregate or closure env that escapes
- `merged_escape` — control-flow merge makes precise lifetime unclear
- `unknown_escape` — conservative fallback

### 2. Binding/value lifetime lattice

Track lifetimes of owned/shared/borrowed values.

Recommended states:

```zig
pub const ValueLifetime = enum {
    dead,
    local_only,
    block_live,
    function_live,
    escaping,
    merged,
    unknown,
};
```

And keep ownership separate from lifetime.

This avoids conflating:

- who owns the value
- how long it may remain live
- whether it escapes the current region

### 3. Capture transfer classification

For each closure capture, compute:

- capture ownership (`shared`, `unique`, `borrowed`)
- capture escape legality
- capture transfer mode

Recommended modes:

```zig
pub const CaptureTransfer = enum {
    borrow_local,
    move_into_env,
    share_into_env,
    forward_direct,
    illegal,
};
```

## Control-Flow Foundation

### CFG requirement

This system should not be built on raw AST recursion.

Need:

- block graph per function
- explicit predecessors/successors
- closure create/use sites attached to blocks
- storage/call/return sites attached to blocks

Recommended first implementation:

- derive CFG from IR blocks, not from AST

Reason:

- IR already has blocks and `Phi`
- escape/lifetime analysis belongs closer to executable semantics than syntax

## SSA and Phi Use

`Phi` already exists in IR, but production-quality escape analysis should
actually consume it.

Why:

- closures and borrowed values may cross:
  - branches
  - loops
  - join points
- without phi-aware analysis, any such path becomes a heuristic mess

Recommended approach:

- treat each `LocalId` as SSA-like where possible
- use `PhiSource` edges to merge escape/lifetime states
- define join rules such as:
  - `no_escape + returned -> returned`
  - `call_local + block_local -> block_local`
  - `block_local + returned -> merged_escape`
  - `borrow_local + escaping -> illegal`

## Borrowed-Capture Legality

### Production rule

Borrowed captures should be allowed if and only if the analysis proves the
closure stays within the borrow region.

### Initial proven-safe cases

- immediate call in same statement/block
- local-only closure value never stored/returned/passed beyond known-safe region
- direct specialization path where closure never materializes as an escaping
  object

### Illegal cases

- returned closures with borrowed captures
- passed-to-unknown closures with borrowed captures
- closures stored into aggregates/heap envs while carrying borrowed captures
- closures crossing merges/loops where borrow lifetime cannot be proven

### Diagnostics

Replace generic errors with specific ones:

- `borrowed capture 'handle' escapes through return`
- `borrowed capture 'x' escapes through argument 'f' to unknown callee`
- `borrowed capture 'buf' crosses loop boundary and lifetime cannot be proven`
- `borrowed capture 'h' stored in escaping closure environment`

## Closure Optimization Strategy

### Tier 1: Local specialization

Use analysis to optimize the easy profitable cases first.

- non-capturing nested def -> plain direct function path
- capturing closure with `call_local` escape -> direct lifted call with forwarded
  captures
- statically-known closure call with non-escaping env -> invoke wrapper directly,
  skip generic `DynClosure` path

### Tier 2: Allocation strategy

Use escape class to choose environment representation.

- `call_local` -> no env object, forward captures directly
- `block_local` -> stack/local env representation
- `stored_local` -> local env if analysis proves non-escaping
- escaping kinds -> heap env + release helper

### Tier 3: ARC strategy for captures

Use ownership + escape together.

- `unique` capture -> move only, no retain
- `borrowed` capture -> no ARC ops, only if region-safe
- `shared` capture + local-only env -> avoid retain/release where possible
- `shared` capture + escaping env -> retain on env creation, release on env
  destruction

### Tier 4: Interprocedural closure summaries

Once whole-function analysis is stable, add callee summaries.

Each function that accepts closure values can report:

- does not retain/store closure arg
- may store closure arg locally
- returns closure arg
- unknown behavior

This enables `passed_known_safe` and reduces false positives on borrowed captures.

## Data Structures

### Core analysis result

```zig
pub const AnalysisResult = struct {
    closure_sites: std.AutoHashMap(ClosureSiteId, ClosureSummary),
    local_lifetimes: std.AutoHashMap(ir.LocalId, ValueSummary),
    call_sites: std.AutoHashMap(CallSiteId, CallSummary),
};
```

### Closure summary

```zig
pub const ClosureSummary = struct {
    escape: ClosureEscape,
    allocation: AllocationStrategy,
    captures: []const CaptureSummary,
    callable_strategy: CallableStrategy,
};
```

### Capture summary

```zig
pub const CaptureSummary = struct {
    binding_id: scope_mod.BindingId,
    ownership: types.Ownership,
    lifetime: ValueLifetime,
    transfer: CaptureTransfer,
};
```

### Allocation strategy

```zig
pub const AllocationStrategy = enum {
    none_direct_call,
    stack_env,
    local_env,
    heap_env,
};
```

### Callable strategy

```zig
pub const CallableStrategy = enum {
    direct_named,
    direct_wrapper,
    dyn_closure,
};
```

## File-by-File Plan

### `src/escape_analysis.zig`

New file.

Responsibilities:

- build CFG view from IR
- propagate escape/lifetime states
- join states across branches/phis
- compute closure/capture summaries
- expose reusable query API for later phases

### `src/ir.zig`

Add enough metadata for analysis and optimization.

Required changes:

- stable IDs for closure create/call sites
- explicit env allocation op kinds
- direct closure invoke op kinds
- better distinction between stack/local/heap env paths
- richer use of `Phi`

### `src/hir.zig`

Preserve closure site identity and capture descriptors cleanly so analysis can
map HIR closure expressions to IR closure sites.

### `src/types.zig`

Shrink current borrowed-capture heuristics into a thin consumer of analysis
results.

Replace current ad hoc checks with:

- query analysis result for closure escape class
- query capture legality
- emit precise diagnostics from summaries

### `src/codegen.zig`

Consume optimized closure strategies.

- `none_direct_call` -> no closure env emission
- `stack_env` / `local_env` -> emit local/stack env representation
- `heap_env` -> current heap env path
- `direct_wrapper` -> call wrapper directly
- `dyn_closure` -> current `DynClosure` path

### `src/runtime.zig`

Keep runtime generic and simple.

Do not move analysis complexity into runtime.

`DynClosure` should stay the fallback ABI for escaping/general closures, not the
representation for every closure.

## Implementation Phases

### Phase 1: Whole-function escape analysis

- create `src/escape_analysis.zig`
- derive CFG from IR blocks
- compute closure escape states
- compute capture lifetimes and legality
- keep optimizer decisions read-only at first

Success criteria:

- borrowed-capture diagnostics come from analysis results, not AST recursion
- tests distinguish `call_local`, `returned`, `passed_unknown`, `stored`

### Phase 2: Borrow-region legality

- use analysis to allow safe borrowed captures in local-only cases
- reject borrowed captures crossing merges/loops/escapes without proof

Success criteria:

- local immediate borrowed closure call accepted
- return/pass/store borrowed closure rejected with precise diagnostics
- branch/loop cases behave consistently with region reasoning

### Phase 3: Local closure optimization

- optimize immediate captured closure calls into direct lifted calls
- avoid `DynClosure` materialization for local-only cases
- keep heap env only for escaping closures

Success criteria:

- generated Zig no longer emits closure env objects for `call_local` cases
- closure call sites use direct invoke path when statically known and safe

### Phase 4: ARC/capture optimization

- shared captures retain/release only when escaping env requires it
- no ARC ops for local-only shared captures
- unique captures move without retain

Success criteria:

- integration tests prove local-only shared capture path emits no retain/release
- escaping shared capture path still retains/releases correctly

### Phase 5: Interprocedural call summaries

- summarize functions that accept closures
- enable `passed_known_safe`
- reduce false positives and broaden optimization

Success criteria:

- known-safe closure-passing APIs accept borrowed captures when the callee does
  not store/return them

### Phase 6: Whole-program/global optimization

- build call graph summaries
- propagate closure escape and retention summaries globally
- specialize closure env allocation and invoke paths across function boundaries

Success criteria:

- non-escaping closure values propagated through known-safe helper functions stay
  off heap
- global specialization reduces `DynClosure` usage in generated code

## Test Strategy

### Borrow/lifetime tests

- borrowed capture immediate call: allowed
- borrowed capture stored in local tuple/map/struct: rejected
- borrowed capture returned: rejected
- borrowed capture passed to unknown callee: rejected
- borrowed capture passed to known-safe callee: allowed (after summary phase)
- borrowed capture through branch merge: rejected or proven safe
- borrowed capture through loop-carried closure: rejected until proven safe

### Optimization tests

- non-capturing nested def: direct path, no `DynClosure`
- capturing immediate call: no heap env, no `DynClosure`
- capturing returned closure: heap env + release helper
- shared opaque capture local-only: no retain/release
- shared opaque capture escaping: retain/release present
- unique capture escaping: no retain, outer binding moved

### SSA/dataflow tests

- phi merge of closure values produces correct escape join
- closure created in one branch and returned after join is classified as escape
- closure created in loop body is not misclassified as local-only

## Recommended Rollout

1. whole-function escape analysis
2. borrowed-region legality from analysis
3. local closure optimization using analysis
4. ARC optimization using analysis
5. interprocedural safe-passing summaries
6. global closure optimization

## Final Recommendation

Do not implement the three missing capabilities as separate ad hoc efforts.

Build one shared CFG/SSA-based closure escape and lifetime analysis layer, then
reuse it for:

- borrowed-capture legality
- local closure optimization
- ARC/capture optimization
- later whole-program/global closure specialization

That is the production-quality path for this project.
