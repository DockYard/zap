//! Zap Frontend Compiler Pipeline
//!
//! Reusable compilation pipeline: source → parse → collect → macro → desugar →
//! type check → HIR → IR. Used by both the builder phase (compiling build.zap)
//! and the target build phase (compiling project source).

const std = @import("std");
const zap = @import("root.zig");
const ir = zap.ir;
const ast = zap.ast;
// zig_lib_archive is only available in the main binary, not the library.
// extractEmbeddedZigLib is called from main.zig which has access to it.

const runtime_source = @embedFile("runtime.zig");
const lexer = @import("lexer.zig");

pub const CompileResult = struct {
    ir_program: ir.Program,
    analysis_context: ?zap.escape_lattice.AnalysisContext = null,
};

pub const CompileError = error{
    ParseFailed,
    CollectFailed,
    MacroExpansionFailed,
    DesugarFailed,
    TypeCheckFailed,
    HirFailed,
    IrFailed,
    OutOfMemory,
    ReadError,
};

pub const CompileOptions = struct {
    /// Treat type warnings as hard errors.
    strict_types: bool = false,
    /// Show progress output to stderr.
    show_progress: bool = true,
    /// lib mode — skip main function emission in ZIR.
    lib_mode: bool = false,
    /// Module names in dependency order for CTFE evaluation.
    /// When set, computed attributes are evaluated per-module in this order.
    module_order: ?[]const []const u8 = null,
    /// Directory for persistent CTFE cache. When set, computed attribute
    /// results are cached to disk and reused across builds.
    cache_dir: ?[]const u8 = null,
    /// Target name used when hashing CTFE cache keys.
    ctfe_target: ?[]const u8 = null,
    /// Optimize mode used when hashing CTFE cache keys.
    ctfe_optimize: ?[]const u8 = null,
};

fn ctfeCompileOptionsHash(options: CompileOptions) u64 {
    return if (options.ctfe_target != null or options.ctfe_optimize != null)
        zap.ctfe.hashCompileOptions(options.ctfe_target orelse "", options.ctfe_optimize orelse "")
    else
        0;
}

/// Compile Zap source text through the full frontend pipeline:
/// parse → collect → macro → desugar → type check → HIR → IR.
///
/// `source` is raw Zap source.
/// `file_path` is used for diagnostic display only.
/// Diagnostics are emitted to stderr on failure.
pub fn compileFrontend(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    var ctx = try collectAllFromUnits(alloc, &[_]SourceUnit{.{ .file_path = file_path, .source = source }}, options);
    return try compileFiles(alloc, &ctx, options);
}

// ============================================================
// Per-File Compilation Architecture
//
// Three-pass pipeline:
//   Pass 1 (collectAll): Parse all files, collect declarations into shared context
//   Pass 2 (compileFile): Per-file macro expand → desugar → typecheck → HIR → IR
//   Pass 3 (mergeAndFinalize): Merge IR programs, run analysis pipeline
// ============================================================

/// Shared compilation state from Pass 1. Holds the scope graph, type store,
/// and interner that all files compile against.
pub const CompilationContext = struct {
    alloc: std.mem.Allocator,
    /// The merged program AST (all files' modules combined)
    merged_program: ast.Program,
    /// Single-module AST programs keyed by module name, used by the
    /// module-by-module pipeline so it does not need to re-extract modules
    /// from the merged AST during later stages.
    module_programs: []const ModuleProgram,
    /// First-class per-module compilation units derived during collectAll.
    units: []CompilationUnit,
    /// Original per-file source units used to derive merged parser input.
    source_units: []const SourceUnit,
    /// String interner shared across all parsed source units.
    interner: ast.StringInterner,
    /// Scope graph with all modules' declarations
    collector: zap.Collector,
    /// Diagnostic engine
    diag_engine: zap.DiagnosticEngine,
    /// The full source (all files) for diagnostic display
    full_source: []const u8,
    /// Source file path for diagnostic display
    source_path: []const u8,
};

pub const ModuleProgram = struct {
    name: []const u8,
    program: ast.Program,
};

/// Per-file compilation state.
pub const CompilationUnit = struct {
    file_path: []const u8,
    module_name: []const u8,
    source: []const u8,
    /// Index of this file's module in the merged program's modules array
    module_index: ?u32 = null,
    /// Per-file IR program, populated by compileFile
    ir_program: ?ir.Program = null,
    /// Which dep this file belongs to (null for project files)
    dep: ?[]const u8 = null,
};

pub const SourceUnit = struct {
    file_path: []const u8,
    source: []const u8,
};

/// Pass 1: Parse all source files and collect declarations into a shared context.
///
/// Takes a merged source string (all files concatenated) and a file path for
/// diagnostics. Returns a CompilationContext with the shared scope graph and
/// type store populated.
///
/// This is equivalent to the parse + collect phases of compileFrontend.
pub fn collectAll(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: CompileOptions,
) CompileError!CompilationContext {
    const source_units = [_]SourceUnit{.{ .file_path = file_path, .source = source }};
    return collectAllFromUnits(alloc, &source_units, options);
}

