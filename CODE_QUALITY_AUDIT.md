# Zap Compiler & Zig Fork — Comprehensive Code Quality Audit

**Date:** 2026-04-26
**Scope:** Full audit of `/Users/bcardarella/projects/zap/src/**` and `/Users/bcardarella/projects/zig/src/{zir_api,zir_builder,Sema}.zig` for duplication, hacks, hardcoded compiler knowledge, and parallel implementations.
**Method:** 17 parallel investigation agents, each focused on a specific code area, applying the project's `CLAUDE.md` standards.

**Total findings:** ~280 individual issues across 18 files.

---

## Executive Summary

The compiler is functionally working (586/585 tests passing) but has accumulated significant architectural debt across its lifetime. The audit identified five systemic patterns that account for the majority of issues:

1. **Hardcoded Zap library names in Zig source** — direct violation of CLAUDE.md's most-emphasized rule. Found in 11 files with hundreds of literal string occurrences (`"List"`, `"Map"`, `"Range"`, `"Kernel"`, `"Zest"`, `"Prelude"`, `"ArcRuntime"`, `"to_string"`, `"begin_test"`, etc.).
2. **`@native` mechanism is documented but functionally dead** — README claims it's the canonical bridge to runtime functions; in reality `:zig.Struct.fn(args)` is the only working mechanism. Five parallel runtime-call paths coexist.
3. **Two-track pipeline architecture** — `compileForCtfe` and `compileStructByStruct` have drifted into largely-duplicate ~250-line pipelines with subtly different invariants. Two-collector-pass and re-registration loops paper over stale-AST-pointer fragility.
4. **Parallel implementations of the same concept** — many fundamental operations have 3-5 implementations: capture detection (4 paths), call dispatch (3 paths), tuple emission (3 paths), return-type setters (7 variants), AST walkers (8+ implementations), name lookup (3 different scope-walk semantics).
5. **Dead/abandoned code masquerading as live infrastructure** — `escape_analysis.zig` (1100 lines, zero callers), 70 of 159 fork C-ABI exports unused (44%), 8 of 13 macro_eval builtins unreferenced, dead `MonomorphRegistry` (write-only), dead `ReuseAlloc`/`Phi`/`Reset` IR instructions, dead `compileFile`/`cloneFunctionWithOffset` machinery.

The highest single concentration of CLAUDE.md violations is in `zir_builder.zig` (Zap-side) and `macro_eval.zig`, with `zir_api.zig` (fork) also carrying substantial cleanup debt.

---

## Severity Tiers

### Tier 1: Critical (silent correctness bugs)

These are issues where the current code can produce wrong output, leak memory, or fail silently in ways that could only be caught by accidentally exercising the right input.

| # | Issue | Location | Impact |
|---|-------|----------|--------|
| C1 | `parent_assignment_bindings` fabricates `binding_id = 0` | hir.zig:2277-2295 | Capture lookup uses whichever binding happens to live at index 0; closure-of-closure with parent-assignment captures gets wrong type/ownership |
| C2 | `current_map_bindings` declared, populated, never read | hir.zig:1676, 1734, 3151-3170 | Map pattern bindings silently fail for nested closures; not saved/restored in buildFunctionGroup; leaked in deinit |
| C3 | Impl functions registered twice; second `collectFunction` clobbers `clause.meta.scope_id` | collector.zig:373-389 vs 445-453 | Impl-scope function lookup orphaned; two `FunctionFamily` entries pointing at same clauses |
| C4 | `__try` variant generation silently omits `map_bindings` | ir.zig:1438-1456 vs 1156-1177 | `~>` on map-pattern functions produces broken try-variant |
| C5 | ARC optimizer's `identifySkippableValues` inner loop unconditionally `break;`s on first iteration | arc_optimizer.zig:91-117 | "Find matching escape state" never matches anything; relies on luck |
| C6 | `setOptionalReturnType` overloads `error_union_ret_type_inst` | fork zir_builder.zig:2473-2480 | `error!?T` and `?error!T` cannot be expressed; second setter silently clobbers first |
| C7 | `analysisFunctionIdByName` heuristic suffix-matching on `__` characters | types.zig:1505-1521 | Function lookup misclassifies any name containing `__` correctly (parses scoring by char position) |
| C8 | `_emit_set_runtime_safety` returns `u32` but only ever `0` or `0xFFFFFFFF` | fork zir_api.zig:1927 | Wrong type signature; callers checking `>= 0` for success silently broken |
| C9 | `setTupleReturnType` doesn't clear other return-type setter state | fork zir_builder.zig:2068+ | Calling two setters on same FuncBody silently leaves stale state; first wins in endFunction's switch order |
| C10 | `findClosureTargetInInstrsDepth` 32-frame depth limit silently aborts to dyn dispatch | zir_builder.zig:2108-2164 | Deeply-nested code degrades to slow path with no diagnostic |
| C11 | Empty list/map literals default to `[i64]` / `Map(Atom,i64)` in monomorphizer | monomorphize.zig:436-450 | Calls passing `[]` to `[String]` param silently produce wrong specialization |
| C12 | `collectCapturedBindingsFromExpr` doesn't recurse into anonymous_function | types.zig:1817 | Closure-of-closure borrow-leak validation hole; soundness gap |
| C13 | `buildErrorHandlerExpr` discards all but first case clause | hir.zig:4340-4374 | Multi-clause `~>` error handlers silently drop arms; comment admits "For now" |
| C14 | Sema-side patches weaken stock invariants (`unreachable` → `runtime fail`, `assert(.pointer)` → branch) with fake source locations | fork Sema.zig:6090, 25853 | Affects all Zig users of fork; misleading diagnostics from `@enumFromInt(0)` source location |
| C15 | Pattern-matching debug allocator fill bytes (`0x5555...`, `0xaaaa...`) for "uninitialized memory" detection | fork zir_api.zig:496 | Reads undefined memory; works only by coincidence; will fail on non-debug allocator |
| C16 | Assignment LHS destructuring silently dropped — `{a, b} = pair` parses, type-checks, lowers to HIR but extracts no bindings | hir.zig:3413-3419, types.zig:2715-2722 | Tuple/list/struct/map destructure on `=` LHS produces broken IR; only `.bind` patterns get `AssignmentBinding` |
| C17 | `compileConstructorColumn` missing struct_match and map_match cases — silently treated as wildcards | hir.zig:786-823 | Multi-clause function dispatching on `%User{}` vs `%Admin{}` patterns compiles as if both were wildcards; map patterns have no support at all |
| C18 | case_expr binding processor only handles `.bind`, `.tuple`, `.binary_match` — silently drops list/struct/map/list_cons/pin | hir.zig:3851-3888 | `case x { %User{name: n} -> n }` fails to bind `n` |
| C19 | `compileBinaryCheck` keeps only FIRST clause's segments via `break;` | hir.zig:1497 | Multi-clause binary dispatch bypasses matrix entirely, hand-rolled in lowerDecisionTreeForDispatch with dead `has_prefix_dispatch` flag |

