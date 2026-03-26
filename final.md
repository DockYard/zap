# Remaining Implementation Plan

This document captures the remaining work needed to fully complete the research plan after the recent analysis, backend, and validation improvements.

## 1. Canonical Backend Lowering from `AnalysisContext.reuse_pairs` / `drop_specializations`

### Current state

- `AnalysisContext.reuse_pairs` is now preserved as a list and available to both backends.
- `AnalysisContext.drop_specializations` is now preserved with insertion points and extracted field locals.
- `codegen.zig` and `zir_builder.zig` now consume:
  - analysis-driven `retain` / `release`
  - analysis-driven Perceus reset insertion for `case_block`
  - analysis-driven drop-specialized releases
- The remaining major gap is that `reuse_alloc` is still not lowered canonically from analysis-owned data.

### Why this is still incomplete

- The backends can identify reset sites from `ReusePair.reset`, but construction rewriting is still mostly tied to normal constructor lowering paths.
- `ReusePair.reuse` is not yet being used as the canonical trigger to replace ordinary aggregate construction with reuse-aware allocation.
- This means Perceus is only partially analysis-driven end-to-end.

### Goal

Use `AnalysisContext.reuse_pairs` as the single source of truth for reuse-aware allocation lowering in canonical backends.

### Implementation steps

#### 1.1 Add reuse lookup helpers

In both backends, add helpers that find a reuse candidate for the current constructor site by matching:

- `current_function_id`
- current block / instruction index
- constructor destination local

Recommended files:

- `src/codegen.zig`
- `src/zir_builder.zig`

Recommended helper shape:

- `findReusePairForDest(dest: ir.LocalId) ?lattice.ReusePair`

This should prefer exact destination matching over ad hoc pattern assumptions.

#### 1.2 Implement canonical `reuse_alloc` lowering for named structs first

Start with `struct_init`, because it has the cleanest type information.

Recommended file:

- `src/zir_builder.zig`

Recommended approach:

1. Detect whether the current `struct_init.dest` matches a `ReusePair.reuse.dest`
2. Load the token local from `ReusePair.reuse.token`
3. Derive the real type from the constructor instruction itself, not the partially populated `ReusePair.reuse.dest_type`
4. Emit `ArcRuntime.reuseAllocByType`
5. Initialize fields into the reused allocation
6. Keep plain construction as fallback when no reuse pair matches

The same pattern can then be applied to:

- `union_init`
- `tuple_init`

#### 1.3 Decide representation boundary for reused aggregates

The source backend and ZIR backend need a consistent rule for reused values:

- whether reused constructors yield pointer-like storage directly
- or whether they reconstruct a value-level wrapper after reuse-aware allocation

This needs to be explicit before extending beyond `struct_init`.

#### 1.4 Consume drop specializations more precisely

Current drop specialization lowering emits release calls for extracted field locals.
The next refinement is to make this constructor/arm-aware rather than only insertion-point-aware.

Recommended follow-up:

- ensure the right specialization fires only for the matching constructor arm
- avoid duplicate releases if generic ARC ops are still present nearby

#### 1.5 Add end-to-end reuse tests

Add tests that prove constructor lowering changed because of `AnalysisContext.reuse_pairs`, not just because reset tokens exist.

Recommended tests:

- reused struct reconstruction after `case`
- reused union reconstruction after `case`
- tuple reuse if supported by current representation

Recommended files:

- `src/integration_tests.zig`
- `src/zir_integration_tests.zig`
- possibly backend-local unit tests in `src/zir_builder.zig`

### Exit criteria

- Constructors are rewritten from analysis-owned reuse data, not ad hoc local logic
- `reuse_alloc` is emitted canonically for supported aggregate kinds
- tests prove reuse-aware lowering is happening end-to-end

## 2. Full Tier-Specific Closure Lowering in `src/zir_builder.zig`

### Current state

- Non-capturing lambda-lifted closures now avoid environment allocation.
- Closure structs now better match runtime shape by including `env_release`.
- The remaining tiers are not yet lowered as fully distinct strategies.

### Why this is still incomplete

The backend still does not fully distinguish the intended closure tiers:

- `lambda_lifted`
- `immediate_invocation`
- `block_local`
- `function_local`
- `escaping`

Several code paths still effectively collapse into a generic closure object path.

### Goal

Make `src/zir_builder.zig` lower each closure tier intentionally rather than treating closure representation as mostly uniform.

### Implementation steps

#### 2.1 Centralize closure-tier queries

Add a dedicated helper layer around:

- `getClosureTier`
- whether a wrapper is needed
- whether an env object is needed
- whether the env should be stack-local or escaping-compatible

Recommended file:

- `src/zir_builder.zig`

#### 2.2 Implement tier behavior explicitly

##### Tier 0: `lambda_lifted`

Desired behavior:

- no environment allocation
- direct function reference shape
- no capture object

Current status:

- partially implemented for non-capturing closures

Still needed:

- ensure all call/creation paths consistently avoid env materialization

##### Tier 1: `immediate_invocation`

Desired behavior:

- do not materialize a closure object when the closure is immediately consumed
- forward captures as direct arguments to the lifted function or wrapper

Still needed:

- make `make_closure` + `call_closure` pairs collapse into immediate call lowering where analysis says this tier applies

##### Tier 2: `block_local`

Desired behavior:

- stack-local environment object
- no escaping ARC machinery
- closure valid only for block lifetime

Still needed:

- represent env as stack-local data rather than generic escaping-compatible closure shape

##### Tier 3: `function_local`

Desired behavior:

- function-frame-local environment object
- no heap ARC behavior

Still needed:

- distinguish it from `block_local` and from `escaping`

##### Tier 4: `escaping`

Desired behavior:

- current `DynClosure`-style representation remains valid here
- env release hook should be meaningful for actual escaping ownership

Still needed:

- make this the only tier that truly requires the escaping closure object path

#### 2.3 Fix `capture_get`

`capture_get` still depends on an implicit environment-local convention.
This should be refactored so closure env access is explicit and tier-aware.

Recommended direction:

- generated wrapper/env parameter for tiers that need env access
- no `capture_get` env lookup for tiers that eliminate env materialization

#### 2.4 Add tier-specific tests

Recommended coverage:

- lambda-lifted closure emits no env object
- immediate-invocation closure emits no closure object
- block-local closure stays stack-local
- function-local closure stays stack-local to the function
- escaping closure still produces the full closure representation

Recommended files:

- `src/integration_tests.zig`
- `src/zir_integration_tests.zig`
- `src/lambda_sets.zig` / `src/analysis_pipeline.zig` for tier classification assertions

### Exit criteria

- each closure tier has a distinct lowering path in `src/zir_builder.zig`
- `capture_get` semantics align with the chosen tier
- escaping behavior is isolated to the escaping tier

## 3. Real Non-Tail Contification / Jump Semantics

### Current state

- Tail-position contification exists as a tail-call optimization slice.
- Non-tail contification still does not exist as true continuation/jump lowering.

### Why this is still incomplete

- Current `.contified` handling is mostly a specialized call emission choice.
- The IR’s `jump` capability is effectively unused for real continuation-style lowering.
- This means contification is not yet represented as a control-flow transformation.

### Goal

Lower contified closures as structured control flow rather than just specialized calls, especially for non-tail cases.

### Implementation steps

#### 3.1 Extend IR jump semantics minimally

Current `ir.Jump` only carries a target label.
To support useful continuation-style lowering, it likely needs enough payload to carry a value/result.

Recommended file:

- `src/ir.zig`

Suggested minimal evolution:

- add optional result/value payload to `Jump`
- keep the change narrow to avoid a full IR redesign

#### 3.2 Add a narrow rewrite pass

Add a rewrite phase that converts a constrained subset of contified closure-call patterns into jump-based control flow.

Recommended starting constraints:

- singleton contified lambda set
- straight-line continuation
- non-escaping closure
- no complex merge/phi interaction initially

Recommended file:

- `src/ir.zig` or a dedicated small lowering pass next to existing IR rewrites

#### 3.3 Teach backends to lower jump-based continuations

Recommended files:

- `src/codegen.zig`
- `src/zir_builder.zig`

Recommended direction:

- represent continuation jumps as structured labeled breaks / inline blocks
- ensure result propagation is preserved
- keep fallback to current specialized-call path for unsupported shapes

#### 3.4 Add non-tail contification tests

Recommended tests:

- contified closure in non-tail position inside straight-line code
- contified closure inside `if` / `case` continuation-safe shapes
- fallback cases where rewrite must not fire

Recommended files:

- `src/integration_tests.zig`
- `src/lambda_sets.zig`
- backend-local tests if useful

### Exit criteria

- non-tail contified calls are represented as structured jumps/continuations in supported cases
- backends lower those jumps correctly
- unsupported cases still safely fall back to specialized call lowering

## Recommended Execution Order

1. Finish canonical analysis-driven `reuse_alloc` lowering for `struct_init` in `src/zir_builder.zig`
2. Extend that to more aggregate constructors where representation is clear
3. Complete full tier-specific closure lowering in `src/zir_builder.zig`
4. Add minimal IR jump payload support for continuation-style lowering
5. Implement a constrained non-tail contification rewrite
6. Add targeted integration and backend tests for each step

## Definition of Done

The remaining work is complete when:

- `AnalysisContext` fully drives canonical Perceus reuse/drop backend lowering for supported constructors
- `src/zir_builder.zig` has distinct lowering behavior for all closure tiers
- contification supports real non-tail continuation/jump lowering for at least a well-defined safe subset
- `zig build test`, `zig build zir-test`, `zig build phase9-test`, and `zig build bench` all pass with coverage for the new behavior
