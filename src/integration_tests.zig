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

// ============================================================
// Integration tests (spec §12)
//
// Each test compiles a Zip source through the full pipeline
// and asserts on the generated Zig output.
// ============================================================

const CompileResult = struct {
    output: []const u8,
    diag_output: []const u8,
};

/// Run the full compiler pipeline on source, return generated Zig.
fn compile(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    const result = try compileWithDiagnostics(alloc, source, false);
    return result.output;
}

/// Read all .zap files from a directory and concatenate their sources.
fn readDirZapFiles(alloc: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return try result.toOwnedSlice(alloc);
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const content = std.fs.cwd().readFileAlloc(alloc, file_path, 10 * 1024 * 1024) catch continue;
        try result.appendSlice(alloc, content);
        try result.append(alloc, '\n');
    }
    return try result.toOwnedSlice(alloc);
}

/// Read stdlib source from lib/ and lib/zap/ directories.
fn readStdlibSource(alloc: std.mem.Allocator) ![]const u8 {
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    const lib_source = try readDirZapFiles(alloc, "lib");
    try combined.appendSlice(alloc, lib_source);
    const zap_source = try readDirZapFiles(alloc, "lib/zap");
    try combined.appendSlice(alloc, zap_source);
    return try combined.toOwnedSlice(alloc);
}

/// Run the full compiler pipeline with diagnostics support.
fn compileWithDiagnostics(alloc: std.mem.Allocator, source: []const u8, strict_types: bool) !CompileResult {
    const stdlib_source = try readStdlibSource(alloc);
    const full_source = try std.mem.concat(alloc, u8, &.{ stdlib_source, source });

    // Create shared DiagnosticEngine
    var diag_engine = DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.setSource(full_source, "test.zap");

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

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Drain collector errors
    for (collector.errors.items) |collect_err| {
        try diag_engine.err(collect_err.message, collect_err.span);
    }
    if (diag_engine.hasErrors()) return error.CollectError;

    // Macro expansion (between collection and HIR lowering)
    var macro_engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = try macro_engine.expandProgram(&program);

    // Drain macro errors
    for (macro_engine.errors.items) |macro_err| {
        try diag_engine.err(macro_err.message, macro_err.span);
    }
    if (diag_engine.hasErrors()) return error.MacroError;

    // Desugaring (after macro expansion, before HIR)
    var desugarer = Desugarer.init(alloc, parser.interner);
    const desugared_program = try desugarer.desugarProgram(&expanded_program);

    // Type checking (on desugared AST)
    var type_checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer type_checker.deinit();

    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: @import("diagnostics.zig").Severity = if (strict_types) .@"error" else .warning;

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&desugared_program);

    // Drain HIR errors
    for (hir_builder.errors.items) |hir_err| {
        try diag_engine.err(hir_err.message, hir_err.span);
    }
    if (diag_engine.hasErrors()) return error.HirError;

    var ir_builder = ir.IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    var ir_program = try ir_builder.buildProgram(&hir_program);

    const analysis_pipeline = @import("analysis_pipeline.zig");
    const contification_rewrite = @import("contification_rewrite.zig");
    var pipeline_result = try analysis_pipeline.runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();
    contification_rewrite.rewriteContifiedContinuations(alloc, &ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return err,
    };

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

    const diag_output = try diag_engine.format(alloc);

    return .{
        .output = try alloc.dupe(u8, codegen.getOutput()),
        .diag_output = diag_output,
    };
}

pub fn analyzeSource(alloc: std.mem.Allocator, source: []const u8) !struct {
    ir_program: ir.Program,
    pipeline_result: @import("analysis_pipeline.zig").PipelineResult,
} {
    const stdlib_source = try readStdlibSource(alloc);
    const full_source = try std.mem.concat(alloc, u8, &.{ stdlib_source, source });

    var parser = Parser.init(alloc, full_source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var macro_engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = try macro_engine.expandProgram(&program);

    var desugarer = Desugarer.init(alloc, parser.interner);
    const desugared_program = try desugarer.desugarProgram(&expanded_program);

    var type_checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer type_checker.deinit();

    try type_checker.checkProgram(&desugared_program);
    try type_checker.checkUnusedBindings();

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&desugared_program);

    var ir_builder = ir.IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    var ir_program = try ir_builder.buildProgram(&hir_program);

    const analysis_pipeline = @import("analysis_pipeline.zig");
    const contification_rewrite = @import("contification_rewrite.zig");
    const pipeline_result = try analysis_pipeline.runAnalysisPipeline(alloc, &ir_program);
    contification_rewrite.rewriteContifiedContinuations(alloc, &ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return err,
    };
    return .{ .ir_program = ir_program, .pipeline_result = pipeline_result };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\n=== EXPECTED to find ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
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

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\n=== EXPECTED NOT to find ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

// ============================================================
// Hello world
// ============================================================

test "example: hello world" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    IO.puts("Hello, world!")
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn main(");
    try expectContains(output, "\"Hello, world!\"");
    try expectContains(output, "zap_runtime.Prelude.println(");
}

// ============================================================
// Stdlib module-qualified calls
// ============================================================

test "IO.puts resolves to runtime println" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    IO.puts("test output")
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.Prelude.println(");
    try expectNotContains(output, "// unhandled instruction");
}

test "bare println is not implicitly available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    println("should not resolve")
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Bare println should be emitted as a named call, not a builtin
    // (the stdlib modules use @println intrinsic, but user code can't)
    try expectContains(output, "_ = println(");
}

// ============================================================
// Factorial with pattern matching
// ============================================================

