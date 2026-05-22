const std = @import("std");

/// Wraps std.c.getenv to return a Zig-native slice (?[]const u8).
fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

fn resolveZapBinary(allocator: std.mem.Allocator) TestError![:0]u8 {
    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";
    if (std.fs.path.isAbsolute(zap_binary_raw)) {
        return allocator.dupeZ(u8, zap_binary_raw) catch return error.OutOfMemory;
    }
    return std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator) catch
        return error.Unexpected;
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

const COMPILE_OUTPUT_LIMIT = 4 * 1024 * 1024;

const CompileFailureDiagnostics = enum {
    silent,
    report,
};

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

fn printUnexpectedCompileFailure(exit_code: u8, stdout: []const u8, stderr: []const u8) void {
    std.debug.print("\n=== COMPILATION FAILED (exit {d}) ===\n", .{exit_code});
    if (stdout.len != 0) {
        std.debug.print("=== stdout ===\n{s}\n", .{stdout});
    }
    if (stderr.len != 0) {
        std.debug.print("=== stderr ===\n{s}\n", .{stderr});
    }
}

fn printUnexpectedRunFailure(command: []const []const u8, exit_code: u8, stdout: []const u8, stderr: []const u8) void {
    std.debug.print("\n=== RUN FAILED (exit {d}) ===\n", .{exit_code});
    std.debug.print("=== command ===", .{});
    for (command) |arg| {
        std.debug.print(" {s}", .{arg});
    }
    std.debug.print("\n", .{});
    if (stdout.len != 0) {
        std.debug.print("=== stdout ===\n{s}\n", .{stdout});
    }
    if (stderr.len != 0) {
        std.debug.print("=== stderr ===\n{s}\n", .{stderr});
    }
}

fn expectTimingOrderDiffers(first_stdout: []const u8, second_stdout: []const u8, names: []const []const u8) !void {
    var differs = false;

    for (names, 0..) |left_name, left_index| {
        const first_left = std.mem.indexOf(u8, first_stdout, left_name) orelse return error.TestUnexpectedResult;
        const second_left = std.mem.indexOf(u8, second_stdout, left_name) orelse return error.TestUnexpectedResult;

        for (names[left_index + 1 ..]) |right_name| {
            const first_right = std.mem.indexOf(u8, first_stdout, right_name) orelse return error.TestUnexpectedResult;
            const second_right = std.mem.indexOf(u8, second_stdout, right_name) orelse return error.TestUnexpectedResult;

            if ((first_left < first_right) != (second_left < second_right)) {
                differs = true;
            }
        }
    }

    try std.testing.expect(differs);
}

fn runZapBuild(
    allocator: std.mem.Allocator,
    zap_binary: []const u8,
    tmp_dir_path: []const u8,
    collect_arc_stats: bool,
    diagnostics: CompileFailureDiagnostics,
) TestError!void {
    const compile_argv: []const []const u8 = if (collect_arc_stats)
        &.{ zap_binary, "build", "test_prog", "--collect-arc-stats" }
    else
        &.{ zap_binary, "build", "test_prog" };

    const compile_result = std.process.run(allocator, getTestIo(), .{
        .argv = compile_argv,
        .cwd = .{ .path = tmp_dir_path },
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.CompilationFailed;
    defer allocator.free(compile_result.stdout);
    defer allocator.free(compile_result.stderr);

    const compile_exit = switch (compile_result.term) {
        .exited => |code| code,
        else => {
            if (diagnostics == .report) {
                printUnexpectedCompileFailure(255, compile_result.stdout, compile_result.stderr);
            }
            return error.CompilationFailed;
        },
    };

    if (compile_exit != 0) {
        if (diagnostics == .report) {
            printUnexpectedCompileFailure(compile_exit, compile_result.stdout, compile_result.stderr);
        }
        return error.CompilationFailed;
    }
}

fn compileOnlyWithDiagnostics(source: []const u8, diagnostics: CompileFailureDiagnostics) TestError!void {
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
        \\          root: &TestProg.main/0,
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

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    try runZapBuild(allocator, zap_binary, tmp_dir_path, false, diagnostics);
}

fn compileOnly(source: []const u8) TestError!void {
    return compileOnlyWithDiagnostics(source, .report);
}

fn expectCompileFails(source: []const u8) !void {
    try std.testing.expectError(error.CompilationFailed, compileOnlyWithDiagnostics(source, .silent));
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
        \\          root: &TestProg.main/0,
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
    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    // Compile: zap build test_prog
    // The child process runs with `cwd` set to the temp project so it
    // discovers the test's synthesized build.zap (with `:test_prog` target)
    // instead of the parent's project-root build.zap.
    try runZapBuild(allocator, zap_binary, tmp_dir_path, false, .report);

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

const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

const CompileRunEnvOptions = struct {
    collect_arc_stats: bool = false,
};

/// Compile a Zap source string and run the resulting binary with extra
/// environment variables layered on top of the parent's environment.
/// Used by Phase 4 ARC ownership tests that observe `ZAP_ARC_STATS=1`
/// counter dumps emitted on stderr by the runtime atexit hook.
fn compileAndRunWithEnvOptions(
    source: []const u8,
    extra_env: []const EnvEntry,
    options: CompileRunEnvOptions,
) TestError!TestResult {
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
        \\          root: &TestProg.main/0,
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

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    try runZapBuild(allocator, zap_binary, tmp_dir_path, options.collect_arc_stats, .report);

    const compiled_binary = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/test_prog", allocator) catch {
        std.debug.print("\n=== COMPILED BINARY NOT FOUND ===\n", .{});
        return error.CompilationFailed;
    };
    defer allocator.free(compiled_binary);

    // Build a child environment by cloning the parent's and overlaying
    // every extra entry. The clone is necessary because std.process.run
    // accepts `?*const Environ.Map`, and each test owns its own env map
    // so concurrent tests don't race on a shared mutation. The
    // testing harness exposes `std.testing.environ` as the parent's
    // process environment view; `createMap` materialises it into a
    // mutable map that the test owns.
    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    for (extra_env) |entry| {
        env_map.put(entry.name, entry.value) catch return error.OutOfMemory;
    }

    const run_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{compiled_binary},
        .environ_map = &env_map,
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

fn compileAndRunWithArcStatsEnv(source: []const u8, extra_env: []const EnvEntry) TestError!TestResult {
    return compileAndRunWithEnvOptions(source, extra_env, .{ .collect_arc_stats = true });
}

test "ZIR helper: ARC stats env helper opts into compile-time collection" {
    const source = @embedFile("zir_integration_tests.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "--collect-arc-stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "compileAndRunWithArcStatsEnv") != null);
}

test "ZIR helper: compiler subprocess output is captured by the harness" {
    const source = @embedFile("zir_integration_tests.zig");
    const stderr_inherit = ".stderr" ++ " = .inherit";
    const stdout_inherit = ".stdout" ++ " = .inherit";
    try std.testing.expect(std.mem.indexOf(u8, source, stderr_inherit) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stdout_inherit) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "expectCompileFails") != null);
}

/// Parse a single `[zap-arc-stats] ... key=value ...` line emitted by
/// `runtime.dumpArcStats`, returning the integer value associated with
/// `key`. Returns null when the key is not present in `stderr_dump`.
fn parseArcStatCounter(stderr_dump: []const u8, key: []const u8) ?u64 {
    // The dump format is documented in `src/runtime.zig:dumpArcStats`.
    // Each counter line begins with `[zap-arc-stats] ` and lists global
    // counters as space-separated `name=number` pairs.
    var line_iter = std.mem.splitScalar(u8, stderr_dump, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "[zap-arc-stats]") == null) continue;
        var token_iter = std.mem.splitScalar(u8, line, ' ');
        while (token_iter.next()) |token| {
            const eq_idx = std.mem.indexOfScalar(u8, token, '=') orelse continue;
            if (!std.mem.eql(u8, token[0..eq_idx], key)) continue;
            const value_str = token[eq_idx + 1 ..];
            return std.fmt.parseInt(u64, value_str, 10) catch return null;
        }
    }
    return null;
}

const ExtraFile = struct {
    path: []const u8,
    data: []const u8,
};

const ARENA_MANAGER_SOURCE = @embedFile("memory/arena/manager.zig");

/// Compile and run with additional source files alongside test_prog.zap.
fn compileAndRunWithFiles(source: []const u8, extra_files: []const ExtraFile) TestError!TestResult {
    return compileAndRunCustomProject(defaultTestProgBuildSource(), source, extra_files);
}

fn defaultTestProgBuildSource() []const u8 {
    return
    \\pub struct TestProg.Builder {
    \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    \\    case env.target {
    \\      :test_prog ->
    \\        %Zap.Manifest{
    \\          name: "test_prog",
    \\          version: "0.1.0",
    \\          kind: :bin,
    \\          root: &TestProg.main/0,
    \\          paths: ["lib/**/*.zap"]
    \\        }
    \\      _ ->
    \\        panic("Unknown target")
    \\    }
    \\  }
    \\}
    ;
}

fn compileAndRunCustomProject(
    build_source: []const u8,
    source: []const u8,
    extra_files: []const ExtraFile,
) TestError!TestResult {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/test_prog.zap", .data = source }) catch
        return error.Unexpected;

    for (extra_files) |ef| {
        // Ensure parent directory exists
        if (std.fs.path.dirname(ef.path)) |dir| {
            tmp_dir.dir.createDirPath(getTestIo(), dir) catch return error.Unexpected;
        }
        tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = ef.path, .data = ef.data }) catch
            return error.Unexpected;
    }

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    try runZapBuild(allocator, zap_binary, tmp_dir_path, false, .report);

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