### Tier 2: Major architectural issues (CLAUDE.md rule violations)

Every item here violates one or more of the explicit project rules: "no hardcoded Zap struct names in compiler", "no shortcuts/hacks", "Zap features must be implemented in Zap".

#### Hardcoded Zap library names in compiler

| Code | Where | Notes |
|------|-------|-------|
| `"Kernel"` | discovery.zig:115, collector.zig:21-60, compiler.zig:344-472, desugar.zig:212 | Auto-import bootstrapping in 3 files |
| `"List"` | types.zig:364, hir.zig:4405, monomorphize.zig:1128, zir_builder.zig (15+ sites), ir.zig:3804+ | Container, type, dispatch, runtime cell |
| `"Map"` | types.zig:365, hir.zig:4400, desugar.zig:351, monomorphize.zig:1129, zir_builder.zig (10+ sites), ir.zig:3804 | Same plus `MapAtomInt`, `MapOf`, `MapNested:` encoding |
| `"Range"` | hir.zig:4020, types.zig:3208, ir.zig:3288/3614 | `.in_range` opcode hardcoded; `Range.start/.end/.step` desugared in HIR |
| `"String"` | parser.zig:3780, types.zig:330+, desugar.zig:1099+, hir.zig:2531-5162, macro.zig:1824, macro_eval.zig:826/877, zir_builder.zig:2587 | Type primitive plus runtime `String.concat`/`length`/`byte_at` |
| `"Enumerable"` | desugar.zig:1275 | Single literal — protocol name in macro expansion |
| `"Zest"` | runtime.zig:1886-2020, macro_eval.zig (entire `build_test_*` family), zir_builder.zig:951/964 | Test framework name in 3 places |
| `"Zap.Env/Manifest/Dep/Builder"` | zir_builder.zig:716+, doc_generator.zig:80-83 | Build system struct names |
| `"Inspect"` / `"to_string"` | desugar.zig:34/949, resolver.zig:488 | String interpolation hardcodes `Kernel.to_string` |
| `"Ok"` / variant names | types.zig:3283, zir_builder.zig:5504 | `~>` operator hardcodes Result variant name |
| `"Prelude"` | zir_builder.zig (8+ sites) | Runtime sub-namespace |
| `"ArcRuntime"` | zir_builder.zig (8+ sites) | ARC ops route through hardcoded chain |
| `"BinaryHelpers"` | zir_builder.zig:4360+ | Per-encoding hardcoded function-name table |
| `"BuilderRuntime"` | zir_builder.zig:1218+ | Builder mode entry point |

#### `@native` is documented but dead

- README documents `@native = "Struct.function"` as the canonical mechanism (README.md:558-577).
- **Zero `.zap` files in `lib/` use `@native`.** All bindings use `:zig.Struct.function(args)` calls.
- **No code in `src/*.zig` reads, registers, or routes via the `@native` attribute.** Only vestigial comments exist.
- Five parallel runtime-call mechanisms coexist:
  1. `:zig.X.Y(args)` → HIR `CallTarget.builtin` → IR `call_builtin` → ZIR via `Struct.function` parsing
  2. `@native = "X.Y"` (documented, non-functional)
  3. Direct `zir_builder_emit_import("zap_runtime", 11)` + `field_val` chains (37+ sites)
  4. Raw ZIR primitive emission (`addwrap`/`subwrap`/`cmp_*` for primitive arithmetic — bypasses `Arithmetic` impl entirely)
  5. `@import("std").mem.eql` for string equality

The `Arithmetic for Integer` and `Comparator for Integer` impls in `lib/integer/*.zap` are **dead code** for primitive `i64`/`f64` operations.

#### Two-track pipeline architecture

- `compileForCtfe` (compiler.zig:525-773) and `compileStructByStruct` (compiler.zig:1057-1178) duplicate the entire post-collect pipeline.
- The CTFE path has a *second* type-check pass (compiler.zig:738-742) the per-struct path doesn't.
- Per-struct path *intentionally skips* `checkUnusedBindings` (1018-1024) due to false positives in shared-scope-graph mode.
- Three CTFE evaluator entry points exist: `evaluateStructAttributesInOrder`, `evaluateComputedAttributes`, `evaluateComputedAttributesForStruct` — each duplicating ~50 lines of interpreter setup; the ordered variant ends with a fallback whole-program pass.
- Two-collector-pass pattern (lines 346-403, 463-506) workarounds stale AST-node pointers after macro expansion. Re-registration loops at 584-604 and 618-639 cover the same ground at the project level.
- `@constCast` of immutable slices in 4+ places to back-patch analysis results.

### Tier 3: Significant duplication / parallel implementations

| Concept | # of implementations | Files |
|---------|----------------------|-------|
| "Is this a closure?" detection | 3 booleans + 1 helper | ir.zig (`is_closure`), zir_builder.zig (`current_function_is_closure`), analysis_pipeline.zig (defensive `or`) |
| Capture computation | 4 algorithms | hir.zig (canonical + parent-assignment), types.zig (`collectCapturedBindings*`, `capturedBindingsForFunctionDecl`), escape_analysis.zig (`summarizeClosure`, dead) |
| Generic call dispatch | 3 parallel pipelines | types.zig:3501-3568 (bare-name) and 3653-3717 (struct-qualified) and monomorphize.zig:389-453 — all do the same `containsTypeVars + unify + applyToType` dance |
| Tuple-decl emission | 3 + 1 = 4 paths | fork zir_api: `emit_tuple_decl`, `_body`, `_untracked`, plus `_with_body` (the new one); plus internal `mapTupleElementType`/`emitBodyLocalTupleType`/`emitTypeRef` cluster |
| Return-type setters on FuncBody | 7 variants + 8 mutually-exclusive state fields | fork zir_builder.zig — `setTupleReturnType`, `_with_body`, `setUnionReturnType`, `setErrorUnionReturnType`, `setOptionalReturnType`, `setImportedReturnType`, `setDeclValReturnType`, `setCustomReturnType` |
| `containsTypeVar(s)` | 2 implementations with contradicting protocol_constraint semantics | monomorphize.zig:1033-1067 vs types.zig:502-540 |
| Name mangling for monomorphized fns | 2 schemes producing different output | monomorphize.zig:1081-1137 vs types.zig:916-1000 (`MonomorphRegistry.generateNameSuffix`) |
| AST instruction walker | 8+ independent re-implementations | analysis_pipeline.zig (×3), lambda_sets.zig (×4), interprocedural.zig, region_solver.zig (×3), perceus.zig (×2), generalized_escape.zig — none share infrastructure |
| Worklist / fixpoint engine | 4 different semantics | generalized_escape.zig (`orderedRemove(0)`), lambda_sets.zig (re-walks per pop, quadratic), region_solver.zig (`while changed`), escape_analysis.zig (dead, also `while changed`) |
| `findStructScope*` lookup | 1 canonical + 2 shadows + 14+ inline `for` loops | scope.zig (canonical), ctfe.zig (×2), and inline scans throughout types.zig and ctfe.zig |
| `findClosureEscape` | 2 implementations | types.zig:1542-1597 vs analysis_pipeline.zig:474-522 |
| Decision-tree lowering | 2 × ~600 lines, ~95% identical | ir.zig:2594-2834 (Case) vs 2837-3224 (Dispatch) |
| Block lowering | 2 implementations with diverging type-propagation | ir.zig:3374-3410 (`lowerBlock`) vs 3961-4001 (lowerExpr `.block`) |
| Pattern-binding extraction | 2 walkers covering different pattern kinds | hir.zig:3033-3170 (clause params: 7 kinds) vs hir.zig:3849-3888 (case arms: 3 kinds — silently drops struct/list/list_cons/map) |
| `resolveBindingType` vs `buildBindingReference` | 2 walks of overlapping binding state | hir.zig:1765-1809 vs 2226-2311 |
| `currentScope()` resolution | inlined 13× | hir.zig (orelse-orelse-orelse pattern at 13 sites) |
| StructName-to-string serialization | 3 different separators | hir.zig:2779 (`.`), hir.zig:4619 (`_`), hir.zig:4084-4088 inline (`.`) |
| Diagnostic emission "show_progress + emit + return error" pattern | copy-pasted 17× | compiler.zig (8× in compileForCtfe, 9× in collectAllFromUnits) |
| Borrowed-capture validation message | 4 sites construct identical error strings | types.zig:1276, 1779, 2642, 3434 |

