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
pub const arc_drop_insertion = @import("arc_drop_insertion.zig");
pub const arc_materialize = @import("arc_materialize.zig");
pub const uniqueness = @import("uniqueness.zig");
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

test {
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
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
    _ = @import("arc_optimizer.zig");
    _ = @import("arc_liveness.zig");
    _ = @import("arc_param_convention.zig");
    _ = @import("arc_drop_insertion.zig");
    _ = @import("arc_materialize.zig");
    _ = @import("uniqueness.zig");
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
    _ = @import("wyhash.zig");
    _ = @import("memory/section_parser.zig");
    _ = @import("memory/abi.zig");
    _ = @import("memory/driver.zig");
    _ = @import("memory/elision.zig");
    // Phase 4.d — Bacon–Rajan trial-deletion cycle detector. Carries
    // runtime-level unit tests that assemble cyclic `ArcHeader`-style
    // object graphs directly and drive the engine (cycles are not
    // user-constructible from today's immutable Zap; see the module
    // header). Imported here so those tests run under `zig build test`.
    _ = @import("memory/cycle_detector.zig");
    // The tracking manager carries inline behavioural tests for canary
    // detection, leak reporting, invalid-free, and size/alignment
    // mismatch. The integration tests in `memory/driver.zig` validate
    // the section/symbol pipeline using synthesised objects; this
    // import drives the manager's actual runtime behaviour through the
    // capturing diagnostic-writer hook declared in `tracking/manager.zig`.
    //
    // Importing the manager into the test binary pulls in its
    // `pub export const zap_memory_section` — the only `zap_memory_section`
    // export in the test binary. `runtime.zig`'s `externalMemorySection`
    // early-returns null in `builtin.is_test` mode, so the symbol's
    // presence is harmless: the test-only ARC fallback continues to
    // drive every test allocation.
    _ = @import("memory/tracking/manager.zig");
}