test "ZIR memory manager: project-local third-party adapter builds and runs" {
    const build_source =
        \\pub struct TestProg.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test_prog ->
        \\        %Zap.Manifest{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &TestProg.main/0,
        \\          paths: ["lib/**/*.zap"],
        \\          memory: ThirdParty.ProjectArena
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    // Full build+run against the real Zap stdlib: collection validates
    // this impl against `lib/memory/manager.zap`. Phase 3 made
    // `Memory.Manager` a zero-method conformance marker, so the
    // conformant third-party adapter is the empty-impl marker form. The
    // resolver keys off the impl DECL span, so it resolves to this
    // adapter's source path and binds the embedded Zig backend below.
    const adapter_source =
        \\pub struct ThirdParty.ProjectArena {
        \\}
        \\
        \\pub impl Memory.Manager for ThirdParty.ProjectArena {}
    ;

    const source =
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    IO.puts("project fake manager")
        \\    "done"
        \\    0
        \\  }
        \\}
    ;

    var result = try compileAndRunCustomProject(build_source, source, &.{
        .{ .path = "lib/third_party/project_arena.zap", .data = adapter_source },
        .{ .path = "src/third_party/project_arena/manager.zig", .data = ARENA_MANAGER_SOURCE },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("project fake manager\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR memory manager: dependency third-party adapter builds and runs" {
    const build_source =
        \\pub struct TestProg.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test_prog ->
        \\        %Zap.Manifest{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &TestProg.main/0,
        \\          paths: ["lib/**/*.zap"],
        \\          deps: [%Zap.Dep{name: "fake_mem", path: "deps/fake_mem"}],
        \\          memory: ThirdParty.DepArena
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    // Full build+run against the real Zap stdlib: see the project-local
    // adapter test above — Phase 3 made `Memory.Manager` a zero-method
    // conformance marker, so the conformant third-party dependency
    // adapter is the empty-impl marker form.
    const adapter_source =
        \\pub struct ThirdParty.DepArena {
        \\}
        \\
        \\pub impl Memory.Manager for ThirdParty.DepArena {}
    ;

    const source =
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    IO.puts("dep fake manager")
        \\    "done"
        \\    0
        \\  }
        \\}
    ;

    var result = try compileAndRunCustomProject(build_source, source, &.{
        .{ .path = "deps/fake_mem/lib/third_party/dep_arena.zap", .data = adapter_source },
        .{ .path = "deps/fake_mem/src/third_party/dep_arena/manager.zig", .data = ARENA_MANAGER_SOURCE },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("dep fake manager\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
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
        \\          root: &TestRunner.main/1,
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
        \\
        \\    test("three") {
        \\      assert(1 + 1 == 2)
        \\    }
        \\
        \\    test("four") {
        \\      reject(1 + 1 == 3)
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

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    const first = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "test", "--seed", "123", "--timings" },
        .cwd = .{ .path = tmp_dir_path },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(first.stdout);
    defer allocator.free(first.stderr);

    const first_exit_code = switch (first.term) {
        .exited => |code| code,
        else => return error.RunFailed,
    };

    const second = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "test", "--seed", "456", "--timings" },
        .cwd = .{ .path = tmp_dir_path },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(second.stdout);
    defer allocator.free(second.stderr);

    const second_exit_code = switch (second.term) {
        .exited => |code| code,
        else => return error.RunFailed,
    };

    try std.testing.expectEqual(@as(u8, 0), first_exit_code);
    try std.testing.expectEqual(@as(u8, 0), second_exit_code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "4 tests, 0 failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "4 assertions, 0 failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "4 tests, 0 failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "4 assertions, 0 failures") != null);

    const names = [_][]const u8{
        "SampleTest - sample - one",
        "SampleTest - sample - two",
        "SampleTest - sample - three",
        "SampleTest - sample - four",
    };
    try expectTimingOrderDiffers(first.stdout, second.stdout, &names);
}

test "CLI: zap run doc-runner target generates documentation via Zap-side pipeline" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib/doc") catch return error.Unexpected;

    // The doc pipeline lives entirely in Zap source: `Zap.Doc.Builder`'s
    // compile-time `__using__` macro reflects on the supplied paths and
    // bakes manifest functions; the user's `Doc.Runner.main/1` body then
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
        \\          root: &DocExample.Doc.Runner.main/1,
        \\          paths: ["lib/**/*.zap"],
        \\          deps: [%Zap.Dep{name: "zap_stdlib", path: "lib"}]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;

    const lib_source =
        \\@doc = """
        \\A documented example struct.
        \\"""
        \\
        \\pub struct DocExample {
        \\  @doc = """
        \\  Returns a greeting.
        \\  """
        \\
        \\  pub fn greeting() -> String {
        \\    "hello"
        \\  }
        \\}
        \\
        \\@doc = """
        \\A documented example protocol.
        \\"""
        \\
        \\pub protocol DocProtocol {
        \\  fn convert(value :: String) -> String
        \\}
        \\
        \\@doc = """
        \\A documented example union.
        \\"""
        \\
        \\pub union DocUnion {
        \\  Empty,
        \\  Value :: String
        \\}
    ;

    const doc_runner_source =
        \\pub struct DocExample.Doc.Runner {
        \\  use Zap.Doc.Builder, paths: ["lib/**/*.zap"]
        \\
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    _count = write_docs_to("docs", "DocExample", "0.1.0", "")
        \\    "Documentation generated in docs/"
        \\    0
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/doc_example.zap", .data = lib_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/doc/runner.zap", .data = doc_runner_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    const run_argv = &.{ zap_binary, "run", "doc" };
    const result = std.process.run(allocator, getTestIo(), .{
        .argv = run_argv,
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

    if (exit_code != 0) {
        printUnexpectedRunFailure(run_argv, exit_code, result.stdout, result.stderr);
    }
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(20 + 22)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts("hello world")
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.print_str("line1\nline2\n")
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(true)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(add(20, 22))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    if true {
        \\      IO.puts("yes")
        \\    } else {
        \\      IO.puts("no")
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    if false {
        \\      IO.puts("yes")
        \\    } else {
        \\      IO.puts("no")
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    case :ok {
        \\      :ok -> IO.puts("matched")
        \\      _ -> IO.puts("default")
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    case 1 {
        \\      1 -> IO.puts("one")
        \\      _ -> IO.puts("other")
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(sum_to(5))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(add_one(double(10)))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(bar())
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(make_adder(32))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(compute(10))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(compute(100, 1))
        \\    Kernel.inspect(compute(100, 2))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("110\n120\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: struct function ref call resolves statically" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(&TestProg.double/1(21))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: local function ref call resolves statically" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(&double/1(21))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: static Function struct literal call resolves statically" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(%Function{struct: TestProg, name: :double, arity: 1}(21))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: static local function ref call captures environment" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn make_and_apply(base :: i64) -> i64 {
        \\    pub fn add_base(x :: i64) -> i64 {
        \\      base + x
        \\    }
        \\
        \\    &add_base/1(10)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(make_and_apply(32))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    add_one = fn(x :: i64) -> i64 {
        \\      x + 1
        \\    }
        \\    Kernel.inspect(apply(41, add_one))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    offset = 10
        \\    add_offset = fn(x :: i64) -> i64 {
        \\      x + offset
        \\    }
        \\    Kernel.inspect(apply(32, add_offset))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(describe(1))
        \\    IO.puts(describe(2))
        \\    IO.puts(describe(99))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(try_ok())
        \\    IO.puts(try_nope())
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    result = "three"
        \\    |> parse()
        \\    ~> {
        \\      val -> "unmatched: " <> val
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(generated())
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    my_test("check math") {
        \\      Kernel.inspect(1 + 1)
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    result = with_block("test") {
        \\      "hello"
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    result = outer("describe") {
        \\      inner("test") {
        \\        "pass"
        \\      }
        \\    }
        \\    IO.puts(result)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    r = "nope"
        \\    |> parse()
        \\    ~> fallback("unhandled: ")
        \\    IO.puts(r)
        \\    "done"
        \\    0
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

test "ZIR: parametric struct emits distinct per-instantiation types" {
    // End-to-end check that the IR's per-instantiation TypeDef
    // emission flows through ZIR correctly. Two literals
    // `%Box(i64){...}` and `%Box(String){...}` must compile against
    // distinct per-instantiation ZIR struct types (`Box_i64` and
    // `Box_String`); reading `.value` from each must return values
    // of the right concrete shape (i64 prints as a digit, String
    // prints as itself).
    var result = try compileAndRun(
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct TestProg {
        \\  pub fn read_int(b :: Box(i64)) -> i64 {
        \\    b.value
        \\  }
        \\  pub fn read_str(b :: Box(String)) -> String {
        \\    b.value
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(read_int(%Box(i64){value: 42}))
        \\    IO.puts(read_str(%Box(String){value: "ok"}))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\nok\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: parametric struct with two type parameters" {
    // Pair(a, b) instantiated as Pair(i64, String) emits a
    // Pair_i64_String ZIR struct type. Field accesses on each
    // declared field return the substituted-type value, exercising
    // both formal slots through to ZIR.
    var result = try compileAndRun(
        \\pub struct Pair(a, b) {
        \\  left :: a
        \\  right :: b
        \\}
        \\pub struct TestProg {
        \\  pub fn build() -> Pair(i64, String) {
        \\    %Pair(i64, String){left: 7, right: "hi"}
        \\  }
        \\  pub fn main() -> u8 {
        \\    p = build()
        \\    Kernel.inspect(p.left)
        \\    IO.puts(p.right)
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("7\nhi\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: parametric struct supports inferred return-type instantiation" {
    // `make()` is declared to return `Box(i64)`. The body's
    // `%Box{value: 42}` literal omits the explicit type-arg list and
    // relies on the HIR's context-driven inference (1.1.5.c) to
    // resolve to `Box(i64)`. The IR/ZIR layer must accept that the
    // inferred instantiation produces a distinct per-instantiation
    // type from a separately-written `Box(String)` instantiation.
    var result = try compileAndRun(
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct TestProg {
        \\  pub fn make_int() -> Box(i64) {
        \\    %Box{value: 99}
        \\  }
        \\  pub fn make_str() -> Box(String) {
        \\    %Box{value: "yep"}
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(make_int().value)
        \\    IO.puts(make_str().value)
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("99\nyep\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance B): parametric struct with concrete default" {
    // `Counter(T) { value :: T, step :: i64 = 1 }` — only the
    // non-parametric field carries a default. The instantiation
    // `%Counter(i64){value: 0}` must take both:
    //   value <- 0 (explicit)
    //   step <- 1 (concrete default)
    // and the per-instantiation TypeDef must include the substituted
    // i64 `value` field alongside the concrete-defaulted `step`.
    var result = try compileAndRun(
        \\pub struct Counter(t) {
        \\  value :: t
        \\  step :: i64 = 1
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    c = %Counter(i64){value: 0}
        \\    Kernel.inspect(c.value)
        \\    Kernel.inspect(c.step)
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("0\n1\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Option stdlib): Option(i64).Some construction round-trips" {
    // Smoke-test the stdlib Option(T) declaration end-to-end:
    // `Option(i64).Some(42)` constructs the per-instantiation tagged
    // union and assigns it to a binding without crashing. Payload
    // extraction lives in Phase 1.3 (case-arm tagged-union pattern
    // destructuring); the construction half lands here and proves the
    // stdlib type wires through to ZIR.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _ = Option(i64).Some(42)
        \\    _ = Option(i64).None
        \\    _ = Option(String).Some("hello")
        \\    IO.puts("constructed")
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("constructed\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance E): nested parametric struct round-trip" {
    // `Box(Option(i64))` is the canonical nested-generic shape the
    // brief calls out. The inner `Option(i64).Some(7)` returns the
    // `.applied { base = Option, args = [i64] }` form which the
    // outer `%Box(Option(i64)){value: ...}` consumes as `T -> Option(i64)`.
    // Reading `outer.value` gives back the nested Option(i64), and
    // its `Some` payload (extracted via a separate `case` pattern
    // when destructuring lands; today exercised through field
    // access on the per-instantiation type).
    //
    // To keep the test runnable without tagged-union pattern
    // destructuring (deferred to Phase 1.3), we exercise the
    // round-trip by storing and reading back the nested Box, plus
    // by asserting that Box_Option_i64 emits as a per-instantiation
    // TypeDef. The actual payload extraction lives in the IR test
    // `IR per-instantiation TypeDef substitutes nested field types`.
    var result = try compileAndRun(
        \\pub struct Inner(t) {
        \\  value :: t
        \\}
        \\pub struct Outer(t) {
        \\  wrapped :: Inner(t)
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    inner = %Inner(i64){value: 7}
        \\    outer = %Outer(i64){wrapped: inner}
        \\    Kernel.inspect(outer.wrapped.value)
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("7\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Option stdlib helpers): is_some?, is_none?, unwrap_or end-to-end" {
    // Exercises the predicate + unwrap helpers shipped directly under
    // `Option` in `lib/option.zap`. Round 2's blocker B merged the
    // co-named `pub union Option(t)` and `pub struct Option` into a
    // single resolution entry: the union owns the type identity (its
    // variants are the runtime values) and the struct contributes
    // associated functions reachable as `Option.is_some?`,
    // `Option.unwrap_or`, etc. The merge is structural (no special
    // case in the type registry) — it works because the cross-
    // interner remap fix in `remapExpr` for `.struct_ref` and the
    // `remap*Decl` type-param remap routes both the variant
    // constructors and the function declarations through the same
    // global StringIds.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    some = Option(i64).Some(42)
        \\    none = Option(i64).None
        \\    Kernel.inspect(Option.is_some?(some))
        \\    Kernel.inspect(Option.is_none?(none))
        \\    Kernel.inspect(Option.unwrap_or(some, 0))
        \\    Kernel.inspect(Option.unwrap_or(none, 7))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("true\ntrue\n42\n7\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance D): case destructuring on Option(i64) extracts payload" {
    // Acceptance test D — destructuring half. The construction half
    // is pinned by `parametric tagged-union variant construction
    // infers applied receiver type`; this exercises end-to-end:
    //   case Option(i64).Some(42) {
    //     Option.Some(v) -> v
    //     Option.None -> 0
    //   } ⇒ 42
    // Confirms parser routes `Option.Some(v)` to a
    // `tagged_union_variant` pattern, type-check binds `v :: i64`,
    // the match-matrix compiler emits a `switch_variant` decision,
    // and the IR + ZIR emit `activeTag` + `.Some` payload extraction
    // against the per-instantiation tagged-union layout produced by
    // 1.1.5.d.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn unwrap_some() -> i64 {
        \\    opt = Option(i64).Some(42)
        \\    case opt {
        \\      Option.Some(v) -> v
        \\      Option.None -> 0
        \\    }
        \\  }
        \\  pub fn unwrap_none() -> i64 {
        \\    opt = Option(i64).None
        \\    case opt {
        \\      Option.Some(v) -> v
        \\      Option.None -> 0
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(unwrap_some())
        \\    Kernel.inspect(unwrap_none())
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance F): case destructuring on Result(T, E) extracts payload" {
    // Acceptance test F — destructuring half. Result(T, E) is
    // declared locally in the test fixture (the stdlib `Result(T, E)`
    // lands in Phase 1.3). Confirms the parametric tagged-union
    // case-arm destructuring works with multiple type parameters and
    // distinct payload types per variant.
    var result = try compileAndRun(
        \\pub union Result(T, E) {
        \\  Ok :: T
        \\  Err :: E
        \\}
        \\pub struct TestProg {
        \\  pub fn unwrap_ok() -> i64 {
        \\    r = Result(i64, String).Ok(42)
        \\    case r {
        \\      Result.Ok(v) -> v
        \\      Result.Err(_) -> 0
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(unwrap_ok())
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (comptime-fold fix): comptime-known dual-payload Result match extracts active arm" {
    // Phase 1 gap loop #17 item 1 — the comptime-fold UB acceptance case.
    // BOTH arms bind a payload (`Ok(v)` and `Error(e)`), and the
    // scrutinee is comptime-known (`Result(i64, i64).Ok(42)` assigned to
    // a local, not threaded through a runtime parameter). Before the
    // generalized switch_block lowering this tripped Zig Sema's
    // "access of union field Error while Ok is active" UB because the
    // old match_variant_tag + guard_block + variant_payload_get chain
    // emitted `scrutinee.Error` on the inactive prong, which Sema
    // comptime-evaluates against the constant Ok value. Routing through
    // the switch_block-with-capture path makes Sema analyze ONLY the
    // active prong, so the inactive payload field is never reached.
    var result = try compileAndRun(
        \\pub union Pair(t, e) {
        \\  Ok :: t
        \\  Error :: e
        \\}
        \\pub struct TestProg {
        \\  pub fn from_ok() -> i64 {
        \\    r = Pair(i64, i64).Ok(42)
        \\    case r {
        \\      Pair.Ok(v) -> v
        \\      Pair.Error(e) -> e
        \\    }
        \\  }
        \\  pub fn from_error() -> i64 {
        \\    r = Pair(i64, i64).Error(7)
        \\    case r {
        \\      Pair.Ok(v) -> v
        \\      Pair.Error(e) -> e
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(from_ok())
        \\    Kernel.inspect(from_error())
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n7\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (comptime-fold fix): comptime-known Option None nullary arm with sibling payload arm" {
    // The acceptance case from the brief: a comptime-known scrutinee
    // bound to a local where one arm is nullary (`Option.None -> 0`) and
    // the sibling binds a payload (`Option.Some(v) -> v`). The brief's
    // exact minimal repro is `Option(i64).None` matched against a
    // two-arm case producing `0`. Confirms the generalized switch_block
    // path handles mixed nullary + payload prongs with a comptime-known
    // discriminant (no runtime-parameter workaround).
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn unwrap_none() -> i64 {
        \\    opt = Option(i64).None
        \\    case opt {
        \\      Option.Some(v) -> v
        \\      Option.None -> 0
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(unwrap_none())
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (comptime-fold fix): comptime-known three-payload-arm match with catch-all" {
    // Stress the generalized switch beyond two arms: three payload-
    // bearing variants plus a `_` catch-all (lowered to the switch's
    // `else` prong). Confirms N-arm fan-out, distinct payload types per
    // variant, and the catch-all all route through one switch_block.
    var result = try compileAndRun(
        \\pub union Tri(a, b, c) {
        \\  First :: a
        \\  Second :: b
        \\  Third :: c
        \\}
        \\pub struct TestProg {
        \\  pub fn classify() -> i64 {
        \\    t = Tri(i64, i64, i64).Second(99)
        \\    case t {
        \\      Tri.First(x) -> x
        \\      Tri.Second(y) -> y
        \\      Tri.Third(z) -> z
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(classify())
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("99\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Result stdlib): Result(T, E) construction round-trips both variants" {
    // Smoke-test the stdlib `Result(t, e)` declaration (lib/result.zap)
    // end-to-end: `Result(i64, String).Ok(42)` and
    // `Result(i64, String).Error("boom")` each construct the
    // per-instantiation tagged union and assign without crashing. The
    // `Error` variant name exercises the Phase 1.3 contextual-keyword
    // change (`error` is no longer a hard keyword, so `Result.Error`
    // parses as an ordinary variant qualifier).
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _ = Result(i64, String).Ok(42)
        \\    _ = Result(i64, String).Error("boom")
        \\    IO.puts("constructed")
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("constructed\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Result stdlib helpers): is_ok?, is_error?, unwrap_or end-to-end" {
    // Exercises the predicate + unwrap helpers shipped under `Result`
    // in lib/result.zap. As with the Option helpers, the scrutinee is
    // threaded through each helper's function parameter, which forces a
    // runtime discriminant so the match does not hit the pre-existing
    // comptime-fold limitation on constant-discriminant scrutinees.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    ok = Result(i64, String).Ok(42)
        \\    err = Result(i64, String).Error("boom")
        \\    Kernel.inspect(Result.is_ok?(ok))
        \\    Kernel.inspect(Result.is_error?(err))
        \\    Kernel.inspect(Result.unwrap_or(ok, 0))
        \\    Kernel.inspect(Result.unwrap_or(err, 7))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("true\ntrue\n42\n7\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Result stdlib): map/map_error transform the matching variant" {
    // `Result.map/2` transforms the Ok payload and passes Error
    // through; `Result.map_error/2` does the inverse. Both route the
    // scrutinee through their function parameter (runtime discriminant)
    // and read the result back via param-boundary helpers so neither
    // hits the comptime-fold limitation.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn ok_value(r :: Result(i64, String)) -> i64 {
        \\    case r {
        \\      Result.Ok(v) -> v
        \\      Result.Error(_) -> 0
        \\    }
        \\  }
        \\  pub fn err_reason(r :: Result(i64, String)) -> String {
        \\    case r {
        \\      Result.Ok(_) -> "no"
        \\      Result.Error(e) -> e
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    ok = Result(i64, String).Ok(21)
        \\    err = Result(i64, String).Error("boom")
        \\    Kernel.inspect(ok_value(Result.map(ok, fn(v :: i64) -> i64 { v * 2 })))
        \\    Kernel.inspect(err_reason(Result.map(err, fn(v :: i64) -> i64 { v * 2 })))
        \\    Kernel.inspect(ok_value(Result.map_error(ok, fn(e :: String) -> String { e <> "!" })))
        \\    Kernel.inspect(err_reason(Result.map_error(err, fn(e :: String) -> String { e <> "!" })))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\nboom\n21\nboom!\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// NOTE: `Result.and_then/2` is fully implemented in lib/result.zap and is
// structurally identical to the working `Option.and_then/2`. An end-to-end
// integration test is intentionally deferred: exercising it requires passing
// a continuation (closure or `&fn/1`) to a parameter whose declared type is
// the *generic* callable `(value -> Result(mapped, err))`. Passing a
// function reference or a `Result`-returning closure through a type-var
// callable parameter currently fails callable-signature matching — a
// pre-existing higher-order-generic inference gap (orthogonal to Phase 1.3,
// surfaced to the Phase 1 gap loop). `Result.map/2` and `Result.map_error/2`
// are covered above because their continuations have *concrete* return types
// (`i64`, `String`), which the inliner resolves without the generic-callable
// path.

test "ZIR (Phase 1.1.5.f Blocker A): union_init across multiple call sites stays per-instantiation typed" {
    // Round 1's HIR threads `.applied { base = Option, args = [i64] }`
    // onto the `union_init` literal type. Round 2 makes the ZIR side
    // honor that by emitting `@unionInit(Option_i64, ...)` regardless
    // of whether the enclosing function's return type is the union.
    // This test calls `Option(i64).Some(42)` from non-return positions
    // and threads the result through a function-parameter boundary to
    // a destructuring `case`. The parameter forces the discriminant to
    // runtime so Zig's comptime-fold of constant-discriminant matches
    // doesn't evaluate both arms against the same constant (a
    // pre-existing orthogonal pattern-match limitation; see the
    // round-2 report for the follow-up).
    //
    // Construction sites covered:
    //   1. call argument (`unwrap(Option(i64).Some(42))`),
    //   2. call argument with the nullary variant (`unwrap(Option(i64).None)`),
    //   3. multi-step pipeline through `from_some/from_none` helpers
    //      that re-emit `union_init` and route through a parameter.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn unwrap(opt :: Option(i64)) -> i64 {
        \\    case opt {
        \\      Option.Some(v) -> v
        \\      Option.None -> 0
        \\    }
        \\  }
        \\  pub fn from_some() -> Option(i64) {
        \\    Option(i64).Some(7)
        \\  }
        \\  pub fn from_none() -> Option(i64) {
        \\    Option(i64).None
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(unwrap(Option(i64).Some(42)))
        \\    Kernel.inspect(unwrap(Option(i64).None))
        \\    Kernel.inspect(unwrap(from_some()))
        \\    Kernel.inspect(unwrap(from_none()))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n0\n7\n0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Phase 1.1.5.f Blocker A): multi-arg parametric Result(T,E) destructures via runtime scrutinee" {
    // Acceptance F (Result(T, E)) with multiple type params. Confirms
    // the consistent threading rule extends to multi-arg parametric
    // unions and that the per-instantiation mangled name
    // (`Result_i64_String`) flows through to `@unionInit` for both
    // payload variants (Ok :: i64, Err :: String). Same runtime-
    // scrutinee shape as the single-arg case to keep the construction-
    // side fix isolated from the comptime-fold pattern-match issue.
    var result = try compileAndRun(
        \\pub union Result(t, e) {
        \\  Ok :: t
        \\  Err :: e
        \\}
        \\pub struct TestProg {
        \\  pub fn unwrap_ok(r :: Result(i64, String)) -> i64 {
        \\    case r {
        \\      Result.Ok(v) -> v
        \\      Result.Err(_) -> -1
        \\    }
        \\  }
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(unwrap_ok(Result(i64, String).Ok(42)))
        \\    Kernel.inspect(unwrap_ok(Result(i64, String).Err("bad")))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n-1\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Phase 1.2 `pub error` declaration form (acceptance suite A, B, D, F).
//
// Tests A/B/D/F exercise the desugar end-to-end: every `pub error` /
// `error` is rewritten to a `pub struct + pub impl Error` pair before
// HIR, and protocol dispatch through `Error.message/1` and
// `Error.kind/1` returns the expected values.
//
// Tests C (`@code Zxxxx` round-trip) and E (cause chain end-to-end)
// are pinned at the desugar layer (see desugar unit tests in
// `src/desugar.zig`) and via the script fixture
// `script_fixtures/phase_1_2_5_e_cause_chain.zap`. Their runtime
// `compileAndRun` acceptance is gated by:
//
//   - Test C: the `Option(Atom)` return-type Sema layout fix
//     (Phase 1 gap loop).
//   - Test E: the Phase 1.2.5.a-d protocol-box construction pipeline
//     LLVM-emission gap surfaced by Phase 1.2.5.e (cause auto-
//     injection makes every `pub error` reachable through
//     protocol-box construction). Documented in the Phase 1.2.5.e
//     final report.
// ============================================================

test "ZIR (acceptance A — pub error): minimal pub error TimeoutError" {
    // The brief's minimal acceptance case. `%TimeoutError{}` constructs
    // the desugared struct with no user fields; the auto-generated impl
    // methods give:
    //   Error.message(e) == "TimeoutError"    (bare type name default)
    //   Error.kind(e)    == :timeout_error    (snake_cased type name)
    var result = try compileAndRun(
        \\pub error TimeoutError {}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    e = %TimeoutError{}
        \\    IO.puts(Error.message(e))
        \\    IO.puts(Atom.to_string(Error.kind(e)))
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("TimeoutError\ntimeout_error\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance B — pub error): user-declared `message :: String = ...` default" {
    // The user-declared `message` field wins over the auto-injection.
    // `Error.message(e)` reads the user's default and `Error.kind(e)`
    // still derives from the type name.
    var result = try compileAndRun(
        \\pub error NotConnected {
        \\  message :: String = "no active connection"
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    e = %NotConnected{}
        \\    IO.puts(Error.message(e))
        \\    IO.puts(Atom.to_string(Error.kind(e)))
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("no active connection\nnot_connected\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (acceptance D — pub error): inline `pub fn message/1` overrides the protocol method" {
    // The brief's most subtle case. The user defines `pub fn
    // message(self :: KeyError) -> String` *inside* the `pub error`
    // body. The desugar matches the name+arity to the `Error` protocol
    // method and routes the user's body into the impl's `message/1`,
    // dropping what would otherwise have been the auto-generated
    // `self.message` field read. `Error.kind(e)` still resolves
    // through the auto-generated body.
    var result = try compileAndRun(
        \\pub error KeyError {
        \\  key :: Atom
        \\  pub fn message(self :: KeyError) -> String {
        \\    "key " <> Atom.to_string(self.key) <> " not found"
        \\  }
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    e = %KeyError{key: :missing}
        \\    IO.puts(Error.message(e))
        \\    IO.puts(Atom.to_string(Error.kind(e)))
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("key missing not found\nkey_error\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Phase 1.2.5.c): Option(Error) field accepts a None value" {
    // Lightweight first half of the construction-site auto-boxing
    // acceptance: a struct field typed as `Option(Error)` accepts
    // `Option.None` directly. No protocol box is constructed (None
    // is the absent case) — this pins the structural Option(Error)
    // lowering through the `ZigType.protocol_box` shape from Phase
    // 1.2.5.b.
    var result = try compileAndRun(
        \\pub error MyError {}
        \\pub struct Holder {
        \\  cause :: Option(Error) = Option.None
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    h = %Holder{}
        \\    IO.puts("ok")
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR (Phase 1.2.5.c): Option(Error) field accepts a Some(%MyError{}) box" {
    // The construction-site auto-boxing acceptance. A `cause ::
    // Option(Error)` field receives `Option.Some(%MyError{})`; the
    // value flows through HIR/IR as a concrete `MyError` and the
    // IR-level construction-site detector emits a `box_as_protocol`
    // coercion before the `union_init`. The lowered program
    // allocates the inner via `ArcRuntime.allocAny`, populates the
    // box with the impl's vtable pointer, and stores it in the
    // field. The test only verifies the program runs without a
    // panic — consumption-site dispatch through the box (calling
    // `Error.message(cause)`) is Phase 1.2.5.d's contract.
    var result = try compileAndRun(
        \\pub error MyError {
        \\  message :: String = "something failed"
        \\}
        \\pub struct Holder {
        \\  cause :: Option(Error) = Option.None
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    inner = %MyError{}
        \\    h = %Holder{cause: Option.Some(inner)}
        \\    IO.puts("boxed")
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("boxed\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// Acceptance Test E (cause chain end-to-end via Error.source) is
// pinned by the script fixture `script_fixtures/phase_1_2_5_e_cause_chain.zap`
// and by the desugar-level unit tests in `src/desugar.zig`
// (`desugar auto-injects cause :: Option(Error) ...`, `... source/1
// default body reads self.cause`). Phase 1.2.5.e closes the desugar
// surface (cause is now auto-injected and `source/1` reads
// `self.cause`).
//
// The runtime end-to-end through this harness is currently blocked by
// a pre-existing LLVM emission gap in Phase 1.2.5.a-d's
// protocol-box construction pipeline: constructing any `pub error`
// (now that it carries an Option(Error) cause field) reaches an
// `attempt to use null value` in `getConstantIndex` during bitcode
// emit, surfaced via `zap run` / `zap build` of a fixture that
// constructs a `%MyError{}`. The desugar layer is verified; the LLVM
// emission gap is documented in the final 1.2.5.e report and is the
// blocker for adding the cause-chain compileAndRun acceptance here
// alongside A/B/D/F.

test "ZIR (acceptance F — pub error): bare `error InternalIce` constructs and dispatches inside its file" {
    // Bare `error X { ... }` desugars to non-`pub` `struct X +
    // impl Error for X`. Inside the declaring file the type still
    // works through the `Error` protocol (same impl walk). Phase 1.2
    // doesn't yet enforce the matchability boundary — that lands
    // alongside Phase 1.5's diagnostic surface — but the visibility
    // flag is the single source of truth on both generated decls,
    // ready for that follow-up.
    var result = try compileAndRun(
        \\error InternalIce {
        \\  message :: String = "internal"
        \\}
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    e = %InternalIce{}
        \\    IO.puts(Error.message(e))
        \\    IO.puts(Atom.to_string(Error.kind(e)))
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("internal\ninternal_ice\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(get_x(%Point{x: 10, y: 20}))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(greet("world"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    n = 42
        \\    IO.puts("The answer is #{n}")
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    a = "foo"
        \\    b = "bar"
        \\    IO.puts("#{a} and #{b}")
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(first_byte("AB"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(skip_first("Hello"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    5
        \\    |> double()
        \\    |> add_one()
        \\    |> Integer.to_string()
        \\    |> IO.puts()
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    factorial(10)
        \\    |> Integer.to_string()
        \\    |> IO.puts()
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts("hello" <> " " <> "world")
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(classify(5))
        \\    IO.puts(classify(-3))
        \\    IO.puts(classify(0))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(parse("one"))
        \\    IO.puts(parse("two"))
        \\    IO.puts(parse("three"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(status(:ok))
        \\    IO.puts(status(:error))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(add(5))
        \\    Kernel.inspect(add(5, 20))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(join("hello", " ", "world"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(color_name(Color.Red))
        \\    IO.puts(color_name(Color.Green))
        \\    IO.puts(color_name(Color.Blue))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(sum_pair({10, 32}))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(second({10, 42}))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: tuple destructure param preserves element types for downstream dispatch" {
    // Regression: a tuple-destructured parameter (`{m, k} :: {%{...}, String}`)
    // must propagate each element's type into `known_local_types` so that
    // downstream container dispatch (here `:zig.Map.get`) instantiates the
    // correct `Map(K, V)` runtime variant. Without the propagation the
    // dispatcher defaults to `Map(u32, ...)` and the ZIR backend rejects the
    // call as a pointer-type mismatch.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn make_map() -> %{String => i64} {
        \\    Map.put(%{"" => 0 :: i64}, "answer", 42 :: i64)
        \\  }
        \\
        \\  pub fn lookup({m, k} :: {%{String => i64}, String}) -> i64 {
        \\    Map.get(m, k, 0 :: i64)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    m = make_map()
        \\    Kernel.inspect(lookup({m, "answer"}))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: tuple destructure param preserves String type for protocol dispatch" {
    // Regression for `tuple_protocol_dispatch.zap`: when a function destructures
    // a `{String, i64}` parameter, the String binding must reach the protocol
    // dispatcher (`<>` → `Concatenable.concat`) with its concrete element type
    // intact. Without `known_local_types` propagation in `emitTupleBindings`
    // the IR-level Concatenable dispatch loses the type and downstream codegen
    // breaks.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn greet({name, _} :: {String, i64}) -> String {
        \\    name <> " world"
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(greet({"hello", 1 :: i64}))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================
// Variable assignment and reuse
// ============================================================

test "ZIR: variable assignment chain" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    a = 10
        \\    b = a + 20
        \\    c = b * 2
        \\    Kernel.inspect(c)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(classify(0, 0))
        \\    IO.puts(classify(0, 5))
        \\    IO.puts(classify(3, 0))
        \\    IO.puts(classify(3, 5))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(area(1.0))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(classify(1 :: i32))
        \\    IO.puts(classify(1 :: u32))
        \\    IO.puts(classify(1))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(classify(1 :: i32))
        \\    IO.puts(classify(1 :: u32))
        \\    IO.puts(classify(1.5 :: f32))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("i64\nu64\nf64\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: unsigned integer does not widen to signed integer" {
    try expectCompileFails(
        \\pub struct TestProg {
        \\  pub fn classify(value :: i64) -> String {
        \\    "i64"
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    classify(1 :: u32)
        \\    0
        \\  }
        \\}
    );
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(accept(Integer.abs(-7 :: i32)))
        \\    IO.puts(accept(Integer.abs(7 :: u32)))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(accept(Float.abs(-1.5 :: f32)))
        \\    IO.puts(accept(Float.abs(-2.5)))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(classify(1 :: i64))
        \\    IO.puts(classify(1 :: u64))
        \\    IO.puts(classify(1.5 :: f64))
        \\    IO.puts(classify(2.5 :: f128))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    doubled = for x <- [1, 2, 3] { x * 2 }
        \\    Kernel.inspect(sum(doubled))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    chars = for c <- "abc" {
        \\      c <> "!"
        \\    }
        \\    IO.puts(join(chars))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    evens = for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 { x }
        \\    Kernel.inspect(sum(evens))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("12\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR: protocol dispatch rejects unconstrained lowercase receiver type" {
    try expectCompileFails(
        \\pub struct TestProg {
        \\  pub fn bad(collection :: enumerable) -> i64 {
        \\    case Enumerable.next(collection) {
        \\      {:done, _, _} -> 0
        \\      {:cont, value, _} -> value
        \\    }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    "done"
        \\    0
        \\  }
        \\}
    );
}

test "ZIR: protocol parameter rejects unconstrained lowercase argument type" {
    try expectCompileFails(
        \\pub struct TestProg {
        \\  pub fn bad(collection :: enumerable) -> [i64] {
        \\    Enum.to_list(collection)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    "done"
        \\    0
        \\  }
        \\}
    );
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
        \\  pub fn main() -> u8 {
        \\    doubled = Enum.map(1..3, fn(x :: i64) -> i64 { x * 2 })
        \\    Kernel.inspect(sum(doubled))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    total = Enum.reduce(%{a: 10, b: 20, c: 30}, 0, fn(accumulator :: i64, entry :: {Atom, i64}) -> i64 {
        \\      case entry {
        \\        {_key, value} -> accumulator + value
        \\      }
        \\    })
        \\    Kernel.inspect(total)
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(Enum.at(["a"], 2, "none"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(countdown(10))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(Helper.greet("World"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(hello())
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    m = %{name: "Alice", age: 30}
        \\    IO.puts(Map.get(m, :name, "unknown"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    m = %{x: 10, y: 20}
        \\    Kernel.inspect(Map.get(m, :x, 0))
        \\    Kernel.inspect(Map.get(m, :z, 99))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    m = %{name: "Alice", age: 30}
        \\    m2 = %{m | name: "Bob"}
        \\    IO.puts(Map.get(m2, :name, "unknown"))
        \\    Kernel.inspect(Map.get(m2, :age, 0))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
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
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(greet(%{name: "World", greeting: "Hello"}))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    m = %{a: 1, b: 2, c: 3}
        \\    Kernel.inspect(Map.size(m))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(sum_list([10, 20, 12]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(head([42, 10, 20]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(sum([10, 20, 12]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(len([1, 2, 3, 4, 5]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(sum(double_all([1, 2, 3])))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(get_name([name: "Brian"]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(get_age([name: "Brian", age: 42]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    opts = [greeting: "Hello", name: "World"]
        \\    case opts {
        \\      [greeting: g, name: n] -> IO.puts(g <> ", " <> n <> "!")
        \\      _ -> IO.puts("no match")
        \\    }
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(first(["hello", "world"]))
        \\    IO.puts(first([]))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(countdown(100_000_000))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(String.length("hello"))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts(String.slice("hello", 0, 3))
        \\    "done"
        \\    0
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
        \\  pub fn main() -> u8 {
        \\    IO.puts("ok")
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// Phase-1 microbench for the k-nucleotide RSS roadmap. Mirrors
// `src/test_reductions/persistent_map_tail_loop.zap`: a tail-recursive
// `Map.put` accumulator threaded over a small but non-trivial bound.
// The microbench's job is to make the persistent-Map RSS leak observable
// at fast iteration speed; later phases tighten counter / RSS assertions
// once the ARC ownership pass populates the consume / return-elision
// hooks. For now the test only asserts the program runs to completion
// and emits the expected lookup result, which proves the runtime
// substrate handles the workload end-to-end.
test "ZIR: persistent-map tail loop microbench (Phase 1 RSS reproducer)" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
        \\    if i >= n {
        \\      m
        \\    } else {
        \\      next = Map.put(m, i, i)
        \\      TestProg.loop(next, i + (1 :: i64), n)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    seed = %{-1 :: i64 => 0 :: i64}
        \\    cleared = Map.delete(seed, -1 :: i64)
        \\    result = TestProg.loop(cleared, 0 :: i64, 1000 :: i64)
        \\    Kernel.inspect(Map.get(result, 500 :: i64, -1 :: i64))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("500\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ----------------------------------------------------------------
// Phase 4: ARC ownership pass wired to share_value mode write-back.
// ----------------------------------------------------------------

// Phase 4 baseline: the Phase 1 persistent-Map microbench must still
// produce the same lookup result and exit code after the ARC ownership
// write-back wire-up. `.map` is not yet flagged as ARC-managed (Phase 6
// flips the flag), so the analysis records no ARC locals on this
// program and the ZIR backend emits identical instructions to before
// Phase 4. The byte-exact regression test catches accidental write-back
// reaching Map locals before Phase 6 is intentionally enabled.
test "ZIR: Phase 4 Map microbench regression baseline" {
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
        \\    if i >= n {
        \\      m
        \\    } else {
        \\      next = Map.put(m, i, i)
        \\      TestProg.loop(next, i + (1 :: i64), n)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    seed = %{-1 :: i64 => 0 :: i64}
        \\    cleared = Map.delete(seed, -1 :: i64)
        \\    result = TestProg.loop(cleared, 0 :: i64, 1000 :: i64)
        \\    Kernel.inspect(Map.get(result, 500 :: i64, -1 :: i64))
        \\    "done"
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("500\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// Phase 4 byte-exact regression: a Map-based tail-recursive workload
// must produce the same output after ownership rewriting. Pairs the
// counter dump with `ZAP_ARC_STATS=1` so a future regression that
// silently inflates retain/release traffic or loses dense-Map
// uniqueness coverage is observable through stderr.
test "ZIR: Phase 4 Map workload byte-exact with dense-map ownership stats" {
    var result = try compileAndRunWithArcStatsEnv(
        \\pub struct TestProg {
        \\  pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
        \\    if i >= n {
        \\      m
        \\    } else {
        \\      next = Map.put(m, i, i)
        \\      TestProg.loop(next, i + (1 :: i64), n)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    seed = %{-1 :: i64 => 0 :: i64}
        \\    cleared = Map.delete(seed, -1 :: i64)
        \\    result = TestProg.loop(cleared, 0 :: i64, 100 :: i64)
        \\    Kernel.inspect(Map.get(result, 50 :: i64, -1 :: i64))
        \\    "done"
        \\    0
        \\  }
        \\}
    ,
        &.{.{ .name = "ZAP_ARC_STATS", .value = "1" }},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("50\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Post-Phase-F: `.map` IS ARC-managed. Phase E.9's per-callee
    // consume convention infers `.owned` for tail-recursive accumulator
    // params, but the optimization emits `.move_value` (not the
    // counter-bumping `share_value(.consume)`), so `consumes_total`
    // stays 0 — Phase 6.9 gated consume_share_sites entirely off and
    // E.9 replaces them with move_value emission instead.
    const consumes_total = parseArcStatCounter(result.stderr, "consumes_total") orelse return error.RunFailed;
    try std.testing.expectEqual(@as(u64, 0), consumes_total);
    // Soundness retained: with Phase E.9's ownership discipline,
    // releases >= retains is the new invariant (each iteration's
    // intermediate Map.put result is released at scope exit, plus
    // the final returned map gets released by the caller).
    const retains = parseArcStatCounter(result.stderr, "retains_total") orelse return error.RunFailed;
    const releases = parseArcStatCounter(result.stderr, "releases_total") orelse return error.RunFailed;
    try std.testing.expect(releases >= retains);
    // Current arc_liveness invariant, pinned by
    // "arc_liveness: Phase 5 — k-nucleotide-shaped tail loop populates
    // both categories": after Phase E.7 pushes the base-arm `ret m`
    // into the arm and Phase E.5 Gap 4 rejects borrowed-param-returned
    // locals, this shape does NOT populate `return_source_locals`.
    // Ownership is observed through dense Map's unchecked mutation
    // counters instead.
    const return_elisions_total = parseArcStatCounter(result.stderr, "return_elisions_total") orelse return error.RunFailed;
    try std.testing.expectEqual(@as(u64, 0), return_elisions_total);

    const dense_map_mut_calls_total = parseArcStatCounter(result.stderr, "dense_map_mut_calls_total") orelse return error.RunFailed;
    const dense_map_unchecked_total = parseArcStatCounter(result.stderr, "dense_map_unchecked_total") orelse return error.RunFailed;
    try std.testing.expect(dense_map_mut_calls_total > 0);
    try std.testing.expectEqual(dense_map_mut_calls_total, dense_map_unchecked_total);
}

// ----------------------------------------------------------------
// Phase 5: return-source drop elision counter regression baseline.
// ----------------------------------------------------------------

// Phase E.7/E.5 current invariant for the k-nucleotide-shaped Map
// tail loop: tail-call rewriting pushes the base-arm `ret m` into the
// arm, and borrowed-param returns do not enter `return_source_locals`.
// The return-elision counter therefore stays zero. The load-bearing
// ownership signal for this workload is now dense Map's unchecked
// mutation counters.
test "ZIR: Phase 5 Map tail loop keeps return-elision counter zero and uses unchecked Map mutations" {
    var result = try compileAndRunWithArcStatsEnv(
        \\pub struct TestProg {
        \\  pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
        \\    if i >= n {
        \\      m
        \\    } else {
        \\      next = Map.put(m, i, i)
        \\      TestProg.loop(next, i + (1 :: i64), n)
        \\    }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    seed = %{-1 :: i64 => 0 :: i64}
        \\    cleared = Map.delete(seed, -1 :: i64)
        \\    result = TestProg.loop(cleared, 0 :: i64, 100 :: i64)
        \\    Kernel.inspect(Map.get(result, 50 :: i64, -1 :: i64))
        \\    "done"
        \\    0
        \\  }
        \\}
    ,
        &.{.{ .name = "ZAP_ARC_STATS", .value = "1" }},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("50\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Mirrors arc_liveness' k-nucleotide-shaped tail-loop invariant:
    // the base-arm borrowed-param return does not populate
    // `return_source_locals`, so there are no runtime return-elision
    // bumps for this shape.
    const return_elisions_total = parseArcStatCounter(result.stderr, "return_elisions_total") orelse
        return error.RunFailed;
    try std.testing.expectEqual(@as(u64, 0), return_elisions_total);
    const consumes_total = parseArcStatCounter(result.stderr, "consumes_total") orelse
        return error.RunFailed;
    try std.testing.expectEqual(@as(u64, 0), consumes_total);
    const retains = parseArcStatCounter(result.stderr, "retains_total") orelse
        return error.RunFailed;
    const releases = parseArcStatCounter(result.stderr, "releases_total") orelse
        return error.RunFailed;
    try std.testing.expect(releases >= retains);

    const dense_map_mut_calls_total = parseArcStatCounter(result.stderr, "dense_map_mut_calls_total") orelse
        return error.RunFailed;
    const dense_map_unchecked_total = parseArcStatCounter(result.stderr, "dense_map_unchecked_total") orelse
        return error.RunFailed;
    try std.testing.expect(dense_map_mut_calls_total > 0);
    try std.testing.expectEqual(dense_map_mut_calls_total, dense_map_unchecked_total);
}

// Phase 5 byte-exact regression: a non-ARC integer-arithmetic
// workload must produce zero return-elision counter activity. The
// Phase 5 emission lives entirely inside the `release`-instruction
// lowering, so a program with no `release` instructions in its IR
// must never bump the counter. Pins that the lowering's
// `arc_returned_locals.contains(...)` guard does not accidentally
// fire on unrelated programs.
//
// Note: a program with zero ARC traffic also never registers the
// `ZAP_ARC_STATS=1` atexit hook — `ensureArcStatsAtexit` is gated
// on the first ARC counter bump, so a stats-line absence in stderr
// is itself the proof that no ARC operation (including return-source
// elisions) fired. We accept either an absent dump line or an
// explicit `return_elisions_total=0` reading; both are equivalent
// observations of the load-bearing invariant.
test "ZIR: Phase 5 return-elision counter stays zero for non-ARC workload" {
    var result = try compileAndRunWithArcStatsEnv(
        \\pub struct TestProg {
        \\  pub fn add(a :: i64, b :: i64) -> i64 {
        \\    a + b
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    Kernel.inspect(TestProg.add(20 :: i64, 22 :: i64))
        \\    "done"
        \\    0
        \\  }
        \\}
    ,
        &.{.{ .name = "ZAP_ARC_STATS", .value = "1" }},
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    if (parseArcStatCounter(result.stderr, "return_elisions_total")) |return_elisions_total| {
        try std.testing.expectEqual(@as(u64, 0), return_elisions_total);
    }
    // Else: no stats dumped because no ARC traffic fired — also a
    // valid observation that the counter stayed at zero.
}

// ============================================================
// CLI: generalized Zap stdlib resolver (Phase 1)
//
// These tests exercise the `--zap-lib-dir` flag and the
// `ZAP_LIB_DIR` environment variable end-to-end. They build a
// minimal Zap project whose `build.zap` uses stdlib types
// (`Zap.Env`, `Zap.Manifest`) so the manifest CTFE — and thus
// the build — only succeeds when the resolver locates a valid
// stdlib directory containing `kernel.zap`. The override is
// pointed at the in-repo `lib/` directory (resolved as an
// absolute path from the test runner's project-root cwd), so a
// green build proves the resolver accepted and used the
// explicitly-provided stdlib root.
// ============================================================

/// Resolve the absolute path to the in-repo `lib/` stdlib
/// directory. The test runner's cwd is the project root (the
/// `zir-test` build step runs from there), so `lib/` is
/// reachable relatively; realpath promotes it to the absolute,
/// symlink-free form the resolver compares against.
fn resolveRepoStdlibDir(allocator: std.mem.Allocator) TestError![]const u8 {
    // `realPathFileAlloc` returns a sentinel-terminated `[:0]u8`
    // whose backing allocation is `len + 1` bytes; it MUST be freed
    // through that sentinel slice. Returning it coerced to a
    // `[]const u8` (length `len`) and freeing THAT under-counts by
    // one byte and trips the debug allocator's size-class check
    // (alloc 36 / free 35). Re-dupe into an exact-size buffer and
    // free the sentinel temp through its true shape so every caller's
    // plain `allocator.free(...)` is correctly sized.
    const real_z = std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), "lib", allocator) catch
        return error.Unexpected;
    defer allocator.free(real_z);
    return allocator.dupe(u8, real_z) catch return error.OutOfMemory;
}

/// Write the shared minimal stdlib-dependent project into `dir`.
/// The manifest references `Zap.Env`/`Zap.Manifest`, so it only
/// CTFE-evaluates when the stdlib resolves correctly.
fn writeStdlibResolverProject(dir: std.Io.Dir) TestError!void {
    const build_source =
        \\pub struct TestProg.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test_prog ->
        \\        %Zap.Manifest{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &TestProg.main/0,
        \\          paths: ["lib/**/*.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;
    const prog_source =
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    IO.puts("stdlib-resolver-ok")
        \\    "ok"
        \\    0
        \\  }
        \\}
    ;
    dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;
    dir.writeFile(getTestIo(), .{ .sub_path = "lib/test_prog.zap", .data = prog_source }) catch
        return error.Unexpected;
}

/// Run `zap build test_prog [extra_args...]` in `tmp_dir_path`
/// with `extra_env` overlaid on the parent environment, then run
/// the produced binary and assert it prints the success marker.
fn buildAndRunStdlibResolverProject(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    tmp_dir_path: []const u8,
    extra_args: []const []const u8,
    extra_env: []const EnvEntry,
    // Inferred error set: this helper composes `TestError`-returning
    // calls with `std.testing.expect*` (which raise
    // `error.TestExpectedEqual`/`TestUnexpectedResult`), so it cannot
    // narrow to `TestError`. Matches the `!void` convention every
    // `test` block and `expectCompileFails` already use.
) !void {
    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "build");
    try argv.append(allocator, "test_prog");
    for (extra_args) |a| try argv.append(allocator, a);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    for (extra_env) |entry| {
        env_map.put(entry.name, entry.value) catch return error.OutOfMemory;
    }

    const compile_result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.CompilationFailed;
    defer allocator.free(compile_result.stdout);
    defer allocator.free(compile_result.stderr);

    const compile_exit = switch (compile_result.term) {
        .exited => |code| code,
        else => {
            printUnexpectedCompileFailure(255, compile_result.stdout, compile_result.stderr);
            return error.CompilationFailed;
        },
    };
    if (compile_exit != 0) {
        printUnexpectedCompileFailure(compile_exit, compile_result.stdout, compile_result.stderr);
        return error.CompilationFailed;
    }

    const compiled_binary = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/test_prog", allocator) catch {
        std.debug.print("\n=== COMPILED BINARY NOT FOUND ===\n", .{});
        return error.CompilationFailed;
    };
    defer allocator.free(compiled_binary);

    const run_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{compiled_binary},
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    tmp_dir.dir.deleteTree(getTestIo(), "zap-out") catch {};

    const run_exit = switch (run_result.term) {
        .exited => |code| code,
        else => return error.RunFailed,
    };
    try std.testing.expectEqual(@as(u8, 0), run_exit);
    try std.testing.expect(std.mem.indexOf(u8, run_result.stdout, "stdlib-resolver-ok") != null);
}

test "CLI: ZAP_LIB_DIR env resolves stdlib" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    try buildAndRunStdlibResolverProject(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{},
        &.{.{ .name = "ZAP_LIB_DIR", .value = repo_lib }},
    );
}

test "CLI: --zap-lib-dir flag resolves stdlib" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    try buildAndRunStdlibResolverProject(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{ "--zap-lib-dir", repo_lib },
        &.{},
    );
}

// ------------------------------------------------------------
// Negative / precedence isolation tests
//
// The positive tests above point the override at the real
// in-repo `lib/`, which exe-relative resolution would also find,
// so they do not by themselves prove the override was consulted.
// These tests close that gap: each one supplies an explicit
// override (flag and/or env) that points at a real directory
// which exists but is NOT a valid Zap stdlib root (no
// `kernel.zap`). The resolver MUST hard-error on such an explicit
// override rather than silently falling through to the
// exe-relative `lib/` (which WOULD succeed for the built
// `zig-out/bin/zap`). A failed build with the specific
// diagnostic therefore proves:
//   * the override is actually consulted (not ignored), and
//   * there is no silent fallthrough to a lower-precedence source.
// The precedence pair additionally proves the flag wins over the
// env var in both directions.
// ------------------------------------------------------------

/// Create a real directory under `parent` that exists but is not
/// a valid Zap stdlib root (it deliberately contains no
/// `kernel.zap`). Returns its absolute, symlink-free path so the
/// resolver's `kernel.zap` access check fails for an *existing*
/// directory — isolating "not a stdlib" from "missing directory".
fn makeInvalidStdlibDir(
    allocator: std.mem.Allocator,
    parent: std.Io.Dir,
    sub_path: []const u8,
) TestError![]const u8 {
    parent.createDirPath(getTestIo(), sub_path) catch return error.Unexpected;
    // `realPathFileAlloc` returns a sentinel-terminated `[:0]u8`
    // (backing allocation = len + 1). Returning it coerced to a
    // `[]const u8` and freeing THAT under-counts by one byte and
    // trips the debug allocator's size-class check. Re-dupe into an
    // exact-size buffer and free the sentinel temp through its true
    // shape so the caller's plain `allocator.free(...)` is correctly
    // sized.
    const real_z = parent.realPathFileAlloc(getTestIo(), sub_path, allocator) catch
        return error.Unexpected;
    defer allocator.free(real_z);
    return allocator.dupe(u8, real_z) catch return error.OutOfMemory;
}

/// Run `zap build test_prog [extra_args...]` in `tmp_dir_path`
/// with `extra_env` overlaid on the parent environment, and
/// assert the build FAILS with a non-zero exit and the resolver
/// diagnostic `expected_diagnostic` on stderr.
///
/// Any inherited `ZAP_LIB_DIR` is removed from the child
/// environment before `extra_env` is overlaid so the child sees
/// exactly the env this test specifies — never an ambient
/// `ZAP_LIB_DIR` that could mask the precedence being asserted.
/// Mirrors `buildAndRunStdlibResolverProject` (same env-map
/// creation, cwd, and `std.process.run` shape) but inverts the
/// expectation and additionally asserts no output binary was
/// produced (proving there was no silent fallthrough build).
fn expectStdlibResolverBuildFails(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    tmp_dir_path: []const u8,
    extra_args: []const []const u8,
    extra_env: []const EnvEntry,
    expected_diagnostic: []const u8,
    // Inferred error set — see `buildAndRunStdlibResolverProject`.
) !void {
    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "build");
    try argv.append(allocator, "test_prog");
    for (extra_args) |a| try argv.append(allocator, a);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    // Strip any ambient ZAP_LIB_DIR so the child sees only what
    // this test specifies; swapRemove is a no-op when absent.
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    for (extra_env) |entry| {
        env_map.put(entry.name, entry.value) catch return error.OutOfMemory;
    }

    const compile_result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.CompilationFailed;
    defer allocator.free(compile_result.stdout);
    defer allocator.free(compile_result.stderr);

    // Defensively remove any output even though we expect none —
    // keeps the temp project clean if the resolver regresses.
    defer tmp_dir.dir.deleteTree(getTestIo(), "zap-out") catch {};

    const compile_exit = switch (compile_result.term) {
        .exited => |code| code,
        else => {
            // A signal/abnormal termination is not the clean,
            // deterministic hard-error this test asserts.
            printUnexpectedCompileFailure(255, compile_result.stdout, compile_result.stderr);
            return error.CompilationFailed;
        },
    };

    // The build must hard-error: non-zero exit AND the specific
    // resolver diagnostic on stderr. A zero exit would mean the
    // override was ignored and the resolver silently fell through
    // to the exe-relative `lib/` — exactly the failure mode these
    // tests exist to catch.
    if (compile_exit == 0) {
        std.debug.print(
            "\n=== EXPECTED BUILD FAILURE BUT IT SUCCEEDED ===\n" ++
                "The override was ignored / silently fell through.\n" ++
                "=== stdout ===\n{s}\n=== stderr ===\n{s}\n",
            .{ compile_result.stdout, compile_result.stderr },
        );
        return error.Unexpected;
    }
    try std.testing.expect(compile_exit != 0);

    if (std.mem.indexOf(u8, compile_result.stderr, expected_diagnostic) == null) {
        std.debug.print(
            "\n=== MISSING EXPECTED DIAGNOSTIC ===\nexpected substring: {s}\n" ++
                "=== stdout ===\n{s}\n=== stderr ===\n{s}\n",
            .{ expected_diagnostic, compile_result.stdout, compile_result.stderr },
        );
        return error.Unexpected;
    }

    // No output binary may exist: a hard-error must not have
    // produced an artifact via any lower-precedence path.
    if (tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/test_prog", allocator)) |stray| {
        defer allocator.free(stray);
        std.debug.print(
            "\n=== UNEXPECTED OUTPUT BINARY AFTER HARD-ERROR ===\n{s}\n",
            .{stray},
        );
        return error.Unexpected;
    } else |_| {}
}

test "CLI: invalid --zap-lib-dir hard-errors instead of falling through" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const invalid_dir = try makeInvalidStdlibDir(allocator, tmp_dir.dir, "not_a_stdlib");
    defer allocator.free(invalid_dir);

    try expectStdlibResolverBuildFails(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{ "--zap-lib-dir", invalid_dir },
        &.{},
        // Resolver emits:
        //   Error: --zap-lib-dir '<dir>' is not a valid Zap stdlib
        //   directory (no kernel.zap found)
        "is not a valid Zap stdlib directory",
    );
}

test "CLI: invalid ZAP_LIB_DIR hard-errors even though exe-relative would succeed" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const invalid_dir = try makeInvalidStdlibDir(allocator, tmp_dir.dir, "not_a_stdlib");
    defer allocator.free(invalid_dir);

    // Strong isolation: the built `zig-out/bin/zap` is exe-relative
    // to the real in-repo `lib/`, so exe-relative resolution WOULD
    // succeed here. The build must still fail — proving the invalid
    // env var is consulted and hard-errors with no fallthrough.
    try expectStdlibResolverBuildFails(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{},
        &.{.{ .name = "ZAP_LIB_DIR", .value = invalid_dir }},
        // Resolver emits:
        //   Error: ZAP_LIB_DIR '<dir>' is not a valid Zap stdlib
        //   directory (no kernel.zap found)
        "ZAP_LIB_DIR '",
    );
}

test "CLI: invalid --zap-lib-dir wins over valid ZAP_LIB_DIR (flag precedence, no fallthrough)" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const invalid_dir = try makeInvalidStdlibDir(allocator, tmp_dir.dir, "not_a_stdlib");
    defer allocator.free(invalid_dir);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    // Flag is invalid, env is valid (real in-repo `lib/`). The flag
    // has highest precedence, so the build must fail with the FLAG
    // diagnostic — the valid env is never consulted, and there is
    // no fallthrough to exe-relative.
    try expectStdlibResolverBuildFails(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{ "--zap-lib-dir", invalid_dir },
        &.{.{ .name = "ZAP_LIB_DIR", .value = repo_lib }},
        // Asserting the FLAG diagnostic (not the env one) proves
        // the flag was consulted and won over the valid env var.
        "--zap-lib-dir '",
    );
}

test "CLI: valid --zap-lib-dir wins over invalid ZAP_LIB_DIR (flag precedence, build succeeds)" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const invalid_dir = try makeInvalidStdlibDir(allocator, tmp_dir.dir, "not_a_stdlib");
    defer allocator.free(invalid_dir);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    // Flag is valid (real in-repo `lib/`), env is invalid. Because
    // the flag has highest precedence the invalid env value is
    // never consulted, so the build SUCCEEDS and prints the marker.
    // (buildAndRunStdlibResolverProject overlays the invalid env
    // onto the parent environment and asserts success.)
    try buildAndRunStdlibResolverProject(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{ "--zap-lib-dir", repo_lib },
        &.{.{ .name = "ZAP_LIB_DIR", .value = invalid_dir }},
    );
}

// ============================================================
// CLI: single-file script mode — `zap run <script.zap>`
//
// These tests exercise the end-to-end script path: dispatch
// (an existing regular file that is not `build.zap` is a
// script), the parser's top-level `main/1` carve-out, the
// synthetic manifest, stdlib-only compilation, argument
// forwarding, exit-code propagation, the script-contract
// diagnostics, and the core no-litter invariant (NOTHING is
// written next to the user's script).
//
// Each test writes ONE bare `.zap` file to a fresh tmp dir
// that has NO `build.zap` and NO `lib/`, then invokes
// `zap run <abs script path> [args...]` with cwd = the tmp
// dir. Any ambient `ZAP_LIB_DIR` is stripped and replaced with
// the in-repo `lib/` so the child sees a deterministic stdlib;
// `ZAP_SCRIPT_CACHE_DIR` is pointed at a separate tmp tree so
// the script artifact location is deterministic AND the
// no-litter assertion is meaningful (any litter would land in
// the script's own tmp dir, which we then assert contains only
// the script).
// ============================================================

const ScriptRunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *ScriptRunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Write `script_source` to `<tmp>/<script_name>` and run
/// `zap run <abs script path> [extra_args...]` with cwd = tmp,
/// a deterministic stdlib, and an isolated script cache root.
/// Returns the captured stdout/stderr/exit. The caller owns the
/// `TmpDir` (so it can assert on directory contents before
/// cleanup) and must `deinit` the result.
fn runScriptInTmp(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    script_name: []const u8,
    script_source: []const u8,
    extra_args: []const []const u8,
) TestError!ScriptRunResult {
    return runScriptInTmpWithFlags(allocator, tmp_dir, script_name, script_source, &.{}, extra_args);
}

/// Like `runScriptInTmp`, but additionally places `lead_flags`
/// BEFORE the script path — i.e. `zap run [lead_flags...] <abs
/// script path> [extra_args...]`. This is the single source of
/// truth for the script-process spawn; `runScriptInTmp` delegates
/// here with no leading flags. The recognized leading flags
/// (`-D<key>=<value>` build flags and the two-token
/// `--zap-lib-dir <dir>` stdlib locator) are consumed from the
/// leading region, so Phase 4 tests pass them via `lead_flags`
/// while still exercising `extra_args`/`--` forwarding to `main/1`
/// (everything after the script path is opaque passthrough).
fn runScriptInTmpWithFlags(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    script_name: []const u8,
    script_source: []const u8,
    lead_flags: []const []const u8,
    extra_args: []const []const u8,
) TestError!ScriptRunResult {
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = script_name, .data = script_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const script_path = std.fs.path.join(allocator, &.{ tmp_dir_path, script_name }) catch
        return error.OutOfMemory;
    defer allocator.free(script_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const script_cache = std.fs.path.join(allocator, &.{ tmp_dir_path, "..", "zap-script-cache" }) catch
        return error.OutOfMemory;
    defer allocator.free(script_cache);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "run");
    for (lead_flags) |f| try argv.append(allocator, f);
    try argv.append(allocator, script_path);
    for (extra_args) |a| try argv.append(allocator, a);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    // Deterministic stdlib + isolated, off-tmp script cache so the
    // no-litter assertion is exact.
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;
    env_map.put("ZAP_SCRIPT_CACHE_DIR", script_cache) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.RunFailed;
        },
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

/// Run `zap run <run_args...>` in a fresh empty tmp dir (NO
/// `build.zap`, NO script file, NO positional) with the deterministic
/// stdlib and isolated script cache. Used for the genuine
/// no-positional / missing-value cases under the current unified
/// contract — e.g. `zap run -Doptimize` (a `-D` flag with no `=`) or
/// `zap run --zap-lib-dir` (a two-token leading flag missing its
/// value): the run must fail with a clear `Error:`-prefixed
/// diagnostic and a non-zero exit rather than silently doing nothing.
/// Caller `deinit`s the result.
fn runZapRunRaw(
    allocator: std.mem.Allocator,
    run_args: []const []const u8,
) TestError!ScriptRunResult {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const script_cache = std.fs.path.join(allocator, &.{ tmp_dir_path, "..", "zap-script-cache" }) catch
        return error.OutOfMemory;
    defer allocator.free(script_cache);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "run");
    for (run_args) |a| try argv.append(allocator, a);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;
    env_map.put("ZAP_SCRIPT_CACHE_DIR", script_cache) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.RunFailed;
        },
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

/// Assert the script's own directory still contains ONLY the
/// script after a run — proving the core no-litter invariant
/// (no `zap-out/`, `.zap-cache/`, `zap.lock`, or stub written
/// next to the user's file).
fn expectOnlyScriptInDir(tmp_dir: *std.testing.TmpDir, script_name: []const u8) TestError!void {
    var dir = tmp_dir.dir.openDir(getTestIo(), ".", .{ .iterate = true }) catch
        return error.Unexpected;
    defer dir.close(getTestIo());
    var it = dir.iterate();
    while (it.next(getTestIo()) catch null) |entry| {
        if (!std.mem.eql(u8, entry.name, script_name)) {
            std.debug.print(
                "\n=== NO-LITTER VIOLATION: unexpected entry '{s}' next to script ===\n",
                .{entry.name},
            );
            return error.Unexpected;
        }
    }
}

test "CLI run: no positional and no build.zap fails (manifest path, clear non-zero)" {
    const allocator = std.testing.allocator;
    // `zap run` with NO positional in a dir with NO build.zap: there
    // is nothing to dispatch as a script and no manifest project, so
    // it must fail with a non-zero exit and a clear diagnostic — never
    // hang or silently succeed.
    var r = try runZapRunRaw(allocator, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "build.zap") != null);
}

test "CLI run: leading -Doptimize with no '=' and no script is a clear hard error" {
    const allocator = std.testing.allocator;
    // `zap run -Doptimize` — a `-D` flag missing its `=value`, with no
    // script positional. The shared `-D` parser must reject it with a
    // precise diagnostic and a non-zero exit (not a confusing target
    // error, not a silent no-op).
    var r = try runZapRunRaw(allocator, &.{"-Doptimize"});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "optimize") != null);
}

test "CLI run: leading --zap-lib-dir with no value is a clear hard error" {
    const allocator = std.testing.allocator;
    // `zap run --zap-lib-dir` — the two-token stdlib locator missing
    // its value. It must fail loudly with the specific "requires a
    // path" diagnostic, never consume a non-existent next token.
    var r = try runZapRunRaw(allocator, &.{"--zap-lib-dir"});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--zap-lib-dir") != null);
}

test "CLI script: top-level main/1 prints output (happy path)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "hello.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("script-hello")
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "script-hello") != null);
    try expectOnlyScriptInDir(&tmp_dir, "hello.zap");
}

test "CLI script: main/1 uses a local struct defined in the same file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "ls.zap",
        \\pub struct Scalar {
        \\  pub fn square(x :: i64) -> i64 { x * x }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("square=" <> Integer.to_string(Scalar.square(6)))
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "square=36") != null);
    try expectOnlyScriptInDir(&tmp_dir, "ls.zap");
}

test "CLI script: main/1 uses a local protocol + impl in the same file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "proto.zap",
        \\pub protocol Describable {
        \\  fn describe(value :: Self) -> String
        \\}
        \\
        \\pub struct Widget {
        \\  size :: i64
        \\
        \\  pub fn make(s :: i64) -> Widget { %Widget{size: s} }
        \\}
        \\
        \\pub impl Describable for Widget {
        \\  pub fn describe(value :: Widget) -> String {
        \\    "Widget(size=" <> Integer.to_string(value.size) <> ")"
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  w = Widget.make(7)
        \\  IO.puts(Widget.describe(w))
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Widget(size=7)") != null);
    try expectOnlyScriptInDir(&tmp_dir, "proto.zap");
}

test "CLI script: main/1 uses stdlib (IO, Integer, System)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "std.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("argc=" <> Integer.to_string(System.arg_count()))
        \\  "ok"
        \\  0
        \\}
    , &.{ "a", "b", "c" });
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "argc=3") != null);
    try expectOnlyScriptInDir(&tmp_dir, "std.zap");
}

test "CLI script: args after path are forwarded to main/1" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "args.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("n=" <> Integer.to_string(System.arg_count()))
        \\  "ok"
        \\  0
        \\}
    , &.{ "one", "two", "three", "four" });
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "n=4") != null);
}

test "CLI script: args after explicit -- are forwarded verbatim" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "dd.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("n=" <> Integer.to_string(System.arg_count()))
        \\  "ok"
        \\  0
        \\}
    , &.{ "--", "x", "y" });
    defer r.deinit();

    // Locked Phase 4 contract: the post-path region is OPAQUE
    // PASSTHROUGH — a literal `--` is forwarded VERBATIM to `main/1`,
    // NOT consumed as a separator (see `cmdRunScript`'s doc and the
    // passing `-Dtarget` AFTER-path passthrough test). So `-- x y`
    // is THREE forwarded args, hence `arg_count() == 3`.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "n=3") != null);
}

test "CLI script: exit code is propagated (panic -> non-zero)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "panic.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  panic("boom")
        \\  "unreachable"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
}

test "CLI script: exit code is propagated (normal -> zero)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "ok.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("done")
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "CLI script: main/1 u8 return is propagated as process exit code" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "exit13.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("exit-code-source")
        \\  13
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 13), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "exit-code-source") != null);
}

test "CLI script: main/1 u8 zero return succeeds" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "exit0.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("zero-exit")
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "zero-exit") != null);
}

test "CLI script: main/1 String return is rejected with entrypoint diagnostic" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "string_main.zap",
        \\fn main(_args :: [String]) -> String {
        \\  "not an exit code"
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "main/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "String") != null);
}

test "CLI script error: zero top-level functions" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "z.zap",
        \\pub struct OnlyStruct {
        \\  pub fn helper() -> String { "x" }
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no top-level function") != null);
}

test "CLI script error: two top-level functions" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "two.zap",
        \\fn main(_args :: [String]) -> u8 { 0 }
        \\fn other() -> String { "b" }
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "exactly one top-level function") != null);
}

test "CLI script error: top-level fn not named main" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "named.zap",
        \\fn run(_args :: [String]) -> String { "a" }
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "must be named `main`") != null);
}

test "CLI script error: top-level main wrong arity (0)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "a0.zap",
        \\fn main() -> String { "a" }
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "exactly one argument") != null);
}

test "CLI script error: top-level main wrong arity (2)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "a2.zap",
        \\fn main(a :: [String], b :: i64) -> String { "a" }
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "exactly one argument") != null);
}

test "CLI script error: external dep / use of a non-stdlib package is rejected" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Script mode supplies NO project/dep source roots — only the
    // stdlib — so a reference to a package that is neither stdlib
    // nor defined in this file cannot resolve. The build fails
    // (non-zero exit) and nothing is left behind. The external
    // package must actually be REFERENCED: an unreferenced `use`
    // alone is elided and would not exercise the constraint.
    var r = try runScriptInTmp(allocator, &tmp_dir, "ext.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts(SomeThirdParty.Pkg.greet())
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try expectOnlyScriptInDir(&tmp_dir, "ext.zap");
}

test "CLI script: no artifacts are written next to the script" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "clean.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("clean-run")
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // The script's directory must contain ONLY the script — no
    // zap-out/, .zap-cache/, zap.lock, or root stub.
    try expectOnlyScriptInDir(&tmp_dir, "clean.zap");
}

/// Locate the single published `script` binary under the per-test
/// `ZAP_SCRIPT_CACHE_DIR` tree (`<tmp parent>/zap-script-cache/zap/
/// scripts/<key>/script`). Returns an owned absolute path.
/// `runScriptInTmpWithFlags` writes the cache under the tmp's
/// parent dir, so this helper walks the same tree the test driver
/// established. The cache is per-test (cleaned with the tmp dir's
/// parent, also a tmp), so we expect exactly one published binary.
fn findPublishedScriptBinary(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
) TestError![]const u8 {
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const scripts_dir = std.fs.path.join(allocator, &.{ tmp_dir_path, "..", "zap-script-cache", "zap", "scripts" }) catch
        return error.OutOfMemory;
    defer allocator.free(scripts_dir);

    var dir = std.Io.Dir.cwd().openDir(getTestIo(), scripts_dir, .{ .iterate = true }) catch
        return error.Unexpected;
    defer dir.close(getTestIo());

    var iter = dir.iterate();
    while (iter.next(getTestIo()) catch return error.Unexpected) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = std.fs.path.join(allocator, &.{ scripts_dir, entry.name, "script" }) catch
            return error.OutOfMemory;
        std.Io.Dir.cwd().access(getTestIo(), candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return error.Unexpected;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(getTestIo(), path, .{}) catch return false;
    return true;
}

test "CLI script Phase 0 Gap A: ReleaseSafe Mach-O publishes a sibling .dSYM next to the script binary" {
    // Phase 0 — DWARF foundation, Gap A. `cmdRunScript` was already
    // calling `publishScriptDebugSymbolsIfNeeded` (which honors
    // `needsDarwinDebugSymbols`), but the contract was untested end-
    // to-end: a future refactor could move the script binary and
    // silently lose the `.dSYM` produced by the fork. Lock in the
    // contract by building a real ReleaseSafe script and asserting
    // the sibling `.dSYM` bundle exists at the published path
    // (NOT just at the staged path).
    //
    // ReleaseSafe is the load-bearing case the broader policy table
    // change (`needsDarwinDebugSymbols` honoring the resolved
    // policy, not just Debug) was meant to enable: lldb / addr2line
    // / the Phase-2 panic handler resolve to Zap file:line on
    // release-safe builds.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(
        allocator,
        &tmp_dir,
        "phase0_dsym.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("phase0-dsym")
        \\  0
        \\}
        ,
        // Lead flag: pin the optimize mode to ReleaseSafe so we
        // exercise the broadened `needsDarwinDebugSymbols` branch
        // — Debug would also produce a dSYM, but it would not
        // discriminate the Phase 0 broadening from the legacy
        // Debug-only behavior.
        &.{"-Doptimize=ReleaseSafe"},
        &.{},
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "phase0-dsym") != null);
    try expectOnlyScriptInDir(&tmp_dir, "phase0_dsym.zap");

    // The dSYM bundle must exist next to the *published* binary, not
    // just at the (long-deleted) staging path. The staging dir is
    // cleaned by `cmdRunScript` after the atomic rename publishes
    // the binary; if the dSYM publication path is ever lost, this
    // test fails — the staging-side dSYM is already gone by the
    // time the publish completes.
    const published = try findPublishedScriptBinary(allocator, &tmp_dir);
    defer allocator.free(published);

    const dsym_path = std.fmt.allocPrint(allocator, "{s}.dSYM", .{published}) catch return error.OutOfMemory;
    defer allocator.free(dsym_path);
    if (!pathExists(dsym_path)) {
        std.debug.print(
            "Phase 0 Gap A: expected sibling .dSYM at {s}, but it is missing.\n  published binary: {s}\n",
            .{ dsym_path, published },
        );
        return error.TestUnexpectedResult;
    }

    // Sanity-check the inner DWARF blob exists too — an empty
    // bundle would still satisfy the bare-path test but defeats the
    // purpose. Mach-O layout: `<bin>.dSYM/Contents/Resources/DWARF/
    // <name>`. Phase-2's crash printer relies on the inner DWARF
    // being readable, so make sure the publisher produced it.
    const dwarf_inner = std.fmt.allocPrint(
        allocator,
        "{s}/Contents/Resources/DWARF/script",
        .{dsym_path},
    ) catch return error.OutOfMemory;
    defer allocator.free(dwarf_inner);
    if (!pathExists(dwarf_inner)) {
        std.debug.print(
            "Phase 0 Gap A: expected inner DWARF blob at {s}, but it is missing.\n",
            .{dwarf_inner},
        );
        return error.TestUnexpectedResult;
    }
}

test "CLI script Phase 0 Gap D: -Ddebug-info=split publishes sibling dSYM + strips main binary" {
    // Phase 0 — DWARF foundation, Gap D. The `-Ddebug-info=split`
    // override compiles the Zap binary with the DWARF debug-map
    // intact so `dsymutil` can extract a sibling `.dSYM`, then the
    // post-link strip pass removes the debug-map from the published
    // binary. Acceptance per the gap brief:
    //   (a) The main binary contains no `__DWARF` segment / no
    //       `__debug_*` sections (`otool -l` / `llvm-objdump`).
    //   (b) A sibling `.dSYM` exists with the full DWARF blob.
    //   (c) `atos` against the binary still resolves a Zap function
    //       to its `<file>:<line>` via the sibling.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(
        allocator,
        &tmp_dir,
        "phase0_split.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("phase0-split")
        \\  0
        \\}
        ,
        // Debug + `-Ddebug-info=split`: Debug already keeps DWARF
        // by default, so the split override is exercising the
        // override path (the per-mode default would be `.full`).
        &.{ "-Doptimize=Debug", "-Ddebug-info=split" },
        &.{},
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "phase0-split") != null);

    const published = try findPublishedScriptBinary(allocator, &tmp_dir);
    defer allocator.free(published);

    // (b) Sibling .dSYM with DWARF blob.
    const dsym_path = std.fmt.allocPrint(allocator, "{s}.dSYM", .{published}) catch return error.OutOfMemory;
    defer allocator.free(dsym_path);
    if (!pathExists(dsym_path)) {
        std.debug.print(
            "Phase 0 Gap D: expected sibling .dSYM at {s}.\n",
            .{dsym_path},
        );
        return error.TestUnexpectedResult;
    }
    const dwarf_inner = std.fmt.allocPrint(
        allocator,
        "{s}/Contents/Resources/DWARF/script",
        .{dsym_path},
    ) catch return error.OutOfMemory;
    defer allocator.free(dwarf_inner);
    if (!pathExists(dwarf_inner)) {
        std.debug.print(
            "Phase 0 Gap D: expected inner DWARF blob at {s}.\n",
            .{dwarf_inner},
        );
        return error.TestUnexpectedResult;
    }

    // (a) Main binary contains NO DWARF section. Read the Mach-O
    // load commands via `otool -l` and assert no `sectname` line
    // starts with `__debug` — that's the family of section names
    // dsymutil-extractable debug info lives in (`__debug_info`,
    // `__debug_line`, `__debug_str`, etc.). The historical Phase 0
    // bug was that `-Ddebug-info=split` left the binary
    // byte-identical to `-Ddebug-info=full` because the post-strip
    // pass was missing.
    const otool_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "otool", "-l", published },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(otool_result.stdout);
    defer allocator.free(otool_result.stderr);
    if (std.mem.indexOf(u8, otool_result.stdout, "__debug") != null) {
        std.debug.print(
            "Phase 0 Gap D: main binary at {s} still carries DWARF __debug sections:\n{s}\n",
            .{ published, otool_result.stdout },
        );
        return error.TestUnexpectedResult;
    }

    // (c) `atos` round-trip via the sibling dSYM resolves the Zap
    // user code to `<file>.zap:<line>`. The hoisted script main
    // wrapper lives at symbol `_script.main` (the script-mode
    // synthetic struct that owns `main/1`); resolving its address
    // through the dSYM must produce the original Zap source
    // coordinates.
    const nm_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "nm", published },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(nm_result.stdout);
    defer allocator.free(nm_result.stderr);

    // Walk `nm` lines to extract the address for `_script.main`.
    var script_main_addr: ?[]const u8 = null;
    var addr_buf: [64]u8 = undefined;
    var line_iter = std.mem.splitScalar(u8, nm_result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, " _script.main") == null) continue;
        // Format: "<16hex_addr> T _script.main" — extract the leading hex.
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const addr_hex = line[0..space];
        if (addr_hex.len == 0 or addr_hex.len > 16) continue;
        const written = std.fmt.bufPrint(&addr_buf, "0x{s}", .{addr_hex}) catch continue;
        script_main_addr = written;
        break;
    }
    const addr = script_main_addr orelse {
        std.debug.print(
            "Phase 0 Gap D: could not locate `_script.main` in nm output:\n{s}\n",
            .{nm_result.stdout},
        );
        return error.TestUnexpectedResult;
    };

    const atos_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "atos", "-o", dwarf_inner, "-arch", "arm64", "-l", "0x100000000", addr },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(atos_result.stdout);
    defer allocator.free(atos_result.stderr);

    // Expect the resolved symbol description to mention the script
    // file name — the dSYM carries the original Zap source path
    // and atos formats `<symbol> (in <binary>) (<file>:<line>)`.
    if (std.mem.indexOf(u8, atos_result.stdout, "phase0_split.zap") == null) {
        std.debug.print(
            "Phase 0 Gap D: atos did not resolve `_script.main` at {s} to a phase0_split.zap location.\n  stdout: {s}\n  stderr: {s}\n",
            .{ addr, atos_result.stdout, atos_result.stderr },
        );
        return error.TestUnexpectedResult;
    }
}

test "CLI script Phase 0 Gap A: -Ddebug-info=none on Debug does NOT publish a dSYM" {
    // The other half of the Phase 0 contract: an explicit policy
    // override that strips debug-info MUST suppress dSYM
    // publication. Without this, a user who asked for a fully-
    // stripped binary would still ship the matching DWARF — a
    // privacy regression (dSYM contains absolute source paths and
    // a per-symbol map of the binary).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(
        allocator,
        &tmp_dir,
        "phase0_no_dsym.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("phase0-no-dsym")
        \\  0
        \\}
        ,
        &.{ "-Doptimize=Debug", "-Ddebug-info=none" },
        &.{},
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);

    const published = try findPublishedScriptBinary(allocator, &tmp_dir);
    defer allocator.free(published);

    const dsym_path = std.fmt.allocPrint(allocator, "{s}.dSYM", .{published}) catch return error.OutOfMemory;
    defer allocator.free(dsym_path);
    if (pathExists(dsym_path)) {
        std.debug.print(
            "Phase 0 Gap A: -Ddebug-info=none must suppress dSYM, but one was published at {s}.\n",
            .{dsym_path},
        );
        return error.TestUnexpectedResult;
    }
}

test "CLI script Phase 0 Gap E: ReleaseFast default publishes sibling dSYM + strips main binary" {
    // Phase 0 — DWARF foundation, Gap E. The error-system research
    // brief (`docs/error-system-research-brief.md`, Part VI.B #13 &
    // Part VIII) requires ReleaseFast and ReleaseSmall to ship the
    // split-debug shape — stripped main binary + sibling `.dSYM` —
    // BY DEFAULT, not only when the user passes `-Ddebug-info=split`
    // explicitly. The unit test "Phase 0 Gap E: per-mode dSYM
    // defaults follow the spec table" pins the gate-level decision;
    // this integration test exercises the full pipeline end-to-end
    // on aarch64-macos:
    //
    //   (a) Main binary contains no `__debug_*` Mach-O sections.
    //   (b) Sibling `.dSYM` exists with a non-empty inner DWARF blob.
    //   (c) `atos` against the dSYM resolves a Zap function to its
    //       original `<file>.zap:<line>` source coordinates.
    //
    // ReleaseFast is the high-signal mode — ReleaseSmall would
    // produce the same shape (Gap E flips both defaults
    // identically) but rebuilding the script in two release modes
    // doubles a slow integration-test run; the gate matrix is
    // already covered by the unit test.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    if (@import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(
        allocator,
        &tmp_dir,
        "phase0_release_fast.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("phase0-release-fast")
        \\  0
        \\}
        ,
        // ReleaseFast WITHOUT any `-Ddebug-info=` override — this is
        // the spec-table default the Gap E fix introduces.
        &.{"-Doptimize=ReleaseFast"},
        &.{},
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "phase0-release-fast") != null);

    const published = try findPublishedScriptBinary(allocator, &tmp_dir);
    defer allocator.free(published);

    // (b) Sibling .dSYM with non-empty inner DWARF blob.
    const dsym_path = std.fmt.allocPrint(allocator, "{s}.dSYM", .{published}) catch return error.OutOfMemory;
    defer allocator.free(dsym_path);
    if (!pathExists(dsym_path)) {
        std.debug.print(
            "Phase 0 Gap E: ReleaseFast default did not publish sibling .dSYM at {s}.\n",
            .{dsym_path},
        );
        return error.TestUnexpectedResult;
    }
    const dwarf_inner = std.fmt.allocPrint(
        allocator,
        "{s}/Contents/Resources/DWARF/script",
        .{dsym_path},
    ) catch return error.OutOfMemory;
    defer allocator.free(dwarf_inner);
    if (!pathExists(dwarf_inner)) {
        std.debug.print(
            "Phase 0 Gap E: ReleaseFast default sibling .dSYM is missing inner DWARF blob at {s}.\n",
            .{dwarf_inner},
        );
        return error.TestUnexpectedResult;
    }

    // (a) Main binary has NO DWARF section. Read the Mach-O load
    // commands via `otool -l` and assert no line starts with
    // `__debug` — that is the family of section names
    // dsymutil-extractable debug info lives in (`__debug_info`,
    // `__debug_line`, `__debug_str`, etc.). The Gap E regression
    // would be "Gap D wired the post-strip only for the explicit
    // override, not for the release-mode default" — leaving the
    // unflagged ReleaseFast binary still carrying its full DWARF
    // debug-map and silently doubling shipped binary size.
    const otool_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "otool", "-l", published },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(otool_result.stdout);
    defer allocator.free(otool_result.stderr);
    if (std.mem.indexOf(u8, otool_result.stdout, "__debug") != null) {
        std.debug.print(
            "Phase 0 Gap E: ReleaseFast default main binary at {s} still carries DWARF __debug sections:\n{s}\n",
            .{ published, otool_result.stdout },
        );
        return error.TestUnexpectedResult;
    }

    // (c) `atos` round-trip via the sibling dSYM resolves the Zap
    // user code to `<file>.zap:<line>`. The hoisted script main
    // wrapper lives at symbol `_script.main`; resolving its address
    // through the dSYM must produce the original Zap source
    // coordinates so Phase 2's crash printer / lldb / addr2line can
    // surface user-meaningful frames on optimized builds.
    const nm_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "nm", published },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(nm_result.stdout);
    defer allocator.free(nm_result.stderr);

    var script_main_addr: ?[]const u8 = null;
    var addr_buf: [64]u8 = undefined;
    var line_iter = std.mem.splitScalar(u8, nm_result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, " _script.main") == null) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const addr_hex = line[0..space];
        if (addr_hex.len == 0 or addr_hex.len > 16) continue;
        const written = std.fmt.bufPrint(&addr_buf, "0x{s}", .{addr_hex}) catch continue;
        script_main_addr = written;
        break;
    }
    const addr = script_main_addr orelse {
        std.debug.print(
            "Phase 0 Gap E: could not locate `_script.main` in nm output for ReleaseFast default:\n{s}\n",
            .{nm_result.stdout},
        );
        return error.TestUnexpectedResult;
    };

    const atos_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "atos", "-o", dwarf_inner, "-arch", "arm64", "-l", "0x100000000", addr },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(atos_result.stdout);
    defer allocator.free(atos_result.stderr);

    if (std.mem.indexOf(u8, atos_result.stdout, "phase0_release_fast.zap") == null) {
        std.debug.print(
            "Phase 0 Gap E: atos did not resolve `_script.main` at {s} to a phase0_release_fast.zap location.\n  stdout: {s}\n  stderr: {s}\n",
            .{ addr, atos_result.stdout, atos_result.stderr },
        );
        return error.TestUnexpectedResult;
    }
}

/// Disassemble a Mach-O text section and return true if `add x29,
/// sp, #...` appears anywhere in the matching function — the
/// aarch64 frame-pointer materialization instruction. Used to
/// observe the FP policy from the published binary.
fn aarch64MainHasFramePointerSetup(
    allocator: std.mem.Allocator,
    binary_path: []const u8,
) TestError!bool {
    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "otool", "-tv", "-p", "_main", binary_path },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Walk only the first ~30 lines of the disassembly — the FP
    // setup is part of the prologue and always lands near the
    // function entry. Looking further risks catching a callee's
    // prologue spilled into the listing.
    var seen_lines: usize = 0;
    var line_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (line_iter.next()) |line| : (seen_lines += 1) {
        if (seen_lines >= 30) break;
        // The `add x29, sp, #...` instruction is the FP setup.
        // Loose whitespace match so the otool output format doesn't
        // tie this assertion to a specific column.
        if (std.mem.indexOf(u8, line, "add\tx29, sp, #") != null) return true;
        if (std.mem.indexOf(u8, line, "add  x29, sp, #") != null) return true;
        if (std.mem.indexOf(u8, line, "add x29, sp, #") != null) return true;
    }
    return false;
}

test "CLI script Phase 0 Gap C: -Dframe-pointers=off omits the aarch64 FP prologue" {
    // Phase 0 — DWARF foundation, Gap C. The `-Dframe-pointers=`
    // CLI flag must reach codegen so the published binary's
    // prologue actually changes. Cover the override path on
    // aarch64-macos: the default ReleaseSafe policy keeps FP on
    // (the `add x29, sp, #N` instruction is present in `_main`);
    // `-Dframe-pointers=off` removes it.
    //
    // ReleaseSafe is the high-signal mode for this test — Debug
    // keeps the wrapper's FP setup in either case because the Zig
    // startup glue has its own prologue, but the optimized Zap
    // user code lives directly under `_main` in release modes and
    // observes the override cleanly.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    if (@import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // ReleaseSafe default (FP on).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptInTmpWithFlags(
            allocator,
            &tmp_dir,
            "phase0_fp_on.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("fp-on")
            \\  0
            \\}
            ,
            &.{"-Doptimize=ReleaseSafe"},
            &.{},
        );
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        const published = try findPublishedScriptBinary(allocator, &tmp_dir);
        defer allocator.free(published);
        const has_fp = try aarch64MainHasFramePointerSetup(allocator, published);
        if (!has_fp) {
            std.debug.print(
                "Phase 0 Gap C: expected FP prologue in ReleaseSafe default binary {s}, but none observed.\n",
                .{published},
            );
            return error.TestUnexpectedResult;
        }
    }

    // ReleaseSafe -Dframe-pointers=off (FP off).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptInTmpWithFlags(
            allocator,
            &tmp_dir,
            "phase0_fp_off.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("fp-off")
            \\  0
            \\}
            ,
            &.{ "-Doptimize=ReleaseSafe", "-Dframe-pointers=off" },
            &.{},
        );
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        const published = try findPublishedScriptBinary(allocator, &tmp_dir);
        defer allocator.free(published);
        const has_fp = try aarch64MainHasFramePointerSetup(allocator, published);
        if (has_fp) {
            std.debug.print(
                "Phase 0 Gap C: -Dframe-pointers=off ReleaseSafe binary {s} still has FP prologue.\n",
                .{published},
            );
            return error.TestUnexpectedResult;
        }
    }

    // ReleaseFast default (FP off — the per-mode default).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptInTmpWithFlags(
            allocator,
            &tmp_dir,
            "phase0_fp_fast.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("fp-fast")
            \\  0
            \\}
            ,
            &.{"-Doptimize=ReleaseFast"},
            &.{},
        );
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        const published = try findPublishedScriptBinary(allocator, &tmp_dir);
        defer allocator.free(published);
        const has_fp = try aarch64MainHasFramePointerSetup(allocator, published);
        if (has_fp) {
            std.debug.print(
                "Phase 0 Gap C: ReleaseFast default binary {s} unexpectedly carries an FP prologue.\n",
                .{published},
            );
            return error.TestUnexpectedResult;
        }
    }

    // ReleaseFast -Dframe-pointers=on (FP on via override).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptInTmpWithFlags(
            allocator,
            &tmp_dir,
            "phase0_fp_fast_on.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("fp-fast-on")
            \\  0
            \\}
            ,
            &.{ "-Doptimize=ReleaseFast", "-Dframe-pointers=on" },
            &.{},
        );
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        const published = try findPublishedScriptBinary(allocator, &tmp_dir);
        defer allocator.free(published);
        const has_fp = try aarch64MainHasFramePointerSetup(allocator, published);
        if (!has_fp) {
            std.debug.print(
                "Phase 0 Gap C: -Dframe-pointers=on ReleaseFast binary {s} is missing the FP prologue.\n",
                .{published},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// ------------------------------------------------------------
// Manifest-path regression under the new dispatch
//
// The script dispatch must leave the manifest path byte-for-
// byte: nothing diverts to script mode unless the first
// positional is an existing regular file that is not
// `build.zap`. These rebuild the existing minimal stdlib
// project and assert the manifest flow still works for: a dir
// containing build.zap, an explicit build.zap file positional,
// no positional, and `<target> -- args`.
// ------------------------------------------------------------

test "CLI dispatch regression: dir-with-build.zap still uses the manifest path" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    // `zap run test_prog` from inside the project (cwd has
    // build.zap; positional is a manifest target, not an on-disk
    // file) must take the manifest path unchanged.
    try buildAndRunStdlibResolverProject(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{},
        &.{},
    );
}

test "CLI dispatch regression: explicit build.zap file positional uses the manifest path" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    // First positional is the literal file `build.zap` — path
    // semantics classify it as the manifest project, NOT a
    // script. (`parseTargetArgs` then treats `build.zap` as the
    // target name; the project's manifest only knows `:test_prog`,
    // so this asserts the script carve-out did not intercept it.)
    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "run", "build.zap" },
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.CompilationFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    defer tmp_dir.dir.deleteTree(getTestIo(), "zap-out") catch {};
    defer tmp_dir.dir.deleteTree(getTestIo(), ".zap-cache") catch {};

    // Manifest path was taken (not the script carve-out): the
    // diagnostic must be a manifest/target error, never the
    // script-contract "top-level function" message.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "no top-level function") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "must be named `main`") == null);
}

test "CLI dispatch regression: <target> -- args still uses the manifest path" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeStdlibResolverProject(tmp_dir.dir);
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    // `zap run test_prog -- a b` — the positional is a manifest
    // target name (no such on-disk file), so the manifest path
    // runs unchanged and the program still produces its marker.
    try buildAndRunStdlibResolverProject(
        allocator,
        &tmp_dir,
        tmp_dir_path,
        &.{ "--", "a", "b" },
        &.{},
    );
}

test "CLI dispatch: a leading removed-flag-looking token is NOT a recognized flag (clean manifest rejection, no swallow/hang)" {
    // Phase 4 deleted the two-token `-O`/`--memory`/`--target`
    // spellings; per the locked position contract ONLY `-D…` and
    // `--zap-lib-dir` are recognized leading flags. A bare `--target`
    // (etc.) BEFORE the positional is therefore NOT a recognized,
    // value-consuming flag — it is itself the first positional
    // candidate. Since it is not an on-disk file, dispatch correctly
    // falls to the manifest path and the invocation is rejected
    // CLEANLY (non-zero exit, the manifest "unexpected argument"
    // diagnostic) — never a hang, a crash, or silent success. This is
    // the contract-correct behavior; the regression this guards is the
    // dead `firstPositionalIndex` entries that used to treat the token
    // as value-consuming and additionally SWALLOW the following token
    // (a script path) — which `firstPositionalIndex`'s own unit tests
    // pin, and which would never even reach this clean rejection.
    inline for (.{ "--target", "--memory", "-O" }) |stale_flag| {
        const allocator = std.testing.allocator;
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        // A real script file IS present in the tmp dir; the point is
        // that `<stale_flag> <script>` does NOT reach script dispatch
        // (the flag, not the file, is the first positional candidate).
        var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "disp.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("dispatched-to-script")
            \\  "ok"
            \\  0
            \\}
        , &.{stale_flag}, &.{});
        defer r.deinit();

        // Cleanly rejected via the manifest path, not run as a script.
        try std.testing.expect(r.exit_code != 0);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "dispatched-to-script") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unexpected argument") != null);
        // No script-contract diagnostic (it never entered script mode).
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "top-level function") == null);
        try expectOnlyScriptInDir(&tmp_dir, "disp.zap");
    }
}

test "CLI dispatch: removed-flag-looking tokens AFTER the script path forward to main/1 verbatim (real D3 guard)" {
    // The genuine D3/position guarantee the dead `firstPositionalIndex`
    // entries threatened: EVERYTHING after the script path is opaque
    // passthrough. A `--memory` / `--target` / `-O` token placed AFTER
    // the script path is NOT consumed as a build flag — it is forwarded
    // verbatim to `main/1`'s `[String]`. The script builds NATIVE and
    // RUNS, observing every post-path token as an argument. (A literal
    // `--` is likewise forwarded, not a separator — pinned elsewhere.)
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "fwd.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("argc=" <> Integer.to_string(System.arg_count()))
        \\  IO.puts("a0=" <> System.arg_at(0))
        \\  IO.puts("a1=" <> System.arg_at(1))
        \\  IO.puts("a2=" <> System.arg_at(2))
        \\  IO.puts("fwd-ran")
        \\  "ok"
        \\  0
        \\}
    , &.{}, &.{ "--memory", "Memory.NoOp", "-O" });
    defer r.deinit();

    // It RAN natively (not "Cross-compiled for ...", not a memory-mode
    // error) and saw the three post-path tokens verbatim, in order.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "fwd-ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "argc=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a0=--memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a1=Memory.NoOp") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a2=-O") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Cross-compiled for") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unsupported memory manager") == null);
    try expectOnlyScriptInDir(&tmp_dir, "fwd.zap");
}

// ============================================================
// CLI: unified Zig-style `-D<key>=<value>` build flags
//
// Phase 4. ONE parser + ONE per-field override step shared by
// `zap build <target>`, `zap run <target>` (manifest), and
// `zap run <file.zap>` (script). Syntax is Zig-build-style
// `-D<key>=<value>` ONLY (the legacy `-O`/`--memory` spellings
// were removed). Recognized keys: `-Doptimize=`, `-Dmemory=`,
// `-Dtarget=`, `-Dcpu=`. The CLI is the ultimate per-field
// source of truth: a set flag overrides the manifest/synthetic
// default; an unset flag preserves it. Script-mode flags are
// consumed before the script path (never forwarded to main/1);
// everything after the path forwards verbatim. Invalid/missing
// values yield a clear `Error:`-prefixed diagnostic + non-zero
// exit. Memory.Tracking / Memory.Leak may emit stats to stderr,
// so those cases assert on stdout only.
// ============================================================

// ---- Manifest-mode harness -------------------------------------
// Writes a project whose `build.zap` declares a specific
// `optimize:` and `memory:` plus a runtime marker, builds it
// with the supplied `-D` flags, runs the binary, and returns the
// captured output. This is the manifest analogue of
// `runScriptInTmp*`, used to prove the CLI overrides the
// manifest per-field for `zap build` and `zap run <target>`.

const ManifestRunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *ManifestRunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Build (`subcommand` = "build") or build+run (`subcommand` =
/// "run") the target `cli` in a tmp project whose `build.zap`
/// sets `manifest_memory` (a Type expression, e.g. "Memory.ARC")
/// and `manifest_optimize` (an atom, e.g. ":release_fast"), with
/// `flags` placed before the target name. Returns the captured
/// process result (for "build" the build output; for "run" the
/// program's stdout/exit).
fn runManifestProject(
    allocator: std.mem.Allocator,
    subcommand: []const u8,
    manifest_optimize: []const u8,
    manifest_memory: []const u8,
    flags: []const []const u8,
) TestError!ManifestRunResult {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source = std.fmt.allocPrint(allocator,
        \\pub struct Cli.Builder {{
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {{
        \\    case env.target {{
        \\      :cli ->
        \\        %Zap.Manifest{{
        \\          name: "cli",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &Cli.main/1,
        \\          optimize: {s},
        \\          memory: {s},
        \\          paths: ["lib/**/*.zap"]
        \\        }}
        \\      _ ->
        \\        panic("Unknown target")
        \\    }}
        \\  }}
        \\}}
    , .{ manifest_optimize, manifest_memory }) catch return error.OutOfMemory;
    defer allocator.free(build_source);

    const prog_source =
        \\pub struct Cli {
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    s = "a" <> "b" <> "c"
        \\    IO.puts("manifest-marker=" <> s)
        \\    "ok"
        \\    0
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/cli.zap", .data = prog_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, subcommand);
    for (flags) |f| try argv.append(allocator, f);
    try argv.append(allocator, "cli");

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    var stdout = result.stdout;
    var stderr = result.stderr;

    var exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => {
            allocator.free(stdout);
            allocator.free(stderr);
            return error.RunFailed;
        },
    };

    // For `run`, the build prints to stdout then the program runs;
    // we want the program's behavior. For `build`, the build output
    // is what we assert on. Either way, run the produced binary for
    // the "run" subcommand semantics already handled by `zap run`.
    if (std.mem.eql(u8, subcommand, "build") and exit_code == 0) {
        // Execute the produced binary so the manifest marker (and any
        // manager stderr) is observable, mirroring what `zap run`
        // would do, without depending on `zap run`'s own dispatch.
        const bin_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/cli", allocator) catch {
            return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code, .allocator = allocator };
        };
        defer allocator.free(bin_path);
        const run2 = std.process.run(allocator, getTestIo(), .{
            .argv = &.{bin_path},
            .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
            .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
        }) catch {
            return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code, .allocator = allocator };
        };
        allocator.free(stdout);
        allocator.free(stderr);
        stdout = run2.stdout;
        stderr = run2.stderr;
        exit_code = switch (run2.term) {
            .exited => |c| c,
            else => 255,
        };
    }

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

test "CLI script flags: -Doptimize runs under each Zig optimize mode" {
    const allocator = std.testing.allocator;
    inline for (.{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" }) |mode| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "opt.zap",
            \\fn main(_args :: [String]) -> u8 {
            \\  IO.puts("opt-ok=" <> Integer.to_string(2 + 3))
            \\  "ok"
            \\  0
            \\}
        , &.{"-Doptimize=" ++ mode}, &.{});
        defer r.deinit();

        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "opt-ok=5") != null);
        try expectOnlyScriptInDir(&tmp_dir, "opt.zap");
    }
}

test "CLI script flags: default (no -Doptimize) runs in Debug" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "optdef.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("default-opt-ok")
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "default-opt-ok") != null);
    try expectOnlyScriptInDir(&tmp_dir, "optdef.zap");
}

test "CLI script flags: -Dmemory runs under each stdlib manager" {
    const allocator = std.testing.allocator;
    inline for (.{
        "Memory.ARC",
        "Memory.Arena",
        "Memory.NoOp",
        "Memory.Leak",
        "Memory.Tracking",
    }) |mgr| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "mem.zap",
            \\pub struct Builder {
            \\  pub fn join(n :: i64, acc :: String) -> String {
            \\    if n <= 0 {
            \\      acc
            \\    } else {
            \\      Builder.join(n - 1, acc <> Integer.to_string(n))
            \\    }
            \\  }
            \\}
            \\
            \\fn main(_args :: [String]) -> u8 {
            \\  s = Builder.join(5, "")
            \\  IO.puts("mem-ok=" <> s)
            \\  "ok"
            \\  0
            \\}
        , &.{"-Dmemory=" ++ mgr}, &.{});
        defer r.deinit();

        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "mem-ok=54321") != null);
        try expectOnlyScriptInDir(&tmp_dir, "mem.zap");
    }
}

test "CLI script flags: default (no -Dmemory) runs with Memory.ARC" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmp(allocator, &tmp_dir, "memdef.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  s = "x" <> "y" <> "z"
        \\  IO.puts("mem-default-ok=" <> s)
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "mem-default-ok=xyz") != null);
    try expectOnlyScriptInDir(&tmp_dir, "memdef.zap");
}

test "CLI script flags: combined -Doptimize and -Dmemory before the path" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "combo.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("combo-ok")
        \\  "ok"
        \\  0
        \\}
    , &.{ "-Doptimize=ReleaseFast", "-Dmemory=Memory.Arena" }, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "combo-ok") != null);
    try expectOnlyScriptInDir(&tmp_dir, "combo.zap");
}

test "CLI script flags error: invalid -Doptimize value is rejected" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "badopt.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("never-runs")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Doptimize=ReleaseTurbo"}, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown optimize mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "ReleaseTurbo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "never-runs") == null);
    try expectOnlyScriptInDir(&tmp_dir, "badopt.zap");
}

test "CLI script flags error: -Doptimize with no value is rejected" {
    const allocator = std.testing.allocator;
    // `zap run -Doptimize script.zap` — `-D` flag with no `=`.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "noval.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("never-runs")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Doptimize"}, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "optimize") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "never-runs") == null);
}

test "CLI script flags error: third-party -Dmemory is rejected (no dep graph)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "badmem.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("never-runs")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Dmemory=MyApp.CustomArena"}, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unsupported memory manager") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "MyApp.CustomArena") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "never-runs") == null);
    try expectOnlyScriptInDir(&tmp_dir, "badmem.zap");
}

test "CLI build flags error: unknown -D key lists supported keys" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Script mode has no manifest/`System.get_build_opt` consumer, so
    // an unknown `-D` key is a hard error that lists the keys.
    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "unk.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("never-runs")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Dnonsense=1"}, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "nonsense") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "optimize") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "never-runs") == null);
}

test "CLI script flags: -D flags consumed, post-path args forward verbatim" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // `zap run -Doptimize=ReleaseSafe -Dmemory=Memory.Arena
    //     <echo.zap> -Doptimize=foo -- x`
    // The leading `-D` flags are consumed; EVERYTHING after the
    // script path (including a `-D`-looking token and a literal
    // `--`) forwards to main/1 verbatim and opaquely.
    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "echo.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  n = System.arg_count()
        \\  IO.puts("argc=" <> Integer.to_string(n))
        \\  IO.puts("a0=" <> System.arg_at(0))
        \\  IO.puts("a1=" <> System.arg_at(1))
        \\  IO.puts("a2=" <> System.arg_at(2))
        \\  "ok"
        \\  0
        \\}
    , &.{ "-Doptimize=ReleaseSafe", "-Dmemory=Memory.Arena" }, &.{ "-Doptimize=foo", "--", "x" });
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // The post-path region is opaque: the `-D`-looking token, the
    // literal `--`, and `x` ALL reach main/1 verbatim, in order.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "argc=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a0=-Doptimize=foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a1=--") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a2=x") != null);
    try expectOnlyScriptInDir(&tmp_dir, "echo.zap");
}

// ---- Manifest-mode override scenarios -----------------------------

test "CLI manifest: -Doptimize=Debug overrides manifest optimize: :release_fast (zap build)" {
    const allocator = std.testing.allocator;
    // The manifest declares release_fast; the CLI forces Debug. The
    // robust observable is that the build SUCCEEDS end-to-end under
    // the override and the binary runs correctly — exercising the
    // full CTFE→applyBuildOverrides→compileAndLink path with the CLI
    // value, not the manifest value.
    var r = try runManifestProject(allocator, "build", ":release_fast", "Memory.ARC", &.{"-Doptimize=Debug"});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manifest-marker=abc") != null);
}

test "CLI manifest: -Doptimize overrides manifest for zap run <target>" {
    const allocator = std.testing.allocator;
    var r = try runManifestProject(allocator, "run", ":release_fast", "Memory.ARC", &.{"-Doptimize=Debug"});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manifest-marker=abc") != null);
}

test "CLI manifest: -Dmemory overrides manifest memory: (Leak emits stats)" {
    const allocator = std.testing.allocator;
    // Manifest says Memory.ARC; `-Dmemory=Memory.Leak` overrides it.
    // Memory.Leak is observably different — it emits a leak report to
    // stderr on exit — proving the CLI memory value replaced the
    // manifest one through the unified override step.
    var r = try runManifestProject(allocator, "build", ":release_safe", "Memory.ARC", &.{"-Dmemory=Memory.Leak"});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manifest-marker=abc") != null);
    // Memory.Leak's distinctive end-of-run accounting on stderr.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak") != null or
        std.mem.indexOf(u8, r.stderr, "Leak") != null);
}

