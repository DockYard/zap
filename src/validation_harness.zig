const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const MacroEngine = @import("macro.zig").MacroEngine;
const Desugarer = @import("desugar.zig").Desugarer;
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const ir = @import("ir.zig");
const CodeGen = @import("codegen.zig").CodeGen;
const DiagnosticEngine = @import("diagnostics.zig").DiagnosticEngine;
const analysis_pipeline = @import("analysis_pipeline.zig");
pub const stdlib = @import("stdlib.zig");

pub const CompileResult = struct {
    output: []const u8,
    diag_output: []const u8,

    pub fn deinit(self: *CompileResult, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
        alloc.free(self.diag_output);
    }
};

pub const AnalysisSummary = struct {
    function_count: usize,
    closure_tier_count: usize,
    alloc_summary_count: usize,
    arc_op_count: usize,
    reuse_pair_count: usize,
    drop_specialization_count: usize,
    borrow_diagnostic_count: usize,
};

pub const AnalysisSnapshot = struct {
    compile_result: CompileResult,
    summary: AnalysisSummary,

    pub fn deinit(self: *AnalysisSnapshot, alloc: std.mem.Allocator) void {
        self.compile_result.deinit(alloc);
    }
};

pub fn compile(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    const result = try compileWithDiagnostics(alloc, source, false);
    defer alloc.free(result.diag_output);
    return result.output;
}

pub fn compileWithDiagnostics(alloc: std.mem.Allocator, source: []const u8, strict_types: bool) !CompileResult {
    const prepend_result = try stdlib.prependStdlib(alloc, source);
    const full_source = prepend_result.source;

    var diag_engine = DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.setSource(full_source, "validation.zap");
    diag_engine.setLineOffset(prepend_result.stdlib_line_count);

    var parser = Parser.init(alloc, full_source);
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
        return error.ParseError;
    };

    if (parser.errors.items.len > 0) {
        for (parser.errors.items) |parse_err| {
            try diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            });
        }
        return error.ParseError;
    }

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);
    for (collector.errors.items) |collect_err| {
        try diag_engine.err(collect_err.message, collect_err.span);
    }
    if (diag_engine.hasErrors()) return error.CollectError;

    var macro_engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = try macro_engine.expandProgram(&program);
    for (macro_engine.errors.items) |macro_err| {
        try diag_engine.err(macro_err.message, macro_err.span);
    }
    if (diag_engine.hasErrors()) return error.MacroError;

    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared_program = try desugarer.desugarProgram(&expanded_program);

    var type_checker = types_mod.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: @import("diagnostics.zig").Severity = if (strict_types) .@"error" else .warning;

    var hir_builder = hir_mod.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&desugared_program);
    for (hir_builder.errors.items) |hir_err| {
        try diag_engine.err(hir_err.message, hir_err.span);
    }
    if (diag_engine.hasErrors()) return error.HirError;

    var ir_builder = ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var pipeline_result = try analysis_pipeline.runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();

    type_checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
    try type_checker.checkProgram(&desugared_program);
    try type_checker.checkUnusedBindings();
    for (pipeline_result.diagnostics.items) |analysis_diag| {
        try diag_engine.reportDiagnostic(analysis_diag);
    }
    for (type_checker.errors.items) |type_err| {
        try diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        });
    }
    if (diag_engine.hasErrors()) return error.TypeError;

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &pipeline_result.context;
    try codegen.emitProgram(&ir_program);

    return .{
        .output = try alloc.dupe(u8, codegen.getOutput()),
        .diag_output = try diag_engine.format(alloc),
    };
}

pub fn analyzeSource(alloc: std.mem.Allocator, source: []const u8) !AnalysisSummary {
    const prepend_result = try stdlib.prependStdlib(alloc, source);
    const full_source = prepend_result.source;

    var parser = Parser.init(alloc, full_source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var macro_engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = try macro_engine.expandProgram(&program);

    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared_program = try desugarer.desugarProgram(&expanded_program);

    var type_checker = types_mod.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    try type_checker.checkProgram(&desugared_program);
    try type_checker.checkUnusedBindings();

    var hir_builder = hir_mod.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&desugared_program);

    var ir_builder = ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var pipeline_result = try analysis_pipeline.runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();

    return summarizeAnalysisContext(ir_program.functions.len, &pipeline_result);
}

pub fn compileAndAnalyzeSnapshot(alloc: std.mem.Allocator, source: []const u8) !AnalysisSnapshot {
    var compile_result = try compileWithDiagnostics(alloc, source, false);
    errdefer compile_result.deinit(alloc);
    const summary = try analyzeSource(alloc, source);
    return .{ .compile_result = compile_result, .summary = summary };
}

pub fn summarizeAnalysisContext(function_count: usize, pipeline_result: *const analysis_pipeline.PipelineResult) !AnalysisSummary {
    var borrow_diagnostic_count: usize = 0;
    for (pipeline_result.diagnostics.items) |diag| {
        if (diag.code != null and std.mem.eql(u8, diag.code.?, "E-BORROW")) {
            borrow_diagnostic_count += 1;
        }
    }
    return .{
        .function_count = function_count,
        .closure_tier_count = pipeline_result.context.closure_tiers.count(),
        .alloc_summary_count = pipeline_result.context.alloc_summaries.count(),
        .arc_op_count = pipeline_result.context.arc_ops.items.len,
        .reuse_pair_count = pipeline_result.context.reuse_pairs.items.len,
        .drop_specialization_count = pipeline_result.context.drop_specializations.items.len,
        .borrow_diagnostic_count = borrow_diagnostic_count,
    };
}

pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) {
        if (std.mem.indexOf(u8, haystack[start..], needle)) |pos| {
            count += 1;
            start += pos + needle.len;
        } else break;
    }
    return count;
}

pub fn countArcOpsInOutput(output: []const u8) usize {
    return countOccurrences(output, "ArcRuntime.retainAny(") + countOccurrences(output, "ArcRuntime.releaseAny(");
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.TestExpectedContains;
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return error.TestExpectedNotContains;
}
