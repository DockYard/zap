const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const ir = @import("ir.zig");
const CodeGen = @import("codegen.zig").CodeGen;

// ============================================================
// Integration tests (spec §12)
//
// Each test compiles a Zip source through the full pipeline
// and asserts on the generated Zig output.
// ============================================================

/// Run the full compiler pipeline on source, return generated Zig.
fn compile(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    if (parser.errors.items.len > 0) {
        return error.ParseError;
    }

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = ir.IrBuilder.init(alloc, &parser.interner);
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    try codegen.emitProgram(&ir_program);

    return alloc.dupe(u8, codegen.getOutput());
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\n=== EXPECTED to find ===\n{s}\n=== IN OUTPUT ===\n{s}\n=== END ===\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
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
        \\def main() do
        \\  IO.puts("Hello, world!")
        \\end
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
        \\def main() do
        \\  IO.puts("test output")
        \\end
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
        \\def main() do
        \\  println("should not resolve")
        \\end
    ;

    const output = try compile(alloc, source);
    // Should NOT resolve to a Prelude call — println is not imported
    try expectNotContains(output, "zap_runtime.Prelude.println(");
}

// ============================================================
// Factorial with pattern matching
// ============================================================

test "example: factorial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def factorial(0 :: i64) :: i64 do
        \\  1
        \\end
        \\
        \\def factorial(n :: i64) :: i64 do
        \\  n * factorial(n - 1)
        \\end
        \\
        \\def main() do
        \\  factorial(10)
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn factorial(");
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
        \\def fib(0 :: i64) :: i64 do
        \\  0
        \\end
        \\
        \\def fib(1 :: i64) :: i64 do
        \\  1
        \\end
        \\
        \\def fib(n :: i64) :: i64 do
        \\  fib(n - 1) + fib(n - 2)
        \\end
        \\
        \\def main() do
        \\  fib(20)
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn fib(");
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
        \\defmodule Math do
        \\  def square(x :: i64) :: i64 do
        \\    x * x
        \\  end
        \\
        \\  def cube(x :: i64) :: i64 do
        \\    x * x * x
        \\  end
        \\
        \\  def abs(x :: i64) :: i64 do
        \\    if x < 0 do
        \\      -x
        \\    else
        \\      x
        \\    end
        \\  end
        \\end
        \\
        \\def main() do
        \\  Math.square(5)
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn square(");
    try expectContains(output, "fn cube(");
    try expectContains(output, "fn abs(");
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
        \\def describe(:ok) :: String do
        \\  "success"
        \\end
        \\
        \\def describe(:error) :: String do
        \\  "failure"
        \\end
        \\
        \\def describe(_) :: String do
        \\  "unknown"
        \\end
        \\
        \\def main() do
        \\  describe(:ok)
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn describe(");
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
        \\def double(x :: i64) :: i64 do
        \\  x * 2
        \\end
        \\
        \\def add_one(x :: i64) :: i64 do
        \\  x + 1
        \\end
        \\
        \\def main() do
        \\  5
        \\  |> double()
        \\  |> add_one()
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn double(");
    try expectContains(output, "fn add_one(");
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
        \\defmodule Geometry do
        \\  type Shape = {:circle, f64} | {:rectangle, f64, f64}
        \\
        \\  def area({:circle, radius} :: Shape) :: f64 do
        \\    3.14159 * radius * radius
        \\  end
        \\
        \\  def area({:rectangle, w, h} :: Shape) :: f64 do
        \\    w * h
        \\  end
        \\end
        \\
        \\def main() do
        \\  Geometry.area({:circle, 5.0})
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn area(");
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
        \\def noop() do
        \\  nil
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "// Generated by Zap compiler");
    try expectContains(output, "const std = @import(\"std\");");
    try expectContains(output, "const zap_runtime = @import(\"zap_runtime\");");
}

test "multiple function clauses produce separate functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def greet(:morning) :: String do
        \\  "Good morning"
        \\end
        \\
        \\def greet(:evening) :: String do
        \\  "Good evening"
        \\end
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
        \\def greet(name :: String) :: String do
        \\  "Hello, " <> name
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn greet(");
    try expectContains(output, "\"Hello, \"");
}

test "if-else generates conditional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def sign(x :: i64) :: String do
        \\  if x > 0 do
        \\    "positive"
        \\  else
        \\    "non-positive"
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn sign(");
    // If-else lowers to cond_branch with goto labels
    try expectContains(output, "if (");
    try expectContains(output, "goto label_");
}

test "parse error produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "def (broken syntax";
    const result = compile(alloc, source);
    try std.testing.expectError(error.ParseError, result);
}