test "CLI manifest: unresolvable -Dmemory errors like a bad manifest memory:" {
    const allocator = std.testing.allocator;
    // Manifest mode resolves `-Dmemory=` through the SAME memory
    // driver a manifest `memory:` uses, so a name no dep provides
    // fails the build the same way an unresolvable manifest value
    // would (NOT the script-mode stdlib-only message — manifest mode
    // keeps third-party support, this name just doesn't exist).
    var r = try runManifestProject(allocator, "build", ":release_safe", "Memory.ARC", &.{"-Dmemory=Totally.Missing"});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
}

test "CLI manifest: no -D flags keeps the manifest values (regression)" {
    const allocator = std.testing.allocator;
    var r = try runManifestProject(allocator, "build", ":release_safe", "Memory.ARC", &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manifest-marker=abc") != null);
}

// ---- stdlib manager selection matrix (build pipeline) -------------
// Build-time replacement for the deleted runtime
// `Memory.Manager.backend(...)` Zest cases
// (`test/zap/memory_manager_test.zap` and the WIP
// `test/zap/memory/manager_test.zap`). Backend resolution is a
// build-time concern — Phase 3 removed the runtime `backend/1`
// mechanism — so the architecturally-correct surface is the build
// pipeline against the REAL stdlib `lib/memory/<x>.zap` adapter and
// `src/memory/<x>/manager.zig` backend.
//
// The deleted .zap cases only ever asserted `backend(X) == true` for
// ARC, Arena, Leak, Tracking, NoOp. This matrix is strictly stronger:
// for each of those five managers AND the default/omitted case it
// drives a real end-to-end build (CTFE manifest -> source-graph
// resolve -> compile the real backend -> validate `.zapmem` ->
// thread `declared_caps` -> link) and then RUNS the produced binary,
// asserting it executes correctly. The companion
// `src/builder.zig` resolver matrix asserts the
// selection -> backend-source -> REFCOUNT_V1-caps invariant per
// manager; together they cover strictly more than the removed runtime
// assertion (which never built or ran anything).

/// Build+run a tmp project whose `build.zap` either sets
/// `memory: <manifest_memory>` (when non-null) or OMITS the field
/// entirely (when null, exercising the default `Memory.ARC` path).
/// Returns the produced binary's captured stdout/stderr/exit.
fn runManifestMemoryProject(
    allocator: std.mem.Allocator,
    manifest_memory: ?[]const u8,
) TestError!ManifestRunResult {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const memory_line = if (manifest_memory) |m|
        std.fmt.allocPrint(allocator, "          memory: {s},\n", .{m}) catch return error.OutOfMemory
    else
        allocator.dupe(u8, "") catch return error.OutOfMemory;
    defer allocator.free(memory_line);

    const build_source = std.fmt.allocPrint(allocator,
        \\pub struct Cli.Builder {{
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {{
        \\    case env.target {{
        \\      :cli ->
        \\        %Zap.Manifest{{
        \\          name: "cli",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &Cli.main/1,
        \\{s}          paths: ["lib/**/*.zap"]
        \\        }}
        \\      _ ->
        \\        panic("Unknown target")
        \\    }}
        \\  }}
        \\}}
    , .{memory_line}) catch return error.OutOfMemory;
    defer allocator.free(build_source);

    const prog_source =
        \\pub struct Cli {
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    s = "m" <> "a" <> "n"
        \\    IO.puts("manager-marker=" <> s)
        \\    "ok"
        \\    0
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/cli.zap", .data = prog_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;

    const build_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "build", "cli" },
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;
    allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    const build_exit: u8 = switch (build_result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (build_exit != 0) {
        return .{
            .stdout = allocator.dupe(u8, "") catch return error.OutOfMemory,
            .stderr = allocator.dupe(u8, build_result.stderr) catch return error.OutOfMemory,
            .exit_code = build_exit,
            .allocator = allocator,
        };
    }

    const bin_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/cli", allocator) catch
        return error.CompilationFailed;
    defer allocator.free(bin_path);

    const run = std.process.run(allocator, getTestIo(), .{
        .argv = &.{bin_path},
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    return .{
        .stdout = run.stdout,
        .stderr = run.stderr,
        .exit_code = switch (run.term) {
            .exited => |c| c,
            else => 255,
        },
        .allocator = allocator,
    };
}

test "stdlib manager matrix: each manager + default builds the real backend and runs" {
    const allocator = std.testing.allocator;

    // Exactly the managers the deleted runtime Zest cases targeted,
    // plus the default/omitted case. `null` => `memory:` omitted from
    // the manifest, exercising the default `Memory.ARC` resolution.
    const cases = [_]?[]const u8{
        null,
        "Memory.ARC",
        "Memory.Arena",
        "Memory.Leak",
        "Memory.Tracking",
        "Memory.NoOp",
    };

    inline for (cases) |manifest_memory| {
        var r = try runManifestMemoryProject(allocator, manifest_memory);
        defer r.deinit();

        // Selection -> backend -> link -> run end-to-end: a non-zero
        // exit here means the real `lib/memory/<x>.zap` adapter failed
        // to resolve, the real `src/memory/<x>/manager.zig` backend
        // failed to compile, the `.zapmem` section failed validation,
        // or the linked binary crashed. The deleted runtime assertion
        // could not catch any of these.
        if (r.exit_code != 0) {
            std.debug.print(
                "manager case {s} failed: exit={d}\nstderr:\n{s}\n",
                .{ manifest_memory orelse "<default>", r.exit_code, r.stderr },
            );
        }
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manager-marker=man") != null);
    }
}

// ---- target / cpu scenarios ---------------------------------------

test "CLI script: native default when neither manifest nor -Dtarget set" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // No `-Dtarget=`/`-Dcpu=` ⇒ the script builds and runs on the
    // host natively (the plain `zir_compilation_create` path).
    var r = try runScriptInTmp(allocator, &tmp_dir, "nat.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("native-ok")
        \\  "ok"
        \\  0
        \\}
    , &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "native-ok") != null);
}

test "CLI script: -Dcpu refines the native target (host build still runs)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // `-Dcpu=baseline` with no `-Dtarget=` takes the cross path
    // (triple "native", CPU explicit). "baseline" is valid for every
    // arch, so the host binary still builds and runs — proving cpu is
    // threaded into the fork's target query without breaking native.
    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "cpu.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("cpu-ok")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Dcpu=baseline"}, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "cpu-ok") != null);
    try expectOnlyScriptInDir(&tmp_dir, "cpu.zap");
}