pub fn collectAllFromUnits(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    options: CompileOptions,
) CompileError!CompilationContext {
    const progress = std.fs.File.stderr().deprecatedWriter();
    var step: u32 = 0;
    const total_steps: u32 = 11;
    const file_path = if (source_units.len > 0) source_units[0].file_path else "<memory>";

    if (options.show_progress) {
        progress.print("Compiling\n", .{}) catch {};
    }

    var diag_engine = zap.DiagnosticEngine.init(alloc);
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Parse each source unit independently with a shared interner.
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Parse", .{ step, total_steps }) catch {};

    const all_source_units = source_units;
    const merged_source = try mergeSourceUnits(alloc, all_source_units);

    setDiagnosticSources(&diag_engine, all_source_units);
    diag_engine.setLineOffset(0);

    var interner = ast.StringInterner.init(alloc);
    const parsed_programs = try alloc.alloc(ast.Program, all_source_units.len);
    for (all_source_units, 0..) |unit, i| {
        var parser = zap.Parser.initWithSharedInterner(alloc, unit.source, &interner, @intCast(i));
        defer parser.deinit();

        parsed_programs[i] = parser.parseProgram() catch {
            emitParseErrorsFromUnits(alloc, parser.errors.items, all_source_units, diag_engine.use_color);
            if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
            return error.ParseFailed;
        };

        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    const program = try mergePrograms(alloc, parsed_programs);
    const module_programs = try buildModulePrograms(alloc, &program, &interner);

    // Collect declarations from explicit per-module programs instead of
    // rebuilding the graph from the merged AST.
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Collect", .{ step, total_steps }) catch {};

    var collector = zap.Collector.init(alloc, &interner);
    for (module_programs) |entry| {
        collector.collectProgramSurface(&entry.program) catch {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }

    // Collect top-level items (struct, enum, etc.) from the merged program.
    // Per-module programs only contain modules; top_items live on the merged program.
    if (program.top_items.len > 0) {
        const top_only = ast.Program{ .modules = &.{}, .top_items = program.top_items };
        collector.collectProgramSurface(&top_only) catch {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }
    const program_slices = try alloc.alloc(ast.Program, module_programs.len);
    for (module_programs, 0..) |entry, i| program_slices[i] = entry.program;
    collector.finalizeCollectedPrograms(program_slices) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.CollectFailed;
    };

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.CollectFailed;
    }

    const units = try buildCompilationUnits(alloc, module_programs, all_source_units);

    return .{
        .alloc = alloc,
        .merged_program = program,
        .module_programs = module_programs,
        .units = units,
        .source_units = all_source_units,
        .interner = interner,
        .collector = collector,
        .diag_engine = diag_engine,
        .full_source = merged_source,
        .source_path = file_path,
    };
}

/// Pass 2: Compile the merged program through macro expansion, desugaring,
/// type checking, HIR, and IR.
///
/// This processes all files together (the per-file parallelization will be
/// added when the type checker and HIR builder support single-module operation).
/// Returns an ir.Program covering all modules.
pub fn compileFiles(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    options: CompileOptions,
) CompileError!CompileResult {
    const progress = std.fs.File.stderr().deprecatedWriter();
    const total_steps: u32 = 11;
    var step: u32 = 2; // already past parse + collect

    // Attribute substitution (replace @name references with attribute values)
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Substitute attributes", .{ step, total_steps }) catch {};

    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const substituted_program = zap.attr_substitute.substituteAttributes(
        alloc,
        &ctx.merged_program,
        &ctx.collector.graph,
        &ctx.interner,
        &subst_errors,
    ) catch {
        ctx.diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    }

    // Macro expansion
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Expand macros", .{ step, total_steps }) catch {};

    var macro_engine = zap.MacroEngine.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&substituted_program) catch {
        for (macro_engine.errors.items) |macro_err| {
            ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    };

    for (macro_engine.errors.items) |macro_err| {
        ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    }

    // Desugaring
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps }) catch {};

    var desugarer = zap.Desugarer.init(alloc, &ctx.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        ctx.diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };

    // Register new functions added by desugaring (e.g., __for_N helpers from for comprehensions).
    // Walk the desugared program and collect any priv_function items that aren't already in scope.
    for (desugared_program.modules) |*mod| {
        // Find the existing module scope
        const mod_scope = ctx.collector.graph.findModuleScope(mod.name) orelse continue;
        for (mod.items) |item| {
            switch (item) {
                .priv_function => |func| {
                    const key = zap.scope.FamilyKey{
                        .name = func.name,
                        .arity = @intCast(func.clauses[0].params.len),
                    };
                    const scope_data = ctx.collector.graph.getScope(mod_scope);
                    if (scope_data.function_families.get(key) == null) {
                        // New function — register it
                        ctx.collector.collectFunction(func, mod_scope) catch {};
                    }
                },
                else => {},
            }
        }
    }

    // Type checking (first pass)
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Type check", .{ step, total_steps }) catch {};

    var type_checker = zap.types.TypeChecker.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer type_checker.deinit();

    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // HIR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] HIR", .{ step, total_steps }) catch {};

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.interner, &ctx.collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };

    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    }

    // IR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] IR", .{ step, total_steps }) catch {};

    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.interner);
    ir_builder.type_store = &type_checker.store;
    ir_builder.scope_graph = &ctx.collector.graph;
    defer ir_builder.deinit();
    var ir_program = ir_builder.buildProgram(&hir_program) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };

    // CTFE for computed attributes
    if (options.module_order) |module_order| {
        _ = zap.ctfe.evaluateModuleAttributesInOrder(
            alloc,
            &ir_program,
            &ctx.collector.graph,
            &ctx.interner,
            module_order,
            options.cache_dir,
            ctfeCompileOptionsHash(options),
        ) catch {};
    } else {
        _ = zap.ctfe.evaluateComputedAttributes(
            alloc,
            &ir_program,
            &ctx.collector.graph,
            &ctx.interner,
            options.cache_dir,
            ctfeCompileOptionsHash(options),
        ) catch {};
    }

    // Analysis pipeline
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Escape analysis", .{ step, total_steps }) catch {};

    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, &ir_program) catch {
        ctx.diag_engine.err("Error during escape analysis", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };
    zap.contification_rewrite.rewriteContifiedContinuations(alloc, &ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return error.IrFailed,
    };

    // Second type-check pass (with analysis context)
    type_checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    for (pipeline_result.diagnostics.items) |analysis_diag| {
        ctx.diag_engine.reportDiagnostic(analysis_diag) catch {};
    }

    for (type_checker.errors.items) |type_err| {
        ctx.diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.TypeCheckFailed;
    }

    // Emit warnings
    if (ctx.diag_engine.warningCount() > 0) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitContextDiagnostics(ctx, alloc);
    }

    if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};

    return .{ .ir_program = ir_program, .analysis_context = pipeline_result.context };
}

