const std = @import("std");

/// Wraps std.c.getenv to return a Zig-native slice (?[]const u8).
fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

/// Use the test framework's own IO so spawned subprocesses inherit the
/// parent test runner's environment (PATH, HOME, ZIG_LIB_DIR, etc.). The
/// previous local Threaded was init'd with `.environ = .empty`, which
/// stripped HOME from the spawned `zap` and broke `extractEmbeddedZigLib`.
fn getTestIo() std.Io {
    return std.testing.io;
}

// ============================================================
// ZIR Integration Tests
//
// Each test compiles a Zap source through the full ZIR pipeline
// by invoking the `zap` binary as a subprocess, then runs the
// compiled binary and asserts on stdout.
//
// IMPORTANT: Struct names must match file path. Since all test
// sources are written to `lib/test_prog.zap`, every struct must
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
} || std.posix.ReadError || std.posix.PollError || std.process.SpawnError;

const TestResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,
    /// Path to compiled binary for cleanup.
    /// Stored as a sentinel-terminated slice because `realPathFileAlloc` returns
    /// `[:0]u8` whose backing allocation is `len + 1` bytes; freeing through a
    /// non-sentinel `[]const u8` would under-count and trip the testing allocator.
    output_dir: ?[:0]const u8,

    pub fn deinit(self: *TestResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        if (self.output_dir) |dir| {
            // Clean up compiled output
            std.Io.Dir.cwd().deleteTree(getTestIo(), dir) catch {};
            self.allocator.free(dir);
        }
    }
};

fn compileOnly(source: []const u8) TestError!void {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source =
        \\pub struct TestProg.Builder {
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

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/test_prog.zap", .data = source }) catch return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";

    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    const compile_argv: []const []const u8 = &.{ zap_binary, "build", "test_prog" };
    var compile_child = std.process.spawn(getTestIo(), .{
        .argv = compile_argv,
        .cwd = .{ .path = tmp_dir_path },
        .stderr = .inherit,
        .stdout = .inherit,
    }) catch return error.CompilationFailed;
    const compile_term = compile_child.wait(getTestIo()) catch return error.CompilationFailed;

    const compile_exit = switch (compile_term) {
        .exited => |code| code,
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

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source =
        \\pub struct TestProg.Builder {
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

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/test_prog.zap", .data = source }) catch
        return error.Unexpected;

    // Get the real path to the temp project directory.
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    // Get zap binary path from environment or use default.
    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";

    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    // Compile: zap build test_prog
    // The child process runs with `cwd` set to the temp project so it
    // discovers the test's synthesized build.zap (with `:test_prog` target)
    // instead of the parent's project-root build.zap.
    const compile_argv: []const []const u8 = &.{ zap_binary, "build", "test_prog" };
    var compile_child = std.process.spawn(getTestIo(), .{
        .argv = compile_argv,
        .cwd = .{ .path = tmp_dir_path },
        .stderr = .inherit,
        .stdout = .inherit,
    }) catch return error.CompilationFailed;
    const compile_term = compile_child.wait(getTestIo()) catch return error.CompilationFailed;

    const compile_exit = switch (compile_term) {
        .exited => |code| code,
        else => return error.CompilationFailed,
    };

    if (compile_exit != 0) {
        std.debug.print("\n=== COMPILATION FAILED (exit {d}) ===\n", .{compile_exit});
        return error.CompilationFailed;
    }

    // The zap binary outputs to zap-out/bin/test_prog (relative to cwd)
    const compiled_binary = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/test_prog", allocator) catch {
        std.debug.print("\n=== COMPILED BINARY NOT FOUND ===\n", .{});
        return error.CompilationFailed;
    };
    defer allocator.free(compiled_binary);

    // Run the compiled binary
    const run_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{compiled_binary},
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;

    const run_exit = switch (run_result.term) {
        .exited => |code| code,
        else => {
            allocator.free(run_result.stdout);
            allocator.free(run_result.stderr);
            return error.RunFailed;
        },
    };

    // Build output dir path for cleanup
    const output_dir = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out", allocator) catch null;

    return .{
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .exit_code = run_exit,
        .allocator = allocator,
        .output_dir = output_dir,
    };
}

const ExtraFile = struct {
    path: []const u8,
    data: []const u8,
};

/// Compile and run with additional source files alongside test_prog.zap.
fn compileAndRunWithFiles(source: []const u8, extra_files: []const ExtraFile) TestError!TestResult {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source =
        \\pub struct TestProg.Builder {
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

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/test_prog.zap", .data = source }) catch
        return error.Unexpected;

    for (extra_files) |ef| {
        // Ensure parent directory exists
        if (std.fs.path.dirname(ef.path)) |dir| {
            tmp_dir.dir.createDirPath(getTestIo(), dir) catch {};
        }
        tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = ef.path, .data = ef.data }) catch
            return error.Unexpected;
    }

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";

    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    const compile_argv: []const []const u8 = &.{ zap_binary, "build", "test_prog" };
    var compile_child = std.process.spawn(getTestIo(), .{
        .argv = compile_argv,
        .cwd = .{ .path = tmp_dir_path },
        .stderr = .inherit,
        .stdout = .inherit,
    }) catch return error.CompilationFailed;
    const compile_term = compile_child.wait(getTestIo()) catch return error.CompilationFailed;

    const compile_exit = switch (compile_term) {
        .exited => |code| code,
        else => return error.CompilationFailed,
    };

    if (compile_exit != 0) {
        std.debug.print("\n=== COMPILATION FAILED (exit {d}) ===\n", .{compile_exit});
        return error.CompilationFailed;
    }

    const compiled_binary = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/test_prog", allocator) catch {
        return error.CompilationFailed;
    };
    defer allocator.free(compiled_binary);

    const run_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{compiled_binary},
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;

    const run_exit = switch (run_result.term) {
        .exited => |code| code,
        else => {
            allocator.free(run_result.stdout);
            allocator.free(run_result.stderr);
            return error.RunFailed;
        },
    };

    const output_dir = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out", allocator) catch null;

    return .{
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .exit_code = run_exit,
        .allocator = allocator,
        .output_dir = output_dir,
    };
}