### Tier 4: Dead code

| Item | Lines | Confidence |
|------|-------|------------|
| `escape_analysis.zig` entire file | ~1100 | Zero callers (only test imports in root.zig) |
| Fork zir_api math/SIMD wrappers (`emit_sqrt`, `_sin`, etc. ×30) | ~300 | Zero externs in Zap |
| Fork zir_api type-introspection wrappers (`emit_size_of` etc. ×12) | ~120 | Zero externs in Zap |
| Fork zir_api type-reification wrappers (`reify_int` etc. ×6) | ~80 | Zero externs in Zap |
| `desugarErrorPipe`/`flattenPipeChain`/`buildErrorHandler`/`wrapInErrorCheck`/`replacePlaceholder` | ~200 | Calls undefined `desugarPipe`; never invoked |
| `compileFile` in compiler.zig | 13 | Doc claims to delegate to nonexistent `compileFiles` |
| `cloneFunctionWithOffset` + helpers | ~110 | Comment in `compileStructByStruct` says "no cloneWithOffset needed"; only test consumes it |
| `compileStructTask` + `Io.Group` parallel infrastructure | ~50 | `_ = pio;` discard at line 1070 confirms unused |
| `MonomorphRegistry` in types.zig | ~200 | Recorded twice but never read; `getInstantiationsForFamily` has no callers |
| 8 of 13 macro_eval builtins | ~400 | `make_fn_decl`, `find_setup`, `find_teardown`, `inject_setup`, `defstruct`, `defenum`, `defunion`, `split_words`, `slugify`, `string_concat`, `is_tuple`, `is_list`, `is_atom` — all have no `.zap` callers |
| Dead IR instructions (`cond_branch`, `if_expr`, `branch`, `phi`, `reset`, `reuse_alloc`, `jump`) | ~80 | Defined but never produced |
| Dead IR-builder fields (`default_arg_wrappers`, `group_id_to_name`, `next_label`, `next_function_id`) | ~30 | Initialized but never read |
| Dead ZIR builder fields (`cached_list_type_ref`) | ~5 | Field reset to 0 but never assigned non-zero |
| Dead `direct_capture_params` / `tier` / `stack_env` / `storage_scope` / `needs_closure_object` | ~20 (× 5 branches that read them) | All `closure_lowering_for_tier` paths set `direct_capture_params = false` |
| `registerFunctionGroup` + `buildGroupClauses` in HIR | ~40 | Cog reports zero callers |
| `inherited_iter` loop in `buildStruct` | ~30 | Always `continue`s — entire body dead |
| `setErrorUnionReturnType` C-ABI export and Zap-side declaration | ~25 | Zero externs |
| Stale `// Fourth pass` comment | 1 | There are only 2 passes |

### Tier 5: Hardcoded conventions / smells

| Item | Where |
|------|-------|
| `__anon_fn_` prefix detection (string match instead of AST flag) | parser.zig:2317, types.zig:2483 |
| `__for_` prefix detection (synthetic helper marker) | desugar.zig:1089/1264, types.zig:2655-2670 |
| `__try` suffix detection | zir_builder.zig:1808 |
| `__main__` substring sniffing for entry detection | zir_builder.zig:1750-1751 |
| `__Struct__` prefix demangling | ir.zig:4262, zir_builder.zig:2723 (different rules in each) |
| Hardcoded `?` and `!` suffix validation in `buildFunctionGroup` | hir.zig:2799-2834 |
| `ctx` variable name hardcoded in test setup expansion | macro_eval.zig:739, 927 |
| `test_` prefix and slugify rules in macro_eval | macro_eval.zig:851-865 |
| Hardcoded `"ok"` and `"."` test-tracking literals | macro_eval.zig:941, 953, 980, 990 |
| `Test.` struct prefix enforcement | main.zig:1110-1138 |
| `lib/zest/` directory probe | main.zig:280-283 |
| `manifest`/`__manifest__1` name patterns in builder | builder.zig:184-194 |
| Magic number `next_try_id = 10000` | ir.zig:825 (will collide silently if program has ≥10000 functions) |
| Magic depth limit 32 in alias chasing | analysis_pipeline.zig:648, contification_rewrite.zig:136 |
| Magic safety limit `transitive_iterations > 10` in monomorphizer | monomorphize.zig:99-126 |
| `0xFFFFFFFF` literal used 349 times in fork zir_api | (file-level constant should exist) |
| Magic "struct name = `top`" used as synthetic top-level marker | compiler.zig:1152-1166 (CTFE silently no-ops for top-level functions) |
| Substring-match `unit.source` against struct name to map struct→file | compiler.zig:1316 |
| `interner.lookupExisting("run") and ("String")` to decide whether to synthesize `run()` | hir.zig:2511-2538 (depends on coincidental interner state) |

---

## Findings by file (per-agent reports)

### Zap-side: `src/types.zig` — 23 findings
**Most critical:** `inferCall` has two parallel ~340-line dispatch pipelines (bare-name vs struct-qualified), each independently rebuilding `SubstitutionMap` + unify + applyToType. Same for monomorphic call paths.