/// Compile a single file's module through macro expansion, desugaring,
/// type checking, HIR, and IR. Stores the result in the CompilationUnit.
///
/// This is the per-file compilation entry point. Currently it requires the
/// full merged program (via CompilationContext) because the type checker,
/// HIR builder, and IR builder operate on the full program. When these
/// phases support single-module operation, this function will process only
/// the unit's module.
///
/// For now, this delegates to compileFiles for the actual work and extracts
/// the per-module IR. The function signature is the correct API for future
/// per-file parallelism.
pub fn compileFile(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    unit: *CompilationUnit,
    options: CompileOptions,
) CompileError!void {
    const mod_program = lookupModuleProgram(ctx, unit.module_name) orelse {
        ctx.diag_engine.err("Module disappeared during per-module compilation", .{ .start = 0, .end = 0 }) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.CollectFailed;
    };
    unit.ir_program = try compileSingleModuleIr(alloc, ctx, unit.module_name, mod_program, options);
}

/// Pass 3: Finalize compilation — wrap the IR program with analysis context.
///
/// Currently this is a no-op wrapper since analysis runs inside compileFiles.
/// When per-file IR generation is implemented, this will merge per-file IR
/// programs and run the analysis pipeline on the merged result.
/// Pass 3: Merge per-file IR programs and run the analysis pipeline.
///
/// When per-file IR generation is implemented, this will accept multiple
/// per-file IR programs, merge them, and run analysis on the merged result.
/// Currently takes a single pre-merged IR program.
pub fn mergeAndFinalize(
    alloc: std.mem.Allocator,
    ir_program: *ir.Program,
) CompileError!CompileResult {
    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, ir_program) catch {
        return error.IrFailed;
    };
    zap.contification_rewrite.rewriteContifiedContinuations(alloc, ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return error.IrFailed,
    };

    return .{ .ir_program = ir_program.*, .analysis_context = pipeline_result.context };
}

/// Compile using the per-file architecture: collectAll → compileFiles → result.
/// This is the new entry point that replaces compileFrontend for the
/// import-driven pipeline.
pub fn compilePerFile(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    var ctx = try collectAll(alloc, source, file_path, options);
    return try compileFiles(alloc, &ctx, options);
}

fn compileSingleModuleIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    mod_program: *const ast.Program,
    options: CompileOptions,
) CompileError!ir.Program {
    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const substituted = zap.attr_substitute.substituteAttributes(
        alloc,
        mod_program,
        &ctx.collector.graph,
        &ctx.interner,
        &subst_errors,
    ) catch {
        ctx.diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    }

    var macro_engine = zap.MacroEngine.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer macro_engine.deinit();
    const expanded = macro_engine.expandProgram(&substituted) catch {
        for (macro_engine.errors.items) |macro_err| {
            ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    };
    for (macro_engine.errors.items) |macro_err| {
        ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    }

    var desugarer = zap.Desugarer.init(alloc, &ctx.interner);
    const desugared = desugarer.desugarProgram(&expanded) catch {
        ctx.diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };

    var type_checker = zap.types.TypeChecker.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer type_checker.deinit();

    type_checker.checkProgram(&desugared) catch {};
    type_checker.checkUnusedBindings() catch {};
    for (type_checker.errors.items) |type_err| {
        ctx.diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.TypeCheckFailed;
    }

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.interner, &ctx.collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };
    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    }

    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.interner);
    ir_builder.type_store = &type_checker.store;
    ir_builder.scope_graph = &ctx.collector.graph;
    defer ir_builder.deinit();
    const mod_ir = ir_builder.buildProgram(&hir_program) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };

    const ctfe_result = zap.ctfe.evaluateComputedAttributesForModule(
        alloc,
        &mod_ir,
        &ctx.collector.graph,
        &ctx.interner,
        mod_name,
        options.cache_dir,
        ctfeCompileOptionsHash(options),
    ) catch null;
    if (ctfe_result) |cr| {
        if (cr.errors.len > 0) zap.ctfe.emitCtfeErrors(alloc, cr.errors);
    }

    return mod_ir;
}