test "CLI: zap test runs Zest cases discovered by project-root relative pattern" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "test") catch return error.Unexpected;

    const build_source =
        \\pub struct TestProject.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test ->
        \\        %Zap.Manifest{
        \\          name: "zap_test",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "TestRunner.main/1",
        \\          paths: ["test/**/*_test.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    const runner_source =
        \\pub struct TestRunner {
        \\  use Zest.Runner, pattern: "test/**/*_test.zap"
        \\}
    ;

    const test_source =
        \\pub struct SampleTest {
        \\  use Zest.Case
        \\
        \\  describe("sample") {
        \\    test("one") {
        \\      assert(true)
        \\    }
        \\
        \\    test("two") {
        \\      reject(false)
        \\    }
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "test/test_runner.zap", .data = runner_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "test/sample_test.zap", .data = test_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";
    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "test", "--seed", "123" },
        .cwd = .{ .path = tmp_dir_path },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => return error.RunFailed,
    };

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2 tests, 0 failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2 assertions, 0 failures") != null);
}

test "CLI: zap run doc-runner target generates documentation via Zap-side pipeline" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    // The doc pipeline lives entirely in Zap source: `Zap.Doc.Builder`'s
    // compile-time `__using__` macro reflects on the supplied paths and
    // bakes manifest functions; the user's `DocsRunner.main/1` body then
    // calls `write_docs_to/4` to render and persist HTML pages. The CLI
    // is just a thin shell that builds the binary and runs it.
    const build_source =
        \\pub struct DocExample.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :doc ->
        \\        %Zap.Manifest{
        \\          name: "doc_example",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "DocExample.DocsRunner.main/1",
        \\          paths: ["lib/**/*.zap"],
        \\          deps: [{:zap_stdlib, {:path, "lib"}}]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    const lib_source =
        \\@doc = "A documented example struct."
        \\pub struct DocExample {
        \\  @doc = "Returns a greeting."
        \\  pub fn greeting() -> String {
        \\    "hello"
        \\  }
        \\}
        \\
        \\@doc = "A documented example protocol."
        \\pub protocol DocProtocol {
        \\  fn convert(value :: String) -> String
        \\}
        \\
        \\@doc = "A documented example union."
        \\pub union DocUnion {
        \\  Empty,
        \\  Value :: String
        \\}
    ;

    const docs_runner_source =
        \\pub struct DocExample.DocsRunner {
        \\  use Zap.Doc.Builder, paths: ["lib/**/*.zap"]
        \\
        \\  pub fn main(_args :: [String]) -> String {
        \\    _count = write_docs_to("docs", "DocExample", "0.1.0", "")
        \\    "Documentation generated in docs/"
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/doc_example.zap", .data = lib_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/docs_runner.zap", .data = docs_runner_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";
    const zap_binary = if (std.fs.path.isAbsolute(zap_binary_raw))
        allocator.dupe(u8, zap_binary_raw) catch return error.OutOfMemory
    else
        std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch return error.Unexpected;
    defer allocator.free(zap_binary);

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "run", "doc" },
        .cwd = .{ .path = tmp_dir_path },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => return error.RunFailed,
    };

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    tmp_dir.dir.access(getTestIo(), "docs/index.html", .{}) catch return error.Unexpected;
    tmp_dir.dir.access(getTestIo(), "docs/structs/DocExample.html", .{}) catch return error.Unexpected;
    tmp_dir.dir.access(getTestIo(), "docs/structs/DocProtocol.html", .{}) catch return error.Unexpected;
    tmp_dir.dir.access(getTestIo(), "docs/structs/DocUnion.html", .{}) catch return error.Unexpected;
    tmp_dir.dir.access(getTestIo(), "docs/search-index.json", .{}) catch return error.Unexpected;

    const generated_html = tmp_dir.dir.readFileAlloc(
        getTestIo(),
        "docs/structs/DocExample.html",
        allocator,
        .limited(256 * 1024),
    ) catch return error.Unexpected;
    defer allocator.free(generated_html);
    try std.testing.expect(std.mem.indexOf(u8, generated_html, "A documented example struct.") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_html, "Returns a greeting.") != null);

    const protocol_html = tmp_dir.dir.readFileAlloc(
        getTestIo(),
        "docs/structs/DocProtocol.html",
        allocator,
        .limited(256 * 1024),
    ) catch return error.Unexpected;
    defer allocator.free(protocol_html);
    try std.testing.expect(std.mem.indexOf(u8, protocol_html, "A documented example protocol.") != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol_html, "Required Functions") != null);
    try std.testing.expect(std.mem.indexOf(u8, protocol_html, "convert") != null);

    const union_html = tmp_dir.dir.readFileAlloc(
        getTestIo(),
        "docs/structs/DocUnion.html",
        allocator,
        .limited(256 * 1024),
    ) catch return error.Unexpected;
    defer allocator.free(union_html);
    try std.testing.expect(std.mem.indexOf(u8, union_html, "A documented example union.") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_html, "Variants") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_html, "Value") != null);

    const search_index = tmp_dir.dir.readFileAlloc(
        getTestIo(),
        "docs/search-index.json",
        allocator,
        .limited(256 * 1024),
    ) catch return error.Unexpected;
    defer allocator.free(search_index);
    try std.testing.expect(std.mem.indexOf(u8, search_index, "\"struct\":\"DocExample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_index, "\"struct\":\"DocProtocol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_index, "\"struct\":\"DocUnion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_index, "\"url\":\"structs/DocExample.html\"") != null);
}