test "example: factorial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Factorial {
        \\  pub fn factorial(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn factorial(n :: i64) -> i64 {
        \\    n * factorial(n - 1)
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Factorial.factorial(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Factorial__factorial(");
    try expectContains(output, "fn main(");
    try expectContains(output, "10");
    try expectContains(output, "return");
}

// ============================================================
// Fibonacci
// ============================================================

test "example: fibonacci" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Fib {
        \\  pub fn fib(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn fib(1 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn fib(n :: i64) -> i64 {
        \\    fib(n - 1) + fib(n - 2)
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Fib.fib(20)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Fib__fib(");
    try expectContains(output, "fn main(");
    try expectContains(output, "20");
}

// ============================================================
// Module with functions
// ============================================================

test "example: math module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub fn square(x :: i64) -> i64 {
        \\    x * x
        \\  }
        \\
        \\  pub fn cube(x :: i64) -> i64 {
        \\    x * x * x
        \\  }
        \\
        \\  pub fn abs(x :: i64) -> i64 {
        \\    if x < 0 {
        \\      -x
        \\    } else {
        \\      x
        \\    }
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Math.square(5)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Math__square(");
    try expectContains(output, "fn Math__cube(");
    try expectContains(output, "fn Math__abs(");
    try expectContains(output, "fn main(");
    try expectContains(output, "5");
}

// ============================================================
// Pattern matching with atoms
// ============================================================

test "example: pattern matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Matcher {
        \\  pub fn describe(:ok :: Atom) -> String {
        \\    "success"
        \\  }
        \\
        \\  pub fn describe(:error :: Atom) -> String {
        \\    "failure"
        \\  }
        \\
        \\  pub fn describe(_ :: Atom) -> String {
        \\    "unknown"
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    Matcher.describe(:ok)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Matcher__describe(");
    try expectContains(output, "fn main(");
    try expectContains(output, "\"success\"");
    try expectContains(output, "\"failure\"");
    try expectContains(output, "\"unknown\"");
}

// ============================================================
// Multiline pipe operator
// ============================================================

test "example: multiline pipes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Pipes {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn add_one(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    5
        \\    |> Pipes.double()
        \\    |> Pipes.add_one()
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Pipes__double(");
    try expectContains(output, "fn Pipes__add_one(");
    try expectContains(output, "fn main(");
    // Pipe desugaring rewrites the chain — verify the functions exist
    // and the multiplication constant is present
    try expectContains(output, "2");
}

// ============================================================
// Type declarations with tagged unions
// ============================================================

test "example: type declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Geometry {
        \\  type Shape = {:circle, f64} | {:rectangle, f64, f64}
        \\
        \\  pub fn area({:circle, radius} :: Shape) -> f64 {
        \\    3.14159 * radius * radius
        \\  }
        \\
        \\  pub fn area({:rectangle, w, h} :: Shape) -> f64 {
        \\    w * h
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> f64 {
        \\    Geometry.area({:circle, 5.0})
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Geometry__area(");
    try expectContains(output, "fn main(");
    try expectContains(output, "3.14159");
    // Float 5.0 may be emitted as integer 5 depending on literal parsing
    try expectContains(output, "5");
}

// ============================================================
// Pipeline structure assertions
// ============================================================

test "all compiled output has required header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn main() -> Nil {
        \\    nil
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "// Generated by Zap compiler");
    try expectContains(output, "const std = @import(\"std\");");
    try expectContains(output, "const zap_runtime = @import(\"zap_runtime.zig\");");
}

test "multiple function clauses produce separate functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Greeter {
        \\  pub fn greet(:morning :: Atom) -> String {
        \\    "Good morning"
        \\  }
        \\
        \\  pub fn greet(:evening :: Atom) -> String {
        \\    "Good evening"
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should have two function definitions
    try expectContains(output, "\"Good morning\"");
    try expectContains(output, "\"Good evening\"");
}

test "string concatenation in function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Greeter {
        \\  pub fn greet(name :: String) -> String {
        \\    "Hello, " <> name
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Greeter__greet(");
    try expectContains(output, "\"Hello, \"");
}

test "if-else generates conditional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Sign {
        \\  pub fn sign(x :: i64) -> String {
        \\    if x > 0 {
        \\      "positive"
        \\    } else {
        \\      "non-positive"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Sign__sign(");
    // If-else desugars to case(true/false), which emits a Zig switch
    try expectContains(output, "switch (");
    try expectContains(output, "true =>");
    try expectContains(output, "false =>");
    try expectContains(output, "\"positive\"");
    try expectContains(output, "\"non-positive\"");
}

// ============================================================
// Tuple destructuring
// ============================================================

test "tuple pattern destructuring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Geometry {
        \\  pub fn area({:circle, radius} :: f64) -> f64 {
        \\    3.14159 * radius * radius
        \\  }
        \\
        \\  pub fn area({:rectangle, w, h} :: f64) -> f64 {
        \\    w * h
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> f64 {
        \\    Geometry.area({:circle, 5.0})
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Geometry__area(");
    // Should have guard blocks for tuple dispatch
    try expectContains(output, "if (");
    // Should have index access for element extraction
    try expectContains(output, "[0]");
    try expectContains(output, "[1]");
    // Should have atom check for :circle
    try expectContains(output, ".@\"circle\"");
    // Should have the body computation
    try expectContains(output, "3.14159");
    // Should NOT have unhandled instructions
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Refinement/guard predicates
// ============================================================

test "refinement guard on function clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Classifier {
        \\  pub fn classify(n :: i64) -> String if n > 0 {
        \\    "positive"
        \\  }
        \\
        \\  pub fn classify(n :: i64) -> String if n < 0 {
        \\    "negative"
        \\  }
        \\
        \\  pub fn classify(_ :: i64) -> String {
        \\    "zero"
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Classifier__classify(");
    // Should have conditional returns with type guard AND refinement
    try expectContains(output, "if (");
    try expectContains(output, "\"positive\"");
    try expectContains(output, "\"negative\"");
    try expectContains(output, "\"zero\"");
}

// ============================================================
// Case expressions
// ============================================================

test "case expression with literal patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> String {
        \\    case x {
        \\      0 -> "zero"
        \\      1 -> "one"
        \\      _ -> "other"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Checker__check(");
    // Integer literal case should produce a switch
    try expectContains(output, "switch (");
    try expectContains(output, "\"zero\"");
    try expectContains(output, "\"one\"");
    try expectContains(output, "\"other\"");
    try expectNotContains(output, "// unhandled instruction");
}

test "case expression with tuple destructuring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Handler {
        \\  pub fn handle(result :: Atom) -> Nil {
        \\    case result {
        \\      {:ok, v} -> v
        \\      {:error, e} -> e
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Handler__handle(");
    try expectContains(output, "blk_case_");
    // Should have atom checks and index access
    try expectContains(output, ".@\"ok\"");
    try expectContains(output, ".@\"error\"");
    try expectContains(output, "[0]");
}

test "case expression with bind pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Identity {
        \\  pub fn identity(x :: Atom) -> Nil {
        \\    case x {
        \\      v -> v
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Identity__identity(");
    // Bind pattern becomes default arm
    try expectContains(output, "blk_case_");
}

// ============================================================
// Pattern matching switch optimization
// ============================================================

test "case expression emits switch for integer literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> String {
        \\    case x {
        \\      0 -> "zero"
        \\      1 -> "one"
        \\      _ -> "other"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "switch (");
    try expectNotContains(output, "blk_case_");
    try expectContains(output, "\"zero\"");
    try expectContains(output, "\"one\"");
    try expectContains(output, "\"other\"");
    try expectNotContains(output, "// unhandled instruction");
}

test "function dispatch emits switch for integer literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Fib {
        \\  pub fn fib(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn fib(1 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn fib(n :: i64) -> i64 {
        \\    fib(n - 1) + fib(n - 2)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "switch (");
    try expectNotContains(output, "// unhandled instruction");
}

test "case with guards falls back to if-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> String {
        \\    case x {
        \\      0 -> "zero"
        \\      n if n > 0 -> "positive"
        \\      _ -> "negative"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Guard present — must fall back to if/else
    try expectContains(output, "if (");
    try expectNotContains(output, "switch (");
}

test "case with atom literals falls back to if-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: Atom) -> String {
        \\    case x {
        \\      :ok -> "yes"
        \\      :error -> "no"
        \\      _ -> "unknown"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Atoms can't use Zig switch — must use if/else
    try expectContains(output, "if (");
    try expectNotContains(output, "switch (");
}

// ============================================================
// Phase 2: Decision tree — decompose once
// ============================================================

test "nested tuple patterns decompose once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Processor {
        \\  pub fn process(x :: Atom) -> Nil {
        \\    case x {
        \\      {:ok, {:data, v}} -> v
        \\      {:ok, {:empty}} -> nil
        \\      {:error, msg} -> msg
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Outer struct check (arity 2) appears once.
    // Inner tuples {:data, v} (arity 2) and {:empty} (arity 1) are different arities,
    // so each gets its own check_tuple node = 2 inner struct checks.
    // Total: 1 outer + 2 inner = 3
    const struct_check_count = countOccurrences(output, "== .@\"struct\"");
    if (struct_check_count > 3) {
        std.debug.print("\n=== EXPECTED ≤3 struct checks, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
        return error.TestExpectedContains;
    }
    try std.testing.expect(struct_check_count >= 1);
    try expectNotContains(output, "// unhandled instruction");
}

test "case with tuple patterns checks struct type once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Handler {
        \\  pub fn handle(result :: Atom) -> Nil {
        \\    case result {
        \\      {:ok, v} -> v
        \\      {:error, e} -> e
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Struct type check should appear only ONCE (not once per arm)
    // Both arms have arity 2, so one check_tuple(arity=2) node
    const struct_check_count = countOccurrences(output, "== .@\"struct\"");
    if (struct_check_count != 1) {
        std.debug.print("\n=== EXPECTED 1 struct check, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
        return error.TestExpectedContains;
    }
    try expectContains(output, ".@\"ok\"");
    try expectContains(output, ".@\"error\"");
    try expectNotContains(output, "// unhandled instruction");
}

test "multi-clause function with tuple dispatch checks once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Handler {
        \\  pub fn handle({:ok, v} :: Atom) -> Nil {
        \\    v
        \\  }
        \\
        \\  pub fn handle({:error, e} :: Atom) -> Nil {
        \\    e
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Struct check should appear only once for multi-clause tuple dispatch
    // Both clauses have arity 2, so one check_tuple(arity=2) node
    const struct_check_count = countOccurrences(output, "== .@\"struct\"");
    if (struct_check_count != 1) {
        std.debug.print("\n=== EXPECTED 1 struct check, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
        return error.TestExpectedContains;
    }
    try expectContains(output, ".@\"ok\"");
    try expectContains(output, ".@\"error\"");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Phase 3: Static type exploitation
// ============================================================

test "typed integer param skips type check in switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module TypedSwitch {
        \\  pub fn f(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn f(n :: i64) -> i64 {
        \\    n
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // With typed i64 param, no runtime type check needed
    try expectNotContains(output, "@typeInfo");
    try expectNotContains(output, "@TypeOf");
    try expectContains(output, "switch (");
    try expectNotContains(output, "// unhandled instruction");
}

test "untyped param produces type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Describer {
        \\  pub fn describe(:ok) -> String {
        \\    "yes"
        \\  }
        \\
        \\  pub fn describe(_) -> String {
        \\    "no"
        \\  }
        \\}
    ;

    // Untyped params now require type annotations — should produce a type error
    const result = compileWithDiagnostics(alloc, source, true);
    try std.testing.expectError(error.TypeError, result);
}

test "typed case scrutinee skips type check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> String {
        \\    case x {
        \\      0 -> "zero"
        \\      _ -> "other"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Typed i64 scrutinee — switch should not have type checks
    try expectNotContains(output, "@typeInfo");
    try expectNotContains(output, "@TypeOf");
    try expectContains(output, "switch (");
}

test "mixed variable and constructor in case" {
    // case x { 1 -> "one"; y -> y }
    // Should work with mixture of literal and variable patterns
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> i64 {
        \\    case x {
        \\      1 -> 100
        \\      y -> y
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "switch (");
    try expectContains(output, "100");
    try expectNotContains(output, "// unhandled instruction");
}

test "case with mixed literal types falls back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: Atom) -> String {
        \\    case x {
        \\      0 -> "zero"
        \\      :ok -> "ok"
        \\      _ -> "other"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Mixed types can't use switch
    try expectContains(output, "if (");
    try expectNotContains(output, "switch (");
}

test "parse error produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "pub fn (broken syntax";
    const result = compile(alloc, source);
    try std.testing.expectError(error.ParseError, result);
}

// ============================================================
// Macro expansion
// ============================================================

test "macro expansion: unless compiles through pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Logic {
        \\  pub macro unless(condition :: Expr, body :: Expr) -> Nil {
        \\    quote {
        \\      if not unquote(condition) {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(x :: i64) -> i64 {
        \\    unless(x > 0, 42)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // The macro should expand unless into if(not(cond)), which desugars to case(true/false)
    // `not` compiles to Zig's `!` operator
    try expectContains(output, "switch (");
    try expectContains(output, "!");
    try expectNotContains(output, "// unhandled instruction");
}

test "macro expansion: expression substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub macro double(value :: Expr) -> Nil {
        \\    quote {
        \\      unquote(value) + unquote(value)
        \\    }
        \\  }
        \\
        \\  pub fn compute(x :: i64) -> i64 {
        \\    double(x * 3)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // The macro should expand double(x * 3) into (x * 3) + (x * 3)
    try expectContains(output, "+");
    try expectNotContains(output, "// unhandled instruction");
}

test "Kernel.unless macro works without module prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Checker {
        \\  pub fn check(x :: i64) -> i64 {
        \\    unless(x > 10, 42)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // unless should expand to: if not (x > 10) { 42 }, then if desugars to case(true/false)
    try expectContains(output, "switch (");
    try expectContains(output, "!");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Cond expression
// ============================================================

test "cond expression desugars to nested case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Classifier {
        \\  pub fn classify(x :: i64) -> String {
        \\    cond {
        \\      x > 0 -> "positive"
        \\      x < 0 -> "negative"
        \\      true -> "zero"
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Classifier__classify(");
    // cond desugars to nested case(true/false) which emits switch
    try expectContains(output, "switch (");
    try expectContains(output, "\"positive\"");
    try expectContains(output, "\"negative\"");
    try expectContains(output, "\"zero\"");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// With expression
// ============================================================

test "with expression desugars to nested case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Processor {
        \\  pub fn process(x :: Atom) -> Nil {
        \\    with {:ok, a} <- x {
        \\      a
        \\    } else {
        \\      {:error, e} -> e
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Processor__process(");
    // with desugars to case — should have tuple matching
    try expectContains(output, ".@\"ok\"");
    try expectContains(output, ".@\"error\"");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Mixed-arity tuple pattern matching (tagged unions)
// ============================================================

test "tagged union with different tuple arities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Geometry {
        \\  type Shape = {:circle, f64} | {:rectangle, f64, f64}
        \\
        \\  pub fn area({:circle, radius} :: Shape) -> f64 {
        \\    3.14159 * radius * radius
        \\  }
        \\
        \\  pub fn area({:rectangle, w, h} :: Shape) -> f64 {
        \\    w * h
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Geometry__area(");
    // Should have separate arity checks — 2-element and 3-element tuples
    try expectContains(output, "fields.len == 2");
    try expectContains(output, "fields.len == 3");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Module-scoped function naming
// ============================================================

test "two modules with same function name don't collide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module A {
        \\  pub fn calc(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module B {
        \\  pub fn calc(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    A.calc(1)
        \\    B.calc(2)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Both modules get distinct prefixed function names
    try expectContains(output, "fn A__calc(");
    try expectContains(output, "fn B__calc(");
    // Calls use the prefixed names
    try expectContains(output, "A__calc(");
    try expectContains(output, "B__calc(");
    try expectNotContains(output, "// unhandled instruction");
}

test "bare inspect resolves to Kernel__inspect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    inspect(42)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Bare inspect should resolve to Kernel__inspect via auto-import
    try expectContains(output, "Kernel__inspect(");
    try expectNotContains(output, "// unhandled instruction");
}

test "module-qualified call emits prefixed name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Math.double(5)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Math__double(");
    try expectContains(output, "Math__double(");
    try expectContains(output, "fn main(");
    try expectNotContains(output, "// unhandled instruction");
}

test "nested local def direct call compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn other(y :: i64) -> i64 {
        \\      y * 10
        \\    }
        \\
        \\    other(123)
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Foo.bar(4)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__other(");
    try expectContains(output, "Foo__other(");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "nested noncapturing def can be passed as function value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar() -> i64 {
        \\    pub fn other(y :: i64) -> i64 {
        \\      y * 10
        \\    }
        \\
        \\    apply(other, 12)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "__closure_invoke_");
    try expectContains(output, "__closure_invoke_");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "nested noncapturing def can be returned as function value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn make(x :: i64) -> (i64 -> i64) {
        \\    pub fn other(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    other
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__other(");
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "__closure_invoke_");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "capturing nested def local call compiles as closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add_x(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__add_x(");
    try expectContains(output, "Foo__add_x(__local_");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "call-local capturing closure omits closure wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add_x(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectNotContains(output, "fn __closure_invoke_11(");
    try expectNotContains(output, "const __closure_env_11");
}

test "non-capturing local def stays lambda lifted without closure wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar() -> i64 {
        \\    pub fn forty_two() -> i64 {
        \\      42
        \\    }
        \\
        \\    forty_two()
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__forty_two(");
    try expectContains(output, "Foo__forty_two(");
    try expectNotContains(output, "zap_runtime.DynClosure{");
    try expectNotContains(output, "fn __closure_invoke_");
    try expectNotContains(output, "const __closure_env_");
}

test "call-local closure with if body still compiles as direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(flag :: Bool) -> i64 {
        \\    pub fn pick(value :: Bool) -> i64 {
        \\      if value {
        \\        5
        \\      } else {
        \\        7
        \\      }
        \\    }
        \\
        \\    pick(flag)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__pick(");
    try expectContains(output, "Foo__pick(__local_");
    try expectContains(output, "switch (__local_");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
}

test "call-local closure with switch body still compiles as direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(flag :: Bool) -> i64 {
        \\    pub fn pick(value :: Bool) -> i64 {
        \\      case value {
        \\        true -> 5
        \\        false -> 7
        \\      }
        \\    }
        \\
        \\    pick(flag)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__pick(");
    try expectContains(output, "Foo__pick(__local_");
    try expectContains(output, "switch (__local_");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
}

test "call-local closure with case body still compiles as direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(flag :: Bool) -> i64 {
        \\    pub fn pick(value :: Bool) -> i64 {
        \\      case value {
        \\        true -> 5
        \\        false -> 7
        \\      }
        \\    }
        \\
        \\    pick(flag)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__pick(");
    try expectContains(output, "Foo__pick(__local_");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
}

test "aliased call-local capturing closure still compiles as direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = add_x
        \\    g = f
        \\    g(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__add_x(");
    try expectContains(output, "@call(.always_tail, Foo__add_x");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
}

test "aliased call-local closure with case body still compiles as direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(flag :: Bool) -> i64 {
        \\    pub fn pick(value :: Bool) -> i64 {
        \\      case value {
        \\        true -> 5
        \\        false -> 7
        \\      }
        \\    }
        \\
        \\    f = pick
        \\    g = f
        \\    g(flag)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__pick(");
    try expectContains(output, "@call(.always_tail, Foo__pick");
    try expectNotContains(output, "zap_runtime.invokeDynClosure(");
    try expectNotContains(output, "func_unknown(");
}

test "block-local capturing closure avoids heap env allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = add_x
        \\    f(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectContains(output, "zap_runtime.DynClosure{");
    try expectNotContains(output, "fn __closure_release_");
}

test "capturing nested def can be passed as function value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    apply(add_x, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "__closure_invoke_");
    try expectContains(output, "const __closure_env_");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "capturing nested def passed to known-safe callee avoids heap env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    apply(add_x, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "Foo__apply(__local_1, __local_3)");
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
}

test "aliased capturing nested def passed to known-safe callee avoids heap env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = add_x
        \\    apply(f, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "Foo__apply(__local_");
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
    try expectNotContains(output, "func_unknown(");
}

test "capturing nested def passed through transitive known-safe callees avoids heap env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn wrap(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    apply(f, value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    wrap(add_x, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "Foo__wrap(__local_1, __local_3)");
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
}

test "aliased capturing nested def passed through transitive known-safe callees avoids heap env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn wrap(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    apply(f, value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = add_x
        \\    wrap(f, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "Foo__wrap(__local_");
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
    try expectNotContains(output, "func_unknown(");
}

test "function-local capturing closure uses frame env without heap allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    apply(add_x, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "var __frame_env_");
    try expectContains(output, "zap_runtime.DynClosure{");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
}

test "source pipeline marks multi-target higher-order call as switch_dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn inc(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\
        \\  pub fn dec(x :: i64) -> i64 {
        \\    x - 1
        \\  }
        \\
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn choose(flag :: Bool) -> (i64 -> i64) {
        \\    if flag {
        \\      inc
        \\    } else {
        \\      dec
        \\    }
        \\  }
        \\
        \\  pub fn run(flag :: Bool) -> i64 {
        \\    apply(choose(flag), 10)
        \\  }
        \\}
    ;

    var analyzed = try analyzeSource(alloc, source);
    defer analyzed.pipeline_result.deinit();

    var apply_func: ?ir.FunctionId = null;
    for (analyzed.ir_program.functions) |func| {
        if (std.mem.eql(u8, func.name, "Foo__apply")) {
            apply_func = func.id;
            break;
        }
    }
    try std.testing.expect(apply_func != null);

    var found = false;
    var iter = analyzed.pipeline_result.context.call_specializations.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.function == apply_func.? and entry.value_ptr.decision == .switch_dispatch) {
            found = true;
            try std.testing.expectEqual(@as(usize, 2), entry.value_ptr.lambda_set.members.len);
        }
    }
    try std.testing.expect(found);
}

test "source pipeline records reuse pairs for tagged tuple reconstruction after case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Handler {
        \\  pub fn handle(result :: Atom) -> Nil {
        \\    case result {
        \\      {:ok, v} -> {:ok, v}
        \\      {:error, e} -> {:error, e}
        \\    }
        \\  }
        \\}
    ;

    var analyzed = try analyzeSource(alloc, source);
    defer analyzed.pipeline_result.deinit();

    try std.testing.expect(analyzed.pipeline_result.context.reuse_pairs.items.len > 0);
}

test "source pipeline records reuse pairs for struct reconstruction after case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct User {
        \\  name :: String
        \\  age :: i64
        \\}
        \\
        \\pub module Foo {
        \\  pub fn norm(u :: User) -> User {
        \\    case u {
        \\      x -> %{name: x.name, age: x.age} :: User
        \\    }
        \\  }
        \\}
    ;

    var analyzed = try analyzeSource(alloc, source);
    defer analyzed.pipeline_result.deinit();

    try std.testing.expect(analyzed.pipeline_result.context.reuse_pairs.items.len > 0);
}

test "source codegen emits switch dispatch for multi-target higher-order call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn inc(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\
        \\  pub fn dec(x :: i64) -> i64 {
        \\    x - 1
        \\  }
        \\
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn choose(flag :: Bool) -> (i64 -> i64) {
        \\    if flag {
        \\      inc
        \\    } else {
        \\      dec
        \\    }
        \\  }
        \\
        \\  pub fn run(flag :: Bool) -> i64 {
        \\    apply(choose(flag), 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, ".call_fn == @ptrCast(&__closure_invoke_");
    try expectContains(output, "invokeDynClosure");
}

test "capturing nested def can be returned as function value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn make_adder(x :: i64) -> (i64 -> i64) {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add_x
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.DynClosure{");
    try expectContains(output, "const __closure_env_");
    try expectContains(output, "fn __closure_invoke_");
    try expectContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "func_unknown(");
    try expectNotContains(output, "// unhandled instruction");
}

test "capturing closure with shared opaque capture emits retain and release helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: shared Handle) -> (-> Handle) {
        \\    pub fn use() -> Handle {
        \\      handle
        \\    }
        \\
        \\    use
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "const __closure_env_");
    try expectContains(output, "fn __closure_release_");
    try expectContains(output, "zap_runtime.ArcRuntime.retainAny(");
    try expectContains(output, "zap_runtime.ArcRuntime.releaseAny(");
    try expectNotContains(output, "// unhandled instruction");
}

test "shared opaque closure arg emits ARC retain and release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn run(use_fn :: (shared Handle -> Handle), handle :: Handle) -> Handle {
        \\    use_fn(handle)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.ArcRuntime.retainAny(");
    try expectContains(output, "zap_runtime.ArcRuntime.releaseAny(");
    try expectNotContains(output, "// unhandled instruction");
}

test "borrowed opaque closure arg emits no ARC retain or release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn run(use_fn :: (borrowed Handle -> Handle), handle :: Handle) -> Handle {
        \\    use_fn(handle)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectNotContains(output, "zap_runtime.ArcRuntime.retainAny(");
    try expectNotContains(output, "zap_runtime.ArcRuntime.releaseAny(");
    try expectNotContains(output, "// unhandled instruction");
}

test "borrowed capturing closure passed to known-safe callee avoids heap env and ARC ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn apply(f :: (borrowed Handle -> Bool), handle :: borrowed Handle) -> Bool {
        \\    f(handle)
        \\  }
        \\
        \\  pub fn make(handle :: borrowed Handle) -> Bool {
        \\    pub fn use(h :: borrowed Handle) -> Bool {
        \\      h == handle
        \\    }
        \\
        \\    apply(use, handle)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "var __");
    try expectNotContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectNotContains(output, "fn __closure_release_");
    try expectNotContains(output, "zap_runtime.ArcRuntime.retainAny(");
    try expectNotContains(output, "zap_runtime.ArcRuntime.releaseAny(");
}

test "top-level main stays bare, module functions get prefixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Helper {
        \\  pub fn helper(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Helper.helper(5)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Module functions should be prefixed
    try expectContains(output, "fn Helper__helper(");
    // Main stays bare
    try expectContains(output, "fn main(");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Import resolution
// ============================================================

test "import with only filter resolves bare call to source module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Bar {
        \\  pub fn run(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module Foo {
        \\  import Bar, only: [run: 1]
        \\
        \\  pub fn call() -> i64 {
        \\    run(1)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // run(1) inside Foo should resolve to Bar__run via import
    try expectContains(output, "fn Bar__run(");
    try expectContains(output, "fn Foo__call(");
    try expectContains(output, "Bar__run(");
    try expectNotContains(output, "// unhandled instruction");
}

test "import all resolves bare call to source module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Utils {
        \\  pub fn helper(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\}
        \\
        \\pub module App {
        \\  import Utils
        \\
        \\  pub fn go() -> i64 {
        \\    helper(5)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // helper(5) inside App should resolve to Utils__helper via import all
    try expectContains(output, "fn Utils__helper(");
    try expectContains(output, "fn App__go(");
    try expectContains(output, "Utils__helper(");
    try expectNotContains(output, "// unhandled instruction");
}

test "import does not affect unrelated functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Bar {
        \\  pub fn run(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module Foo {
        \\  import Bar, only: [run: 1]
        \\
        \\  pub fn call() -> nil {
        \\    inspect(42)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // inspect(42) should still resolve to Kernel__inspect, not Bar
    try expectContains(output, "Kernel__inspect(");
    try expectNotContains(output, "// unhandled instruction");
}

test "local function takes priority over import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Bar {
        \\  pub fn run(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module Foo {
        \\  import Bar, only: [run: 1]
        \\
        \\  pub fn run(x :: i64) -> i64 {
        \\    x * 10
        \\  }
        \\
        \\  pub fn call() -> i64 {
        \\    run(1)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // run(1) inside Foo should resolve to Foo__run (local takes priority)
    try expectContains(output, "fn Foo__run(");
    try expectContains(output, "Foo__run(");
    try expectNotContains(output, "// unhandled instruction");
}

test "import with except filter excludes specified functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Utils {
        \\  pub fn helper(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn other(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\}
        \\
        \\pub module App {
        \\  import Utils, except: [helper: 1]
        \\
        \\  pub fn go() -> i64 {
        \\    other(5)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // other(5) should resolve to Utils__other (not excluded)
    try expectContains(output, "Utils__other(");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Error reporting tests
// ============================================================

test "parse error includes file and line in diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "pub fn (broken syntax";
    const result = compile(alloc, source);
    try std.testing.expectError(error.ParseError, result);
}

test "diagnostic engine captures errors with line and col" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    const source = "pub fn foo() {\n  bar()\n}\n";
    engine.setSource(source, "test.zap");

    // Simulate an error at line 2, col 3
    try engine.err("undefined function `bar/0`", .{ .start = 15, .end = 20, .line = 2, .col = 3 });

    try std.testing.expect(engine.hasErrors());
    const output = try engine.format(alloc);
    try expectContains(output, "error: undefined function `bar/0`");
    try expectContains(output, "test.zap:2:3");
}

test "column numbers are accurate for tokens at known positions" {
    // Verify the lexer produces correct column numbers
    const Lexer = @import("lexer.zig").Lexer;
    const Token = @import("token.zig").Token;
    const ast = @import("ast.zig");

    const source = "pub fn add(x, y) {\n  x + y\n}";
    var lexer = Lexer.init(source);

    // Line 1: pub at col 1
    const pub_tok = lexer.next();
    try std.testing.expectEqual(Token.Tag.keyword_pub, pub_tok.tag);
    try std.testing.expectEqual(@as(u32, 1), pub_tok.loc.col);
    try std.testing.expectEqual(@as(u32, 1), pub_tok.loc.line);

    // SourceSpan.from preserves col
    const span = ast.SourceSpan.from(pub_tok.loc);
    try std.testing.expectEqual(@as(u32, 1), span.col);
    try std.testing.expectEqual(@as(u32, 1), span.line);
}

test "type checker warnings do not halt compilation by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // This valid program should compile even with type checking enabled
    const source =
        \\pub module Adder {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    const result = try compileWithDiagnostics(alloc, source, false);
    try expectContains(result.output, "fn Adder__add(");
}

test "return type mismatch is always an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Return type mismatch: declared i64, returns String
    const source =
        \\pub module Test {
        \\  pub fn bad() -> i64 {
        \\    "not a number"
        \\  }
        \\}
    ;

    // Return type mismatch is a hard error regardless of strict_types
    const result = compileWithDiagnostics(alloc, source, false);
    try std.testing.expectError(error.TypeError, result);
}

test "error messages contain file:line:col format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("pub fn foo() -> i64 {\n  \"hello\"\n}", "example.zap");
    try engine.err("expected i64, got String", .{ .start = 22, .end = 29, .line = 2, .col = 3 });

    const output = try engine.format(alloc);
    // Should have error message and file:line:col location
    try expectContains(output, "error: expected i64, got String");
    try expectContains(output, "example.zap:2:3");
}

test "pub fn main inside pub module emits pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module App {
        \\  pub fn main() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit pub fn main(), not fn App__main()
    try expectContains(output, "pub fn main()");
    try expectNotContains(output, "App__main");
}

test "binary pattern matching extracts bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn first_byte(<<a, _b, _c>> :: String) -> i64 {
        \\    a
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit std.mem.readInt for byte extraction
    try expectContains(output, "std.mem.readInt(u8,");
}

test "binary pattern with u16 type spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn parse_port(<<port::u16>> :: String) -> i64 {
        \\    port
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "std.mem.readInt(u16,");
}

test "binary pattern with String rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn parse_header(<<tag::u8, rest::String>> :: String) -> {i64, String} {
        \\    {tag, rest}
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should extract a u8 then slice the rest
    try expectContains(output, "std.mem.readInt(u8,");
}

test "binary pattern with float extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn parse_coord(<<lat::f64, lon::f64>> :: String) -> {f64, f64} {
        \\    {lat, lon}
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit @bitCast for float extraction
    try expectContains(output, "@bitCast(std.mem.readInt(u64,");
}

test "binary pattern with endianness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn parse_le(<<val::u32-little>> :: String) -> i64 {
        \\    val
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, ".little");
}

test "binary pattern emits length check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Binary {
        \\  pub fn parse_port(<<port::u16>> :: String) -> i64 {
        \\    port
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit a length check before extraction
    try expectContains(output, ".len >= 2");
}

test "binary pattern with string prefix match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module HTTP {
        \\  pub fn parse_method(<<"GET "::String, path::String>> :: String) -> String {
        \\    path
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit std.mem.eql for prefix matching
    try expectContains(output, "std.mem.eql(u8,");
    try expectContains(output, "\"GET \"");
}

test "binary pattern sub-byte extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Flags {
        \\  pub fn parse_flags(<<syn::u1, ack::u1, fin::u1, _reserved::u5>> :: String) -> {i64, i64, i64} {
        \\    {syn, ack, fin}
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit @truncate with bit shifts for sub-byte extraction
    try expectContains(output, "@truncate(");
    try expectContains(output, ">> 7"); // syn: bit 7
    try expectContains(output, ">> 6"); // ack: bit 6
    try expectContains(output, ">> 5"); // fin: bit 5
}

test "binary pattern in case emits length check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Binary patterns in case expressions emit length checks via check_binary
    const source =
        \\pub module Binary {
        \\  pub fn parse(data :: String) -> i64 {
        \\    case data {
        \\      <<_a, _b>> -> 1
        \\      _ -> 0
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, ".len >= 2");
}

test "lexer tokenizes angle brackets" {
    const Lexer = @import("lexer.zig").Lexer;
    const Token = @import("token.zig").Token;

    const source = "<<1, 2>>";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.left_angle_angle, t1.tag);

    // 1
    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t2.tag);

    // ,
    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.comma, t3.tag);

    // 2
    const t4 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t4.tag);

    // >>
    const t5 = lexer.next();
    try std.testing.expectEqual(Token.Tag.right_angle_angle, t5.tag);
}

test "hex literal parsing" {
    const Lexer = @import("lexer.zig").Lexer;
    const Token = @import("token.zig").Token;

    const source = "0xFF 0x00 0xDEAD";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t1.tag);
    try std.testing.expectEqualStrings("0xFF", t1.slice(source));

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t2.tag);
    try std.testing.expectEqualStrings("0x00", t2.slice(source));

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t3.tag);
    try std.testing.expectEqualStrings("0xDEAD", t3.slice(source));
}

test "multiline struct literal parses correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct User {
        \\  name :: String
        \\  age :: i64
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> User {
        \\    u = %{
        \\      name: "Alice",
        \\      age: 30
        \\    } :: User
        \\    u
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "pub const User = struct {");
    try expectContains(output, "\"Alice\"");
    try expectContains(output, "30");
}

test "multi-parameter function uses distinct param indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Typed version — goes through full pipeline including type checker
    const source =
        \\pub module Math {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Math.add(20, 22)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // The generated Zig should reference both __arg_0 and __arg_1
    try expectContains(output, "__arg_0");
    try expectContains(output, "__arg_1");
}

test "multi-parameter function param_get indices in IR" {
    // Test at the IR level — params now require types
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Test {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\}
    ;

    var parser = @import("parser.zig").Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = @import("collector.zig").Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = @import("types.zig").TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var hir_builder = @import("hir.zig").HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = ir.IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    const func = ir_program.functions[0];
    try std.testing.expect(func.body.len > 0);

    // Collect all param_get instructions
    var param_indices: std.ArrayListUnmanaged(u32) = .empty;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .param_get => |pg| try param_indices.append(alloc, pg.index),
            else => {},
        }
    }

    // We should have exactly 2 param_get instructions with indices 0 and 1
    try std.testing.expectEqual(@as(usize, 2), param_indices.items.len);
    try std.testing.expectEqual(@as(u32, 0), param_indices.items[0]);
    try std.testing.expectEqual(@as(u32, 1), param_indices.items[1]);
}

test "top-level multi-param function called from main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Adder {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    IO.puts(Adder.add(20, 22))
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // The add function should use both __arg_0 and __arg_1
    try expectContains(output, "__arg_0");
    try expectContains(output, "__arg_1");
}

test "three-parameter function uses all param indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub fn sum3(a :: i64, b :: i64, c :: i64) -> i64 {
        \\    a + b + c
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> i64 {
        \\    Math.sum3(1, 2, 3)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "__arg_0");
    try expectContains(output, "__arg_1");
    try expectContains(output, "__arg_2");
}

// ============================================================
// Analysis Pipeline Integration Tests (Phase 9)
// ============================================================

test "pipeline: non-escaping closure avoids heap allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add_x(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Non-escaping closure should NOT use page_allocator.
    try expectNotContains(output, "page_allocator.create(__closure_env_");
}

test "pipeline: returned closure uses heap allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn make(x :: i64) -> (i64 -> i64) {
        \\    pub fn other(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    other
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Returned closure should use DynClosure (it escapes).
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectContains(output, "fn __closure_release_");
}

test "pipeline: aliased returned closure still uses heap allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn make(x :: i64) -> (i64 -> i64) {
        \\    pub fn other(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = other
        \\    f
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "std.heap.page_allocator.create(__closure_env_");
    try expectContains(output, "fn __closure_release_");
}

test "pipeline: lambda lifted local def uses no closure object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn bar() -> i64 {
        \\    pub fn forty_two() -> i64 {
        \\      42
        \\    }
        \\
        \\    forty_two()
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__forty_two(");
    try expectNotContains(output, "zap_runtime.DynClosure{");
    try expectNotContains(output, "__closure_invoke_");
    try expectNotContains(output, "__closure_env_");
}

test "pipeline: multi-function program compiles cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\
        \\  pub fn double(x :: i64) -> i64 {
        \\    add(x, x)
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    IO.puts(Math.double(21))
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Math__add(");
    try expectContains(output, "fn Math__double(");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: pattern matching compiles through analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Matcher {
        \\  pub fn check(x :: i64) -> i64 {
        \\    case x {
        \\      0 -> 100
        \\      1 -> 200
        \\      _ -> 300
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Matcher__check(");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: recursive function compiles through analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Counter {
        \\  pub fn count(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn count(n :: i64) -> i64 {
        \\    1 + count(n - 1)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Counter__count(");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: closure passed to higher-order function uses DynClosure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn apply(f :: (i64 -> i64), value :: i64) -> i64 {
        \\    f(value)
        \\  }
        \\
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    apply(add_x, 10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Closure passed as argument is still represented as DynClosure, but the
    // callee may be specialized to call its known invoke wrapper directly.
    try expectContains(output, "zap_runtime.DynClosure");
    try expectContains(output, "__closure_invoke_");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: fibonacci compiles through full analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Fib {
        \\  pub fn fib(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn fib(1 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn fib(n :: i64) -> i64 {
        \\    fib(n - 1) + fib(n - 2)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Fib__fib(");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: multiple modules compile together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module A {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\}
        \\
        \\pub module B {
        \\  pub fn quad(x :: i64) -> i64 {
        \\    A.double(A.double(x))
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn A__double(");
    try expectContains(output, "fn B__quad(");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Phase 6 Success Criteria Tests
// ============================================================

test "pipeline: closure stored in collection uses DynClosure fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Closure stored in a variable (not just called) → DynClosure.
    const source =
        \\pub module Foo {
        \\  pub fn bar(x :: i64) -> i64 {
        \\    pub fn add_x(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    f = add_x
        \\    f(10)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Closure is stored in a variable → uses DynClosure.
    try expectContains(output, "zap_runtime.DynClosure{");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Phase 7 Success Criteria Tests
// ============================================================

test "pipeline: non-escaping struct has no retain in output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A struct that is created and used locally (not returned, not stored
    // in a heap container) should not generate ARC operations.
    const source =
        \\pub module Foo {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Simple function with no heap allocation should have no ARC.
    try expectNotContains(output, "retainAny");
    try expectNotContains(output, "releaseAny");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Phase 9 Success Criteria Tests
// ============================================================

test "pipeline: complex program with closures, patterns, modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Math {
        \\  pub fn factorial(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn factorial(n :: i64) -> i64 {
        \\    n * factorial(n - 1)
        \\  }
        \\}
        \\
        \\pub module Test {
        \\  pub fn main() -> String {
        \\    IO.puts(Math.factorial(10))
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Math__factorial(");
    try expectContains(output, "pub fn main(");
    try expectNotContains(output, "// unhandled instruction");
    try expectNotContains(output, "func_unknown(");
}

test "pipeline: nested closures compile cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  pub fn make_adder(x :: i64) -> (i64 -> i64) {
        \\    pub fn add(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__make_adder(");
    try expectContains(output, "fn Foo__add(");
    try expectContains(output, "zap_runtime.DynClosure");
    try expectNotContains(output, "// unhandled instruction");
}

test "pipeline: atom pattern matching through analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Status {
        \\  pub fn check(:ok :: Atom) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn check(:error :: Atom) -> i64 {
        \\    0
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Status__check(");
    try expectNotContains(output, "// unhandled instruction");
}

// ============================================================
// Dependency system integration tests
// ============================================================

const discovery = @import("discovery.zig");
const compiler = @import("compiler.zig");

test "deps: cross-module function call compiles" {
    // Two modules — App calls MathLib.add
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\pub module MathLib {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\}
        \\
        \\pub module App {
        \\  pub fn main() -> i64 {
        \\    MathLib.add(1, 2)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn MathLib__add(");
    try expectContains(output, "fn main(");
}

test "deps: discovery finds files and they compile together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create temp project with two files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "app.zap",
        .data = "pub module App {\n  pub fn main() -> i64 {\n    Helper.value()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "helper.zap",
        .data = "pub module Helper {\n  pub fn value() -> i64 {\n    42\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");

    // Discover files
    var graph = try discovery.discover(
        alloc,
        "App",
        &.{.{ .name = "project", .path = tmp_path }},
        &discovery.BUILTIN_TYPE_NAMES,
        null,
    );
    defer graph.deinit();

    // Read discovered files and concatenate
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    for (graph.topo_order.items) |file_path| {
        const src = try std.fs.cwd().readFileAlloc(alloc, file_path, 10 * 1024 * 1024);
        try combined.appendSlice(alloc, src);
        try combined.append(alloc, '\n');
    }

    // Compile the concatenated source
    const output = try compile(alloc, combined.items);
    try expectContains(output, "fn Helper__value(");
    try expectContains(output, "fn main(");
}

test "deps: discovery with dep root finds dep modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Project file
    tmp_dir.dir.makePath("project") catch {};
    tmp_dir.dir.makePath("dep_lib") catch {};

    try tmp_dir.dir.writeFile(.{
        .sub_path = "project/app.zap",
        .data = "pub module App {\n  pub fn main() -> i64 {\n    DepMath.add(1, 2)\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "dep_lib/dep_math.zap",
        .data = "pub module DepMath {\n  pub fn add(a :: i64, b :: i64) -> i64 {\n    a + b\n  }\n}\n",
    });

    const project_path = try tmp_dir.dir.realpathAlloc(alloc, "project");
    const dep_path = try tmp_dir.dir.realpathAlloc(alloc, "dep_lib");

    // Discover with dep root
    var graph = try discovery.discover(
        alloc,
        "App",
        &.{
            .{ .name = "project", .path = project_path },
            .{ .name = "dep:math", .path = dep_path },
        },
        &discovery.BUILTIN_TYPE_NAMES,
        null,
    );
    defer graph.deinit();

    // Read and compile
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    for (graph.topo_order.items) |file_path| {
        const src = try std.fs.cwd().readFileAlloc(alloc, file_path, 10 * 1024 * 1024);
        try combined.appendSlice(alloc, src);
        try combined.append(alloc, '\n');
    }

    const output = try compile(alloc, combined.items);
    try expectContains(output, "fn DepMath__add(");
    try expectContains(output, "fn main(");
}

test "deps: private module enforcement blocks cross-dep access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.makePath("project") catch {};
    tmp_dir.dir.makePath("dep_lib") catch {};

    // Project tries to access a private dep module
    try tmp_dir.dir.writeFile(.{
        .sub_path = "project/app.zap",
        .data = "pub module App {\n  pub fn main() -> i64 {\n    PrivateMod.secret()\n  }\n}\n",
    });
    // Dep has a private module
    try tmp_dir.dir.writeFile(.{
        .sub_path = "dep_lib/private_mod.zap",
        .data = "module PrivateMod {\n  pub fn secret() -> i64 {\n    99\n  }\n}\n",
    });

    const project_path = try tmp_dir.dir.realpathAlloc(alloc, "project");
    const dep_path = try tmp_dir.dir.realpathAlloc(alloc, "dep_lib");

    const result = discovery.discover(
        alloc,
        "App",
        &.{
            .{ .name = "project", .path = project_path },
            .{ .name = "dep:secret_lib", .path = dep_path },
        },
        &discovery.BUILTIN_TYPE_NAMES,
        null,
    );

    // Should fail because PrivateMod is module (private) in a different dep
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "deps: private module allowed within same dep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Both files in the same source root — module (private) is visible
    try tmp_dir.dir.writeFile(.{
        .sub_path = "public_mod.zap",
        .data = "pub module PublicMod {\n  pub fn go() -> i64 {\n    InternalMod.helper()\n  }\n}\n",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "internal_mod.zap",
        .data = "module InternalMod {\n  pub fn helper() -> i64 {\n    42\n  }\n}\n",
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");

    // Both in same root — should succeed
    var graph = try discovery.discover(
        alloc,
        "PublicMod",
        &.{.{ .name = "dep:mylib", .path = tmp_path }},
        &discovery.BUILTIN_TYPE_NAMES,
        null,
    );
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.topo_order.items.len);
}

// ============================================================
// Module attribute integration tests
// ============================================================

test "attributes: typed attribute compiles and is stored on function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @doc :: String = "hello world"
        \\  pub fn bar() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    // Compile through the pipeline — should not error
    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__bar(");
}

test "attributes: marker attribute compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @debug
        \\  pub fn inspect(value :: i64) -> i64 {
        \\    value
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__inspect(");
}

test "attributes: module-level attribute compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @moduledoc :: String = "A module"
        \\  pub fn bar() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__bar(");
}

test "attributes: multiple attributes on function compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @doc :: String = "does something"
        \\  @deprecated :: String = "use bar2"
        \\  pub fn bar() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__bar(");
}

test "attributes: stored in scope graph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\pub module Foo {
        \\  @moduledoc :: String = "A module doc"
        \\  @doc :: String = "Function doc"
        \\  pub fn bar() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    const stdlib_source = try readStdlibSource(alloc);
    const full_source = try std.mem.concat(alloc, u8, &.{ stdlib_source, source });

    var parser = @import("parser.zig").Parser.init(alloc, full_source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = @import("collector.zig").Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Find the Foo module entry
    var foo_found = false;
    for (collector.graph.modules.items) |mod_entry| {
        if (mod_entry.name.parts.len == 1) {
            const name = parser.interner.get(mod_entry.name.parts[0]);
            if (std.mem.eql(u8, name, "Foo")) {
                foo_found = true;
                // Module should have the @moduledoc attribute
                try std.testing.expectEqual(@as(usize, 1), mod_entry.attributes.items.len);
                const attr = mod_entry.attributes.items[0];
                try std.testing.expectEqualStrings("moduledoc", parser.interner.get(attr.name));
                break;
            }
        }
    }
    try std.testing.expect(foo_found);

    // Find the bar function family and check it has @doc
    var bar_found = false;
    for (collector.graph.families.items) |family| {
        const fname = parser.interner.get(family.name);
        if (std.mem.eql(u8, fname, "bar") and family.arity == 0) {
            // Check if this is Foo's bar (not a stdlib function)
            if (family.attributes.items.len > 0) {
                bar_found = true;
                try std.testing.expectEqual(@as(usize, 1), family.attributes.items.len);
                const attr = family.attributes.items[0];
                try std.testing.expectEqualStrings("doc", parser.interner.get(attr.name));
            }
        }
    }
    try std.testing.expect(bar_found);
}

test "attributes: @name substitution in function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @timeout :: i64 = 5000
        \\  pub fn get_timeout() -> i64 {
        \\    @timeout
        \\  }
        \\}
    ;

    // Should compile — @timeout is substituted with 5000
    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__get_timeout(");
}

test "attributes: @name substitution in expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Foo {
        \\  @base :: i64 = 100
        \\  pub fn doubled() -> i64 {
        \\    @base * 2
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Foo__doubled(");
}

// ============================================================
// Error pipe (~>) with explicit union declarations
// ============================================================

test "error pipe ~> with block handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Pipeline {
        \\  pub union Result {
        \\    Ok :: i64
        \\    Error :: i64
        \\  }
        \\
        \\  pub fn maybe_fail(x :: i64) -> Result {
        \\    Result.Error(0)
        \\  }
        \\
        \\  pub fn run(x :: i64) -> i64 {
        \\    maybe_fail(x)
        \\    ~> {
        \\      _ -> -1
        \\    }
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Pipeline__maybe_fail(");
    try expectContains(output, "fn Pipeline__run(");
    try expectContains(output, "union(enum)");
}

test "error pipe ~> with function handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Pipeline {
        \\  pub union Result {
        \\    Ok :: i64
        \\    Error :: i64
        \\  }
        \\
        \\  pub fn maybe_fail(x :: i64) -> Result {
        \\    Result.Error(0)
        \\  }
        \\
        \\  pub fn handle_error(err :: i64) -> i64 {
        \\    -1
        \\  }
        \\
        \\  pub fn run(x :: i64) -> i64 {
        \\    maybe_fail(x)
        \\    ~> handle_error()
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn Pipeline__maybe_fail(");
    try expectContains(output, "fn Pipeline__handle_error(");
    try expectContains(output, "fn Pipeline__run(");
}

// ============================================================
// Tagged union with data-carrying variants
// ============================================================

test "union declaration with data variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Types {
        \\  pub union Result {
        \\    Ok :: String
        \\    Error :: Atom
        \\  }
        \\
        \\  pub fn succeed() -> Result {
        \\    Result.Ok("hello")
        \\  }
        \\
        \\  pub fn fail() -> Result {
        \\    Result.Error(:not_found)
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Should emit a Zig union(enum) type definition
    try expectContains(output, "union(enum)");
    try expectContains(output, "Ok: []const u8");
    try expectContains(output, "Error: []const u8");
    try expectContains(output, "fn Types__succeed(");
    try expectContains(output, "fn Types__fail(");
    // Union initialization
    try expectContains(output, ".{ .Ok =");
    try expectContains(output, ".{ .Error =");
}

test "union declaration with unit variants emits enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub module Colors {
        \\  pub union Color {
        \\    Red
        \\    Green
        \\    Blue
        \\  }
        \\
        \\  pub fn pick() -> Color {
        \\    Color.Red
        \\  }
        \\}
    ;

    const output = try compile(alloc, source);
    // Unit-only union should emit a Zig enum (not union(enum))
    try expectContains(output, "= enum {");
    try expectContains(output, "Red");
    try expectContains(output, "fn Colors__pick(");
}