test "CLI script error: invalid -Dcpu is rejected with a clear error" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "badcpu.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("never-runs")
        \\  "ok"
        \\  0
        \\}
    , &.{"-Dcpu=totally_not_a_cpu_model"}, &.{});
    defer r.deinit();

    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "never-runs") == null);
    // Strengthened: assert the diagnostic actually names the bad CPU,
    // not merely that *some* error occurred. The fork's
    // `std.Target.Query.parse` failure path writes
    // `invalid -Dcpu='<value>' for target` into the manager-`.o`
    // driver diagnostic, surfaced verbatim by Zap.
    try std.testing.expect(
        std.mem.indexOf(u8, r.stderr, "totally_not_a_cpu_model") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "-Dcpu") != null);
}

// ============================================================
// Cross-compilation via `-Dtarget=` — REAL successful cross
// builds (not just error paths).
//
// These prove `-Dtarget=` actually cross-compiles: the produced
// binary is inspected with `/usr/bin/file` and asserted to be for
// the requested NON-NATIVE arch/OS. `*-linux-musl` is used because
// the Zig fork bundles musl completely — no external toolchain is
// required, isolating a genuine fork/Zap bug from a missing-libc
// environment limitation.
// ============================================================

/// Result of a cross-build: the captured `zap build` process output
/// plus the `/usr/bin/file` description of the produced binary (empty
/// when the build failed / produced nothing).
const CrossBuildResult = struct {
    build_stdout: []const u8,
    build_stderr: []const u8,
    build_exit: u8,
    file_desc: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *CrossBuildResult) void {
        self.allocator.free(self.build_stdout);
        self.allocator.free(self.build_stderr);
        self.allocator.free(self.file_desc);
    }
};