// ============================================================
// Constants and arithmetic
// ============================================================

test "ZIR: integer arithmetic" {
    var result = try compileAndRun(
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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

test "ZIR: struct function ref is first-class callable" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
        \\    f(x)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(apply(21, &TestProg.double/1))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: local function ref is first-class callable" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
        \\    f(x)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(apply(21, &double/1))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: nested local function ref captures environment" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn make_and_apply(base :: i64) -> i64 {
        \\    pub fn add_base(x :: i64) -> i64 {
        \\      base + x
        \\    }
        \\
        \\    apply(10, &add_base/1)
        \\  }
        \\
        \\  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
        \\    f(x)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    Kernel.inspect(make_and_apply(32))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: anonymous closure is first-class callable" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
        \\    f(x)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    add_one = fn(x :: i64) -> i64 {
        \\      x + 1
        \\    }
        \\    Kernel.inspect(apply(41, add_one))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: anonymous closure captures environment" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
        \\    f(x)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    offset = 10
        \\    add_offset = fn(x :: i64) -> i64 {
        \\      x + offset
        \\    }
        \\    Kernel.inspect(apply(32, add_offset))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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

test "ZIR: catch basin receives unmatched value" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn parse("one" :: String) -> String {
        \\    "1"
        \\  }
        \\
        \\  pub fn parse("two" :: String) -> String {
        \\    "2"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    result = "three"
        \\    |> parse()
        \\    ~> {
        \\      val -> "unmatched: " <> val
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("unmatched: three\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: catch basin handler pattern matches on unmatched value" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn process("ok" :: String) -> String {
        \\    "success"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    r1 = "ok"
        \\    |> process()
        \\    ~> {
        \\      "fail" -> "got fail"
        \\      other -> "got: " <> other
        \\    }
        \\    IO.puts(r1)
        \\
        \\    r2 = "fail"
        \\    |> process()
        \\    ~> {
        \\      "fail" -> "got fail"
        \\      other -> "got: " <> other
        \\    }
        \\    IO.puts(r2)
        \\
        \\    r3 = "xyz"
        \\    |> process()
        \\    ~> {
        \\      "fail" -> "got fail"
        \\      other -> "got: " <> other
        \\    }
        \\    IO.puts(r3)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("success\ngot fail\ngot: xyz\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: catch basin short-circuits multi-step pipe" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn validate("good" :: String) -> String {
        \\    "valid"
        \\  }
        \\
        \\  pub fn format(s :: String) -> String {
        \\    "formatted: " <> s
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    good = "good"
        \\    |> validate()
        \\    |> format()
        \\    ~> {
        \\      val -> "rejected: " <> val
        \\    }
        \\    IO.puts(good)
        \\
        \\    bad = "bad"
        \\    |> validate()
        \\    |> format()
        \\    ~> {
        \\      val -> "rejected: " <> val
        \\    }
        \\    IO.puts(bad)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("formatted: valid\nrejected: bad\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Trailing block syntax
// ============================================================

test "ZIR: macro generates function from trailing block" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub macro make_fn(name :: Expr, body :: Expr) -> Expr {
        \\    quote {
        \\      pub fn generated() -> String {
        \\        unquote(body)
        \\        "generated ran"
        \\      }
        \\    }
        \\  }
        \\
        \\  make_fn("my func") {
        \\    IO.puts("inside generated")
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(generated())
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("inside generated\ngenerated ran\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: macro receives trailing block as AST" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub macro my_test(name :: Expr, body :: Expr) -> Expr {
        \\    quote {
        \\      IO.puts(unquote(name))
        \\      unquote(body)
        \\      IO.puts("passed")
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    my_test("check math") {
        \\      Kernel.inspect(1 + 1)
        \\    }
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("check math\n2\npassed\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: trailing block as last argument" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn with_block(name :: String, body :: String) -> String {
        \\    name <> ": " <> body
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    result = with_block("test") {
        \\      "hello"
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("test: hello\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: nested trailing blocks" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn outer(name :: String, body :: String) -> String {
        \\    "[" <> name <> " " <> body <> "]"
        \\  }
        \\
        \\  pub fn inner(name :: String, body :: String) -> String {
        \\    "(" <> name <> " " <> body <> ")"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    result = outer("describe") {
        \\      inner("test") {
        \\        "pass"
        \\      }
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("[describe (test pass)]\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: catch basin ~> with function handler" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn parse("one" :: String) -> String {
        \\    "1"
        \\  }
        \\
        \\  pub fn handle_error(val :: String) -> String {
        \\    "error: " <> val
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    r1 = "one"
        \\    |> parse()
        \\    ~> handle_error()
        \\    IO.puts(r1)
        \\
        \\    r2 = "bad"
        \\    |> parse()
        \\    ~> handle_error()
        \\    IO.puts(r2)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("1\nerror: bad\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: catch basin ~> function handler with extra args" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn parse("ok" :: String) -> String {
        \\    "parsed"
        \\  }
        \\
        \\  pub fn fallback(val :: String, prefix :: String) -> String {
        \\    prefix <> val
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    r = "nope"
        \\    |> parse()
        \\    ~> fallback("unhandled: ")
        \\    IO.puts(r)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("unhandled: nope\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Struct literals
// ============================================================

test "ZIR: struct literal field access" {
    var result = try compileAndRun(
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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

test "ZIR: exact numeric overload beats widening fallback" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn classify(value :: i64) -> String {
        \\    "i64"
        \\  }
        \\
        \\  pub fn classify(value :: i32) -> String {
        \\    "i32"
        \\  }
        \\
        \\  pub fn classify(value :: u32) -> String {
        \\    "u32"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(classify(1 :: i32))
        \\    IO.puts(classify(1 :: u32))
        \\    IO.puts(classify(1))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("i32\nu32\ni64\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: numeric widening is fallback after exact overload search" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn classify(value :: i64) -> String {
        \\    "i64"
        \\  }
        \\
        \\  pub fn classify(value :: u64) -> String {
        \\    "u64"
        \\  }
        \\
        \\  pub fn classify(value :: f64) -> String {
        \\    "f64"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(classify(1 :: i32))
        \\    IO.puts(classify(1 :: u32))
        \\    IO.puts(classify(1.5 :: f32))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("i64\nu64\nf64\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: unsigned integer does not widen to signed integer" {
    try std.testing.expectError(error.CompilationFailed, compileOnly(
        \\pub struct TestProg {
        \\  pub fn classify(value :: i64) -> String {
        \\    "i64"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    classify(1 :: u32)
        \\  }
        \\}
    ));
}

test "ZIR: Integer overloads preserve exact integer width" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn accept(value :: i32) -> String {
        \\    "i32"
        \\  }
        \\
        \\  pub fn accept(value :: u32) -> String {
        \\    "u32"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(accept(Integer.abs(-7 :: i32)))
        \\    IO.puts(accept(Integer.abs(7 :: u32)))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("i32\nu32\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: Float overloads preserve exact float width" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn accept(value :: f32) -> String {
        \\    "f32"
        \\  }
        \\
        \\  pub fn accept(value :: f64) -> String {
        \\    "f64"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(accept(Float.abs(-1.5 :: f32)))
        \\    IO.puts(accept(Float.abs(-2.5)))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("f32\nf64\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: 128-bit integers and extended floats resolve and widen within family" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn classify(value :: i128) -> String {
        \\    "i128"
        \\  }
        \\
        \\  pub fn classify(value :: u128) -> String {
        \\    "u128"
        \\  }
        \\
        \\  pub fn classify(value :: f80) -> String {
        \\    "f80"
        \\  }
        \\
        \\  pub fn classify(value :: f128) -> String {
        \\    "f128"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(classify(1 :: i64))
        \\    IO.puts(classify(1 :: u64))
        \\    IO.puts(classify(1.5 :: f64))
        \\    IO.puts(classify(2.5 :: f128))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("i128\nu128\nf80\nf128\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: Integer supports i128 and u128 helper overloads" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn accept(value :: i128) -> String {
        \\    "i128"
        \\  }
        \\
        \\  pub fn accept(value :: u128) -> String {
        \\    "u128"
        \\  }
        \\
        \\  pub fn accept_string(value :: String) -> String {
        \\    "String"
        \\  }
        \\
        \\  pub fn accept_float(value :: f64) -> String {
        \\    "f64"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(accept((1 :: i128) + (2 :: i128)))
        \\    IO.puts(accept((5 :: i128) - (2 :: i128)))
        \\    IO.puts(accept((2 :: u128) * (3 :: u128)))
        \\    IO.puts(accept(Integer.max(3 :: u128, 2 :: u128)))
        \\    IO.puts(Integer.to_string((9 :: i128) / (2 :: i128)))
        \\    IO.puts(Integer.to_string((9 :: u128) rem (4 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.abs(-7 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.min(3 :: i128, 2 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.clamp(9 :: u128, 2 :: u128, 7 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.pow(2 :: u128, 4 :: u128)))
        \\    IO.puts(accept_string(Integer.to_string(5 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.digits(-12345 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.digits(12345 :: u128)))
        \\    IO.puts(accept_float(Integer.to_float(42 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.count_leading_zeros(1 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.count_trailing_zeros(8 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.popcount(7 :: u128)))
        \\    IO.puts(accept(Integer.byte_swap(1 :: i128)))
        \\    IO.puts(accept(Integer.bit_reverse(1 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.add_sat(1 :: i128, 2 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.sub_sat(0 :: u128, 1 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.mul_sat(2 :: i128, 3 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.band(6 :: u128, 3 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.bor(6 :: i128, 3 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.bxor(6 :: u128, 3 :: u128)))
        \\    IO.puts(accept(Integer.bnot(0 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.bsl(1 :: u128, 3 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.bsl(1 :: u128, 100 :: u128)))
        \\    IO.puts(Integer.to_string(Integer.bsr(8 :: i128, 3 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.sign(-7 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.sign(7 :: u128)))
        \\    IO.puts(Bool.to_string(Integer.even?(8 :: u128)))
        \\    IO.puts(Bool.to_string(Integer.odd?(7 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.gcd(48 :: i128, 18 :: i128)))
        \\    IO.puts(Integer.to_string(Integer.lcm(4 :: u128, 6 :: u128)))
        \\    IO.puts(Bool.to_string((1 :: i128) == (1 :: i128)))
        \\    IO.puts(Bool.to_string((1 :: u128) < (2 :: u128)))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "i128\ni128\nu128\nu128\n4\n1\n7\n2\n7\n16\nString\n5\n5\nf64\n127\n3\n3\ni128\nu128\n3\n0\n6\n2\n7\n5\ni128\n8\n1267650600228229401496703205376\n1\n-1\n1\ntrue\ntrue\n6\n12\ntrue\ntrue\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: Float supports f80 and f128 helper overloads" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn accept(value :: f80) -> String {
        \\    "f80"
        \\  }
        \\
        \\  pub fn accept(value :: f128) -> String {
        \\    "f128"
        \\  }
        \\
        \\  pub fn accept_string(value :: String) -> String {
        \\    "String"
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(accept(Float.abs(-1.5 :: f80)))
        \\    IO.puts(accept(Float.max(1.0 :: f128, 2.0 :: f128)))
        \\    IO.puts(accept(Float.min(3.0 :: f80, 2.0 :: f80)))
        \\    IO.puts(accept(Float.round(1.5 :: f128)))
        \\    IO.puts(accept(Float.floor(1.9 :: f80)))
        \\    IO.puts(accept(Float.ceil(1.1 :: f128)))
        \\    IO.puts(accept((1.5 :: f80) + (2.5 :: f80)))
        \\    IO.puts(accept((5.0 :: f128) - (2.0 :: f128)))
        \\    IO.puts(accept((2.0 :: f80) * (3.0 :: f80)))
        \\    IO.puts(accept((6.0 :: f128) / (2.0 :: f128)))
        \\    IO.puts(accept((5.5 :: f80) rem (2.0 :: f80)))
        \\    IO.puts(accept(Float.clamp(5.0 :: f128, 1.0 :: f128, 3.0 :: f128)))
        \\    IO.puts(accept(Float.truncate(3.75 :: f128)))
        \\    IO.puts(Integer.to_string(Float.to_integer(3.75 :: f80)))
        \\    IO.puts(Integer.to_string(Float.to_integer(Float.floor(3.75 :: f128))))
        \\    IO.puts(Integer.to_string(Float.to_integer(Float.ceil(3.25 :: f80))))
        \\    IO.puts(Integer.to_string(Float.to_integer(Float.round(3.75 :: f128))))
        \\    IO.puts(accept_string(Float.to_string(1.5 :: f80)))
        \\    IO.puts(accept_string(Float.to_string(2.5 :: f128)))
        \\    IO.puts(Bool.to_string((1.0 :: f80) < (2.0 :: f80)))
        \\    IO.puts(Bool.to_string((2.0 :: f128) >= (2.0 :: f128)))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "f80\nf128\nf80\nf128\nf80\nf128\nf80\nf128\nf80\nf128\nf80\nf128\nf128\n3\n3\n4\n4\nString\nString\ntrue\ntrue\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// For comprehensions
// ============================================================

test "ZIR: for comprehension doubles list" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn sum([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn sum([h | t] :: [i64]) -> i64 {
        \\    h + sum(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    doubled = for x <- [1, 2, 3] { x * 2 }
        \\    Kernel.inspect(sum(doubled))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("12\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: for comprehension over string" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn join([] :: [String]) -> String {
        \\    ""
        \\  }
        \\
        \\  pub fn join([h | t] :: [String]) -> String {
        \\    h <> join(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    chars = for c <- "abc" {
        \\      c <> "!"
        \\    }
        \\    IO.puts(join(chars))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("a!b!c!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: for comprehension with filter" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn sum([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn sum([h | t] :: [i64]) -> i64 {
        \\    h + sum(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    evens = for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 { x }
        \\    Kernel.inspect(sum(evens))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("12\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: protocol dispatch rejects unconstrained lowercase receiver type" {
    try std.testing.expectError(error.CompilationFailed, compileOnly(
        \\pub struct TestProg {
        \\  pub fn bad(collection :: enumerable) -> i64 {
        \\    case Enumerable.next(collection) {
        \\      {:done, _, _} -> 0
        \\      {:cont, value, _} -> value
        \\    }
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    "done"
        \\  }
        \\}
    ));
}

test "ZIR: protocol parameter rejects unconstrained lowercase argument type" {
    try std.testing.expectError(error.CompilationFailed, compileOnly(
        \\pub struct TestProg {
        \\  pub fn bad(collection :: enumerable) -> [i64] {
        \\    Enum.to_list(collection)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    "done"
        \\  }
        \\}
    ));
}

test "ZIR: Enum map dispatches through exact Enumerable constraint" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn sum([] :: [i64]) -> i64 {
        \\    0
        \\  }
        \\
        \\  pub fn sum([h | t] :: [i64]) -> i64 {
        \\    h + sum(t)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    doubled = Enum.map(1..3, fn(x :: i64) -> i64 { x * 2 })
        \\    Kernel.inspect(sum(doubled))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("12\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: Enum reduce maps through Enumerable entries" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    total = Enum.reduce(%{a: 10, b: 20, c: 30}, 0, fn(accumulator :: i64, entry :: {Atom, i64}) -> i64 {
        \\      case entry {
        \\        {_key, value} -> accumulator + value
        \\      }
        \\    })
        \\    Kernel.inspect(total)
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("60\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: Enum at uses caller-provided default type" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    IO.puts(Enum.at(["a"], 2, "none"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("none\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Tail calls
// ============================================================

test "ZIR: tail recursive countdown (small)" {
    var result = try compileAndRun(
        \\pub struct TestProg {
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
// use Struct with __using__ callback
// ============================================================

test "ZIR: use Struct imports functions" {
    var result = try compileAndRunWithFiles(
        \\pub struct TestProg {
        \\  use Helper
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(Helper.greet("World"))
        \\    "done"
        \\  }
        \\}
    , &.{
        .{ .path = "lib/helper.zap", .data =
        \\pub struct Helper {
        \\  pub fn greet(name :: String) -> String {
        \\    "Hello, " <> name <> "!"
        \\  }
        \\}
        },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, World!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: use Struct with __using__ callback injects function" {
    var result = try compileAndRunWithFiles(
        \\pub struct TestProg {
        \\  use Greeter
        \\
        \\  pub fn main() -> String {
        \\    IO.puts(hello())
        \\    "done"
        \\  }
        \\}
    , &.{
        .{ .path = "lib/greeter.zap", .data =
        \\pub struct Greeter {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      pub fn hello() -> String {
        \\        "Hello from __using__!"
        \\      }
        \\    }
        \\  }
        \\}
        },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello from __using__!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Map operations
// ============================================================

test "ZIR: map literal creation" {
    var result = try compileAndRun(
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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

test "ZIR: map update syntax" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    m = %{name: "Alice", age: 30}
        \\    m2 = %{m | name: "Bob"}
        \\    IO.puts(Map.get(m2, :name, "unknown"))
        \\    Kernel.inspect(Map.get(m2, :age, 0))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("Bob\n30\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: map has_key check" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    m = %{name: "Alice", age: 30}
        \\    if Map.has_key?(m, :name) {
        \\      IO.puts("has name")
        \\    } else {
        \\      IO.puts("no name")
        \\    }
        \\    if Map.has_key?(m, :email) {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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
        \\pub struct TestProg {
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

test "ZIR: String.length cross-struct call" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    Kernel.inspect(String.length("hello"))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("5\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: String.slice cross-struct call" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    IO.puts(String.slice("hello", 0, 3))
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hel\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: pub fn with operator name parses and emits" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn <>(left :: String, right :: String) -> String {
        \\    :zig.String.concat(left, right)
        \\  }
        \\
        \\  pub fn main() -> String {
        \\    IO.puts("ok")
        \\    "done"
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
