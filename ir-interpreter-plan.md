# IR Interpreter Plan

> Research-grade, production-quality compile-time execution for Zap.
>
> This plan replaces the earlier "small IR interpreter + pipeline wiring"
> approach with a design that matches Zap's actual compiler architecture and
> borrows the strongest ideas from Rust const-eval/Miri, Zig comptime,
> Clang's constexpr interpreter, and modern incremental build systems.

## Goals

- Execute selected Zap code at compile time with deterministic, target-aware semantics
- Support computed attributes and eventually `build.zap` execution
- Integrate with Zap's current IR, ownership model, and structured control flow
- Allow controlled compile-time file/env access with correct invalidation
- Provide strong diagnostics, bounded execution, and a path to incremental caching

## Non-goals for v1

- Full runtime equivalence for every Zap feature
- Native/JIT execution of compile-time code
- Ambient host access (`cwd`, time, random, subprocesses, network)
- Full per-module frontend compilation refactor before interpreter value is proven
- Full Miri-grade pointer provenance and memory-model fidelity on day one

## Current Reality

Zap is not yet truly compiling modules one-by-one, but CTFE is operational.

- File discovery is dependency-aware in `src/discovery.zig` with topological ordering
- `main.zig` still concatenates discovered files into one `merged_source`
- `compilePerFile` chains `collectAll` → `compileFiles` (still whole-program under the hood)
- `compileModuleByModule` exists as experimental per-module pipeline but is not the default path
- CTFE runs at Phase 7.5 in `compileFrontend`, after IR lowering, before escape analysis
- `evaluateComputedAttributes` / `evaluateModuleAttributesInOrder` store results on scope graph
- `build.zap` is evaluated via CTFE (`builder.ctfeManifest`) — the old AST extraction code has been removed
- `constValueToExpr` bridges CTFE results back to AST for attribute substitution
- Persistent cache stores results to disk with full dependency tracking and validation
- `-Dkey=value` build options are available via `System.get_build_opt/1` at compile time