/// Build a minimal manifest `:bin` project for `target_triple` (passed
/// as `-Dtarget=`) and return the build result plus `/usr/bin/file`'s
/// description of `zap-out/bin/cross`. When `target_triple` is null, a
/// native build is performed (no `-Dtarget=`). The produced binary is
/// NOT executed — cross binaries are foreign to the test host; the
/// `file` description is the portable correctness oracle.
fn runCrossBuild(
    allocator: std.mem.Allocator,
    target_triple: ?[]const u8,
) TestError!CrossBuildResult {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source =
        \\pub struct Cross.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :cross ->
        \\        %Zap.Manifest{
        \\          name: "cross",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &Cross.main/1,
        \\          paths: ["lib/**/*.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;
    const prog_source =
        \\pub struct Cross {
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    IO.puts("cross-ok")
        \\    "ok"
        \\    0
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/cross.zap", .data = prog_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "build");
    if (target_triple) |t| {
        const flag = std.fmt.allocPrint(allocator, "-Dtarget={s}", .{t}) catch
            return error.OutOfMemory;
        try argv.append(allocator, flag);
    }
    try argv.append(allocator, "cross");

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    // Free the per-flag allocation now that the child has been spawned.
    if (target_triple != null) allocator.free(argv.items[2]);

    const build_exit: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };

    // Inspect the produced binary with `/usr/bin/file`. If the build
    // failed there is no binary; `file_desc` stays empty.
    var file_desc: []const u8 = "";
    if (build_exit == 0) {
        const bin_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/cross", allocator) catch null;
        if (bin_path) |bp| {
            defer allocator.free(bp);
            const file_run = std.process.run(allocator, getTestIo(), .{
                .argv = &.{ "/usr/bin/file", "-b", bp },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
            }) catch null;
            if (file_run) |fr| {
                allocator.free(fr.stderr);
                file_desc = fr.stdout;
            }
        }
    }

    return .{
        .build_stdout = result.stdout,
        .build_stderr = result.stderr,
        .build_exit = build_exit,
        .file_desc = file_desc,
        .allocator = allocator,
    };
}

test "CLI cross: -Dtarget=aarch64-linux-musl produces an ARM aarch64 Linux ELF" {
    const allocator = std.testing.allocator;
    var r = try runCrossBuild(allocator, "aarch64-linux-musl");
    defer r.deinit();

    if (r.build_exit != 0) {
        std.debug.print(
            "\n=== cross build FAILED (expected success) ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.build_stdout, r.build_stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), r.build_exit);
    // Must be a Linux ELF for the aarch64 architecture — NOT the
    // macOS/host Mach-O. This is the proof that `-Dtarget=` actually
    // cross-compiled rather than silently building for the host.
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "ELF") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "Mach-O") == null);
}

test "CLI cross: -Dtarget=x86_64-linux-musl produces an x86-64 Linux ELF" {
    const allocator = std.testing.allocator;
    var r = try runCrossBuild(allocator, "x86_64-linux-musl");
    defer r.deinit();

    if (r.build_exit != 0) {
        std.debug.print(
            "\n=== cross build FAILED (expected success) ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.build_stdout, r.build_stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), r.build_exit);
    // Different ARCH than the host (aarch64) — proves arch retargeting.
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "ELF") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "x86-64") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "Mach-O") == null);
}

