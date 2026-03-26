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
        progress.print("Compiling {s}\n", .{file_path}) catch {};
    }

    // Create shared DiagnosticEngine
    var diag_engine = zap.DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Phase 1: Parse (with stdlib prepended)
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Parse\n", .{ step, total_steps }) catch {};

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
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    // Phase 2: Collect declarations
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Collect\n", .{ step, total_steps }) catch {};

    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    };

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        emitDiagnostics(&diag_engine, alloc);
        return error.CollectFailed;
    }

    // Phase 3: Macro expansion
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Expand macros\n", .{ step, total_steps }) catch {};

    var macro_engine = zap.MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        emitDiagnostics(&diag_engine, alloc);
        return error.MacroExpansionFailed;
    };

    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        emitDiagnostics(&diag_engine, alloc);
        return error.MacroExpansionFailed;
    }

    // Phase 4: Desugaring
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Desugar\n", .{ step, total_steps }) catch {};

    var desugarer = zap.Desugarer.init(alloc, &parser.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.DesugarFailed;
    };

    // Phase 5: Type checking
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Type check\n", .{ step, total_steps }) catch {};

    var type_checker = zap.types.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // Phase 6: HIR lowering
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] HIR\n", .{ step, total_steps }) catch {};

    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        emitDiagnostics(&diag_engine, alloc);
        return error.HirFailed;
    };

    for (hir_builder.errors.items) |hir_err| {
        diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        emitDiagnostics(&diag_engine, alloc);
        return error.HirFailed;
    }

    // Phase 7: IR lowering
    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] IR\n", .{ step, total_steps }) catch {};

    var ir_builder = zap.ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    var ir_program = ir_builder.buildProgram(&hir_program) catch {
        diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        emitDiagnostics(&diag_engine, alloc);
        return error.IrFailed;
    };

    step += 1;
    if (options.show_progress) progress.print("  [{d}/{d}] Escape analysis\n", .{ step, total_steps }) catch {};

    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, &ir_program) catch {
        diag_engine.err("Error during escape analysis", .{ .start = 0, .end = 0 }) catch {};
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
        emitDiagnostics(&diag_engine, alloc);
        return error.TypeCheckFailed;
    }

    // Emit any accumulated warnings
    if (diag_engine.warningCount() > 0) {
        emitDiagnostics(&diag_engine, alloc);
    }

    return .{ .ir_program = ir_program, .analysis_context = pipeline_result.context };
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
        progress.print("  [8/10] ZIR\n", .{}) catch {};
    }

    var opts = backend_opts;
    if (result.analysis_context != null) {
        opts.analysis_context = &result.analysis_context.?;
    }
    try zap.zir_backend.compile(alloc, result.ir_program, opts);

    if (frontend_opts.show_progress) {
        progress.print("  [9/10] Sema + Codegen\n", .{}) catch {};
        progress.print("  [10/10] Linked {s}\n", .{output_path}) catch {};
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

/// Get the embedded runtime source.
pub fn getRuntimeSource() []const u8 {
    return runtime_source;
}