/// True per-module compilation: process each module independently through
/// macro → desugar → typecheck → HIR → IR, in dependency order.
///
/// After each module's IR is built, runs CTFE on its computed attributes
/// and registers the results for downstream modules to reference.
///
/// This is the architecture described in ir-interpreter-plan.md Phase 5:
/// "split macro expansion, desugaring, typechecking, HIR, and IR lowering
/// into real per-module units."
///
/// Requires that collectAll has already populated the shared scope graph
/// with all modules' declarations. Each module compiles against the full
/// scope graph (for cross-module type resolution) but only processes its
/// own AST through the pipeline.
pub fn compileModuleByModule(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    module_order: []const []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    const progress = std.fs.File.stderr().deprecatedWriter();

    // Collect all IR functions and type defs across modules
    var all_functions = std.ArrayListUnmanaged(ir.Function).empty;
    var all_type_defs = std.ArrayListUnmanaged(ir.TypeDef).empty;
    var entry_id: ?ir.FunctionId = null;
    var func_id_offset: u32 = 0;

    // Process each module in dependency order
    for (module_order, 0..) |mod_name, mod_idx| {
        if (options.show_progress) {
            progress.print("\r\x1b[K  [module {d}/{d}] {s}", .{ mod_idx + 1, module_order.len, mod_name }) catch {};
        }
        const unit = lookupCompilationUnit(ctx, mod_name) orelse {
            ctx.diag_engine.err("Module compilation unit disappeared during per-module compilation", .{ .start = 0, .end = 0 }) catch {};
            emitDiagnostics(&ctx.diag_engine, alloc);
            return error.CollectFailed;
        };
        try compileFile(alloc, ctx, unit, options);
        const mod_ir = unit.ir_program orelse return error.IrFailed;

        // Merge into combined program
        for (mod_ir.functions) |func| {
            const adjusted = try cloneFunctionWithOffset(alloc, func, func_id_offset);
            all_functions.append(alloc, adjusted) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |eid| {
            entry_id = func_id_offset + eid;
        }
        func_id_offset += @intCast(mod_ir.functions.len);
        for (mod_ir.type_defs) |td| {
            all_type_defs.append(alloc, td) catch return error.OutOfMemory;
        }
    }

    // Build merged IR program
    var merged_ir = ir.Program{
        .functions = all_functions.items,
        .type_defs = all_type_defs.items,
        .entry = entry_id,
    };

    // Run analysis pipeline on merged result
    return mergeAndFinalize(alloc, &merged_ir);
}

/// Extract a single-module ast.Program from the merged program.
fn extractModuleProgram(
    alloc: std.mem.Allocator,
    merged: *const ast.Program,
    mod_name: []const u8,
    interner: *const ast.StringInterner,
) ?ast.Program {
    for (merged.modules) |mod| {
        // Build module name string from parts
        if (mod.name.parts.len == 1) {
            if (std.mem.eql(u8, interner.get(mod.name.parts[0]), mod_name)) {
                const mods = alloc.alloc(ast.ModuleDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .modules = mods, .top_items = &.{} };
            }
        } else {
            var buf: [256]u8 = undefined;
            var pos: usize = 0;
            for (mod.name.parts, 0..) |part, i| {
                if (i > 0 and pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
                const s = interner.get(part);
                const end = @min(pos + s.len, buf.len);
                @memcpy(buf[pos..end], s[0 .. end - pos]);
                pos = end;
            }
            if (std.mem.eql(u8, buf[0..pos], mod_name)) {
                const mods = alloc.alloc(ast.ModuleDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .modules = mods, .top_items = &.{} };
            }
        }
    }
    return null;
}

fn buildModulePrograms(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *const ast.StringInterner,
) ![]const ModuleProgram {
    const result = try alloc.alloc(ModuleProgram, program.modules.len);
    for (program.modules, 0..) |mod, i| {
        const name = try moduleNameToOwnedString(alloc, mod.name, interner);
        const mods = try alloc.alloc(ast.ModuleDecl, 1);
        mods[0] = mod;
        result[i] = .{
            .name = name,
            .program = .{ .modules = mods, .top_items = &.{} },
        };
    }
    return result;
}

fn buildCompilationUnits(
    alloc: std.mem.Allocator,
    module_programs: []const ModuleProgram,
    source_units: []const SourceUnit,
) ![]CompilationUnit {
    // Build a unit for each module by matching module names to source files.
    // Source files that contain only top-level items (e.g., Zap.zap with pub struct)
    // won't have a matching module_program and are skipped.
    var units_list: std.ArrayListUnmanaged(CompilationUnit) = .empty;
    for (module_programs, 0..) |entry, mod_idx| {
        // Find the source unit whose file path best matches this module name.
        // For 1:1 cases (same count), use index mapping. Otherwise, try to
        // match by checking if the source file contains the module definition.
        const source_idx: usize = if (module_programs.len == source_units.len)
            mod_idx
        else blk: {
            // Convert module name to expected file basename: "Foo.Bar" -> "bar.zap"
            // Check each source unit for a match.
            for (source_units, 0..) |unit, si| {
                if (std.mem.indexOf(u8, unit.source, entry.name)) |_| {
                    break :blk si;
                }
            }
            // Fallback: use mod_idx clamped to source_units range
            break :blk @min(mod_idx, if (source_units.len > 0) source_units.len - 1 else 0);
        };
        const su = source_units[source_idx];
        try units_list.append(alloc, .{
            .file_path = su.file_path,
            .module_name = entry.name,
            .source = su.source,
            .module_index = @intCast(mod_idx),
            .ir_program = null,
            .dep = null,
        });
    }
    return try units_list.toOwnedSlice(alloc);
}

fn mergePrograms(alloc: std.mem.Allocator, programs: []const ast.Program) !ast.Program {
    var module_count: usize = 0;
    var top_item_count: usize = 0;
    for (programs) |program| {
        module_count += program.modules.len;
        top_item_count += program.top_items.len;
    }
    const modules = try alloc.alloc(ast.ModuleDecl, module_count);
    const top_items = try alloc.alloc(ast.TopItem, top_item_count);
    var module_index: usize = 0;
    var top_index: usize = 0;
    for (programs) |program| {
        @memcpy(modules[module_index .. module_index + program.modules.len], program.modules);
        @memcpy(top_items[top_index .. top_index + program.top_items.len], program.top_items);
        module_index += program.modules.len;
        top_index += program.top_items.len;
    }
    return .{ .modules = modules, .top_items = top_items };
}

pub fn mergeSourceUnits(alloc: std.mem.Allocator, source_units: []const SourceUnit) ![]const u8 {
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    for (source_units) |unit| {
        try combined.appendSlice(alloc, unit.source);
        try combined.append(alloc, '\n');
    }
    return combined.toOwnedSlice(alloc);
}

fn emitParseErrorsFromUnits(
    alloc: std.mem.Allocator,
    parse_errors: []const zap.Parser.Error,
    source_units: []const SourceUnit,
    use_color: bool,
) void {
    var engine = zap.DiagnosticEngine.init(alloc);
    engine.use_color = use_color;
    setDiagnosticSources(&engine, source_units);
    for (parse_errors) |parse_err| {
        engine.reportDiagnostic(.{
            .severity = .@"error",
            .message = parse_err.message,
            .span = parse_err.span,
            .label = parse_err.label,
            .help = parse_err.help,
        }) catch {};
    }
    emitDiagnostics(&engine, alloc);
}

fn setDiagnosticSources(engine: *zap.DiagnosticEngine, source_units: []const SourceUnit) void {
    const sources = engine.allocator.alloc(zap.DiagnosticEngine.SourceFile, source_units.len) catch return;
    defer engine.allocator.free(sources);
    for (source_units, 0..) |unit, i| {
        sources[i] = .{ .source = unit.source, .file_path = unit.file_path };
    }
    engine.setSources(sources);
}

fn emitDiagnosticsFromUnits(
    alloc: std.mem.Allocator,
    diagnostics: []const zap.diagnostics.Diagnostic,
    source_units: []const SourceUnit,
    use_color: bool,
) void {
    var engine = zap.DiagnosticEngine.init(alloc);
    engine.use_color = use_color;
    setDiagnosticSources(&engine, source_units);
    for (diagnostics) |diag| {
        engine.reportDiagnostic(.{
            .severity = diag.severity,
            .message = diag.message,
            .span = diag.span,
            .notes = diag.notes,
            .label = diag.label,
            .secondary_spans = diag.secondary_spans,
            .help = diag.help,
            .suggestion = diag.suggestion,
            .code = diag.code,
        }) catch {};
    }
    emitDiagnostics(&engine, alloc);
}

fn emitContextDiagnostics(ctx: *const CompilationContext, alloc: std.mem.Allocator) void {
    emitDiagnostics(@constCast(&ctx.diag_engine), alloc);
}

fn moduleNameToOwnedString(
    alloc: std.mem.Allocator,
    name: ast.ModuleName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    if (name.parts.len == 1) return alloc.dupe(u8, interner.get(name.parts[0]));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, interner.get(part));
    }
    return buf.toOwnedSlice(alloc);
}

