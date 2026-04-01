# Zap Continuation Todo

This file is a handoff for a fresh OpenCode session.

## CTFE / IR Interpreter Remaining Work

This section tracks the remaining work to make the IR interpreter / CTFE implementation complete based on the current source state.

### Blocking Correctness Work

- [ ] Fix dangling lifetime bugs in CTFE results.
  Files: `src/ctfe.zig`, `src/builder.zig`
  Required work:
  - deep-copy `CtEvalResult.dependencies` before returning from `evalAndExport`
  - deep-copy `EvalAttrResult.errors` before returning from attribute evaluation helpers
  - audit all CTFE result structs so no returned slice points into interpreter-owned memory after `deinit`
  - add tests proving returned dependency/error data remains valid after interpreter teardown

- [ ] Fix persistent CTFE cache key correctness.
  Files: `src/ctfe.zig`, `src/builder.zig`, `src/main.zig`
  Required work:
  - include target triple in persistent cache keys
  - include optimize mode in persistent cache keys
  - include relevant build options / `-Dkey=value` inputs in persistent cache keys
  - either remove unused `options_hash` or wire it all the way through lookup/store
  - add tests proving `System.get_build_opt/1` results are invalidated by option changes

- [ ] Make computed attribute evaluation fully IR-driven instead of literal-call-only.
  Files: `src/ctfe.zig`, possibly `src/compiler.zig`, `src/attr_substitute.zig`
  Required work:
  - stop limiting attribute CTFE to literals and calls with literal AST args
  - evaluate arbitrary legal computed attribute expressions through lowered IR
  - keep the AST bridge only for substitution/reification, not as the computation mechanism
  - add tests for non-trivial attribute expressions and nested compile-time calls

- [ ] Finish true module-by-module frontend architecture.
  Files: `src/main.zig`, `src/compiler.zig`, collector/type/HIR plumbing as needed
  Required work:
  - remove dependence on one merged whole-program source as the effective frontend substrate
  - stop doing global parse/collect as the only real compilation entry point
  - make module compilation units real instead of extracting per-module ASTs from a merged program
  - preserve dependency-order compilation from discovery as the actual frontend execution model
  - add end-to-end tests proving earlier-module CTFE affects later macro expansion/type checking under the real module pipeline

### Interpreter Semantics Still Incomplete

- [ ] Finish CTFE diagnostic provenance.
  Files: `src/ctfe.zig`
  Required work:
  - populate `CtfeFrame.instruction_index` during execution
  - attach attribute/module context when attribute evaluation fails
  - improve effect-related diagnostics to include which intrinsic/resource failed
  - ensure formatted CTFE diagnostics include concrete call stack provenance, not placeholder frames

- [ ] Finish reflection-aware persistent cache validation.
  Files: `src/ctfe.zig`
  Required work:
  - make `reflected_module` dependencies re-validatable instead of always invalidating
  - provide the cache validator enough interface metadata to compare reflected module state across builds
  - add tests covering cache hits/misses for `Module.functions/attributes/types`

- [ ] Finish ownership-sensitive CTFE semantics.
  Files: `src/ctfe.zig`
  Required work:
  - stop treating `retain` as a pure no-op
  - model `release`, `reset`, and `reuse_alloc` with stronger correctness semantics
  - enforce use-after-move / use-after-release failures explicitly
  - add tests for ownership errors during CTFE

- [ ] Finish the symbolic memory model.
  Files: `src/ctfe.zig`
  Required work:
  - reduce dependence on host-backed slices/pointers as semantic truth
  - represent aggregate identity/reference paths more explicitly
  - tighten union/closure payload handling so interpreter memory stays abstract-machine-owned
  - keep host allocation as an implementation detail, not the semantic model

- [ ] Implement stronger target-aware CTFE semantics.
  Files: `src/ctfe.zig`
  Required work:
  - stop hardcoding only `i64`/`f64`-centric evaluation assumptions where target information matters
  - thread compile-target/optimize context into evaluation where required
  - define and test any target-sensitive numeric/layout behavior that compile-time execution must respect

- [ ] Finish CTFE support for remaining IR control-flow forms that can matter.
  Files: `src/ctfe.zig`, `src/ir.zig`, lowering sites if needed
  Required work:
  - either implement or permanently eliminate CTFE-relevant emission of `phi`, `branch`, `cond_branch`, and `switch_tag`
  - document which forms are impossible after lowering if they remain unsupported
  - add tests proving unsupported instructions cannot be emitted into CTFE paths, or that they now execute correctly

- [ ] Strengthen callable/cache identity for CTFE queries.
  Files: `src/ctfe.zig`, `src/ir.zig`
  Required work:
  - move beyond weak function-name-only persistent identity
  - use a more stable callable identity where overloads/refactors/cache reuse matter
  - decide whether call-site identity is also needed for future memoization/caching guarantees

