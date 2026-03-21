const std = @import("std");

// ============================================================
// ZIR Integration Tests
//
// Each test compiles a Zap source through the full ZIR pipeline
// by invoking the `zap` binary as a subprocess, then runs the
// compiled binary and asserts on stdout.
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

/// Compile a Zap source string and run the resulting binary, returning stdout.
fn compileAndRun(source: []const u8) TestError!TestResult {
    const allocator = std.testing.allocator;

    // Create a temp directory for the source file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write source to temp file
    tmp_dir.dir.writeFile(.{ .sub_path = "test_prog.zap", .data = source }) catch
        return error.Unexpected;

    // Get the real path to the temp source file
    const tmp_path = tmp_dir.dir.realpathAlloc(allocator, "test_prog.zap") catch
        return error.Unexpected;
    defer allocator.free(tmp_path);

    // Get the directory containing the source file (for cwd of compile)
    const tmp_dir_path = tmp_dir.dir.realpathAlloc(allocator, ".") catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    // Get zap binary path from environment or use default.
    // Must be resolved to an absolute path since we change cwd for compilation.
    const zap_binary_raw = std.process.getEnvVarOwned(allocator, "ZAP_BINARY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "zig-out/bin/zap") catch return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer allocator.free(zap_binary_raw);

    // Resolve to absolute path relative to original cwd
    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.fs.cwd().realpathAlloc(allocator, zap_binary_raw) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    // Compile: zap <source.zap>
    // Run from the temp directory so zap-out/ lands there.
    // Ignore stderr — the Zig compiler emits megabytes of debug output.
    const compile_argv: []const []const u8 = &.{ zap_binary, tmp_path };
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
        \\def main() do
        \\  Kernel.println(20 + 22)
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: float arithmetic" {
    var result = try compileAndRun(
        \\def main() do
        \\  Kernel.println(3.14 * 2.0)
        \\end
    );
    defer result.deinit();
    // Float output uses full f64 precision
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "6.28"));
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: string literal" {
    var result = try compileAndRun(
        \\def main() do
        \\  Kernel.println("hello world")
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: boolean" {
    var result = try compileAndRun(
        \\def main() do
        \\  Kernel.println(true)
        \\end
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
        \\defmodule Math do
        \\  def add(a :: i64, b :: i64) :: i64 do
        \\    a + b
        \\  end
        \\end
        \\
        \\def main() do
        \\  Kernel.println(Math.add(20, 22))
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: void function" {
    var result = try compileAndRun(
        \\def main() do
        \\end
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
        \\def main() do
        \\  if true do
        \\    Kernel.println("yes")
        \\  else
        \\    Kernel.println("no")
        \\  end
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("yes\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: if-else false branch" {
    var result = try compileAndRun(
        \\def main() do
        \\  if false do
        \\    Kernel.println("yes")
        \\  else
        \\    Kernel.println("no")
        \\  end
        \\end
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
        \\def main() do
        \\  case :ok do
        \\    :ok -> Kernel.println("matched")
        \\    _ -> Kernel.println("default")
        \\  end
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("matched\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: case with ints" {
    var result = try compileAndRun(
        \\def main() do
        \\  case 1 do
        \\    1 -> Kernel.println("one")
        \\    _ -> Kernel.println("other")
        \\  end
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("one\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Multi-function programs (Phase 6.1)
// ============================================================

test "ZIR: recursive factorial" {
    var result = try compileAndRun(
        \\defmodule Math do
        \\  def factorial(n :: i64) :: i64 do
        \\    case n do
        \\      0 -> 1
        \\      1 -> 1
        \\      _ -> n * Math.factorial(n - 1)
        \\    end
        \\  end
        \\end
        \\
        \\def main() do
        \\  Kernel.println(Math.factorial(5))
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("120\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: multiple helper functions" {
    var result = try compileAndRun(
        \\defmodule Helpers do
        \\  def double(x :: i64) :: i64 do
        \\    x * 2
        \\  end
        \\
        \\  def add_one(x :: i64) :: i64 do
        \\    x + 1
        \\  end
        \\end
        \\
        \\def main() do
        \\  Kernel.println(Helpers.add_one(Helpers.double(10)))
        \\end
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("21\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