fn lookupModuleProgram(ctx: *const CompilationContext, mod_name: []const u8) ?*const ast.Program {
    for (ctx.module_programs) |*entry| {
        if (std.mem.eql(u8, entry.name, mod_name)) return &entry.program;
    }
    return null;
}

fn lookupCompilationUnit(ctx: *CompilationContext, mod_name: []const u8) ?*CompilationUnit {
    for (ctx.units) |*unit| {
        if (std.mem.eql(u8, unit.module_name, mod_name)) return unit;
    }
    return null;
}

fn cloneFunctionWithOffset(alloc: std.mem.Allocator, func: ir.Function, function_id_offset: u32) error{OutOfMemory}!ir.Function {
    const blocks = try alloc.alloc(ir.Block, func.body.len);
    for (func.body, 0..) |block, i| {
        blocks[i] = .{
            .label = block.label,
            .instructions = try cloneInstructionsWithOffset(alloc, block.instructions, function_id_offset),
        };
    }

    var adjusted = func;
    adjusted.id = function_id_offset + func.id;
    adjusted.body = blocks;
    return adjusted;
}

fn cloneInstructionsWithOffset(alloc: std.mem.Allocator, instrs: []const ir.Instruction, function_id_offset: u32) error{OutOfMemory}![]const ir.Instruction {
    const cloned = try alloc.alloc(ir.Instruction, instrs.len);
    for (instrs, 0..) |instr, i| {
        cloned[i] = try cloneInstructionWithOffset(alloc, instr, function_id_offset);
    }
    return cloned;
}

fn cloneInstructionWithOffset(alloc: std.mem.Allocator, instr: ir.Instruction, function_id_offset: u32) error{OutOfMemory}!ir.Instruction {
    var adjusted = instr;
    switch (instr) {
        .call_direct => |call| {
            var next = call;
            next.function += function_id_offset;
            adjusted = .{ .call_direct = next };
        },
        .call_dispatch => |call| {
            var next = call;
            next.group_id += function_id_offset;
            adjusted = .{ .call_dispatch = next };
        },
        .make_closure => |closure| {
            var next = closure;
            next.function += function_id_offset;
            adjusted = .{ .make_closure = next };
        },
        .if_expr => |if_expr| {
            var next = if_expr;
            next.then_instrs = try cloneInstructionsWithOffset(alloc, if_expr.then_instrs, function_id_offset);
            next.else_instrs = try cloneInstructionsWithOffset(alloc, if_expr.else_instrs, function_id_offset);
            adjusted = .{ .if_expr = next };
        },
        .guard_block => |guard| {
            var next = guard;
            next.body = try cloneInstructionsWithOffset(alloc, guard.body, function_id_offset);
            adjusted = .{ .guard_block = next };
        },
        .case_block => |case_block| {
            var next = case_block;
            next.pre_instrs = try cloneInstructionsWithOffset(alloc, case_block.pre_instrs, function_id_offset);
            next.default_instrs = try cloneInstructionsWithOffset(alloc, case_block.default_instrs, function_id_offset);
            const arms = try alloc.alloc(ir.IrCaseArm, case_block.arms.len);
            for (case_block.arms, 0..) |arm, i| {
                var arm_copy = arm;
                arm_copy.cond_instrs = try cloneInstructionsWithOffset(alloc, arm.cond_instrs, function_id_offset);
                arm_copy.body_instrs = try cloneInstructionsWithOffset(alloc, arm.body_instrs, function_id_offset);
                arms[i] = arm_copy;
            }
            next.arms = arms;
            adjusted = .{ .case_block = next };
        },
        .switch_literal => |switch_literal| {
            var next = switch_literal;
            next.default_instrs = try cloneInstructionsWithOffset(alloc, switch_literal.default_instrs, function_id_offset);
            const cases = try alloc.alloc(ir.LitCase, switch_literal.cases.len);
            for (switch_literal.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .switch_literal = next };
        },
        .switch_return => |switch_return| {
            var next = switch_return;
            next.default_instrs = try cloneInstructionsWithOffset(alloc, switch_return.default_instrs, function_id_offset);
            const cases = try alloc.alloc(ir.ReturnCase, switch_return.cases.len);
            for (switch_return.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .switch_return = next };
        },
        .union_switch_return => |switch_return| {
            var next = switch_return;
            const cases = try alloc.alloc(ir.UnionCase, switch_return.cases.len);
            for (switch_return.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .union_switch_return = next };
        },
        else => {},
    }
    return adjusted;
}