test "CLI cross: native build is unchanged (no -Dtarget regression)" {
    const allocator = std.testing.allocator;
    var r = try runCrossBuild(allocator, null);
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.build_exit);
    // The native macOS host build must still produce a host Mach-O
    // executable — the cross machinery must not perturb the native
    // path.
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "Mach-O") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "executable") != null);
}

test "CLI cross error: invalid -Dtarget fails loudly with a naming diagnostic and no binary" {
    const allocator = std.testing.allocator;
    var r = try runCrossBuild(allocator, "bogus-not-a-target");
    defer r.deinit();

    // Must be a hard failure — non-zero exit, NO produced binary, and
    // a diagnostic that names the offending triple. A silent `.Ok`
    // (exit 0) or a host-arch fallback binary is exactly the defect
    // this test guards.
    try std.testing.expect(r.build_exit != 0);
    try std.testing.expectEqualStrings("", r.file_desc);
    try std.testing.expect(
        std.mem.indexOf(u8, r.build_stderr, "bogus-not-a-target") != null,
    );
}

test "CLI cross error: invalid -Dtarget on USER-binary path is graceful (no process.fatal abort)" {
    const allocator = std.testing.allocator;
    // A syntactically-valid-looking but unresolvable triple. The point
    // is that NO path (manager-`.o` OR user-binary) may
    // `std.process.fatal`-abort the whole process: the failure must be
    // a clean non-zero exit with a diagnostic. An abort would manifest
    // as a signal/255 term, which `runCrossBuild` maps to exit 255 AND
    // would typically lack the structured diagnostic text.
    var r = try runCrossBuild(allocator, "aarch64-shenzhen-quux");
    defer r.deinit();

    try std.testing.expect(r.build_exit != 0);
    try std.testing.expectEqualStrings("", r.file_desc);
    // Graceful diagnostic naming the triple (proves a returned error,
    // not a hard abort).
    try std.testing.expect(
        std.mem.indexOf(u8, r.build_stderr, "aarch64-shenzhen-quux") != null,
    );
}