The per-module CTFE→compile loop (compile A, CTFE A's exports, then compile B) is the
remaining architectural gap. Currently CTFE runs after all modules are compiled to IR.

## Design Principles

### 1. Interpret Zap IR, not the AST

The long-term execution engine should run over typed or nearly-typed Zap IR.
AST interpretation is useful for bridges and extraction hacks, but not as the
main production engine.

### 2. Use an abstract machine, not host execution

Compile-time execution must run inside a compiler-owned machine with explicit:

- stack frames
- locals
- symbolic allocations
- typed values
- capability-gated effects
- step and recursion budgets

Do not treat host pointers, host layout, or host runtime behavior as semantic
truth.

### 3. Be hermetic by default

Compile-time code is pure unless explicit capabilities are granted.

- file reads must go through interpreter intrinsics
- env reads must go through interpreter intrinsics
- every effect must be tracked for invalidation
- absent files and absent env vars must also become dependencies

### 4. Split cheap constant folding from full CTFE

Zap should keep a cheap local constant folder for trivial expressions. The IR
 interpreter is for the harder cases: function calls, structured control flow,
 data construction, and compiler-visible compile-time evaluation.

### 5. Optimize for correctness, diagnostics, and cacheability first

Interpreter performance matters, but correctness and determinism matter more.
Specialization, bytecode compilation, or hot-path optimization can come later.

## Target Execution Model

### Values

Use two related but distinct value layers.

#### `CtValue`

Interpreter-time values used while executing Zap IR.

Expected variants:

- integers and floats with target-aware semantics
- strings
- atoms
- bool
- nil
- tuples
- lists
- maps
- structs
- unions/enums
- optionals
- closures
- symbolic references/allocations where needed

`CtValue` is not just a pretty tagged union for literals. It is the semantic
execution value domain.

#### `ConstValue`

Stable compiler-facing results exported from CTFE.

This is what downstream compiler phases and caches should consume. It should be
detached from ephemeral interpreter state.

### Memory

Use a small symbolic memory model.

For v1 this can be simpler than Miri, but it must still avoid raw host memory as
the semantic model.

Recommended shape:

- `AllocId` for compile-time allocations
- allocation records for aggregate storage
- symbolic references as `AllocId + path/offset`
- immutable values where possible
- copy-on-write or fresh-allocation semantics for updates like `field_set`

The first version does not need full provenance checking, but it must preserve a
clear separation between interpreter memory and host memory.

### Frames

Frames need more than the original plan assumed.

Each frame should carry:

- function identity
- local storage
- capture storage if closure calls are enabled
- evaluation provenance (source span / caller trace)
- step budget linkage

The IR currently does not expose a `local_count`, so the interpreter plan must
either:

- add local-count metadata to `ir.Function`, or
- compute max-local usage by scanning instructions recursively

Adding metadata is preferred.

## IR Subset Strategy

Do not start from a generic CFG/SSA interpreter. Start from the IR Zap actually
emits today.

### Phase 1 execution subset

Support these first:

- constants: `const_int`, `const_float`, `const_string`, `const_bool`, `const_atom`, `const_nil`
- locals: `local_get`, `local_set`, `param_get`
- arithmetic and logic: `binary_op`, `unary_op`
- structured calls: `call_direct`, `call_named`, `call_builtin`
- structured control: `if_expr`, `switch_literal`, `switch_return`, `union_switch_return`, `guard_block`
- aggregates: `tuple_init`, `list_init`, `map_init`, `struct_init`, `union_init`, `enum_literal`
- access: `field_get`, `index_get`, `list_get`, `list_len_check`, `optional_unwrap`
- return: `ret`

### Phase 2 execution subset

Add:

- `case_block`
- `call_closure`
- `make_closure`, `capture_get`
- `call_dispatch`
- binary pattern instructions

### Phase 3 execution subset

Add lower-priority or analysis-sensitive semantics:

- `move_value`, `share_value`
- `retain`, `release`
- `reset`, `reuse_alloc`
- CFG-ish leftovers like `jump`, `cond_branch`, `phi` if still needed by emitted IR

The interpreter should implement the structured subset first because that is what
Zap lowering currently favors.

## Effects and Capabilities

Compile-time effects must be mediated through explicit intrinsics.

### Capability model

Recommended capability tiers:

- `pure`
- `read_file`
- `read_env`
- `reflect_module`

Later, if ever justified:

- `read_dir`

Not for v1:

- write access
- subprocess execution
- network access
- clock/random access

### Dependency manifest

Every compile-time evaluation should return both a value and a manifest.

```zig
pub const CtDependency = union(enum) {
    file: struct {
        path: []const u8,
        content_hash: u64,
    },
    env_var: struct {
        name: []const u8,
        value_hash: u64,
        present: bool,
    },
    reflected_module: struct {
        module_name: []const u8,
        interface_hash: u64,
    },
};

pub const CtEvalResult = struct {
    value: ConstValue,
    dependencies: []const CtDependency,
    result_hash: u64,
};
```

This is stronger than a raw list of accessed resources and is suitable for
incremental invalidation.

## Caching Model

Use query-style memoization.

### Cache key inputs

At minimum:

- stable callee identity
- normalized argument values
- target triple / optimize mode / relevant compile options
- capability set
- compiler/interpreter schema version

For persisted caching, include dependency validation using the manifest.

### Scope of caching

Two levels are useful:

- in-process memoization for repeated compile-time calls in one build
- persistent cache entries for repeated builds when manifests still validate

## Compiler Integration Strategy

## Phase 0: Substrate and constraints — COMPLETE

Before building the interpreter itself:

- add stable identities for compile-time call sites and callable functions
- add `local_count` or equivalent IR metadata
- define `CtValue`, `ConstValue`, dependency manifest, and capability types
- define the exact v1 IR execution subset
- add a dedicated compile-time diagnostics stack format

This is prerequisite work.

## Phase 1: Attribute bridge — COMPLETE

Keep current AST substitution, but make it capable of consuming computed values.

Implemented:

- `scope.Attribute` has `computed_value: ?ctfe.ConstValue` to store CTFE results
- `attr_substitute.zig` prefers `computed_value` over raw AST value when substituting
- `constValueToExpr` bridges CTFE results back to AST for attribute substitution
  (production bridge between CTFE and AST-level substitution, in active use)

## Phase 2: Interpreter MVP — COMPLETE

Create `src/ctfe.zig` or `src/ir_interpreter.zig` with:

- abstract machine state
- function registry
- evaluator for the v1 structured IR subset
- step and recursion budgets
- stack-trace diagnostics
- in-process memoization

Public API should be result-oriented:

```zig
pub fn evalFunction(
    self: *Interpreter,
    callee: FunctionHandle,
    args: []const ConstValue,
    caps: CapabilitySet,
) !CtEvalResult
```

Prefer stable function handles over string-only lookup.

## Phase 3: Hook into computed attributes — COMPLETE

After global parse/collect, but before current attribute substitution:

- identify computed attributes
- evaluate them through CTFE when legal
- store `ConstValue` results
- reify to AST only where legacy substitution still requires it

This phase should work even while the rest of the compiler remains globally
compiled.

## Phase 4: Replace `build.zap` AST extraction — COMPLETE

Current `build.zap` handling is an AST bridge. Replace it with CTFE execution of
builder code once the interpreter supports the required subset.

This should happen before true per-module frontend refactoring, because it gives
high-value real-world pressure on the interpreter.

## Phase 5: True module-by-module compilation — NOT STARTED

Only after CTFE is already useful:

- split macro expansion, desugaring, typechecking, HIR, and IR lowering into
  real per-module units
- use discovery topo order as the actual compilation order
- register compiled module interfaces and CTFE-visible exports incrementally

This is where the original plan's dependency-ordered execution becomes real.

## Phase 6: Reflection and `Module.*` — PARTIAL

Implement module reflection as interpreter intrinsics backed by compiler data,
not as ordinary runtime library functions.

Reflection reads must produce dependency edges on module interfaces.

## Phase 7: Advanced semantics — PARTIAL

Add:

- closures
- ownership-sensitive execution semantics
- ARC-sensitive correctness checks
- richer binary and pattern-matching support
- persistent CTFE cache

## `build.zap` as the first proving ground

`build.zap` is the best first production consumer because:

- it already wants compile-time evaluation
- the current AST extraction path is explicitly transitional
- it exercises attributes, structs, case analysis, and controlled host access
- it is high value but bounded in scope

The interpreter should reach `build.zap` viability before trying to support the
entire language at compile time.

## Diagnostics

Research-grade quality depends heavily on diagnostics.

Every CTFE error should report:

- what was being evaluated
- why it had to be compile-time
- the CTFE call stack
- the exact failing operation
- the capability or dependency involved, if effect-related

Examples:

```text
error: compile-time evaluation exceeded step limit
  while evaluating `Config.generate/0`
  called from attribute `@config` in `App`
  help: possible infinite recursion or unexpectedly large compile-time loop
```

```text
error: compile-time file access not permitted
  attempted `File.read("secrets.txt")`
  while evaluating `Builder.manifest/1`
  help: declare `read_file` capability or remove compile-time file access
```

## Testing Strategy

### Unit tests

Interpreter-only tests for:

- constants and arithmetic
- structured control flow
- function calls and memoization
- data construction and access
- step and recursion budgets
- capability enforcement
- dependency manifest generation

### Differential tests

Where possible:

- compare literal-only CTFE with the cheap constant folder
- compare legacy AST manifest extraction with interpreter-backed `build.zap`
- compare interpreter results across repeated runs with cache hits/misses

### Integration tests

- computed attributes across modules
- builder manifest execution
- invalidation on file/env change
- privacy and dependency-order enforcement via discovery graph

## Recommended File-Level Changes

Expected major touch points:

- `src/compiler.zig`
  - CTFE integration hooks
  - future real per-module pipeline split
- `src/ir.zig`
  - local-count or metadata additions
  - stable callable identity support if needed
- `src/attr_substitute.zig`
  - computed-value integration and broader coverage
- `src/scope.zig`
  - attribute storage expansion for computed constants
- `src/main.zig`
  - build cache integration for CTFE manifests
- `src/builder.zig`
  - replace AST manifest extraction with CTFE-backed execution
- `src/discovery.zig`
  - reused for dependency ordering and privacy boundaries
- new file:
  - `src/ctfe.zig` or `src/ir_interpreter.zig`

## Implementation Order

```text
Phase 0  Substrate: values, identities, metadata, diagnostics scaffold
Phase 1  Attribute bridge: computed values + AST reification path
Phase 2  Interpreter MVP: structured IR subset, budgets, memoization
Phase 3  Computed attributes: actual compiler integration
Phase 4  Builder execution: replace AST manifest extraction
Phase 5  True per-module frontend compilation
Phase 6  Reflection intrinsics and module metadata queries
Phase 7  Advanced semantics: closures, ownership, ARC-sensitive behavior, persistent cache
```

## Final Recommendation

The best production-quality implementation for Zap is:

- not an AST interpreter
- not a tiny literal evaluator bolted onto the side
- not backend/JIT execution of compile-time code

It is a typed Zap-IR abstract machine with:

- deterministic semantics
- explicit effect capabilities
- dependency-tracked results
- query-style memoization
- staged integration into the existing compiler

That is the approach most aligned with both the research and Zap's current code.

## Known Limitations

### Per-module CTFE→compile loop

CTFE runs at Phase 7.5 in `compileFrontend()` — after ALL modules are compiled to
IR. This means computed attributes from module A cannot influence macro expansion or
type checking of module B in the same compilation.

`compileModuleByModule()` in `compiler.zig` has the per-module loop structure (extract
single module AST, per-module macro/desugar/typecheck/HIR/IR), but does not integrate
CTFE between modules. The path to true per-module CTFE:

1. After each module's IR is generated in the loop, run `evaluateComputedAttributes()`
   for that module and store results on the scope graph
2. Subsequent modules see earlier modules' computed values during attribute substitution
3. Wire `compileModuleByModule()` into `main.zig` when `module_order` is available
4. Prerequisites: TypeChecker and HirBuilder must resolve cross-module types via shared
   scope graph; `extractModuleProgram()` must include dependent module type declarations;
   IR function ID merge must handle overlapping IDs (partially implemented with offsets)

### Reflected module cache validation

`validateDependencies()` conservatively invalidates any `reflected_module` dependency
because full re-validation would require the scope graph at cache-load time. This means
CTFE results that use `Module.functions/attributes/types` builtins are never cached
across builds. This is correct but not optimal.

### Ownership-sensitive execution

ARC operations (`retain`, `release`) are no-ops during CTFE. `move_value` zeros the
source local but does not enforce use-after-move at the interpreter level. Full
ownership-sensitive execution semantics are deferred to Phase 7.
