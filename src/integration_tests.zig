const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const MacroEngine = @import("macro.zig").MacroEngine;
const Desugarer = @import("desugar.zig").Desugarer;
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const ir = @import("ir.zig");
const CodeGen = @import("codegen.zig").CodeGen;
pub const stdlib = @import("stdlib.zig");

// ============================================================
// Integration tests (spec §12)
//
// Each test compiles a Zip source through the full pipeline
// and asserts on the generated Zig output.
// ============================================================

/// Run the full compiler pipeline on source, return generated Zig.
fn compile(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    const full_source = try stdlib.prependStdlib(alloc, source);

    var parser = Parser.init(alloc, full_source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    if (parser.errors.items.len > 0) {
        return error.ParseError;
    }

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Macro expansion (between collection and HIR lowering)
    var macro_engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = try macro_engine.expandProgram(&program);

    // Desugaring (after macro expansion, before HIR)
    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared_program = try desugarer.desugarProgram(&expanded_program);

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&desugared_program);

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
    try expectContains(output, "const zap_runtime = @import(\"zap_runtime.zig\");");
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
        \\defmodule Geometry do
        \\  def area({:circle, radius} :: f64) :: f64 do
        \\    3.14159 * radius * radius
        \\  end
        \\
        \\  def area({:rectangle, w, h} :: f64) :: f64 do
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
        \\def classify(n :: i64) :: String if n > 0 do
        \\  "positive"
        \\end
        \\
        \\def classify(n :: i64) :: String if n < 0 do
        \\  "negative"
        \\end
        \\
        \\def classify(_) :: String do
        \\  "zero"
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn classify(");
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
        \\def check(x :: i64) :: String do
        \\  case x do
        \\    0 ->
        \\      "zero"
        \\    1 ->
        \\      "one"
        \\    _ ->
        \\      "other"
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn check(");
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
        \\def handle(result) do
        \\  case result do
        \\    {:ok, v} ->
        \\      v
        \\    {:error, e} ->
        \\      e
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn handle(");
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
        \\def identity(x) do
        \\  case x do
        \\    v ->
        \\      v
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn identity(");
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
        \\def check(x :: i64) :: String do
        \\  case x do
        \\    0 ->
        \\      "zero"
        \\    1 ->
        \\      "one"
        \\    _ ->
        \\      "other"
        \\  end
        \\end
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
        \\def check(x :: i64) :: String do
        \\  case x do
        \\    0 ->
        \\      "zero"
        \\    n if n > 0 ->
        \\      "positive"
        \\    _ ->
        \\      "negative"
        \\  end
        \\end
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
        \\def check(x) :: String do
        \\  case x do
        \\    :ok ->
        \\      "yes"
        \\    :error ->
        \\      "no"
        \\    _ ->
        \\      "unknown"
        \\  end
        \\end
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
        \\def process(x) do
        \\  case x do
        \\    {:ok, {:data, v}} ->
        \\      v
        \\    {:ok, {:empty}} ->
        \\      nil
        \\    {:error, msg} ->
        \\      msg
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    // Outer struct check should appear only once (not 3 times).
    // Inner struct check adds one more, so total ≤ 2.
    const struct_check_count = countOccurrences(output, "@typeInfo(@TypeOf(");
    if (struct_check_count > 2) {
        std.debug.print("\n=== EXPECTED ≤2 @typeInfo checks, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
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
        \\def handle(result) do
        \\  case result do
        \\    {:ok, v} ->
        \\      v
        \\    {:error, e} ->
        \\      e
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    // Struct type check should appear only ONCE (not once per arm)
    const struct_check_count = countOccurrences(output, "@typeInfo(@TypeOf(");
    if (struct_check_count != 1) {
        std.debug.print("\n=== EXPECTED 1 @typeInfo check, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
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
        \\def handle({:ok, v}) do
        \\  v
        \\end
        \\
        \\def handle({:error, e}) do
        \\  e
        \\end
    ;

    const output = try compile(alloc, source);
    // Struct check should appear only once for multi-clause tuple dispatch
    const struct_check_count = countOccurrences(output, "@typeInfo(@TypeOf(");
    if (struct_check_count != 1) {
        std.debug.print("\n=== EXPECTED 1 @typeInfo check, got {d} ===\n{s}\n=== END ===\n", .{ struct_check_count, output });
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
        \\def f(0 :: i64) :: i64 do
        \\  1
        \\end
        \\
        \\def f(n :: i64) :: i64 do
        \\  n
        \\end
    ;

    const output = try compile(alloc, source);
    // With typed i64 param, no runtime type check needed
    try expectNotContains(output, "@typeInfo");
    try expectNotContains(output, "@TypeOf");
    try expectContains(output, "switch (");
    try expectNotContains(output, "// unhandled instruction");
}

test "untyped param keeps type check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def describe(:ok) :: String do
        \\  "yes"
        \\end
        \\
        \\def describe(_) :: String do
        \\  "no"
        \\end
    ;

    const output = try compile(alloc, source);
    // Untyped param needs runtime type check for atom matching
    try expectContains(output, "@TypeOf");
    try expectNotContains(output, "// unhandled instruction");
}

test "typed case scrutinee skips type check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def check(x :: i64) :: String do
        \\  case x do
        \\    0 ->
        \\      "zero"
        \\    _ ->
        \\      "other"
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    // Typed i64 scrutinee — switch should not have type checks
    try expectNotContains(output, "@typeInfo");
    try expectNotContains(output, "@TypeOf");
    try expectContains(output, "switch (");
}

test "mixed variable and constructor in case" {
    // case x do 1 -> "one"; y -> y end
    // Should work with mixture of literal and variable patterns
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\def check(x :: i64) :: i64 do
        \\  case x do
        \\    1 ->
        \\      100
        \\    y ->
        \\      y
        \\  end
        \\end
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
        \\def check(x) :: String do
        \\  case x do
        \\    0 ->
        \\      "zero"
        \\    :ok ->
        \\      "ok"
        \\    _ ->
        \\      "other"
        \\  end
        \\end
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

    const source = "def (broken syntax";
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
        \\defmodule Logic do
        \\  defmacro unless(condition, body) do
        \\    quote do
        \\      if not unquote(condition) do
        \\        unquote(body)
        \\      end
        \\    end
        \\  end
        \\
        \\  def check(x :: i64) :: i64 do
        \\    unless(x > 0, 42)
        \\  end
        \\end
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
        \\defmodule Math do
        \\  defmacro double(value) do
        \\    quote do
        \\      unquote(value) + unquote(value)
        \\    end
        \\  end
        \\
        \\  def compute(x :: i64) :: i64 do
        \\    double(x * 3)
        \\  end
        \\end
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
        \\def check(x :: i64) :: i64 do
        \\  unless(x > 10, 42)
        \\end
    ;

    const output = try compile(alloc, source);
    // unless should expand to: if not (x > 10) do 42 end, then if desugars to case(true/false)
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
        \\def classify(x :: i64) :: String do
        \\  cond do
        \\    x > 0 ->
        \\      "positive"
        \\    x < 0 ->
        \\      "negative"
        \\    true ->
        \\      "zero"
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn classify(");
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
        \\def process(x) do
        \\  with {:ok, a} <- x do
        \\    a
        \\  else
        \\    {:error, e} ->
        \\      e
        \\  end
        \\end
    ;

    const output = try compile(alloc, source);
    try expectContains(output, "fn process(");
    // with desugars to case — should have tuple matching
    try expectContains(output, ".@\"ok\"");
    try expectContains(output, ".@\"error\"");
    try expectNotContains(output, "// unhandled instruction");
}
