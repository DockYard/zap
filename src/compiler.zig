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
    StdlibError,
    ReadError,
};

pub const CompileOptions = struct {
    /// Treat type warnings as hard errors.
    strict_types: bool = false,
    /// Show progress output to stderr.
    show_progress: bool = true,
    /// lib mode — skip main function emission in ZIR.
    lib_mode: bool = false,
};

/// Compile Zap source text through the full frontend pipeline:
/// parse → collect → macro → desugar → type check → HIR → IR.
///
/// `source` is raw Zap source (stdlib will be prepended internally).
/// `file_path` is used for diagnostic display only.
/// Diagnostics are emitted to stderr on failure.
pub fn compileFrontend(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    const progress = std.fs.File.stderr().deprecatedWriter();
    const total_steps: u32 = 11;
    var step: u32 = 0;

    if (options.show_progress) {
        progress.print("Compiling\n", .{}) catch {};
    }

    // Create shared DiagnosticEngine
    var diag_engine = zap.DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Phase 1: Parse (with stdlib prepended)
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Parse", .{ step, total_steps }) catch {};

    const prepend_result = zap.stdlib.prependStdlib(alloc, source) catch
        return error.StdlibError;
    const full_source = prepend_result.source;

    diag_engine.setSource(full_source, file_path);
    diag_engine.setLineOffset(prepend_result.stdlib_line_count);

    var parser = zap.Parser.init(alloc, full_source);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    };

    // Drain parser errors
    for (parser.errors.items) |parse_err| {
        diag_engine.reportDiagnostic(.{
            .severity = .@"error",
            .message = parse_err.message,
            .span = parse_err.span,
            .label = parse_err.label,
            .help = parse_err.help,
        }) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    // Phase 2: Collect declarations
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Collect", .{ step, total_steps }) catch {};

    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    };

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    }

    // Phase 3: Macro expansion
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Expand macros", .{ step, total_steps }) catch {};

    var macro_engine = zap.MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.MacroExpansionFailed;
    };

    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.MacroExpansionFailed;
    }

    // Phase 4: Desugaring
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps }) catch {};

    var desugarer = zap.Desugarer.init(alloc, &parser.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.DesugarFailed;
    };

    // Phase 5: Type checking
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Type check", .{ step, total_steps }) catch {};

    var type_checker = zap.types.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // Phase 6: HIR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] HIR", .{ step, total_steps }) catch {};

    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.HirFailed;
    };

    for (hir_builder.errors.items) |hir_err| {
        diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.HirFailed;
    }

    // Phase 7: IR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] IR", .{ step, total_steps }) catch {};

    var ir_builder = zap.ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    var ir_program = ir_builder.buildProgram(&hir_program) catch {
        diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.IrFailed;
    };

    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Escape analysis", .{ step, total_steps }) catch {};

    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, &ir_program) catch {
        diag_engine.err("Error during escape analysis", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.IrFailed;
    };
    zap.contification_rewrite.rewriteContifiedContinuations(alloc, &ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return error.IrFailed,
    };

    type_checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    for (pipeline_result.diagnostics.items) |analysis_diag| {
        diag_engine.reportDiagnostic(analysis_diag) catch {};
    }

    for (type_checker.errors.items) |type_err| {
        diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.TypeCheckFailed;
    }

    // Emit any accumulated warnings
    if (diag_engine.warningCount() > 0) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
    }

    if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
    return .{ .ir_program = ir_program, .analysis_context = pipeline_result.context };
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
    /// String interner shared across all files
    parser: zap.Parser,
    /// Scope graph with all modules' declarations
    collector: zap.Collector,
    /// Diagnostic engine
    diag_engine: zap.DiagnosticEngine,
    /// Stdlib line count for error offset adjustment
    stdlib_line_count: u32,
    /// The full source (stdlib + all files) for diagnostic display
    full_source: []const u8,
    /// Source file path for diagnostic display
    source_path: []const u8,
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
    const progress = std.fs.File.stderr().deprecatedWriter();
    var step: u32 = 0;
    const total_steps: u32 = 11;

    if (options.show_progress) {
        progress.print("Compiling\n", .{}) catch {};
    }

    var diag_engine = zap.DiagnosticEngine.init(alloc);
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Parse (with stdlib prepended)
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Parse", .{ step, total_steps }) catch {};

    const prepend_result = zap.stdlib.prependStdlib(alloc, source) catch
        return error.StdlibError;
    const full_source = prepend_result.source;

    diag_engine.setSource(full_source, file_path);
    diag_engine.setLineOffset(prepend_result.stdlib_line_count);

    var parser = zap.Parser.init(alloc, full_source);

    const program = parser.parseProgram() catch {
        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
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
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    // Collect declarations
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Collect", .{ step, total_steps }) catch {};

    var collector = zap.Collector.init(alloc, &parser.interner);
    collector.collectProgram(&program) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    };

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    }

    return .{
        .alloc = alloc,
        .merged_program = program,
        .parser = parser,
        .collector = collector,
        .diag_engine = diag_engine,
        .stdlib_line_count = prepend_result.stdlib_line_count,
        .full_source = full_source,
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

    // Macro expansion
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Expand macros", .{ step, total_steps }) catch {};

    var macro_engine = zap.MacroEngine.init(alloc, &ctx.parser.interner, &ctx.collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&ctx.merged_program) catch {
        for (macro_engine.errors.items) |macro_err| {
            ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.MacroExpansionFailed;
    };

    for (macro_engine.errors.items) |macro_err| {
        ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.MacroExpansionFailed;
    }

    // Desugaring
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps }) catch {};

    var desugarer = zap.Desugarer.init(alloc, &ctx.parser.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        ctx.diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.DesugarFailed;
    };

    // Type checking (first pass)
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Type check", .{ step, total_steps }) catch {};

    var type_checker = zap.types.TypeChecker.init(alloc, &ctx.parser.interner, &ctx.collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = ctx.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // HIR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] HIR", .{ step, total_steps }) catch {};

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.parser.interner, &ctx.collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.HirFailed;
    };

    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.HirFailed;
    }

    // IR lowering
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] IR", .{ step, total_steps }) catch {};

    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    var ir_program = ir_builder.buildProgram(&hir_program) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.IrFailed;
    };

    // Analysis pipeline
    step += 1;
    if (options.show_progress) progress.print("\r\x1b[K  [{d}/{d}] Escape analysis", .{ step, total_steps }) catch {};

    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, &ir_program) catch {
        ctx.diag_engine.err("Error during escape analysis", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
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
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.TypeCheckFailed;
    }

    // Emit warnings
    if (ctx.diag_engine.warningCount() > 0) {
        if (options.show_progress) progress.print("\r\x1b[K", .{}) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
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
    // Currently delegates to the full pipeline since the internal phases
    // don't yet support single-module operation. The result is the full
    // IR program — we store it in the unit for consistency.
    const result = try compileFiles(alloc, ctx, options);
    unit.ir_program = result.ir_program;
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

/// Validate that a source file contains exactly one defmodule and that the
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

    // Parse without stdlib — we only need to count defmodule declarations
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
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one defmodule declaration, found none", .{file_path}) catch "file has no module";
    }

    if (module_count > 1) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one defmodule declaration, found {d}", .{ file_path, module_count }) catch "file has multiple modules";
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
    const source = "defmodule Config do\n  def load() :: String do\n    \"ok\"\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid nested module name" {
    const alloc = std.testing.allocator;
    const source = "defmodule Config.Parser do\n  def parse() :: String do\n    \"ok\"\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "config/parser.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid private module" {
    const alloc = std.testing.allocator;
    const source = "defmodulep Config.Helpers do\n  def help() :: String do\n    \"ok\"\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "config/helpers.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: zero modules is error" {
    const alloc = std.testing.allocator;
    const source = "defstruct Point do\n  x :: i64\nend\n";
    const result = validateOneModulePerFile(alloc, source, "point.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "found none") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: multiple modules is error" {
    const alloc = std.testing.allocator;
    const source = "defmodule Foo do\n  def foo() :: i64 do\n    1\n  end\nend\ndefmodule Bar do\n  def bar() :: i64 do\n    2\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "foo.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "found 2") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: name mismatch is error" {
    const alloc = std.testing.allocator;
    const source = "defmodule WrongName do\n  def foo() :: i64 do\n    1\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "does not match") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: snake_case path to PascalCase" {
    const alloc = std.testing.allocator;
    const source = "defmodule JsonParser do\n  def parse() :: String do\n    \"ok\"\n  end\nend\n";
    const result = validateOneModulePerFile(alloc, source, "json_parser.zap");
    try std.testing.expectEqual(null, result);
}
