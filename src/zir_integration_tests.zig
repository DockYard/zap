const std = @import("std");

// ============================================================
// ZIR Integration Tests
//
// Each test compiles a Zap source through the full ZIR pipeline
// by invoking the `zap` binary as a subprocess, then runs the
// compiled binary and asserts on stdout.
//
// IMPORTANT: Module names must match file path. Since all test
// sources are written to `lib/test_prog.zap`, every module must
// be named `TestProg`.
// ============================================================

const TestError = error{
    CompilationFailed,
    RunFailed,
    OutOfMemory,
    Unexpected,
    StdoutStreamTooLong,
    StderrStreamTooLong,
    CurrentWorkingDirectoryUnlinked,
} || std.posix.ReadError || std.posix.PollError || std.process.Child.SpawnError;

const TestResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,
    /// Path to compiled binary for cleanup
    output_dir: ?[]const u8,

    pub fn deinit(self: *TestResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        if (self.output_dir) |dir| {
            // Clean up compiled output
            std.fs.cwd().deleteTree(dir) catch {};
            self.allocator.free(dir);
        }
    }
};

fn compileOnly(source: []const u8) TestError!void {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.makePath("lib") catch return error.Unexpected;

    const build_source =
        \\pub module TestProg.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test_prog ->
        \\        %Zap.Manifest{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "TestProg.main/0",
        \\          paths: ["lib/**/*.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "build.zap", .data = build_source }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(.{ .sub_path = "lib/test_prog.zap", .data = source }) catch return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary_raw = std.process.getEnvVarOwned(allocator, "ZAP_BINARY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "zig-out/bin/zap") catch return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer allocator.free(zap_binary_raw);

    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.fs.cwd().realpathAlloc(allocator, zap_binary_raw) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    const compile_argv: []const []const u8 = &.{ zap_binary, "build", "test_prog" };
    var compile_child = std.process.Child.init(compile_argv, allocator);
    compile_child.cwd = tmp_dir_path;
    compile_child.stderr_behavior = .Ignore;
    compile_child.stdout_behavior = .Ignore;
    const compile_term = compile_child.spawnAndWait() catch return error.CompilationFailed;

    const compile_exit = switch (compile_term) {
        .Exited => |code| code,
        else => return error.CompilationFailed,
    };

    if (compile_exit != 0) return error.CompilationFailed;
}

/// Compile a Zap source string and run the resulting binary, returning stdout.
fn compileAndRun(source: []const u8) TestError!TestResult {
    const allocator = std.testing.allocator;

    // Create a temp project directory.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.makePath("lib") catch return error.Unexpected;

    const build_source =
        \\pub module TestProg.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test_prog ->
        \\        %Zap.Manifest{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "TestProg.main/0",
        \\          paths: ["lib/**/*.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(.{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(.{ .sub_path = "lib/test_prog.zap", .data = source }) catch
        return error.Unexpected;

    // Get the real path to the temp project directory.
    const tmp_dir_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    // Get zap binary path from environment or use default.
    const zap_binary_raw = std.process.getEnvVarOwned(allocator, "ZAP_BINARY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "zig-out/bin/zap") catch return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer allocator.free(zap_binary_raw);

    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.fs.cwd().realpathAlloc(allocator, zap_binary_raw) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    // Compile: zap build test_prog
    const compile_argv: []const []const u8 = &.{ zap_binary, "build", "test_prog" };
    var compile_child = std.process.Child.init(compile_argv, allocator);
    compile_child.cwd = tmp_dir_path;
    compile_child.stderr_behavior = .Ignore;
    compile_child.stdout_behavior = .Ignore;
    const compile_term = compile_child.spawnAndWait() catch return error.CompilationFailed;

    const compile_exit = switch (compile_term) {
        .Exited => |code| code,
        else => return error.CompilationFailed,
    };

    if (compile_exit != 0) {
        std.debug.print("\n=== COMPILATION FAILED (exit {d}) ===\n", .{compile_exit});
        return error.CompilationFailed;
    }

    // The zap binary outputs to zap-out/bin/test_prog (relative to cwd)
    const compiled_binary = tmp_dir.dir.realpathAlloc(allocator, "zap-out/bin/test_prog") catch {
        std.debug.print("\n=== COMPILED BINARY NOT FOUND ===\n", .{});
        return error.CompilationFailed;
    };
    defer allocator.free(compiled_binary);

    // Run the compiled binary
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{compiled_binary},
        .max_output_bytes = 256 * 1024,
    }) catch return error.RunFailed;

    const run_exit = switch (run_result.term) {
        .Exited => |code| code,
        else => {
            allocator.free(run_result.stdout);
            allocator.free(run_result.stderr);
            return error.RunFailed;
        },
    };

    // Build output dir path for cleanup
    const output_dir = tmp_dir.dir.realpathAlloc(allocator, "zap-out") catch null;

    return .{
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .exit_code = run_exit,
        .allocator = allocator,
        .output_dir = output_dir,
    };
}

// ============================================================
// Constants and arithmetic
// ============================================================

test "ZIR: integer arithmetic" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    Kernel.inspect(20 + 22)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: string literal" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    IO.puts("hello world")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: string escape sequences" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    IO.print_str("line1\nline2\n")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("line1\nline2\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: boolean" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    Kernel.inspect(true)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("true\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Functions
// ============================================================

test "ZIR: multi-function call" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(add(20, 22))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: void function" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Control flow
// ============================================================

test "ZIR: if-else true branch" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    if true {
        \\      IO.puts("yes")
        \\    } else {
        \\      IO.puts("no")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("yes\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: if-else false branch" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    if false {
        \\      IO.puts("yes")
        \\    } else {
        \\      IO.puts("no")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("no\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Pattern matching
// ============================================================

test "ZIR: case with atoms" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    case :ok {
        \\      :ok -> IO.puts("matched")
        \\      _ -> IO.puts("default")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("matched\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: case with ints" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    case 1 {
        \\      1 -> IO.puts("one")
        \\      _ -> IO.puts("other")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("one\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Multi-function programs
// ============================================================

test "ZIR: recursive sum" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn sum_to(n :: i64) -> i64 {
        \\    case n {
        \\      0 -> 1
        \\      1 -> 1
        \\      _ -> n + sum_to(n - 1)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(sum_to(5))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("15\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: multiple helper functions" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x + x
        \\  }
        \\
        \\  pub fn add_one(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(add_one(double(10)))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("21\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Closures
// ============================================================

test "ZIR: lambda lifted local def" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn bar() -> i64 {
        \\    pub fn forty_two() -> i64 {
        \\      42
        \\    }
        \\
        \\    forty_two()
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(bar())
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: function-local captured closure" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn make_adder(x :: i64) -> i64 {
        \\    pub fn add(y :: i64) -> i64 {
        \\      x + y
        \\    }
        \\
        \\    add(10)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(make_adder(32))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: aliased function-local captured closure" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn compute(base :: i64) -> i64 {
        \\    pub fn offset(n :: i64) -> i64 {
        \\      base + n
        \\    }
        \\
        \\    offset(5) + offset(3)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(compute(10))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("28\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: captured closure called through multiple paths" {
    // Two closures that capture the same variable, selected by case.
    // Exercises closure creation + env struct emission for different functions.
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn compute(base :: i64, mode :: i64) -> i64 {
        \\    pub fn add_ten(y :: i64) -> i64 {
        \\      base + y + 10
        \\    }
        \\
        \\    pub fn add_twenty(y :: i64) -> i64 {
        \\      base + y + 20
        \\    }
        \\
        \\    case mode {
        \\      1 -> add_ten(0)
        \\      _ -> add_twenty(0)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(compute(100, 1))
        \\    Kernel.inspect(compute(100, 2))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("110\n120\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Cond (nested captured bodies)
// ============================================================

test "ZIR: cond with comparisons (nested captured bodies)" {
    // Cond expands to nested case expressions. Each case arm's body is captured
    // in a ZIR condbr body. Inner cases must be able to reference function
    // params from the parent scope. This requires nestable capture buffers.
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn describe(x :: i64) -> String {
        \\    cond {
        \\      x == 1 -> "one"
        \\      x == 2 -> "two"
        \\      true -> "other"
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(describe(1))
        \\    IO.puts(describe(2))
        \\    IO.puts(describe(99))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("one\ntwo\nother\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Catch basin (error pipe)
// ============================================================

test "ZIR: catch basin ~> catches unmatched multi-clause function" {
    // TODO: addCatch block result type is inferred as error union instead of
    // payload type by Sema. The catch basin compiles and runs (process("hello")
    // returns correctly), but passing the result to IO.puts/Kernel.inspect
    // triggers "bad store size: 24" in the codegen because it sees
    // anyerror![]const u8 (24 bytes) instead of []const u8 (16 bytes).
    // The __try variant correctly returns error.NoMatchingClause and the
    // addCatch block correctly unwraps it — the type inference is the issue.
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn process("ok" :: String) -> String {
        \\    "matched"
        \\  }
        \\
        \\  pub fn process("yes" :: String) -> String {
        \\    "also matched"
        \\  }
        \\
        \\  pub fn try_ok() -> String {
        \\    "ok"
        \\    |> process()
        \\    ~> {
        \\      _ -> "caught"
        \\    }
        \\  }
        \\
        \\  pub fn try_nope() -> String {
        \\    "nope"
        \\    |> process()
        \\    ~> {
        \\      _ -> "caught"
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(try_ok())
        \\    IO.puts(try_nope())
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("matched\ncaught\n", result.stdout);
}

// ============================================================
// Struct literals
// ============================================================

test "ZIR: struct literal field access" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub struct Point {
        \\    x :: i64
        \\    y :: i64
        \\  }
        \\
        \\  pub fn get_x(p :: Point) -> i64 {
        \\    p.x
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(get_x(%Point{x: 10, y: 20}))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("10\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// String interpolation
// ============================================================

test "ZIR: string interpolation with string variable" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn greet(name :: String) -> String {
        \\    "Hello, #{name}!"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(greet("world"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, world!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: string interpolation with integer via to_string" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    n = 42
        \\    IO.puts("The answer is #{n}")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("The answer is 42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: string interpolation multiple expressions" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    a = "foo"
        \\    b = "bar"
        \\    IO.puts("#{a} and #{b}")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("foo and bar\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Binary patterns
// ============================================================

test "ZIR: binary pattern byte extraction" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn first_byte(data :: String) -> i64 {
        \\    case data {
        \\      <<a, _>> -> a
        \\      _ -> 0
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(first_byte("AB"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("65\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: binary pattern string rest" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn skip_first(data :: String) -> String {
        \\    case data {
        \\      <<_, rest::String>> -> rest
        \\      _ -> ""
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(skip_first("Hello"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ello\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR compile: binary pattern string prefix" {
    try compileOnly(
        \\pub module TestProg {
        \\  pub fn check_get(data :: String) -> String {
        \\    case data {
        \\      <<"GET "::String, path::String>> -> path
        \\      _ -> "unknown"
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    "done"
        \\  }
        \\}
    );
}

// ============================================================
// Pipe chains with type conversion
// ============================================================

test "ZIR: pipe chain with Integer.to_string" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn add_one(x :: i64) -> i64 {
        \\    x + 1
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    5
        \\    |> double()
        \\    |> add_one()
        \\    |> Integer.to_string()
        \\    |> IO.puts()
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("11\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: multi-clause function with pipes" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn factorial(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn factorial(n :: i64) -> i64 {
        \\    n * factorial(n - 1)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    factorial(10)
        \\    |> Integer.to_string()
        \\    |> IO.puts()
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("3628800\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// String concatenation
// ============================================================

test "ZIR: string concat operator" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    IO.puts("hello" <> " " <> "world")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Guards (multi-clause with conditions)
// ============================================================

test "ZIR: function guards" {
    var result = try compileAndRun(
        \\pub module TestProg {
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
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(classify(5))
        \\    IO.puts(classify(-3))
        \\    IO.puts(classify(0))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("positive\nnegative\nzero\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Multi-clause string matching
// ============================================================

test "ZIR: multi-clause string pattern matching" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn parse("one" :: String) -> String {
        \\    "1"
        \\  }
        \\
        \\  pub fn parse("two" :: String) -> String {
        \\    "2"
        \\  }
        \\
        \\  pub fn parse(_ :: String) -> String {
        \\    "?"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(parse("one"))
        \\    IO.puts(parse("two"))
        \\    IO.puts(parse("three"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("1\n2\n?\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Atoms
// ============================================================

test "ZIR: atom pattern matching in functions" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn status(:ok :: Atom) -> String {
        \\    "success"
        \\  }
        \\
        \\  pub fn status(:error :: Atom) -> String {
        \\    "failure"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(status(:ok))
        \\    IO.puts(status(:error))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("success\nfailure\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Default parameters
// ============================================================

test "ZIR: default parameter values" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn add(a :: i64, b :: i64 = 10) -> i64 {
        \\    a + b
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(add(5))
        \\    Kernel.inspect(add(5, 20))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("15\n25\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Multi-arity functions
// ============================================================

test "ZIR: three-argument function with string concat" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn join(a :: String, sep :: String, b :: String) -> String {
        \\    a <> sep <> b
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(join("hello", " ", "world"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Unions (tagged enums)
// ============================================================

test "ZIR: union variant pattern matching" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub union Color {
        \\    Red
        \\    Green
        \\    Blue
        \\  }
        \\
        \\  pub fn color_name(Color.Red :: Color) -> String {
        \\    "red"
        \\  }
        \\
        \\  pub fn color_name(Color.Green :: Color) -> String {
        \\    "green"
        \\  }
        \\
        \\  pub fn color_name(Color.Blue :: Color) -> String {
        \\    "blue"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(color_name(Color.Red))
        \\    IO.puts(color_name(Color.Green))
        \\    IO.puts(color_name(Color.Blue))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("red\ngreen\nblue\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Tuple destructuring
// ============================================================

test "ZIR: tuple pattern matching in case" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn sum_pair(t :: {i64, i64}) -> i64 {
        \\    case t {
        \\      {a, b} -> a + b
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(sum_pair({10, 32}))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: tuple wildcard pattern" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn second(t :: {i64, i64}) -> i64 {
        \\    case t {
        \\      {_, b} -> b
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(second({10, 42}))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Variable assignment and reuse
// ============================================================

test "ZIR: variable assignment chain" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    a = 10
        \\    b = a + 20
        \\    c = b * 2
        \\    Kernel.inspect(c)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("60\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Nested case expressions
// ============================================================

test "ZIR: nested case expressions" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn classify(x :: i64, y :: i64) -> String {
        \\    case x {
        \\      0 -> case y {
        \\        0 -> "origin"
        \\        _ -> "y-axis"
        \\      }
        \\      _ -> case y {
        \\        0 -> "x-axis"
        \\        _ -> "plane"
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(classify(0, 0))
        \\    IO.puts(classify(0, 5))
        \\    IO.puts(classify(3, 0))
        \\    IO.puts(classify(3, 5))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("origin\ny-axis\nx-axis\nplane\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Float arithmetic
// ============================================================

test "ZIR: float arithmetic" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn area(radius :: f64) -> f64 {
        \\    3.14159 * radius * radius
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(area(1.0))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    // 3.14159 * 1.0 * 1.0 = 3.14159
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "3.14159"));
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Tail calls
// ============================================================

test "ZIR: tail recursive countdown (small)" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn countdown(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn countdown(n :: i64) -> i64 {
        \\    countdown(n - 1)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(countdown(10))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// List operations
// ============================================================

// ============================================================
// Map operations
// ============================================================

test "ZIR: map literal creation" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    m = %{name: "Alice", age: 30}
        \\    IO.puts(Map.get(m, :name, "unknown"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Alice\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: map get with default" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    m = %{x: 10, y: 20}
        \\    Kernel.inspect(Map.get(m, :x, 0))
        \\    Kernel.inspect(Map.get(m, :z, 99))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("10\n99\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: map has_key check" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    m = %{name: "Alice", age: 30}
        \\    if Map.has_key(m, :name) {
        \\      IO.puts("has name")
        \\    } else {
        \\      IO.puts("no name")
        \\    }
        \\    if Map.has_key(m, :email) {
        \\      IO.puts("has email")
        \\    } else {
        \\      IO.puts("no email")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("has name\nno email\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: map pattern matching in function" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn greet(%{name: n, greeting: g} :: %{Atom -> String}) -> String {
        \\    g <> ", " <> n <> "!"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(greet(%{name: "World", greeting: "Hello"}))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, World!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: map size" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    m = %{a: 1, b: 2, c: 3}
        \\    Kernel.inspect(Map.size(m))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("3\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// List operations
// ============================================================

test "ZIR: list literal and fixed-length pattern" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn sum_list(xs :: [i64]) -> i64 {
        \\    case xs {
        \\      [a, b, c] -> a + b + c
        \\      _ -> 0
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(sum_list([10, 20, 12]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: list cons pattern [h | t]" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn head(xs :: [i64]) -> i64 {
        \\    case xs {
        \\      [h | _] -> h
        \\      _ -> 0
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(head([42, 10, 20]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: recursive list sum with cons pattern" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn sum([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn sum([h | t] :: [i64]) -> i64 {
        \\    h + sum(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(sum([10, 20, 12]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: list length via recursion" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn len([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn len([_ | t] :: [i64]) -> i64 {
        \\    1 + len(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(len([1, 2, 3, 4, 5]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("5\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: list map via recursion" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn double_all([] :: [i64]) -> [i64] {
        \\    []
        \\  }
        \\
        \\  pub fn double_all([h | t] :: [i64]) -> [i64] {
        \\    [h * 2 | double_all(t)]
        \\  }
        \\
        \\  pub fn sum([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn sum([h | t] :: [i64]) -> i64 {
        \\    h + sum(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(sum(double_all([1, 2, 3])))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("12\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: keyword list sugar" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn get_name(opts :: [{Atom, String}]) -> String {
        \\    case opts {
        \\      [name: n] -> n
        \\      _ -> "unknown"
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(get_name([name: "Brian"]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Brian\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: keyword list with multiple keys" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn get_age(opts :: [{Atom, i64}]) -> i64 {
        \\    case opts {
        \\      [name: _, age: a] -> a
        \\      _ -> 0
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(get_age([name: "Brian", age: 42]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: keyword list assignment pattern" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn main() -> String {
        \\    opts = [greeting: "Hello", name: "World"]
        \\    case opts {
        \\      [greeting: g, name: n] -> IO.puts(g <> ", " <> n <> "!")
        \\      _ -> IO.puts("no match")
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, World!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: list of strings with pattern matching" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn first([] :: [String]) -> String {
        \\    "empty"
        \\  }
        \\
        \\  pub fn first([h | _] :: [String]) -> String {
        \\    h
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(first(["hello", "world"]))
        \\    IO.puts(first([]))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello\nempty\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: tail recursive countdown (large, guaranteed TCO)" {
    var result = try compileAndRun(
        \\pub module TestProg {
        \\  pub fn countdown(0 :: i64) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn countdown(n :: i64) -> i64 {
        \\    countdown(n - 1)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(countdown(100_000_000))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