/// Compile a Zap source file through the frontend and ZIR backend to produce
/// a native binary.
pub fn compileToNative(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    output_path: []const u8,
    _: []const u8,
    frontend_opts: CompileOptions,
    backend_opts: zap.zir_backend.CompileOptions,
) !void {
    var result = try compileFrontend(alloc, source, file_path, frontend_opts);

    const progress = std.fs.File.stderr().deprecatedWriter();
    if (frontend_opts.show_progress) {
        progress.print("\r\x1b[K  [8/10] ZIR", .{}) catch {};
    }

    var opts = backend_opts;
    if (result.analysis_context != null) {
        opts.analysis_context = &result.analysis_context.?;
    }
    try zap.zir_backend.compile(alloc, result.ir_program, opts);

    if (frontend_opts.show_progress) {
        progress.print("\r\x1b[K  [9/10] Sema + Codegen", .{}) catch {};
        progress.print("\r\x1b[K  [10/10] Linked {s}\n", .{output_path}) catch {};
    }
}

fn emitDiagnostics(diag_engine: *zap.DiagnosticEngine, alloc: std.mem.Allocator) void {
    const rendered = diag_engine.format(alloc) catch return;
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("{s}", .{rendered}) catch {};
}

const testing = std.testing;

test "cloneFunctionWithOffset rewrites nested function references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 2,
        .name = "Test__nested",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_direct = .{ .dest = 0, .function = 1, .args = &.{}, .arg_modes = &.{} } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{.{ .make_closure = .{ .dest = 2, .function = 3, .captures = &.{} } }},
                    .then_result = 2,
                    .else_instrs = &.{.{ .call_dispatch = .{ .dest = 3, .group_id = 4, .args = &.{}, .arg_modes = &.{} } }},
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };

    const adjusted = try cloneFunctionWithOffset(alloc, func, 10);
    try testing.expectEqual(@as(ir.FunctionId, 12), adjusted.id);
    try testing.expectEqual(@as(ir.FunctionId, 11), adjusted.body[0].instructions[0].call_direct.function);
    try testing.expectEqual(@as(ir.FunctionId, 13), adjusted.body[0].instructions[1].if_expr.then_instrs[0].make_closure.function);
    try testing.expectEqual(@as(u32, 14), adjusted.body[0].instructions[1].if_expr.else_instrs[0].call_dispatch.group_id);
}

/// Run a compiled binary by name from zap-out/bin/.
pub fn runBinary(allocator: std.mem.Allocator, bin_path: []const u8, program_args: []const []const u8) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path);
    for (program_args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Validate that a source file contains exactly one module declaration and that the
/// module name matches the file path. Returns an error message if validation
/// fails, or null if the file is valid.
///
/// `file_path` is relative to the lib root (e.g., "config/parser.zap").
/// The expected module name is derived from the path: "config/parser.zap" → "Config.Parser".
pub fn validateOneModulePerFile(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
) ?[]const u8 {
    // Use an arena for scratch allocations (parser, name buffers).
    // Only the returned error message (if any) is allocated with the caller's allocator.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse without stdlib — we only need to count module declarations
    var parser = zap.Parser.init(arena, source);

    const program = parser.parseProgram() catch {
        // Parse errors will be caught later in the full compilation.
        return null;
    };

    // Count top-level module declarations (both public and private)
    var module_count: u32 = 0;
    var module_name_parts: ?[]const ast.StringId = null;
    for (program.top_items) |item| {
        switch (item) {
            .module => |mod| {
                module_count += 1;
                module_name_parts = mod.name.parts;
            },
            .priv_module => |mod| {
                module_count += 1;
                module_name_parts = mod.name.parts;
            },
            else => {},
        }
    }
    // Also count from program.modules (the parser populates both)
    if (module_count == 0) {
        for (program.modules) |mod| {
            module_count += 1;
            module_name_parts = mod.name.parts;
        }
    }

    if (module_count == 0) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one module declaration, found none", .{file_path}) catch "file has no module";
    }

    if (module_count > 1) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one module declaration, found {d}", .{ file_path, module_count }) catch "file has multiple modules";
    }

    // Build the actual module name from the AST
    const parts = module_name_parts orelse return null;
    var actual_name: std.ArrayListUnmanaged(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) actual_name.append(arena, '.') catch return null;
        actual_name.appendSlice(arena, parser.interner.get(part)) catch return null;
    }

    // Build the expected module name from the file path
    // "config/parser.zap" → "Config.Parser"
    var expected_name: std.ArrayListUnmanaged(u8) = .empty;

    // Strip .zap extension
    const path_no_ext = if (std.mem.endsWith(u8, file_path, ".zap"))
        file_path[0 .. file_path.len - 4]
    else
        file_path;

    // Split on '/' and capitalize each segment
    var seg_iter = std.mem.splitScalar(u8, path_no_ext, '/');
    var first_seg = true;
    while (seg_iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (!first_seg) expected_name.append(arena, '.') catch return null;
        first_seg = false;

        // Capitalize: convert snake_case to PascalCase
        // "config_parser" → "ConfigParser", "config" → "Config"
        var capitalize_next = true;
        for (segment) |c| {
            if (c == '_') {
                capitalize_next = true;
            } else {
                if (capitalize_next) {
                    expected_name.append(arena, std.ascii.toUpper(c)) catch return null;
                    capitalize_next = false;
                } else {
                    expected_name.append(arena, c) catch return null;
                }
            }
        }
    }

    if (!std.mem.eql(u8, actual_name.items, expected_name.items)) {
        // Allocate the error message with the caller's allocator so it outlives the arena
        return std.fmt.allocPrint(
            alloc,
            "Module name `{s}` does not match file path `{s}` — expected `{s}`",
            .{ actual_name.items, file_path, expected_name.items },
        ) catch "module name does not match file path";
    }

    return null;
}

/// Get the embedded runtime source.
pub fn getRuntimeSource() []const u8 {
    return runtime_source;
}

// ============================================================
// Tests
// ============================================================