Other top issues:
- `analysisFunctionByDecl` re-walks `program.functions` after `analysisFunctionIdByName` already did
- 3 duplicate "literal pattern → type" switches across `resolveFamilySignature`, `literalType`, `checkFunctionClause`
- 5 separate AST walkers covering overlapping expression sets with diverging coverage
- `Ownership` no-op identity-mapping switch in 3 places (and `recordBindingQualifiedType` maps to itself)
- Builtin type names hardcoded as 18-element string arrays in 2 places
- `typeToString` and `typeIdToMangledName` are parallel name tables (3 synchronized tables to update for each new builtin)
- Hardcoded `"Range"`, `"Map"`, `"List"`, `"Ok"`, `"__"`-prefix strings as "is generated" heuristic
- `defaultOwnershipForType` is a binary opaque-vs-other check disguised as an extension point that's not used anywhere

### Zap-side: `src/hir.zig` — 25 findings
**Most critical:** `current_map_bindings` field is declared, populated by buildClause, but **never consulted by `buildBindingReference`** (it walks 8 binding lists, omits maps), **never saved/restored in buildFunctionGroup**, **never deinited**. Map pattern bindings silently broken in nested closures. Also `parent_assignment_bindings` fabricates `binding_id = 0` (collides with real binding 0).

Other top issues:
- `resolveBindingType` and `buildBindingReference` walk overlapping but inconsistent state with different lookup orders
- `current_param_names` linear scan duplicated 5× for "is parameter?" check
- 4 near-identical `resolveFunction*ReturnType*` functions
- `resolveFunctionParamOwnerships` and `resolveFunctionParamTypes` are 95% identical
- `current_clause_scope orelse current_struct_scope orelse prelude_scope` repeated 13×
- Hardcoded Range field desugaring (`"start"`, `"end"`, `"step"`) in HIR
- Hardcoded `"Map"`, `"List"`, `:zig` atom, `"Arithmetic"`/`"Comparator"`, `"raise"`, `"!"`/`"?"` suffix detection
- `"run"`/`"String"` interner-scan hack for struct-level expression synthesis
- `buildErrorHandlerExpr` discards all but first case clause (`_ = scrutinee; _ = err_name;` placeholder)
- 3 different `StructName.toString` formats with different separators
- 2 protocol-call dispatch paths (binary op vs struct call) duplicate lookup logic

### Zap-side: `src/desugar.zig` — 21 findings
**Most critical:** ~200 lines of dead `desugarErrorPipe`/`flattenPipeChain`/`buildErrorHandler` chain that calls a `desugarPipe` function which doesn't exist (would be a compile error if reachable).

Other top issues:
- `desugarForString` is the missing sibling of the for-comp fix — should be replaced with `Enumerable for String` impl, eliminating ~155 lines of hardcoded `String.length`/`byte_at` desugaring
- Map-update `%{m | k:v}` desugar hardcodes `Map.put` chains
- `desugarTopItem` doesn't recurse into `impl_decl`/`priv_impl_decl` — impl bodies escape desugaring entirely (latent bug)
- Top-level structs processed twice (in `program.structs` AND `program.top_items`)
- `findStructDecl` linear-scan fallback masks bug in `resolveTypeByName`
- Synthesized AST nodes lose source spans (everything zero-spanned)
- Visibility encoded twice on for-comp helpers
- `collectAllStructFields` swallows OOM and returns wrong data
- Inconsistent `var_ref` vs `struct_ref` for struct names

### Zap-side: `src/zir_builder.zig` — 19 findings
**Most critical:** Four parallel "ZigType → ZIR Ref" resolvers with different incomplete coverage and different return conventions. Three tuple-type emission paths. Three `struct_init` paths copying same `decl_val + struct_init_typed` fallback logic. Cross-struct call routing duplicated 6+ times. Closure call dispatch has 5 overlapping fast paths in 240 lines.

Other top issues:
- "zap_runtime" string literal in 25+ places (hardcoded struct name)
- "Prelude", "ArcRuntime", "BinaryHelpers", "MapAtomInt", "BuilderRuntime" hardcoded as runtime struct names
- The colon-encoded "List:Type.method" / "MapNested:str:list" call_builtin parsing scheme
- Hardcoded `"List"` cached refs (6 of them) without equivalent for Map/String/Atom
- `emitUnionSwitch` has admitted broken implementation behind a placeholder comment ("For now, accept that the Ok prong returns void. This means the ~> expression evaluates to void for success. That's wrong for production but let's see if it at least doesn't crash")
- Unused `emitAllocMut`, `emitLoop`, `emitRepeat`
- `structToStructName` leaks per call (allocator.alloc never freed)
- main-name detection by string heuristics instead of `program.entry`
- Dead state field `cached_list_type_ref`

### Zap-side: `src/ir.zig` — 26 findings
**Most critical:** `lowerDecisionTreeForCase` and `lowerDecisionTreeForDispatch` are 95% duplicates (~600 lines, leaves diverge). `__try` variant generation duplicates ~120 lines of `buildFunctionGroup` body and silently omits `map_bindings`. `next_local; param_get; .empty; toOwnedSlice` boilerplate appears 20+ times.