// ============================================================
// Defect-2 regression: a `-D` flag placed AFTER the build
// target must still be honored (not silently dropped).
// `zap build <proj> -Doptimize=...` — the override must reach
// the build. A dropped flag == test failure.
// ============================================================

test "CLI Defect-2 regression: -Doptimize AFTER the target is honored" {
    const allocator = std.testing.allocator;
    // `runManifestProject` places `flags` BEFORE the target; here we
    // need the flag AFTER the target, so drive the build directly.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    // Manifest declares :debug; the post-target `-Doptimize=ReleaseFast`
    // must override it. The program prints a marker so a successful,
    // correctly-built binary is observable.
    const build_source =
        \\pub struct D2.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :d2 ->
        \\        %Zap.Manifest{
        \\          name: "d2",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &D2.main/1,
        \\          optimize: :debug,
        \\          paths: ["lib/**/*.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    ;
    const prog_source =
        \\pub struct D2 {
        \\  pub fn main(_args :: [String]) -> u8 {
        \\    IO.puts("d2-marker=ok")
        \\    "ok"
        \\    0
        \\  }
        \\}
    ;

    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "build.zap", .data = build_source }) catch
        return error.Unexpected;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/d2.zap", .data = prog_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;

    // Flag AFTER the target — the Defect-2 scenario.
    const argv_with = [_][]const u8{ zap_binary, "build", "d2", "-Doptimize=ReleaseFast" };
    const with_run = std.process.run(allocator, getTestIo(), .{
        .argv = &argv_with,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;
    defer allocator.free(with_run.stdout);
    defer allocator.free(with_run.stderr);

    const with_exit: u8 = switch (with_run.term) {
        .exited => |c| c,
        else => 255,
    };
    // The build must succeed with the post-target flag applied. If the
    // flag were dropped the build would still succeed too, so the real
    // discriminator is that the flag is ACCEPTED and PARSED rather than
    // being treated as a stray positional/unknown token: a dropped
    // flag historically caused either a target-parse error or an
    // "unknown build flag" diagnostic. Assert a clean success AND that
    // no flag-parse error leaked to stderr.
    if (with_exit != 0) {
        std.debug.print(
            "\n=== Defect-2: post-target -D flag build FAILED ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ with_run.stdout, with_run.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), with_exit);
    try std.testing.expect(std.mem.indexOf(u8, with_run.stderr, "unknown build flag") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_run.stderr, "could not parse target") == null);

    // Run the produced binary to confirm it built correctly.
    const bin_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), "zap-out/bin/d2", allocator) catch
        return error.Unexpected;
    defer allocator.free(bin_path);
    const prog_run = std.process.run(allocator, getTestIo(), .{
        .argv = &.{bin_path},
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;
    defer allocator.free(prog_run.stdout);
    defer allocator.free(prog_run.stderr);
    try std.testing.expect(std.mem.indexOf(u8, prog_run.stdout, "d2-marker=ok") != null);
}

// ============================================================
// Single-file SCRIPT cross-compilation via `zap run <file>
// -Dtarget=<foreign>`. This locks the script-path defect fix:
// the script path used to UNCONDITIONALLY exec the produced
// binary, so a cross build for a foreign arch/OS died with a
// cryptic `error.InvalidExe` (exit 1). Correct behavior: the
// cross-build SUCCEEDS, the foreign binary is NOT executed, the
// artifact path is reported, and the process exits 0 — exactly
// like `zap build -Dtarget=<foreign>`.
//
// `*-linux-musl` is used because the Zig fork bundles musl
// completely (no external toolchain), isolating a genuine
// fork/Zap bug from a missing-libc environment limitation.
// ============================================================

/// Result of a `zap run <script> -Dtarget=<t>` cross run: the
/// process output plus `/usr/bin/file`'s description of the
/// artifact whose path the CLI printed in the
/// "binary written to <path>" line (empty when no such line /
/// the build failed).
const ScriptCrossResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    file_desc: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *ScriptCrossResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.allocator.free(self.file_desc);
    }
};

/// Extract the cross artifact path the CLI prints on a foreign
/// `zap run` cross build: `... binary written to <path>\n`. The
/// marker text is produced by `cmdRunScript`'s host-runnability
/// gate in `src/main.zig`; keep these in sync.
fn extractWrittenBinaryPath(stdout: []const u8) ?[]const u8 {
    const marker = "binary written to ";
    const start = std.mem.indexOf(u8, stdout, marker) orelse return null;
    const after = stdout[start + marker.len ..];
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    const path = std.mem.trim(u8, after[0..nl], " \t\r");
    if (path.len == 0) return null;
    return path;
}

/// Build (do NOT execute — it is foreign) a single-file script
/// for `target_triple` via `zap run -Dtarget=<t> <script>` (flag
/// BEFORE the path so it is consumed, not forwarded to `main/1`).
/// Returns the process result plus the `file` description of the
/// reported artifact.
fn runScriptCrossBuild(
    allocator: std.mem.Allocator,
    target_triple: []const u8,
) TestError!ScriptCrossResult {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const script_source =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("script-cross-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "sc.zap", .data = script_source }) catch
        return error.Unexpected;

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const script_path = std.fs.path.join(allocator, &.{ tmp_dir_path, "sc.zap" }) catch
        return error.OutOfMemory;
    defer allocator.free(script_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    const script_cache = std.fs.path.join(allocator, &.{ tmp_dir_path, "..", "zap-script-cache" }) catch
        return error.OutOfMemory;
    defer allocator.free(script_cache);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    const flag = std.fmt.allocPrint(allocator, "-Dtarget={s}", .{target_triple}) catch
        return error.OutOfMemory;
    defer allocator.free(flag);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;
    env_map.put("ZAP_SCRIPT_CACHE_DIR", script_cache) catch return error.OutOfMemory;

    // Flag BEFORE the script path ⇒ consumed as a build flag.
    const argv = [_][]const u8{ zap_binary, "run", flag, script_path };
    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &argv,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };

    // The CLI emits the "binary written to <path>" line via
    // `std.debug.print` ⇒ STDERR (along with all compile progress).
    var file_desc: []const u8 = "";
    if (extractWrittenBinaryPath(result.stderr)) |bin_path| {
        const file_run = std.process.run(allocator, getTestIo(), .{
            .argv = &.{ "/usr/bin/file", "-b", bin_path },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch null;
        if (file_run) |fr| {
            allocator.free(fr.stderr);
            file_desc = fr.stdout;
        }
    }

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
        .file_desc = file_desc,
        .allocator = allocator,
    };
}

test "CLI script cross: -Dtarget=x86_64-linux-musl builds a foreign x86-64 ELF, reports it, exits 0 (no InvalidExe)" {
    const allocator = std.testing.allocator;
    var r = try runScriptCrossBuild(allocator, "x86_64-linux-musl");
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "\n=== script cross build FAILED (expected success) ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.stdout, r.stderr },
        );
    }
    // The cross BUILD succeeded; the foreign binary was NOT run.
    // Before the fix this exited 1 with `error.InvalidExe`. The
    // CLI status line is emitted via `std.debug.print` ⇒ stderr,
    // and the script's `IO.puts` marker must be ABSENT from stdout
    // (proving the foreign binary genuinely did not execute).
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Cross-compiled for 'x86_64-linux-musl'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "not executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "script-cross-ok") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "InvalidExe") == null);
    // The reported artifact is genuinely a foreign x86-64 Linux ELF
    // — proves the script path actually cross-compiled (not a host
    // Mach-O, not a silently-native build).
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "ELF") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "x86-64") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "Mach-O") == null);
}

test "CLI script cross: -Dtarget=aarch64-linux-musl builds a foreign ARM aarch64 ELF (host arch, foreign OS)" {
    const allocator = std.testing.allocator;
    var r = try runScriptCrossBuild(allocator, "aarch64-linux-musl");
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "\n=== script cross build FAILED (expected success) ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.stdout, r.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Cross-compiled for 'aarch64-linux-musl'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "script-cross-ok") == null);
    // Foreign-OS ELF even though the arch matches the macOS host —
    // the OS differs, so it is still not host-runnable.
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "ELF") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.file_desc, "Mach-O") == null);
}

test "CLI script cross error: invalid -Dtarget fails loudly with a naming diagnostic and no run" {
    const allocator = std.testing.allocator;
    var r = try runScriptCrossBuild(allocator, "bogus-not-a-target");
    defer r.deinit();

    // Hard failure: non-zero exit, the script body never ran, and
    // the diagnostic NAMES the offending triple (a returned error,
    // not a silent `.Ok`/host fallback and not a process abort).
    try std.testing.expect(r.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "script-cross-ok") == null);
    try std.testing.expectEqualStrings("", r.file_desc);
    try std.testing.expect(
        std.mem.indexOf(u8, r.stderr, "bogus-not-a-target") != null,
    );
}

test "CLI script cross: -Dtarget AFTER the script path is opaque passthrough (forwarded to main/1, native build runs)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Per the locked position contract, EVERYTHING after the script
    // path forwards to `main/1` verbatim — a `-Dtarget=`-looking
    // token there is NOT a build flag. So the script builds NATIVE
    // and RUNS on the host, receiving the token as an arg. This
    // guards against a regression where post-path `-D` tokens are
    // wrongly consumed as build flags (a silent wrong-arch build).
    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "pass.zap",
        \\fn main(args :: [String]) -> u8 {
        \\  IO.puts("passthrough-ran")
        \\  "ok"
        \\  0
        \\}
    , &.{}, &.{"-Dtarget=x86_64-linux-musl"});
    defer r.deinit();

    // Native build + run on the host: it MUST execute (exit 0) and
    // print its marker — a cross build would instead print
    // "Cross-compiled for ..." and never run.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "passthrough-ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Cross-compiled for") == null);
}

// ============================================================
// Phase 5: content-addressed script caching
//
// An UNCHANGED script must re-run with NO recompilation and
// still write NOTHING next to the script. The script artifact
// directory's previously-random component is replaced by a
// strong CONTENT KEY over: the script source, the resolved
// stdlib identity, the compiler identity, and every post-
// override build control (optimize/memory/target/cpu). On a
// second run with an identical key the frontend+backend+link
// are skipped entirely and the cached binary is exec'd; the
// fast path prints a stable `[script-cache hit]` marker to
// stderr (mirroring the manifest path's `[cached]` signal —
// std.debug.print ⇒ stderr, so the script's own stdout is
// never polluted). Any input change (source edit, a flipped
// `-D` flag, a different stdlib) yields a distinct key and a
// fresh compile (no `[script-cache hit]`).
//
// These share ONE `ZAP_SCRIPT_CACHE_DIR` across both runs (the
// real cross-invocation scenario) while keeping the script's
// own dir isolated so the no-litter assertion stays exact.
// ============================================================

const SCRIPT_CACHE_HIT_MARKER = "[script-cache hit]";

const TwoRunResult = struct {
    first: ScriptRunResult,
    second: ScriptRunResult,

    fn deinit(self: *TwoRunResult) void {
        self.first.deinit();
        self.second.deinit();
    }
};

/// The per-test-unique shared `ZAP_SCRIPT_CACHE_DIR` for a test whose
/// tmp dir realpath is `tmp_dir_path`: a `-skcache` SIBLING of the
/// tmp dir. SINGLE source of truth so the spawner and
/// `countScriptKeyDirs` always resolve the IDENTICAL location, and
/// per-test-unique (tmp dir names are unique) so concurrently- or
/// sequentially-run Phase 5 tests can never see each other's keys.
/// A sibling (not a child) keeps it out of the script's own dir so
/// the no-litter assertion on the tmp dir stays exact.
fn scriptSharedCachePath(
    allocator: std.mem.Allocator,
    tmp_dir_path: []const u8,
) TestError![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-skcache", .{tmp_dir_path}) catch
        return error.OutOfMemory;
}

/// Write `first_source` to `<tmp>/<script_name>`, run `zap run
/// [lead_flags...] <abs path> [extra_args...]`, then OPTIONALLY
/// overwrite the script with `second_source` (null ⇒ leave it
/// byte-identical) and run the exact same command again. BOTH
/// runs share the SAME off-tmp `ZAP_SCRIPT_CACHE_DIR` and the
/// SAME deterministic stdlib, so the content-addressed cache is
/// genuinely exercised across invocations. The caller owns
/// `tmp_dir` (to assert on its contents) and must `deinit` the
/// result. `second_lead_flags`/`second_extra_args` default to
/// the first run's when null so an "unchanged" run is literally
/// the same command.
fn runScriptTwiceSharedCache(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    script_name: []const u8,
    first_source: []const u8,
    second_source: ?[]const u8,
    lead_flags: []const []const u8,
    second_lead_flags: ?[]const []const u8,
    extra_args: []const []const u8,
) TestError!TwoRunResult {
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);

    // A SINGLE shared cache root for BOTH runs (so run 2 is a genuine
    // cross-invocation cache probe) that is also PER-TEST-UNIQUE and
    // OFF the script's own directory. `tmp_dir_path` is unique per
    // test (`std.testing.tmpDir`), so a `-skcache` SIBLING of it is
    // unique-per-test (tests never interfere) yet not inside the
    // script dir (so the no-litter assertion on the tmp dir stays
    // exact). Derived through the shared `scriptSharedCachePath` so
    // `countScriptKeyDirs` resolves the identical location.
    const script_cache = try scriptSharedCachePath(allocator, tmp_dir_path);
    defer allocator.free(script_cache);
    // Start clean so a prior run of THIS test can't pre-seed a hit.
    std.Io.Dir.cwd().deleteTree(getTestIo(), script_cache) catch {};

    const first = try runScriptWithCacheRoot(
        allocator,
        tmp_dir,
        tmp_dir_path,
        repo_lib,
        script_cache,
        script_name,
        first_source,
        lead_flags,
        extra_args,
    );

    const second = runScriptWithCacheRoot(
        allocator,
        tmp_dir,
        tmp_dir_path,
        repo_lib,
        script_cache,
        script_name,
        second_source orelse first_source,
        second_lead_flags orelse lead_flags,
        extra_args,
    ) catch |err| {
        var f = first;
        f.deinit();
        return err;
    };

    return .{ .first = first, .second = second };
}

/// Single spawn against an explicit (possibly shared) cache
/// root. Writes `script_source` to `<tmp>/<script_name>` then
/// runs `zap run [lead_flags...] <abs path> [extra_args...]`
/// with cwd = tmp, `ZAP_LIB_DIR` pinned to `repo_lib`, and
/// `ZAP_SCRIPT_CACHE_DIR` = `script_cache`.
fn runScriptWithCacheRoot(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    tmp_dir_path: []const u8,
    repo_lib: []const u8,
    script_cache: []const u8,
    script_name: []const u8,
    script_source: []const u8,
    lead_flags: []const []const u8,
    extra_args: []const []const u8,
) TestError!ScriptRunResult {
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = script_name, .data = script_source }) catch
        return error.Unexpected;

    const script_path = std.fs.path.join(allocator, &.{ tmp_dir_path, script_name }) catch
        return error.OutOfMemory;
    defer allocator.free(script_path);

    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zap_binary);
    try argv.append(allocator, "run");
    for (lead_flags) |f| try argv.append(allocator, f);
    try argv.append(allocator, script_path);
    for (extra_args) |a| try argv.append(allocator, a);

    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;
    env_map.put("ZAP_SCRIPT_CACHE_DIR", script_cache) catch return error.OutOfMemory;

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = tmp_dir_path },
        .environ_map = &env_map,
        .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
    }) catch return error.RunFailed;

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.RunFailed;
        },
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

/// Count immediate entries under `script_cache`/zap/scripts —
/// i.e. how many distinct content-key directories exist. A
/// cache HIT for an unchanged script keeps this at 1; a key
/// change adds a second sibling. Returns 0 when the tree is
/// absent (never created).
fn countScriptKeyDirs(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
) TestError!usize {
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);
    const script_cache = try scriptSharedCachePath(allocator, tmp_dir_path);
    defer allocator.free(script_cache);
    const scripts_dir = std.fs.path.join(allocator, &.{ script_cache, "zap", "scripts" }) catch
        return error.OutOfMemory;
    defer allocator.free(scripts_dir);

    var dir = std.Io.Dir.cwd().openDir(getTestIo(), scripts_dir, .{ .iterate = true }) catch
        return 0;
    defer dir.close(getTestIo());
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(getTestIo()) catch null) |_| n += 1;
    return n;
}

test "Phase5 script cache: unchanged script second run is a cache hit (no recompile), same output + exit" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "cached.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("cache-hit-marker")
        \\  "ok"
        \\  0
        \\}
    , null, &.{}, null, &.{});
    defer r.deinit();

    // Run 1: a genuine compile (no hit marker), correct output.
    try std.testing.expectEqual(@as(u8, 0), r.first.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.first.stdout, "cache-hit-marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.first.stderr, SCRIPT_CACHE_HIT_MARKER) == null);

    // Run 2: identical key ⇒ frontend+backend+link SKIPPED. The
    // fast-path marker MUST be present and the program output +
    // exit code identical to a fresh build.
    try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "cache-hit-marker") != null);
    if (std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null) {
        std.debug.print(
            "\n=== expected cache HIT on 2nd run, got recompile ===\nstderr:\n{s}\n",
            .{r.second.stderr},
        );
        return error.Unexpected;
    }
    // Exactly ONE content-key dir (the unchanged script reused it).
    try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    // Still nothing beside the script after BOTH runs.
    try expectOnlyScriptInDir(&tmp_dir, "cached.zap");
}