test "validateOneModulePerFile: valid single module" {
    const alloc = std.testing.allocator;
    const source = "pub module Config {\n  pub fn load() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid nested module name" {
    const alloc = std.testing.allocator;
    const source = "pub module Config.Parser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config/parser.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid private module" {
    const alloc = std.testing.allocator;
    const source = "module Config.Helpers {\n  pub fn help() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config/helpers.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: zero modules is error" {
    const alloc = std.testing.allocator;
    const source = "pub struct Point {\n  x :: i64\n}\n";
    const result = validateOneModulePerFile(alloc, source, "point.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "found none") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: multiple modules is error" {
    const alloc = std.testing.allocator;
    const source = "pub module Foo {\n  pub fn foo() -> i64 {\n    1\n  }\n}\npub module Bar {\n  pub fn bar() -> i64 {\n    2\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "foo.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "found 2") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: name mismatch is error" {
    const alloc = std.testing.allocator;
    const source = "pub module WrongName {\n  pub fn foo() -> i64 {\n    1\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "does not match") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: snake_case path to PascalCase" {
    const alloc = std.testing.allocator;
    const source = "pub module JsonParser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "json_parser.zap");
    try std.testing.expectEqual(null, result);
}

test "buildModulePrograms stores per-module AST programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub module Foo {\n" ++
        "}\n" ++
        "pub module Bar.Baz {\n" ++
        "}\n" ++
        "";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    try std.testing.expectEqual(@as(usize, 2), module_programs.len);
    try std.testing.expectEqualStrings("Foo", module_programs[0].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[0].program.modules.len);
    try std.testing.expectEqualStrings("Bar.Baz", module_programs[1].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[1].program.modules.len);
}

test "buildCompilationUnits derives units from module programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub module Foo {\n" ++
        "}\n" ++
        "pub module Bar.Baz {\n" ++
        "}\n";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "fixture.zap", .source = "pub module Foo {\n}\n" },
        .{ .file_path = "fixture.zap", .source = "pub module Bar.Baz {\n}\n" },
    };
    const units = try buildCompilationUnits(alloc, module_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].module_name);
    try std.testing.expectEqualStrings("fixture.zap", units[0].file_path);
    try std.testing.expectEqual(@as(u32, 0), units[0].module_index.?);
    try std.testing.expectEqualStrings("Bar.Baz", units[1].module_name);
    try std.testing.expectEqual(@as(u32, 1), units[1].module_index.?);
}

test "mergeSourceUnits concatenates explicit source units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const units = [_]SourceUnit{
        .{ .file_path = "foo.zap", .source = "pub module Foo {\n}\n" },
        .{ .file_path = "bar.zap", .source = "pub module Bar {\n}\n" },
    };

    const merged = try mergeSourceUnits(alloc, &units);
    try std.testing.expectEqualStrings(
        "pub module Foo {\n}\n\npub module Bar {\n}\n\n",
        merged,
    );
}

test "per-unit parser assigns source_id and file-local spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    var parser = zap.Parser.initWithSharedInterner(
        alloc,
        "pub module Bar {\n  bad(\n}\n",
        &interner,
        7,
    );
    defer parser.deinit();

    _ = parser.parseProgram() catch {};
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqual(@as(?u32, 7), parser.errors.items[0].span.source_id);
    try std.testing.expectEqual(@as(u32, 2), parser.errors.items[0].span.line);
    try std.testing.expectEqual(@as(u32, 3), parser.errors.items[0].span.col);
}

test "collector can build graph from per-module programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub module Foo {\n" ++
        "  pub fn run() -> i64 {\n" ++
        "    1\n" ++
        "  }\n" ++
        "}\n" ++
        "pub module Bar {\n" ++
        "  pub fn call() -> i64 {\n" ++
        "    Foo.run()\n" ++
        "  }\n" ++
        "}\n";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const program_slices = try alloc.alloc(ast.Program, module_programs.len);
    for (module_programs, 0..) |entry, i| program_slices[i] = entry.program;

    var collector = zap.Collector.init(alloc, parser.interner);
    defer collector.deinit();
    for (module_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    try std.testing.expectEqual(@as(usize, 2), collector.graph.modules.items.len);
}