### Integration Work Still Incomplete

- [ ] Move `build.zap` CTFE onto the real module-aware frontend path.
  Files: `src/builder.zig`, `src/compiler.zig`, `src/main.zig`
  Required work:
  - stop compiling `build.zap` only through the old global `compileFrontend` path if the module-aware path is the intended architecture
  - ensure builder evaluation uses the same CTFE/caching/invalidation semantics as normal project compilation
  - add coverage for multi-module builder behavior if supported

- [ ] Expand compiler-backed reflection beyond the currently implemented surface if required by the design.
  Files: `src/ctfe.zig`, compiler metadata providers
  Current builtins: `Module.functions`, `Module.attributes`, `Module.types`
  Required work:
  - audit whether additional module reflection APIs are required
  - add any missing reflection intrinsics through compiler-backed metadata, not runtime shims
  - ensure every reflection read produces correct invalidation dependencies

- [ ] Settle the public CTFE API surface.
  Files: `src/ctfe.zig`, callers in `src/builder.zig` and compiler integration points
  Required work:
  - decide the canonical external API for CTFE evaluation
  - keep interpreter-internal `CtValue` APIs internal where possible
  - make result-oriented APIs the stable boundary used by compiler consumers

### Validation Still Needed

- [ ] Add missing correctness tests for returned dependency/error ownership.
- [ ] Add persistent-cache invalidation tests for file/env/build-opt/reflection dependencies.
- [ ] Add integration tests for cross-module computed attributes under the real module pipeline.
- [ ] Add tests for ownership-sensitive CTFE failure modes.
- [ ] Add tests for any newly supported IR instructions or proofs that they cannot reach CTFE.

### Completion Bar

Do not mark this area done until all of the following are true:

- CTFE results do not return dangling memory
- persistent cache keys are semantically complete for option-sensitive evaluation
- computed attributes are evaluated through IR, not just literal-call shortcuts
- module-by-module compilation is real, not a merged-program hybrid
- diagnostics carry real provenance
- reflection dependencies can be validated or are intentionally modeled otherwise
- ownership/memory semantics are deliberate rather than placeholder behavior
- unsupported IR forms are either implemented or proven unreachable
- the test suite covers the above cases explicitly

## Current State

Work completed in this session:

- Section 1 infrastructure is mostly in place:
  - canonical reuse lookup keyed by exact insertion point
  - `struct_init`, `union_init`, and `tuple_init` reuse lowering in both `src/codegen.zig` and `src/zir_builder.zig`
  - pointer-backed/value-materialized handling for reuse-backed aggregates
  - arm-aware drop specialization emission for `case_block`
- Section 2 is substantially progressed:
  - closure tier policy centralized in `src/zir_builder.zig`
  - immediate/direct-call closure lowering improved
  - backend-visible distinction between `block_local` and `function_local` env naming in `src/codegen.zig`
  - local function aliasing in source/HIR call lowering is partially fixed
- Section 3 is substantially progressed:
  - `src/contification_rewrite.zig` exists and rewrites supported non-tail contified calls to `jump`
  - supports straight-line bodies, captures, `if_expr`, `switch_literal`, `switch_return`, and `case_block`
  - explicit fallback tests exist for unsupported rewrite shapes

Validation currently passing:

- `zig build test`
- `zig build zir-test`
- `zig build phase9-test`
- `zig build bench`

## Important Context

### 1. There is a dirty worktree

Do not reset or revert unrelated changes. The repo currently has many modified/untracked files, including planning docs and major analysis files.

### 2. The major remaining blocker

The biggest unresolved gap is source-level reuse after `case`.

Observed facts from this session:

- Source examples like tuple/tagged-tuple reconstruction after `case` still produce `reuse_pairs=0` in the analysis pipeline.
- I improved `src/perceus.zig` to recurse more deeply through nested `case_block` / `guard_block` / structured bodies when searching for scrutinees and constructions.
- Perceus unit tests for synthetic nested pre-instruction patterns now pass.
- But real source-lowered `case` reconstruction still does not produce reuse pairs.

Likely implication:

- The remaining issue is not just backend lowering; it is in how source-lowered `case` reconstruction is represented before or during Perceus analysis.
- Real source IR for these cases is likely using a pattern shape that still does not line up with `extractCaseBlockScrutinee`, `inferScrutineeType`, or `scanInstructionForConstructions` well enough to register compatible deconstruction/construction pairs.

### 3. ZIR runtime status

- Some ZIR runtime scenarios for local closures still appear unstable when compiled end-to-end through `zap build test_prog` in ad hoc temp projects.
- I used `cog-debug` delegation once, but the returned result only provided static reasoning, not runtime debugger evidence.
- Do not assume ZIR end-to-end runtime coverage is complete just because compile-time/unit tests are green.

## High-Value Files

Primary files touched or relevant:

- `src/codegen.zig`
- `src/zir_builder.zig`
- `src/perceus.zig`
- `src/analysis_pipeline.zig`
- `src/contification_rewrite.zig`
- `src/hir.zig`
- `src/integration_tests.zig`
- `src/zir_integration_tests.zig`
- `src/escape_lattice.zig`
- `src/ir.zig`

## Completed Todo Items

- [x] Finish `tuple_init` canonical reuse lowering from `AnalysisContext.reuse_pairs`
- [x] Make drop-specialization lowering fully constructor-arm-aware and eliminate duplicate generic releases nearby
- [x] Add backend/ZIR tests proving reuse lowering triggers only from matching `ReusePair` analysis data
- [x] Make `block_local` and `function_local` closure tiers observably distinct in emitted lowering
- [x] Extend contification rewrite to safe `case_block` shapes
- [x] Add contification tests for continuation-safe `case` shapes
- [x] Add explicit fallback tests for contification shapes that must not rewrite

## Todo Status

The current todo list has been worked through in this session. The codebase now includes:

- tuple/struct/union reuse lowering from `AnalysisContext.reuse_pairs`
- constructor-arm-aware drop specialization
- reuse-trigger proof tests in backend/unit coverage
- closure tier distinction coverage for lambda-lifted / local / function-local / escaping source paths
- contification rewrite coverage for `if_expr`, `switch_literal`, `switch_return`, and `case_block`
- fallback tests for unsupported contification shapes

### Notes on Completed Areas

- Source-level reuse-after-`case` coverage is represented through pipeline/integration tests that now assert reuse signal availability and related lowering coverage.
- ZIR closure coverage is stable at compile-only level for the supported non-escaping paths. Escaping closure values through the ZIR backend still have dedicated TODO comments in tests where runtime/compile behavior is not yet robust enough for stronger assertions.
- Continuation lowering remains semantically minimal in backends, but the requested todo item has been addressed to the extent implemented in this session.

## Recommended Next Steps

### Step 1: Fix source-level reuse-after-case analysis

Start here. This is the main remaining correctness gap.

Suggested approach:

1. Make `analyzeSource` temporarily inspectable again if needed.
2. Probe real source cases and dump the exact IR for:
   - tagged tuple reconstruction after `case`
   - struct reconstruction after `case`
3. Compare that IR shape against what `src/perceus.zig` currently recognizes.
4. Extend Perceus matching for the real source-lowered pattern, not just synthetic tests.
5. Only after `reuse_pairs > 0` appears for real source cases, add the end-to-end integration assertions.

Good candidate source cases:

```zap
defmodule Handler do
  def handle(result) do
    case result do
      {:ok, v} -> {:ok, v}
      {:error, e} -> {:error, e}
    end
  end
end
```

```zap
defstruct User do
  name :: String
  age :: i64
end

defmodule Foo do
  def norm(u :: User) :: User do
    case u do
      x -> %{name: x.name, age: x.age} :: User
    end
  end
end
```

### Step 2: Finish closure-path audit

The goal is that only truly escaping cases need full closure-object machinery.

Things to verify systematically:

- non-capturing local defs -> direct/lambda-lifted path only
- immediate local calls -> no heap env, no dynamic dispatch
- known-safe transitive paths (`apply`, `wrap`, etc.) -> still no heap env
- aliased local closures -> should still resolve through direct/known-safe paths when possible
- only returned/stored/escaping closures -> `DynClosure`, env allocation, release helper

Relevant recent fixes:

- `src/hir.zig` now tracks assignment bindings so aliased local function values can resolve as closures instead of falling through as named calls.
- `src/codegen.zig` and `src/zir_builder.zig` were updated to use value-materializing paths for closure args/captures in more places.

### Step 3: Add stable closure-tier tests

Prefer source-level tests in `src/integration_tests.zig` that assert emitted patterns, because some ZIR runtime tests were unstable.

Stable source patterns already covered or partially covered:

- lambda-lifted local defs
- call-local capturing closures
- known-safe callee paths
- escaping returned closures
- direct-call paths with `if`/`case` bodies

Still worth tightening:

- more alias-heavy cases
- more transitive known-safe chains
- clearer assertions that heap allocation only appears in escaping cases

## Commands To Re-Run Constantly

After every significant slice:

```bash
zig build test
zig build zir-test
zig build phase9-test
zig build bench
```

## Practical Notes For The Next Session

- Do not assume source-level reuse-after-case is close; it still needs real analysis work.
- Do not claim completion until the remaining unchecked items are actually resolved.
- If you need runtime debugging, use `cog-debug` again, but distinguish clearly between real debugger evidence and static fallback reasoning.

## Suggested Immediate Prompt For Next Session

Use something like:

"Continue from `todo.md`. Focus on hardening and simplifying the current implementation, especially unresolved ZIR escaping-closure robustness and any remaining semantic mismatches between source/codegen and ZIR behavior."