test "Phase5 script cache: editing the script source forces a recompile (new key)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "edit.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("v1-output")
        \\  "ok"
        \\  0
        \\}
    ,
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("v2-output")
        \\  "ok"
        \\  0
        \\}
    , &.{}, null, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.first.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.first.stdout, "v1-output") != null);

    // Different source ⇒ different content key ⇒ NO hit, fresh
    // compile, and the NEW behavior runs.
    try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "v2-output") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "v1-output") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
    // Two distinct keys now coexist under the shared root.
    try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
    try expectOnlyScriptInDir(&tmp_dir, "edit.zap");
}

test "Phase5 script cache: -Doptimize change recompiles, unchanged hits" {
    const allocator = std.testing.allocator;
    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("opt-key-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    // Same flag twice ⇒ HIT.
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "o.zap", script, null, &.{"-Doptimize=ReleaseSafe"}, null, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
        try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    }
    // Flag flipped between runs ⇒ MISS (distinct key).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "o.zap", script, null, &.{"-Doptimize=Debug"}, &.{"-Doptimize=ReleaseFast"}, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
        try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
    }
}

test "Phase5 script cache: -Dmemory change recompiles, unchanged hits" {
    const allocator = std.testing.allocator;
    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("mem-key-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "m.zap", script, null, &.{"-Dmemory=Memory.Arena"}, null, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
        try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    }
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "m.zap", script, null, &.{"-Dmemory=Memory.ARC"}, &.{"-Dmemory=Memory.NoOp"}, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
        try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
    }
}

test "Phase5 script cache: -Dcpu change recompiles, unchanged hits (still host-runnable)" {
    const allocator = std.testing.allocator;
    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("cpu-key-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "c.zap", script, null, &.{"-Dcpu=baseline"}, null, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "cpu-key-ok") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
        try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    }
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        // baseline vs native: two distinct CPU strings ⇒ two keys.
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "c.zap", script, null, &.{"-Dcpu=baseline"}, &.{"-Dcpu=native"}, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
        try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
    }
}

test "Phase5 script cache: -Dtarget change yields a distinct key (foreign target still reported, exit 0)" {
    const allocator = std.testing.allocator;
    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("tgt-key-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    // Same foreign target twice ⇒ HIT (the reported-artifact path
    // is cached too — second run still reports + exits 0, no
    // recompile, never execs the foreign binary).
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "t.zap", script, null, &.{"-Dtarget=x86_64-linux-musl"}, null, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.first.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.first.stderr, "Cross-compiled for 'x86_64-linux-musl'") != null);
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "tgt-key-ok") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
        try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    }
    // Different target ⇒ distinct key, fresh cross build.
    {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "t.zap", script, null, &.{"-Dtarget=x86_64-linux-musl"}, &.{"-Dtarget=aarch64-linux-musl"}, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, "Cross-compiled for 'aarch64-linux-musl'") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
        try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
    }
}

/// Recursively copy directory `src_abs` into `dst_abs` (created if
/// absent), parents-before-children. Used to materialise a COMPLETE,
/// usable alternate Zap stdlib root at a fresh path.
fn copyTreeAbs(
    allocator: std.mem.Allocator,
    src_abs: []const u8,
    dst_abs: []const u8,
) TestError!void {
    std.Io.Dir.cwd().createDirPath(getTestIo(), dst_abs) catch return error.Unexpected;
    var src = std.Io.Dir.cwd().openDir(getTestIo(), src_abs, .{ .iterate = true }) catch
        return error.Unexpected;
    defer src.close(getTestIo());
    var dst = std.Io.Dir.cwd().openDir(getTestIo(), dst_abs, .{}) catch
        return error.Unexpected;
    defer dst.close(getTestIo());
    var walker = std.Io.Dir.walk(src, allocator) catch return error.Unexpected;
    defer walker.deinit();
    while (walker.next(getTestIo()) catch null) |entry| {
        switch (entry.kind) {
            .directory => dst.createDirPath(getTestIo(), entry.path) catch {},
            .file => {
                if (std.fs.path.dirname(entry.path)) |d|
                    dst.createDirPath(getTestIo(), d) catch {};
                src.copyFile(entry.path, dst, entry.path, getTestIo(), .{}) catch
                    return error.Unexpected;
            },
            else => {},
        }
    }
}

test "Phase5 script cache: a different --zap-lib-dir (different stdlib) yields a distinct key (no false hit)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);
    // The stdlib source-tree ROOT is the parent of `lib/`; it also
    // holds the `src/memory/<mgr>/manager.zig` backends the managers
    // resolve by convention, so a USABLE alternate stdlib needs BOTH
    // `lib/` and `src/memory/` copied (a bare `lib/` copy cannot
    // build — that is a stdlib-completeness requirement, not a cache
    // concern).
    const repo_root = std.fs.path.dirname(repo_lib) orelse return error.Unexpected;
    const repo_src_memory = std.fs.path.join(allocator, &.{ repo_root, "src", "memory" }) catch
        return error.OutOfMemory;
    defer allocator.free(repo_src_memory);

    // Materialise a COMPLETE alternate stdlib at a fresh path inside
    // the (per-test-unique) tmp dir: same CONTENTS as the repo
    // stdlib, but a different resolved path. The content key MUST
    // still differ because the resolved stdlib dir is part of its
    // identity — proving no false hit across stdlibs and no
    // accidental path-insensitivity, while still being a buildable
    // stdlib so run 2 genuinely succeeds.
    const alt_root = std.fs.path.join(allocator, &.{ tmp_dir_path, "alt-stdlib" }) catch
        return error.OutOfMemory;
    defer allocator.free(alt_root);
    const alt_lib = std.fs.path.join(allocator, &.{ alt_root, "lib" }) catch
        return error.OutOfMemory;
    defer allocator.free(alt_lib);
    const alt_src_memory = std.fs.path.join(allocator, &.{ alt_root, "src", "memory" }) catch
        return error.OutOfMemory;
    defer allocator.free(alt_src_memory);
    try copyTreeAbs(allocator, repo_lib, alt_lib);
    try copyTreeAbs(allocator, repo_src_memory, alt_src_memory);

    // Per-test-unique shared cache root (the shared single-source
    // location) so the key-dir count is exact and tests never
    // interfere.
    const script_cache = try scriptSharedCachePath(allocator, tmp_dir_path);
    defer allocator.free(script_cache);
    std.Io.Dir.cwd().deleteTree(getTestIo(), script_cache) catch {};

    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("stdlib-key-ok")
        \\  "ok"
        \\  0
        \\}
    ;

    // Run 1 with the repo stdlib.
    var r1 = try runScriptWithCacheRoot(allocator, &tmp_dir, tmp_dir_path, repo_lib, script_cache, "sl.zap", script, &.{}, &.{});
    defer r1.deinit();
    if (r1.exit_code != 0)
        std.debug.print("\n=== run1 FAILED ===\nstderr:\n{s}\n", .{r1.stderr});
    try std.testing.expectEqual(@as(u8, 0), r1.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "stdlib-key-ok") != null);

    // Run 2 with the alternate (same-content, different-path)
    // COMPLETE stdlib via --zap-lib-dir. Identity differs ⇒ NO false
    // hit, a fresh compile, a distinct key dir — and it still builds
    // and runs because the alternate stdlib is complete.
    var r2 = try runScriptWithCacheRoot(allocator, &tmp_dir, tmp_dir_path, repo_lib, script_cache, "sl.zap", script, &.{ "--zap-lib-dir", alt_lib }, &.{});
    defer r2.deinit();
    if (r2.exit_code != 0)
        std.debug.print("\n=== run2 FAILED ===\nstderr:\n{s}\n", .{r2.stderr});
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "stdlib-key-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, SCRIPT_CACHE_HIT_MARKER) == null);
    try std.testing.expectEqual(@as(usize, 2), try countScriptKeyDirs(allocator, &tmp_dir));
}

test "Phase5 script cache: NOTHING is written next to the script after many runs (incl. cache hits)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);
    const script_cache = try scriptSharedCachePath(allocator, tmp_dir_path);
    defer allocator.free(script_cache);
    std.Io.Dir.cwd().deleteTree(getTestIo(), script_cache) catch {};

    const script =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("many-runs-ok")
        \\  "ok"
        \\  0
        \\}
    ;
    // 5 runs: run 1 compiles, runs 2-5 are cache hits. After ALL
    // of them the script's own dir must contain ONLY the script.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var r = try runScriptWithCacheRoot(allocator, &tmp_dir, tmp_dir_path, repo_lib, script_cache, "many.zap", script, &.{}, &.{});
        defer r.deinit();
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "many-runs-ok") != null);
        if (i > 0) {
            try std.testing.expect(std.mem.indexOf(u8, r.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
        }
        try expectOnlyScriptInDir(&tmp_dir, "many.zap");
    }
    // One key dir total across all 5 invocations.
    try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
}

test "Phase5 script cache: artifacts land under the cache root, not cwd/script dir" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "root.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("root-ok")
        \\  "ok"
        \\  0
        \\}
    , null, &.{}, null, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
    // The content-key dir tree exists under the explicit cache
    // root (proving the override is honored and artifacts do NOT
    // land in cwd/the script dir).
    try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    try expectOnlyScriptInDir(&tmp_dir, "root.zap");
}

test "Phase5 script cache: cache hit still forwards post-path args to main/1" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "argf.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  if System.arg_count() > 0 {
        \\    IO.puts("arg=" <> System.arg_at(0))
        \\  } else {
        \\    IO.puts("arg=NONE")
        \\  }
        \\  "ok"
        \\  0
        \\}
    , null, &.{}, null, &.{"forwarded-value"});
    defer r.deinit();

    // Run 1 compiles + forwards the arg.
    try std.testing.expectEqual(@as(u8, 0), r.first.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.first.stdout, "arg=forwarded-value") != null);
    // Run 2 is a cache HIT and STILL forwards the post-path arg
    // (the skip-recompile path execs with the same arg contract).
    try std.testing.expectEqual(@as(u8, 0), r.second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.second.stdout, "arg=forwarded-value") != null);
    try expectOnlyScriptInDir(&tmp_dir, "argf.zap");
}

test "Phase5 script cache: cache hit propagates a non-zero exit identically to a fresh build" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // `main/1` panics ⇒ non-zero exit on the FIRST (fresh) run.
    // The cached SECOND run must propagate the SAME non-zero exit
    // (the binary itself is unchanged; only compilation is
    // skipped — the runtime contract is identical).
    var r = try runScriptTwiceSharedCache(allocator, &tmp_dir, "fail.zap",
        \\fn main(_args :: [String]) -> u8 {
        \\  panic("boom")
        \\  "never"
        \\  0
        \\}
    , null, &.{}, null, &.{});
    defer r.deinit();

    try std.testing.expect(r.first.exit_code != 0);
    const first_code = r.first.exit_code;
    try std.testing.expect(std.mem.indexOf(u8, r.second.stderr, SCRIPT_CACHE_HIT_MARKER) != null);
    try std.testing.expectEqual(first_code, r.second.exit_code);
    try expectOnlyScriptInDir(&tmp_dir, "fail.zap");
}

/// Worker for the concurrency test: a self-contained blocking
/// `zap run <script>` against the SHARED cache root, on its own
/// page-backed arena (the testing allocator is single-thread).
/// Records whether this invocation produced the correct output
/// and exit 0.
const ConcurrentRunCtx = struct {
    tmp_dir_path: []const u8,
    script_path: []const u8,
    zap_binary: []const u8,
    /// Built ONCE on the main thread and shared read-only across all
    /// workers. `std.process.run` only READS `environ_map`, so a
    /// single shared const map is race-safe; building one per thread
    /// via `std.testing.environ.createMap` instead races on the
    /// test-runner's global environ snapshot.
    env_map: *const std.process.Environ.Map,
    ok: bool = false,

    fn run(self: *ConcurrentRunCtx) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const argv = [_][]const u8{ self.zap_binary, "run", self.script_path };
        const result = std.process.run(a, getTestIo(), .{
            .argv = &argv,
            .cwd = .{ .path = self.tmp_dir_path },
            .environ_map = self.env_map,
            .stdout_limit = .limited(COMPILE_OUTPUT_LIMIT),
            .stderr_limit = .limited(COMPILE_OUTPUT_LIMIT),
        }) catch return;

        const code = switch (result.term) {
            .exited => |c| c,
            else => return,
        };
        if (code == 0 and std.mem.indexOf(u8, result.stdout, "race-ok") != null) {
            self.ok = true;
        } else {
            std.debug.print(
                "\n=== concurrent run FAILED code={d} ===\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ code, result.stdout, result.stderr },
            );
        }
    }
};

test "Phase5 script cache: concurrent identical runs are race-safe (atomic publish)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);
    const script_cache = try scriptSharedCachePath(allocator, tmp_dir_path);
    defer allocator.free(script_cache);
    std.Io.Dir.cwd().deleteTree(getTestIo(), script_cache) catch {};

    const script_name = "race.zap";
    tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = script_name, .data =
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("race-ok")
        \\  "ok"
        \\  0
        \\}
    }) catch return error.Unexpected;
    const script_path = std.fs.path.join(allocator, &.{ tmp_dir_path, script_name }) catch
        return error.OutOfMemory;
    defer allocator.free(script_path);
    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);

    // Launch N identical `zap run <script>` processes CONCURRENTLY
    // (one OS thread each) against the SAME empty shared cache
    // root. They race to compile-and-publish the SAME content
    // key; the atomic rename publish must make every one of them
    // succeed with correct output and exit 0 (no torn binary, no
    // link/rename clobber, no half-written executable observed).
    // Build the child environment ONCE on the main thread; every
    // worker shares it read-only (race-safe — `std.process.run` only
    // reads it). Building it per-thread would race the test-runner's
    // global environ snapshot.
    var env_map = std.testing.environ.createMap(allocator) catch return error.Unexpected;
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    env_map.put("ZAP_LIB_DIR", repo_lib) catch return error.OutOfMemory;
    env_map.put("ZAP_SCRIPT_CACHE_DIR", script_cache) catch return error.OutOfMemory;

    const N = 4;
    var ctxs: [N]ConcurrentRunCtx = undefined;
    var threads: [N]std.Thread = undefined;
    for (&ctxs) |*c| c.* = .{
        .tmp_dir_path = tmp_dir_path,
        .script_path = script_path,
        .zap_binary = zap_binary,
        .env_map = &env_map,
    };
    for (&threads, 0..) |*t, idx| {
        t.* = std.Thread.spawn(.{}, ConcurrentRunCtx.run, .{&ctxs[idx]}) catch
            return error.Unexpected;
    }
    for (&threads) |*t| t.join();

    var ok_count: usize = 0;
    for (&ctxs) |*c| {
        if (c.ok) ok_count += 1;
    }
    // EVERY concurrent invocation must have produced correct
    // output and exit 0 — the atomic publish is race-safe.
    try std.testing.expectEqual(@as(usize, N), ok_count);
    // Exactly one published content-key dir despite the race.
    try std.testing.expectEqual(@as(usize, 1), try countScriptKeyDirs(allocator, &tmp_dir));
    try expectOnlyScriptInDir(&tmp_dir, script_name);
}

// ============================================================
// Phase 2.d — defer / errdefer (block-scoped LIFO cleanup)
// ============================================================
//
// Semantics (Zig's single-LIFO-stack model):
//   * `defer <expr>`    runs at scope exit on EVERY value-return path
//                       (normal fall-through return AND the `?` Error
//                       early-return), in reverse registration order.
//   * `errdefer <expr>` runs at scope exit ONLY on an error return
//                       (the `?` Error early-return), in reverse order.
//   * defer + errdefer share ONE LIFO stack: on the success path the
//     errdefer entries are skipped; on the error path they fire.
//   * Block-scoped: a defer inside an inner `{ }` block runs at that
//     inner block's exit.
//   * raise/panic/contract abort `_exit` WITHOUT unwinding, so deferred
//     cleanup intentionally does NOT run on those paths.

test "Phase2d defer: runs on normal return in reverse (LIFO) order" {
    // Two defers registered A then B must fire B then A after the
    // function body's tail expression is evaluated.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    defer IO.puts("defer-A")
        \\    defer IO.puts("defer-B")
        \\    IO.puts("body")
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("body\ndefer-B\ndefer-A\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "Phase2d defer: runs on the ? Error early-return path" {
    // `step(0)?` takes the Error prong and early-returns. The function's
    // `defer` must still fire before the early return propagates.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn step(n :: i64) -> Result(i64, String) {
        \\    case n > 0 {
        \\      true -> Result(i64, String).Ok(n - 1)
        \\      false -> Result(i64, String).Error("stop")
        \\    }
        \\  }
        \\
        \\  pub fn run() -> Result(i64, String) {
        \\    defer IO.puts("cleanup-ran")
        \\    next = TestProg.step(0)?
        \\    Result(i64, String).Ok(next)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    case TestProg.run() {
        \\      Result.Ok(_v) -> IO.puts("ok")
        \\      Result.Error(reason) -> IO.puts(reason)
        \\    }
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    // defer fires before the Error propagates out of run/0, then main
    // prints the Error reason.
    try std.testing.expectEqualStrings("cleanup-ran\nstop\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "Phase2d errdefer: fires on ? Error path but NOT on normal return" {
    // run(0) hits the Error prong -> errdefer fires.
    // run(1) succeeds -> errdefer skipped, defer still fires.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn step(n :: i64) -> Result(i64, String) {
        \\    case n > 0 {
        \\      true -> Result(i64, String).Ok(n - 1)
        \\      false -> Result(i64, String).Error("stop")
        \\    }
        \\  }
        \\
        \\  pub fn run(n :: i64) -> Result(i64, String) {
        \\    defer IO.puts("always")
        \\    errdefer IO.puts("on-error-only")
        \\    next = TestProg.step(n)?
        \\    Result(i64, String).Ok(next)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    IO.puts("--- error path ---")
        \\    case TestProg.run(0) {
        \\      Result.Ok(_v) -> IO.puts("ok")
        \\      Result.Error(_r) -> IO.puts("err")
        \\    }
        \\    IO.puts("--- success path ---")
        \\    case TestProg.run(1) {
        \\      Result.Ok(_v) -> IO.puts("ok")
        \\      Result.Error(_r) -> IO.puts("err")
        \\    }
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    // Error path: errdefer fires, then defer (LIFO: errdefer registered
    // after defer, so it unwinds first), then main prints "err".
    // Success path: ONLY defer fires (errdefer skipped), then "ok".
    try std.testing.expectEqualStrings(
        "--- error path ---\non-error-only\nalways\nerr\n--- success path ---\nalways\nok\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "Phase2d interleave: source defer A; errdefer B; defer C — single LIFO stack" {
    // Zig model: ONE LIFO stack. Source order: defer A, errdefer B,
    // defer C. Success path runs C, A (B skipped). Error path runs
    // C, B, A.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn step(n :: i64) -> Result(i64, String) {
        \\    case n > 0 {
        \\      true -> Result(i64, String).Ok(n - 1)
        \\      false -> Result(i64, String).Error("stop")
        \\    }
        \\  }
        \\
        \\  pub fn run(n :: i64) -> Result(i64, String) {
        \\    defer IO.puts("A")
        \\    errdefer IO.puts("B")
        \\    defer IO.puts("C")
        \\    next = TestProg.step(n)?
        \\    Result(i64, String).Ok(next)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    IO.puts("error:")
        \\    case TestProg.run(0) {
        \\      Result.Ok(_v) -> IO.puts("ok")
        \\      Result.Error(_r) -> IO.puts("done")
        \\    }
        \\    IO.puts("success:")
        \\    case TestProg.run(1) {
        \\      Result.Ok(_v) -> IO.puts("ok")
        \\      Result.Error(_r) -> IO.puts("done")
        \\    }
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "error:\nC\nB\nA\ndone\nsuccess:\nC\nA\nok\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "Phase2d block scope: defer inside an inner if-body runs at that block's exit" {
    // Zap's user-facing inner block scopes are `if`/`else` and `case`/
    // `cond` arm bodies (statement lists) — a free-standing `{ ... }`
    // block-expression is not Zap surface syntax. A `defer` inside the
    // `if` body must fire when the if-block exits (before "after-if"),
    // not at function exit; the function-level defer fires last.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn run(n :: i64) -> u8 {
        \\    defer IO.puts("fn-exit")
        \\    if n > 0 {
        \\      defer IO.puts("if-exit")
        \\      IO.puts("in-if")
        \\    } else {
        \\      IO.puts("in-else")
        \\    }
        \\    IO.puts("after-if")
        \\    0
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    TestProg.run(1)
        \\  }
        \\}
    );
    defer result.deinit();
    // in-if, then if-body defer at if-block exit, then after-if, then
    // fn-level defer at function exit.
    try std.testing.expectEqualStrings(
        "in-if\nif-exit\nafter-if\nfn-exit\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "Phase2d raise: deferred cleanup does NOT run on the unrecoverable abort path" {
    // raise/panic/contract abort `_exit` without unwinding, so the
    // `defer` here intentionally never fires. The process aborts
    // non-zero with the Zap crash report; "should-not-print" must be
    // absent from stdout.
    var result = try compileAndRun(
        \\pub struct TestProg {
        \\  pub fn boom() -> Nil {
        \\    defer IO.puts("should-not-print")
        \\    raise "kaboom"
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    TestProg.boom()
        \\    0
        \\  }
        \\}
    );
    defer result.deinit();
    // Defer must NOT have run on the abort path.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "should-not-print") == null);
    // The raise aborts non-zero.
    try std.testing.expect(result.exit_code != 0);
}