test "@native attribute survives parse -> collect pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Source with @native attribute followed by a bodyless function declaration
    const source =
        "pub module TestNative {\n" ++
        "  @native = \"Prelude.println\"\n" ++
        "  pub fn puts(_message :: String) -> String\n" ++
        "\n" ++
        "  @native = \"Prelude.print_str\"\n" ++
        "  pub fn print_str(_message :: String) -> String\n" ++
        "}\n";

    // Step 1: Parse
    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    // Verify parse produced one module with 4 items (2 attributes + 2 functions)
    try std.testing.expectEqual(@as(usize, 1), program.modules.len);
    const mod = program.modules[0];
    try std.testing.expectEqual(@as(usize, 4), mod.items.len);

    // Verify item ordering: attribute, function, attribute, function
    try std.testing.expect(mod.items[0] == .attribute);
    try std.testing.expect(mod.items[1] == .function);
    try std.testing.expect(mod.items[2] == .attribute);
    try std.testing.expect(mod.items[3] == .function);

    // Verify the first attribute is @native = "Prelude.println"
    const attr0 = mod.items[0].attribute;
    try std.testing.expectEqualStrings("native", parser.interner.get(attr0.name));
    try std.testing.expect(attr0.value != null);
    try std.testing.expect(attr0.value.?.* == .string_literal);
    try std.testing.expectEqualStrings("Prelude.println", parser.interner.get(attr0.value.?.string_literal.value));

    // Verify the first function is bodyless (no body = @native declaration)
    const func0 = mod.items[1].function;
    try std.testing.expectEqualStrings("puts", parser.interner.get(func0.name));
    try std.testing.expect(func0.clauses.len == 1);
    try std.testing.expect(func0.clauses[0].body == null); // bodyless = @native

    // Step 2: Collect — verify @native attaches to the function family
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const program_slices = try alloc.alloc(ast.Program, module_programs.len);
    for (module_programs, 0..) |entry, i| program_slices[i] = entry.program;

    var collector = zap.Collector.init(alloc, parser.interner);
    defer collector.deinit();
    for (module_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    // Find the module scope
    try std.testing.expectEqual(@as(usize, 1), collector.graph.modules.items.len);
    const mod_scope_id = collector.graph.modules.items[0].scope_id;
    const mod_scope = collector.graph.getScope(mod_scope_id);

    // Resolve function families and check their @native attributes
    const puts_name = parser.interner.map.get("puts").?;
    const puts_key = zap.scope.FamilyKey{ .name = puts_name, .arity = 1 };
    const puts_fid = mod_scope.function_families.get(puts_key).?;
    const puts_family = collector.graph.getFamily(puts_fid);

    // The @native attribute must be attached to the puts family
    try std.testing.expect(puts_family.attributes.items.len >= 1);
    var found_native_puts = false;
    for (puts_family.attributes.items) |attr| {
        if (std.mem.eql(u8, parser.interner.get(attr.name), "native")) {
            if (attr.value) |val| {
                if (val.* == .string_literal) {
                    try std.testing.expectEqualStrings("Prelude.println", parser.interner.get(val.string_literal.value));
                    found_native_puts = true;
                }
            }
        }
    }
    try std.testing.expect(found_native_puts);

    // Check second function: print_str
    const print_str_name = parser.interner.map.get("print_str").?;
    const print_str_key = zap.scope.FamilyKey{ .name = print_str_name, .arity = 1 };
    const print_str_fid = mod_scope.function_families.get(print_str_key).?;
    const print_str_family = collector.graph.getFamily(print_str_fid);

    try std.testing.expect(print_str_family.attributes.items.len >= 1);
    var found_native_print_str = false;
    for (print_str_family.attributes.items) |attr| {
        if (std.mem.eql(u8, parser.interner.get(attr.name), "native")) {
            if (attr.value) |val| {
                if (val.* == .string_literal) {
                    try std.testing.expectEqualStrings("Prelude.print_str", parser.interner.get(val.string_literal.value));
                    found_native_print_str = true;
                }
            }
        }
    }
    try std.testing.expect(found_native_print_str);
}

test "@native survives multi-file merge (boundary between files)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simulate lib/io.zap content (with @native)
    const io_source =
        "pub module IO {\n" ++
        "  @native = \"Prelude.println\"\n" ++
        "  pub fn puts(_message :: String) -> String\n" ++
        "}\n";

    // Simulate lib/string.zap content (normal module)
    const string_source =
        "pub module MyString {\n" ++
        "  pub fn length(s :: String) -> i64 {\n" ++
        "    0\n" ++
        "  }\n" ++
        "}\n";

    // Step 1: Verify mergeSourceUnits adds newlines between files
    const units = [_]SourceUnit{
        .{ .file_path = "lib/io.zap", .source = io_source },
        .{ .file_path = "lib/string.zap", .source = string_source },
    };
    const merged = try mergeSourceUnits(alloc, &units);

    // The merged source should have a newline between files
    // io_source already ends with \n, mergeSourceUnits adds another \n
    try std.testing.expect(std.mem.indexOf(u8, merged, "}\n\npub module MyString") != null);

    // Step 2: Parse each unit independently (as the real pipeline does)
    var interner = ast.StringInterner.init(alloc);
    const parsed_programs = try alloc.alloc(ast.Program, units.len);
    for (units, 0..) |unit, i| {
        var parser = zap.Parser.initWithSharedInterner(alloc, unit.source, &interner, @intCast(i));
        defer parser.deinit();
        parsed_programs[i] = try parser.parseProgram();
    }

    // Step 3: Merge parsed programs
    const program = try mergePrograms(alloc, parsed_programs);
    try std.testing.expectEqual(@as(usize, 2), program.modules.len);

    // Step 4: Verify IO module has the attribute items
    const io_mod = program.modules[0];
    var io_attr_count: usize = 0;
    var io_func_count: usize = 0;
    for (io_mod.items) |item| {
        switch (item) {
            .attribute => io_attr_count += 1,
            .function => io_func_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), io_attr_count);
    try std.testing.expectEqual(@as(usize, 1), io_func_count);

    // Step 5: Collect and verify @native attaches to puts
    const module_programs = try buildModulePrograms(alloc, &program, &interner);
    const program_slices = try alloc.alloc(ast.Program, module_programs.len);
    for (module_programs, 0..) |entry, i| program_slices[i] = entry.program;

    var collector = zap.Collector.init(alloc, &interner);
    defer collector.deinit();
    for (module_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    try std.testing.expectEqual(@as(usize, 2), collector.graph.modules.items.len);

    // Find IO module scope
    var io_scope_id: ?zap.scope.ScopeId = null;
    for (collector.graph.modules.items) |mod_entry| {
        if (mod_entry.decl.name.parts.len == 1) {
            const name = interner.get(mod_entry.decl.name.parts[0]);
            if (std.mem.eql(u8, name, "IO")) {
                io_scope_id = mod_entry.scope_id;
                break;
            }
        }
    }
    try std.testing.expect(io_scope_id != null);

    const io_scope = collector.graph.getScope(io_scope_id.?);
    const puts_name = interner.map.get("puts").?;
    const puts_key = zap.scope.FamilyKey{ .name = puts_name, .arity = 1 };
    const puts_fid = io_scope.function_families.get(puts_key).?;
    const puts_family = collector.graph.getFamily(puts_fid);

    // @native attribute MUST be on the function family
    try std.testing.expect(puts_family.attributes.items.len >= 1);
    var found_native = false;
    for (puts_family.attributes.items) |attr| {
        if (std.mem.eql(u8, interner.get(attr.name), "native")) {
            if (attr.value) |val| {
                if (val.* == .string_literal) {
                    try std.testing.expectEqualStrings("Prelude.println", interner.get(val.string_literal.value));
                    found_native = true;
                }
            }
        }
    }
    try std.testing.expect(found_native);
}
