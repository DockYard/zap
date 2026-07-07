// Build-time configuration. Re-exported under a uniquely-named decl so
// `runtime.zig` can find it via `@import("root")` without colliding with
// other roots (the embedded user-binary root has no such decl, so the
// runtime there falls back to its baked-in default).
pub const zap_runtime_instrument_map_override: bool = @import("build_options").instrument_map;

pub const Token = @import("token.zig").Token;
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const ast_visitor = @import("ast_visitor.zig");
pub const Parser = @import("parser.zig").Parser;
pub const scope = @import("scope.zig");
pub const Collector = @import("collector.zig").Collector;
pub const MacroEngine = @import("macro.zig").MacroEngine;
pub const Desugarer = @import("desugar.zig").Desugarer;
pub const Resolver = @import("resolver.zig").Resolver;
pub const types = @import("types.zig");
pub const DispatchEngine = @import("dispatch.zig").DispatchEngine;
pub const hir = @import("hir.zig");
pub const ir = @import("ir.zig");
pub const ast_data = @import("ast_data.zig");
pub const macro_eval = @import("macro_eval.zig");
pub const zir_builder = @import("zir_builder.zig");
pub const zir_backend = @import("zir_backend.zig");
pub const ZirDriver = zir_builder.ZirDriver;
pub const ZirBuilderHandle = zir_builder.ZirBuilderHandle;
pub const ZirContext = zir_builder.ZirContext;
pub const escape_lattice = @import("escape_lattice.zig");
pub const generalized_escape = @import("generalized_escape.zig");
pub const interprocedural = @import("interprocedural.zig");
pub const region_solver = @import("region_solver.zig");
pub const lambda_sets = @import("lambda_sets.zig");
pub const perceus = @import("perceus.zig");
pub const analysis_pipeline = @import("analysis_pipeline.zig");
pub const contification_rewrite = @import("contification_rewrite.zig");
pub const arc_optimizer = @import("arc_optimizer.zig");
pub const arc_liveness = @import("arc_liveness.zig");
pub const arc_ownership = @import("arc_ownership.zig");
pub const arc_param_convention = @import("arc_param_convention.zig");
pub const arc_verifier = @import("arc_verifier.zig");
pub const concurrency_verifier = @import("concurrency_verifier.zig");
pub const arc_drop_insertion = @import("arc_drop_insertion.zig");
pub const arc_materialize = @import("arc_materialize.zig");
pub const uniqueness = @import("uniqueness.zig");
pub const uniqueness_decision = @import("uniqueness_decision.zig");
pub const uniqueness_interprocedural = @import("uniqueness_interprocedural.zig");
pub const uniqueness_signature = @import("uniqueness_signature.zig");
pub const uniqueness_fixpoint = @import("uniqueness_fixpoint.zig");
pub const runtime = @import("runtime.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const error_ir = @import("error_ir.zig");
pub const error_format = @import("error_format.zig");
pub const error_json = @import("error_json.zig");
pub const lints = @import("lints.zig");
pub const error_codes = @import("error_codes.zig");
pub const zap_symbol_table = @import("zap_symbol_table.zig");
pub const addr2line = @import("addr2line.zig");
pub const DiagnosticEngine = diagnostics.DiagnosticEngine;
pub const Severity = diagnostics.Severity;
pub const similarity = @import("similarity.zig");
pub const project = @import("project.zig");
pub const compiler = @import("compiler.zig");
pub const builder = @import("builder.zig");
pub const build_cache = @import("build_cache.zig");
pub const frontend_policy = @import("frontend_policy.zig");
pub const incremental_graph = @import("incremental_graph.zig");
pub const progress = @import("progress.zig");
pub const discovery = @import("discovery.zig");
pub const glob = @import("glob.zig");
pub const attr_substitute = @import("attr_substitute.zig");
pub const ctfe = @import("ctfe.zig");
pub const capability_inference = @import("capability_inference.zig");
pub const lockfile = @import("lockfile.zig");
pub const monomorphize = @import("monomorphize.zig");
pub const env = @import("env.zig");
pub const signature = @import("signature.zig");
pub const wyhash = @import("wyhash.zig");
pub const memory_section_parser = @import("memory/section_parser.zig");
pub const memory_abi = @import("memory/abi.zig");
pub const memory_driver = @import("memory/driver.zig");
pub const memory_elision = @import("memory/elision.zig");
pub const concurrency_driver = @import("concurrency_driver.zig");
pub const target_triple = @import("target_triple.zig");
pub const target_caps = @import("target_caps.zig");
pub const target_fold = @import("target_fold.zig");

test {
    // ----------------------------------------------------------------
    // INVARIANT — every test-bearing `src/*.zig` module that compiles
    // under the host `zap` module graph MUST be referenced here.
    //
    // In Zig, a top-level `pub const x = @import("x.zig")` does NOT run
    // x.zig's `test {}` blocks. Only a reference inside THIS aggregating
    // `test {}` block pulls a module's tests into `zig build test`. A
    // test-bearing module left out is silently dead — it compiles, but
    // its guarantees never run. The meta-test below
    // (`test "every test-bearing src module is aggregated"`) walks the
    // `src/` tree at test time and FAILS if a module with `test {}`
    // blocks is missing from the set listed here, so this invariant can
    // never silently regress.
    //
    // DELIBERATE EXCLUSIONS (each covered elsewhere — kept out on purpose;
    // the meta-test's allow-list mirrors this list):
    //   * `src/root.zig` — this file (the aggregator itself).
    //   * `src/zir_integration_tests.zig` — driven by the separate
    //     `zig build zir-test` step (needs the installed `zap` binary).
    //   * `src/main.zig` — the CLI executable root; built as its own test
    //     target by `build.zig` (`main_tests`, wired into `zig build test`).
    //   * `src/runtime_os/posix.zig`, `src/runtime_os/wasi.zig`,
    //     `src/runtime_os/windows.zig`, `src/runtime_os/windows_argv_test.zig`
    //     — each compiled by `build.zig` against its OWN target (native /
    //     wasm32-wasi / x86_64-windows-gnu) so per-target std-API breaks
    //     surface; they cannot share the host `zap` module's single target.
    //   * `src/runtime_os_portability_gate.zig`,
    //     `src/target_capability_audit.zig` — built as dedicated
    //     `build.zig` test targets (the audit needs the generated
    //     `stdlib_sources` import the `zap` module does not provide).
    //   * `src/runtime/concurrency/concurrency.zig` — AGGREGATOR for
    //     `src/runtime/concurrency/`: the root of the concurrency runtime
    //     kernel (P1-J1…J6), a self-contained tree with its own dedicated
    //     `zig build test-kernel` target (whose selected-optimize half is
    //     also wired into `zig build test`): it must run WITHOUT the
    //     compiler link and additionally at ReleaseFast for the fiber
    //     miscompilation canary, neither of which the `zap` module test
    //     binary provides. Kernel modules are NEVER hand-listed here —
    //     the meta-test parses concurrency.zig's own `test {}` block and
    //     FAILS if any test-bearing module under the subtree is missing
    //     from it.
    // ----------------------------------------------------------------
    _ = @import("target_triple.zig");
    _ = @import("target_caps.zig");
    _ = @import("target_fold.zig");
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("ast_visitor.zig");
    _ = @import("parser.zig");
    _ = @import("scope.zig");
    _ = @import("collector.zig");
    _ = @import("macro.zig");
    _ = @import("desugar.zig");
    _ = @import("resolver.zig");
    _ = @import("types.zig");
    _ = @import("dispatch.zig");
    _ = @import("hir.zig");
    _ = @import("ir.zig");
    _ = @import("escape_lattice.zig");
    _ = @import("generalized_escape.zig");
    _ = @import("interprocedural.zig");
    _ = @import("region_solver.zig");
    _ = @import("lambda_sets.zig");
    _ = @import("perceus.zig");
    _ = @import("analysis_pipeline.zig");
    _ = @import("contification_rewrite.zig");
    _ = @import("arc_optimizer.zig");
    _ = @import("arc_liveness.zig");
    _ = @import("arc_ownership.zig");
    _ = @import("arc_param_convention.zig");
    _ = @import("arc_verifier.zig");
    _ = @import("concurrency_verifier.zig");
    _ = @import("arc_drop_insertion.zig");
    _ = @import("arc_materialize.zig");
    _ = @import("uniqueness.zig");
    _ = @import("uniqueness_decision.zig");
    _ = @import("uniqueness_interprocedural.zig");
    _ = @import("uniqueness_signature.zig");
    _ = @import("uniqueness_fixpoint.zig");
    _ = @import("ast_data.zig");
    _ = @import("macro_eval.zig");
    _ = @import("zir_builder.zig");
    _ = @import("zir_backend.zig");
    _ = @import("runtime.zig");
    _ = @import("diagnostics.zig");
    _ = @import("error_ir.zig");
    _ = @import("error_format.zig");
    _ = @import("error_json.zig");
    _ = @import("error_codes.zig");
    _ = @import("lints.zig");
    _ = @import("similarity.zig");
    _ = @import("project.zig");
    _ = @import("compiler.zig");
    _ = @import("frontend_policy.zig");
    _ = @import("incremental_graph.zig");
    _ = @import("builder.zig");
    _ = @import("build_cache.zig");
    _ = @import("discovery.zig");
    _ = @import("glob.zig");
    _ = @import("lockfile.zig");
    _ = @import("attr_substitute.zig");
    _ = @import("ctfe.zig");
    _ = @import("capability_inference.zig");
    _ = @import("monomorphize.zig");
    _ = @import("env.zig");
    _ = @import("signature.zig");
    _ = @import("wyhash.zig");
    _ = @import("progress.zig");
    // Crash-reporter offline-symbolization pair: `addr2line.zig` resolves a
    // runtime address against the `.zap-symbols` sidecar parsed by
    // `zap_symbol_table.zig` (addr2line imports the table). Both carry
    // pure unit tests that run natively on the host.
    _ = @import("zap_symbol_table.zig");
    _ = @import("addr2line.zig");
    _ = @import("memory/section_parser.zig");
    _ = @import("memory/abi.zig");
    _ = @import("memory/driver.zig");
    _ = @import("concurrency_driver.zig");
    _ = @import("memory/elision.zig");
    // First-party memory managers — inline behavioural tests.
    //
    // The Tracking manager carries inline tests for canary detection, leak
    // reporting, invalid-free, and size/alignment mismatch; the ARC manager
    // carries tests for its slab-pool refcount layout and ABI asserts. The
    // integration tests in `memory/driver.zig` validate the section/symbol
    // pipeline using synthesised objects; these imports drive the managers'
    // actual runtime behaviour.
    //
    // All four managers declare `zap_memory_section`, but each gates that
    // export behind `!builtin.is_test` (see the `comptime { @export(...) }`
    // block in each manager). `runtime.zig`'s `externalMemorySection`
    // early-returns null under `builtin.is_test`, so the symbol is dead in
    // the test binary — gating it out lets ALL FOUR managers be aggregated
    // here without a duplicate `zap_memory_section` symbol, while the
    // test-only ARC fallback continues to drive every test allocation.
    //
    // The GC manager carries deterministic unit tests for its conservative
    // stack-base capture (the `stack_bottom` upper bound must cover the
    // caller's entry frame, so an entry-frame-only heap root is scanned and
    // never prematurely swept) and an end-to-end mark-sweep survival witness.
    //
    // The Arena manager carries tests for its single-owner bump-allocation
    // fast path: alignment correctness, chunk-boundary refills, geometric
    // chunk growth capping, dedicated oversize chunks, and full-teardown
    // leak-freedom (its tests run every chunk through
    // `std.testing.allocator`, so any chunk `arenaDeinit` fails to return
    // fails the test run as a leak).
    _ = @import("memory/tracking/manager.zig");
    _ = @import("memory/arc/manager.zig");
    _ = @import("memory/arc/cross_thread_stress.zig");
    _ = @import("memory/gc/manager.zig");
    _ = @import("memory/arena/manager.zig");
}