Other top issues:
- 3 independent call-name resolution paths formatting `"{struct}__{name}__{arity}"` differently
- 4 places computing `max_binding_local` with inconsistent coverage
- Hardcoded `"Range"`/`"List."`/`"Map."` string prefixes for opcode dispatch
- Encoded type names (`"u32"`, `"str"`) duplicated in `zigTypeToEncodedName` AND inline at call sites with `else => "i64"` silent fallback
- `MapInit.key_type/value_type` defaults to `.atom`/`.i64` (`Map(Atom, i64)` if you don't specify); 6 list IR structs default `element_type = .i64`
- `union_dispatch_map` rewrites call sites with field-by-field arg wrapping that should be monomorphizer's job
- Misleading comment about non-existent `@native binding strings` map
- Magic `next_try_id = 10000` will collide silently with ≥10000 functions
- Step numbering in `resolveBareCall` doc comment doesn't match implementation

### Zap-side: `src/macro_eval.zig` — 20 findings
**Most critical:** 8 of 13 macro builtins are dead code with no `.zap` callers. The Zest test framework is implemented inside the Zig macro evaluator (`build_test_fns`, `build_test_fn`, `find_setup`, `find_teardown`, `inject_setup`, plus `buildTestFnDecl`) — should be Zap macros.

Other top issues:
- Hardcoded `begin_test`/`end_test`/`print_result`/`ctx`/`String` return type baked in
- `test_` prefix and slugify rules duplicated (`slugify` builtin and `slugifyString` helper)
- 14 hardcoded operators in evalBinop switch (drift risk vs `ast.BinaryOp.Op`)
- `is_tuple`/`is_list`/`is_atom` shadow Kernel functions
- `cond` interpreter has no Zap-level definition (should be a kernel macro)
- `if` interpreter duplicates `lib/kernel.zap:51`
- `length` builtin shadows `List.length`/`Tuple.size`
- `defstruct`/`defenum`/`defunion` builtins (~119 lines) are dead and should never have existed
- `extractString` helper not consistently used (3 inline copies in defXxx builders)
- `makeList` and `makeListFromSlice` are byte-identical

### Zap-side: `src/compiler.zig` — 15 findings
**Most critical:** `compileForCtfe` is a fully duplicated whole-program pipeline (~250 lines) running side-by-side with `compileStructByStruct`. Two-collector-pass pattern. Type-checker constructed and run twice on the same desugared program in CTFE path.

Other top issues:
- `compileFile` shim contradicts its own doc comment
- `mergeAndFinalize` and `mergeAndFinalizeWithIo` split despite no caller passing non-null `pio`
- `compileStructTask` exists for parallel execution that's never invoked (`_ = pio;` confirms)
- `runTypeCheck`'s "shared store" branch silently mutates caller's store via `clearRetainingCapacity`
- 3 CTFE evaluator entry points doing essentially the same job; one redundantly runs whole-program after running ordered
- Diagnostic emission's "show_progress clear + emit + return error" pattern copy-pasted 17×
- `validateImplConformance` + `registerImplFunctionsInTargetScopes` called twice in same pipeline
- `buildStructPrograms` re-attaches impls into structs at AST-split time (3rd impl-registration pass)
- Magic `"top"` string as struct name for synthesizing top-level functions (CTFE silently doesn't run for top-level)
- `cloneFunctionWithOffset` machinery (~110 lines) is dead — only test consumes it
- `buildCompilationUnits` does `std.mem.find(unit.source, entry.name)` (substring match against raw source text) to map struct→file

### Zap-side: `src/collector.zig` + `src/scope.zig` — 14 findings
**Most critical:** `registerImplFunctionsInTargetScopes` calls `collectFunction` a second time on the same impls, clobbering `clause.meta.scope_id` and creating duplicate `FunctionFamily` entries. Direct `node_scope_map.get(spanKey(...)) orelse meta.scope_id` calls in 7+ files use *reversed priority* from the canonical `resolveClauseScope` — re-introducing the synthetic-span collision bug just fixed.

Other top issues:
- `use Foo` silently rewritten to `import Foo`, dropping `__using__/1` semantics and `opts`
- Top-level vs struct-item dispatch are parallel switches that must be kept in sync
- `findStructScope` linear-scan reinvented as `findStructScopeByName` (×2) plus 14+ inline loops in types.zig and ctfe.zig
- `findProtocol`/`findImpl`/`findImplsForProtocol` use linear scans
- `resolveTypeByName` is a global flat lookup while `resolveBinding`/`resolveFamily` walk scope chain — three different lookup semantics for the same concept
- `resolveFamily`/`resolveMacro` re-resolve `findStructScope(imp.source_struct)` per scope per import (hot path)
- `node_scope_map` writes for struct/protocol/impl/clause/macro/block all use same span-keyed map (collision risk for synthetic code)
- `@constCast` mutation of `*const` fields (`clause.meta.scope_id`, `interner`)
- "Pending attribute" state threaded as in-place mutable accumulator
- `"Kernel"` hardcoded in 3 files (collector, compiler, discovery)
- Multiple memory leaks in `Scope.deinit`, `MacroFamily.deinit`, `FunctionFamily.deinit`, `StructEntry.attributes`, `ProtocolEntry.attributes`
- `formatStructName` returns either borrowed or owned slice — caller can't tell which to free
- `collectAlias` only stores last part — multi-part aliases broken
- `collectNestedStruct` registers using `parts[0]` while `collectStruct` uses full qualified name (different conventions)

### Zap-side: `src/monomorphize.zig` — 15 findings
**Most critical:** `MonomorphRegistry` in types.zig is dead write-only state. Three call-site dispatch implementations re-do unification. Two `containsTypeVar` implementations with **contradicting protocol_constraint semantics**. Two name-mangling implementations producing different output for the same input.

Other top issues:
- Per-struct re-monomorphization via `struct_salt` produces N copies of identical specialized function
- Magic `> 10` cap on transitive iteration loop (silently produces wrong binary if exceeded)
- Local function groups inside specialized clones not specialized — share generic captures with all parents
- Source-struct prefix lookup is O(structs × functions) per specialization
- Pointer-identity-based `call_rewrites` map (heap address as key) — fragile
- Empty-list/map default to `[i64]` / `Map(Atom, i64)`
- `local_types` side-table is workaround for stale `Expr.type_id` after call rewrites
- `current_scan_params` rescue path compensates for incomplete `cloneExpr` substitution
- Inline substitution scattered through 5 cloneXxx functions instead of one canonical visitor
- HIR has its own SubstitutionMap+applyToType driver (`substituteReturnTypeFromArgs`) outside the monomorphizer

### Zap-side: `src/analysis_pipeline.zig` and analyses — 15 findings
**Most critical:** `escape_analysis.zig` is **1100 lines of completely dead code** with zero callers. No shared IR traversal infrastructure — 8+ analyses each carry ~150 lines of duplicate "switch over instr, recurse into nested case/if/etc." walkers with diverging coverage.

Other top issues:
- 4 different worklist/fixpoint engines with inconsistent semantics (FIFO `orderedRemove(0)` vs `while changed` vs re-walk-per-pop)
- ARC optimizer `identifySkippableValues` inner loop unconditionally `break;` — never matches anything
- Phase 3 throws away Phase 1 escape-analysis context and re-runs from scratch
- Pipeline duplicates "extract per-function escapes & alloc sites" between parallel and sequential paths
- Pipeline `@constCast` of `[]const ParamSummary` to back-propagate Perceus into interprocedural results
- 3 (or 4) ad-hoc cycle-prevention strategies: magic-32 depth, hashed visited set, no guard at all
- Perceus reinvents type inference from instruction shapes (`countStructFieldsInInstrs`, hardcoded `[32][]const u8` field arrays that silently truncate)
- Perceus assumes `list_type` is always reuse-compatible — hardcoded knowledge of cons-cell layout
- Duplicate `name_to_id` maps built independently by interprocedural and lambda_sets
- Three "is closure call-local" classifiers (lambda_sets, analysis_pipeline, dead escape_analysis)

### Zap-side: closures/captures (cross-cutting) — 15 findings
**Most critical:** `parent_assignment_bindings` fabricates `binding_id = 0` colliding with real binding 0. 3 redundant "is closure?" booleans. 4 parallel capture-collection algorithms with diverging coverage (HIR canonical doesn't recurse into anonymous_function).

Other top issues:
- `direct_capture_params` field has 5 branches reading it; no write site ever sets `true`
- `capture_depth` mechanism is leaky workaround for ZIR builder limitation (`struct_init_field_type` doesn't enter captured bodies)
- Hardcoded `"Prelude.callCallable0..3"` string switch with arity 0-3 fast path; 4+ args silently fall back
- `closure_function_map` + `capture_closure_function_map` + `findClosureCallTarget` overlap (forward-propagating + backward-scanning + cached map for same info)
- 4 sites independently construct "closure with borrowed captures cannot ..." error
- Two parallel closure-flow analyses (`lambda_sets.zig` vs `escape_lattice.zig`) with overlapping `LambdaSet`/`Decision` types
- Two `findClosureEscape` implementations
- ZIR closure struct field `env_release` always emitted as null and never read
- `__anon_fn_` prefix used as control-flow signal (string match)

### Zap-side: test framework — 15 findings
**Most critical:** Entire Zest test DSL implemented in `macro_eval.zig` instead of Zap macros. `find_setup`/`find_teardown`/`build_test_fns`/`build_test_fn` are Zig functions. Test framework knowledge baked in 5+ places.

Other top issues:
- Hardcoded `Test.` struct prefix validation in `main.zig:1110-1138`
- `lib/zest/` directory probe in `main.zig:280-283` (special-cased)
- HIR synthesizes `pub fn run() -> String` only when interner happens to contain "run" (depends on coincidental interner state — fragile)
- Runtime struct named `Zest` in `runtime.zig:1886-2020` (framework name in runtime)
- CLI `--seed` parsing duplicated between Zig CLI and Zap-level Zest.Runner

### Fork-side: `src/zir_api.zig` — Major findings
**Most critical:** ~70 of 159 C ABI exports (44%) are dead code. 30+ trivial single-op wrappers (`emit_sqrt`, `emit_sin`, etc.) should be one generic `emit_unary(tag, operand)`.

Other top issues:
- 3 near-identical `emit_tuple_decl*` variants
- `0xFFFFFFFF` literal used 349 times (no constant defined)
- Pattern-matching debug allocator fill bytes (`0x5555...`, `0xaaaa...`) for "uninitialized memory" detection — reads undefined memory
- Inconsistent error/return conventions across families (5 distinct conventions in use)
- `emit_set_runtime_safety` wrong return type (u32 for what should be i32)
- `get_tuple_return_type` returns 0 for "not set" — ambiguous because 0 is also `Ref.none`
- `addZirImpl` ignores its `name` parameter (always injects into root)
- Stub source string duplicated literally between `createImpl` and `addZirImpl`
- `bool_true (0x34)` / `bool_false (0x35)` documented in docstrings as magic ints
- `output_mode` integer parsing with silent `else => .Exe` default
- Inconsistent `callconv(.c)` annotation across exports

### Fork-side: `src/zir_builder.zig` — 14 findings
**Most critical:** 7 return-type setter variants + 8 mutually-exclusive state fields when one tagged union would suffice. `endFunction`'s giant if-else chain repeats per ret-type kind. Body-tracking conditional duplicated inline 12×.

Other top issues:
- `setOptionalReturnType` overloads `error_union_ret_type_inst` (wrong field name; cannot express `error!?T`)
- `setErrorUnionReturnType` takes `[]const u8` parameter that's silently ignored
- `tuple_ret_types` is single-element ArrayList by construction
- `tuple_ret_type_inst` and `tuple_ret_types` are 100% redundant (both written together)
- `tuple_element_type_refs` field exists only to expose `len` via C ABI getter
- 3 valid emission entry points (`addInst`, `emitBodyInst`, `emitBodyInstVoid`, plus `addInst(undefined,undefined)` placeholder) — code reviewers can't tell which is correct
- Magic `@bitCast(@as(i32, std.math.maxInt(i32)))` literal (24+ uses) for `OptionalOffset.none`
- Cleanup leaks on error paths (FuncBody's 5 ArrayLists only 2 freed in Builder.deinit; struct scope leaks)
- `setTupleReturnType` doesn't clear other return-type setter state

### Fork-side: `src/Sema.zig` — 2 findings
**Most critical:** Two patches that should be reverted. Fix root causes in Zap-side ZIR emission instead.

- `lookupIdentifier` rewritten to convert stock `unreachable` to `runtime fail` with fake `@enumFromInt(0)` source location — affects all Zig users of fork
- `fieldPtrLoad` accepts non-pointer/slice operands by silently delegating to `fieldVal` — covers for Zap emitting `field_ptr` ZIR where it should emit `field_val` (which 0.16 removed)

Both should be reverted; fix is on Zap side: emit correct ZIR tags, ensure identifiers carry valid source locations.

### Pattern matching (cross-cutting) — 15 findings
**Most critical:** **Assignment LHS destructuring silently dropped** — `{a, b} = pair` parses, type-checks, and lowers to HIR but produces broken IR with no extraction (only `.bind` patterns get an `AssignmentBinding`). `compileConstructorColumn` is missing `struct_match` and `map_match` cases — they fall into `else => stripColumnAndRecurse`, treating struct/map patterns as wildcards. case_expr binding processor only handles `.bind`, `.tuple`, `.binary_match` — list/struct/map/list_cons/pin in case arms are silently dropped.

Other top issues:
- 3 parallel pattern type hierarchies: `ast.Pattern` (11 variants), `hir.MatchPattern` (10 variants), `macro_eval.matchPattern` over CtValue (different again)
- `Resolver.bindPattern` and `Resolver.resolvePattern` are dead duplicates of `Collector.collectPatternBindings` (would create duplicate scope bindings if wired in)
- 5+ pattern walkers covering overlapping pattern shapes with diverging coverage (`collectPatternBindings`, `bindPattern`, `resolvePattern`, `collectBoundNames`, `compilePattern`)
- 6 separate per-kind binding lists on Clause (`tuple_bindings`, `struct_bindings`, `list_bindings`, `cons_tail_bindings`, `binary_bindings`, `map_bindings`) where one path-encoded `Binding{path, local_index}` would suffice
- IR builds PatternMatrix 3 times in 3 places
- `compileBinaryCheck` keeps only the FIRST clause's segments (`break;` at hir.zig:1497) — multi-clause binary dispatch is hand-rolled outside the matrix
- Dead `has_prefix_dispatch` boolean (computed but never used)
- Dead `Clause.decision` placeholder — allocated, never consumed by IR (which rebuilds the matrix instead), faithfully cloned by monomorphizer
- `findParamGetIdInDecision` "fragile heuristic" still alive (called at 4 sites) despite comment claiming `element_scrutinee_ids` was added "to avoid the fragile heuristic" — fix was applied unevenly (CheckTupleNode + CheckListConsNode got it, CheckListNode didn't)
- Pattern exhaustiveness only handled for atom-literal patterns on tagged unions; bool/struct/etc. all silently fall through to runtime panic
- 16 sites manually check `pattern.* == .bind` — should be `Pattern.asBindName() ?StringId` helper
- `next_id: *u32` thread-local mutable counter passed through 11 functions (matrix-compiler should be a struct)

### Cross-cutting: hardcoded struct names search — Categorized
- **Struct names hardcoded** (Kernel, String, List, Map, Range, Enumerable, Zest, Zap.*, Inspect, etc.): **~15 hotspots across 11 files** — HIGH severity
- **Library API function names hardcoded** (`getHead`, `getTail`, `cons`, `length`, `concat`, `to_string`, `setup`, `teardown`, `begin_test`, `end_test`, `print_result`): **~25 hotspots, concentrated in zir_builder.zig and macro_eval.zig** — HIGH
- **Runtime ABI helpers hardcoded** (`zap_runtime`, `Prelude`, `getArgv`, `atomIntern`, `ArcRuntime`, `callCallableN`, `MapAtomInt`): **~30 occurrences** — MEDIUM (runtime ABI is shared by definition but should flow through Zap-side annotations)
- **Internal naming conventions** (`__anon_fn_`, `__for_`, `__main__`, `__using__`, `__try`, `__Struct__*`, `:zig.*`): ~12 occurrences — MEDIUM
- **Variant names** (`Ok`, `Result`, `Some`, etc.): ~3 production hits — MEDIUM (couple to language-item attributes)
- **Duplicated primitive-type lists**: 6 separate copies of the same builtin-type-name array — LOW

### `@native` vs hardcoded routing — Categorized
- README claims `@native` is canonical mechanism — **functionally dead, never wired through**
- 5 distinct mechanisms for invoking runtime/Zig-level code coexist
- `Arithmetic`/`Comparator` impls are dead code for primitive types — compiler emits raw ZIR `addwrap`/`cmp_*` directly
- `String.concat` for `<>` operator bypasses any `Concatenable` protocol
- `in` operator for ranges is hardcoded inline arithmetic chain
- `BinaryHelpers.readInt{...}` switch table (~85 lines) exhaustively hardcodes endianness/sign/width permutations
- Atom interning calls `atomIntern` directly via `field_val` instead of through ABI helper
- Function-name mangling format `Struct__function__arity` is parsed and re-parsed at multiple layers, with operator names having extra prefixing — round-trip fragility

---

## Systemic Patterns

### Pattern A: "Let me just add another variant"
When a primitive needed to do almost-the-same thing, the consistent answer was to add a near-duplicate.
- 7 return-type setters
- 4 tuple-decl emission paths
- 3 call-name resolution paths
- 3 closure-call dispatch paths
- 3 callable-arity wrappers (Prelude.callCallable0/1/2/3)
- 8+ AST walkers, none sharing infrastructure

**Fix posture:** When tempted to add `setXReturnType` or `emit_X_body` or `inferYAlt`, refactor instead. The existing `set_custom_return_type` is the general case for return types; the existing `pop_body_inst` + custom_ret_type_body machinery is the general case for support instructions; one `emit_unary(tag, operand)` covers all 18 math wrappers.

### Pattern B: "This is the wrong layer, but I'll patch it here"
- HIR builder hardcodes `Range.start/.end/.step` field desugaring (should be desugar pass / kernel macro)
- HIR builder hardcodes `?`/`!` suffix validation (should be type checker)
- IR builder rewrites `Map`/`List` calls to type-specialized variants (should be monomorphization)
- IR builder injects `union_init` to wrap call args (should be HIR or monomorphization)
- ZIR builder hardcodes `BinaryHelpers.readInt*` per-encoding switch (should be runtime)
- ZIR builder hardcodes `callCallable0..3` arity dispatch (should be runtime or one polymorphic helper)
- Sema patched to weaken stock invariants (should fix Zap-side ZIR emission)

**Fix posture:** Push knowledge to its rightful layer. Compiler emits structured calls; runtime resolves them. Type system carries enough info that backend is mechanical.

### Pattern C: "I'll set a flag I never trust"
- `Function.is_closure: bool` redundant with `captures.len > 0` (3 booleans for one fact, with defensive `or`)
- `clause.meta.scope_id` set by collector but `node_scope_map` consulted first by 7 callers using reversed priority
- `MonomorphRegistry` recorded by 2 sites, never read
- `direct_capture_params` field with 5 read sites and 0 write sites that set true
- `is_generic` parameter to `setErrorUnionReturnType` taken but ignored
- Comment about `default_arg_wrappers` describes a field that doesn't exist

**Fix posture:** If you set a flag, check it consistently. If you check a flag, remove redundant fields. If you record state, consume it or delete the recorder.

### Pattern D: "Magic numbers and strings as language features"
- `next_try_id = 10000` (silent collision)
- depth limit 32 (silent degradation to slow path)
- `transitive_iterations > 10` (silent wrong specialization)
- `0x5555...` / `0xaaaa...` (debug-allocator fill bytes detected by pattern matching)
- 6 copies of `[18]const []const u8 { "Bool", "String", ... }` (drift risk)
- `__anon_fn_` / `__for_` / `__try` / `__main__` (string-prefix dispatch instead of AST flags)
- 17× copy-paste of `if (options.show_progress) std.debug.print("\r\x1b[K", .{}); emitContextDiagnostics(ctx, alloc); return error.X;`

**Fix posture:** Pull magic numbers to file-level constants. Replace name-prefix dispatch with AST flags or proper enum tags. Extract repeated diagnostic patterns into a `failWith*` helper.

### Pattern E: "Run it twice for safety"
- Two-collector-pass pattern (compiler.zig)
- Two type-check passes in compileForCtfe
- Three impl-registration passes (collectImpl, registerImplFunctionsInTargetScopes, buildStructPrograms)
- Phase 3 of analysis pipeline reruns Phase 1 from scratch
- `evaluateStructAttributesInOrder` falls back to whole-program walk after ordered walk

**Fix posture:** Each "run again" is paying for an information-flow gap. Find what's stale on the first run and fix it (e.g., scope_id on AST nodes via pointer identity instead of span keys).

### Pattern F: "Comment as load-bearing structure"
- "For now, accept that the Ok prong returns void. ... That's wrong for production but let's see if it at least doesn't crash" (zir_builder.zig:5598-5605)
- "Pipe desugaring removed — now handled in macro engine (Phase 4)" (~200 lines of dead code below it)
- "Currently it requires the full merged program... For now, this delegates to compileFiles" (compileFiles doesn't exist)
- "Function IDs are already globally unique from the HIR stage... no cloneWithOffset needed" (cloneFunctionWithOffset is still ~110 lines below)
- "Mirror the bookkeeping so X keeps working" (admits two state machines kept in sync by hand)
- Doc says `// Fourth pass:` when there are 2 passes
- Doc claims `@native` is canonical mechanism for runtime routing (it's never read)

**Fix posture:** Treat "for now" / "TODO" / "should not be reached" comments as red flags requiring action.

---

## Prioritized Action Plan

### Wave 1: Pure deletions (low risk, high signal-to-noise)
Each item below is "delete code with no consumers"; if test suite passes, the cleanup is sound.

1. `src/escape_analysis.zig` — entire file (1100 lines)
2. `src/desugar.zig:651-872` — dead error-pipe chain (~200 lines)
3. Fork zir_api dead exports (~30 unary math wrappers, type-introspection, type-reification, miscellaneous)
4. macro_eval dead builtins (`make_fn_decl`, `find_setup`/`find_teardown`/`inject_setup` if not yet migrated, `defstruct`/`defenum`/`defunion`, `split_words`, `slugify` if duplicate, `string_concat`, `is_tuple`/`is_list`/`is_atom`)
5. Dead IR instructions (`cond_branch`, `if_expr`, `branch`, `phi`, `reset`, `reuse_alloc`, `jump`)
6. Dead IR-builder fields (`default_arg_wrappers`, `group_id_to_name`, `next_label`, `next_function_id`, `cached_list_type_ref`)
7. Dead `MonomorphRegistry` in types.zig
8. Dead `compileFile`, `compileStructTask`, `cloneFunctionWithOffset` machinery
9. Dead `direct_capture_params` field and 5 branches reading it; collapse `ClosureLowering` to `needs_env_param`
10. `inherited_iter` no-op loop in HIR `buildStruct`
11. `registerFunctionGroup`/`buildGroupClauses` orphaned helpers
12. `setErrorUnionReturnType` C ABI export (zero externs)

**Estimated savings:** ~3000 lines of dead code, 50+ dead function symbols.

### Wave 2: Critical correctness fixes (Tier 1 issues)
1. C2: Add `current_map_bindings` to `buildBindingReference` walk, save/restore in buildFunctionGroup, deinit. Or merge all 8 binding lists into one `current_local_bindings` structure.
2. C1: Stop fabricating `binding_id = 0` in HIR; either resolve a real BindingId or change `Capture.binding_id` to `?BindingId`
3. C3: Make `registerImplFunctionsInTargetScopes` only insert FunctionFamilyId pointer into target scope, not call `collectFunction` again
4. C4: Extract `buildFunctionBody(group, try_mode)` so `__try` variant doesn't accidentally drop bindings
5. C5: Fix ARC optimizer's broken inner loop
6. C6: Split `setOptionalReturnType` into its own field (or migrate to RetTypeSpec union per Wave 4)
7. C12: Make `collectCapturedBindings*` recurse into nested anonymous_function
8. C13: Implement multi-clause case lowering in `buildErrorHandlerExpr`
9. C14: Revert Sema patches; fix Zap-side ZIR emission
10. C15: Initialize `sub_file_path` properly; remove fill-byte detection

### Wave 3: Architectural — push knowledge to right layers
1. **Define `Concatenable` and `Membership` (or extend Enumerable) protocols.** Move `<>` and `in` operator dispatch through them. Eliminates `string_eq`/`string_neq`/`in_list`/`in_range` ZIR opcodes. Removes `"Range"` / `"List."` hardcoding from IR builder.
2. **Implement `Enumerable for String`.** Delete `desugarForString` and the `String.length`/`byte_at` desugar. (~155 lines saved.)
3. **Define `Updatable` protocol.** Move `%{m | k:v}` dispatch through it. Eliminates `Map.put` chain hardcoding.
4. **Push container element types into IR's `CallBuiltin.type_args`.** Delete the `List:T.method` / `Map:K:V.method` colon-encoded name parsing in zir_builder. Delete `MapAtomInt` literal. Stops monomorphization-as-string-mangling.
5. **Move `Range.start/.end/.step` field access desugar from HIR to desugarer.** HIR sees only `%Range{...}`.
6. **Wire `@native` properly OR remove it.** Pick one: either the README is authoritative and `@native` becomes the only runtime-binding mechanism (delete `:zig.*` and the various hardcoded routing in zir_builder); or the README is wrong and `@native` is removed entirely. Currently both exist and the documented one is the dead one.
7. **Make `Arithmetic`/`Comparator` impls actually drive primitive arithmetic** (or document explicitly that they exist as documentation-only, not code-driving). Today's silent bypass is misleading.

### Wave 4: Refactor parallel implementations
1. **Single AST visitor** (`src/ir_traversal.zig` proposal in analysis-pipeline audit). Replaces 8+ duplicate walkers across analysis files. Estimated ~1000 line savings.
2. **Single binding-resolver** combining `resolveBindingType` + `buildBindingReference` + map_bindings.
3. **Single call-dispatch path** in types.zig replacing the bare-name + struct-qualified parallel pipelines.
4. **`RetTypeSpec` tagged union** in fork zir_builder, replacing the 7 setter variants and 8 state fields. `endFunction`'s triple if/else chain collapses.
5. **Single decision-tree lowerer** in IR builder with `LeafEmitter` strategy parameter — eliminates ~600 lines duplication between Case and Dispatch lowering.
6. **Unified worklist abstraction** in `src/worklist.zig` — replaces 4 inconsistent fixpoint engines.
7. **Pointer-keyed scope-id side-table** instead of `node_scope_map` + `meta.scope_id` dance. AST stays fully `const`. Synthetic-span collisions impossible by construction.
8. **Single `findStructScope` API** with name-indexed map; eliminates 14+ inline scans.
9. **Decision: lambda_sets.zig vs escape_lattice.zig.** Pick one; merge into the other.
10. **Move Zest test framework into Zap macros.** Eliminates 4 macro_eval builtins, ~430 lines of macro_eval logic, plus `runtime.Zest` rename to neutral name.

### Wave 5: Hardcoded-string consolidation
1. Centralize "zap_runtime" string + length as file-level constants in zir_builder.
2. Centralize `0xFFFFFFFF` as `error_ref` constant in fork zir_api (matches Zap-side).
3. Single `optional_offset_none` constant in fork zir_builder, replacing 24+ literal occurrences.
4. Single `BUILTIN_TYPE_NAMES` array in TypeStore, consumed by 6 current copies.
5. Replace `__anon_fn_`/`__for_`/`__try`/`__main__` prefix dispatch with AST flags.
6. Replace operator-name string compare with single fold primitive in macro_eval.
7. Drop `MapInit.key_type/value_type` / `ListInit.element_type` defaults; require callers to specify.

---

## Closing Notes

- **The compiler is functionally working.** 586/585 tests pass. The for-comp dispatch fix is real progress. None of the issues above block current functionality.
- **The audit identified ~250 issues across 18 files.** Roughly 60% are duplication / parallel implementations, 25% are hardcoded compiler knowledge violating CLAUDE.md, 10% are dead code, 5% are silent correctness bugs.
- **Wave 1 (pure deletions) is ~3000 lines and could be done in days.** It would not change behavior but would make the next change much safer.
- **Wave 2 fixes should be done before Wave 3-5** because architectural refactoring on top of latent silent bugs makes diagnostics impossible.
- **The single most valuable architectural change** is making `@native` actually work and routing all runtime calls through it. That collapses 5 parallel runtime-call mechanisms into one and removes ~30 hardcoded runtime function names from the compiler.
- **The single most valuable per-file cleanup** is `zir_builder.zig` (Zap-side) — accumulates the most CLAUDE.md violations and is hardest to safely change without addressing them.

The audit was performed by 17 parallel agents using `cog` code-intelligence tools and direct Read/Grep when source was outside the cog index. Each agent's full report is preserved at `/private/tmp/claude-501/-Users-bcardarella-projects-zap/b248d5a7-b290-4d56-8e27-d8edf985316b/tasks/*.output`.
