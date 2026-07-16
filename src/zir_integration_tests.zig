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

fn expectCompileFailsWithDiagnostic(source: []const u8, expected_diagnostic: []const u8) !void {
    try expectCompileFailsWithDiagnosticGated(source, expected_diagnostic, false, false);
}

/// Variant of `expectCompileFailsWithDiagnostic` whose synthesized
/// manifest resolves the `runtime_concurrency` gate ON (P2-J2): gated
/// compiles resolve the concurrency kernel unit relative to the stdlib
/// root, so the build is pinned to the repo's `lib/` via
/// `--zap-lib-dir` (the exe-relative stdlib copy under `zig-out/` has
/// no sibling `src/runtime/concurrency`).
fn expectGatedCompileFailsWithDiagnostic(source: []const u8, expected_diagnostic: []const u8) !void {
    try expectCompileFailsWithDiagnosticGated(source, expected_diagnostic, true, true);
}

/// Variant for a gate-OFF build that still references `Process.*`: the
/// manifest leaves `runtime_concurrency` OFF (proving the zero-cost gate
/// diagnostic fires), but the build is still pinned to the repo's `lib/`
/// via `--zap-lib-dir` so the `Process` stdlib module resolves (the gate
/// error must come from the comptime gate, not a missing-module error).
fn expectGateOffConcurrencyCompileFailsWithDiagnostic(source: []const u8, expected_diagnostic: []const u8) !void {
    try expectCompileFailsWithDiagnosticGated(source, expected_diagnostic, false, true);
}

fn expectCompileFailsWithDiagnosticGated(
    source: []const u8,
    expected_diagnostic: []const u8,
    runtime_concurrency: bool,
    pin_repo_lib_dir: bool,
) !void {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(getTestIo(), "lib") catch return error.Unexpected;

    const build_source = if (runtime_concurrency)
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
        \\          runtime_concurrency: true
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
    else
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

    // Concurrency-referencing builds resolve `Process`/the concurrency
    // kernel unit relative to the stdlib root — pin it to the repo's
    // `lib/` (the zir-test runner's cwd is the repo root). Independent of
    // the manifest gate: a gate-OFF test that references `Process` still
    // needs the module to resolve so the comptime gate diagnostic fires.
    var repo_lib_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const repo_lib_dir: ?[]const u8 = if (pin_repo_lib_dir) blk: {
        const canonical_len = std.Io.Dir.cwd().realPathFile(getTestIo(), "lib", &repo_lib_dir_buffer) catch return error.Unexpected;
        break :blk repo_lib_dir_buffer[0..canonical_len];
    } else null;
    const compile_argv: []const []const u8 = if (repo_lib_dir) |lib_dir|
        &.{ zap_binary, "build", "test_prog", "--zap-lib-dir", lib_dir }
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
            printUnexpectedCompileFailure(255, compile_result.stdout, compile_result.stderr);
            return error.CompilationFailed;
        },
    };

    if (compile_exit == 0) {
        std.debug.print(
            "\n=== EXPECTED COMPILE FAILURE BUT IT SUCCEEDED ===\n=== stdout ===\n{s}\n=== stderr ===\n{s}\n",
            .{ compile_result.stdout, compile_result.stderr },
        );
        return error.Unexpected;
    }

    if (std.mem.indexOf(u8, compile_result.stderr, expected_diagnostic) == null) {
        std.debug.print(
            "\n=== MISSING EXPECTED DIAGNOSTIC ===\nexpected substring: {s}\n=== stdout ===\n{s}\n=== stderr ===\n{s}\n",
            .{ expected_diagnostic, compile_result.stdout, compile_result.stderr },
        );
        return error.Unexpected;
    }
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

/// Compile a Zap source string under a gate-ON (`runtime_concurrency: true`)
/// manifest and run the resulting binary — the concurrency twin of
/// `compileAndRun`. Gated compiles resolve the concurrency kernel unit
/// relative to the stdlib root, so the build is pinned to the repo's `lib/`
/// via `--zap-lib-dir` (the exe-relative stdlib copy under `zig-out/` has no
/// sibling `src/runtime/concurrency`).
fn compileAndRunGatedConcurrency(source: []const u8) TestError!TestResult {
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
        \\          paths: ["lib/**/*.zap"],
        \\          runtime_concurrency: true
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

    var repo_lib_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_len = std.Io.Dir.cwd().realPathFile(getTestIo(), "lib", &repo_lib_dir_buffer) catch
        return error.Unexpected;
    const repo_lib_dir = repo_lib_dir_buffer[0..canonical_len];

    const compile_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "build", "test_prog", "--zap-lib-dir", repo_lib_dir },
        .cwd = .{ .path = tmp_dir_path },
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

// ============================================================
// Custom-manager capability-driven-codegen acceptance proof
// (CapMem Phase 4 — `docs/capability-driven-memory-model-plan.md`
// "Verification matrix", the **custom** row).
//
// These tests prove the adapter-bounded principle end-to-end: the
// compiler keys every memory-codegen decision off the manager's
// declared `declared_caps` bits and NEVER off its name. Two custom
// managers — neither one of the five stdlib managers, both with names
// unknown to the compiler — declare the same capability bitmasks as
// their stdlib counterparts and therefore receive byte-identical
// codegen contracts:
//
//   * `Custom.BulkArena`    declares BULK_OR_NEVER (declared_caps=0x0,
//                            identical to `Memory.Arena`)
//   * `Custom.TrackingPool` declares INDIVIDUAL_NO_REFCOUNT |
//                            CLONE_ON_SHARE (declared_caps=0x2,
//                            identical to `Memory.Tracking`)
//
// The backends are self-contained (`std`+`builtin` only) and declare
// only the capability bits — no name appears in any compiler path.
// Each backend's refcount slots are `@panic` stubs: if the compiler
// WRONGLY emitted a retain/release ZIR op for a non-refcounted manager
// (e.g. because it special-cased a name it did not recognise and fell
// back to refcounted codegen), the program would panic at the first
// refcounted-type operation instead of running to completion. Running
// to completion with the expected output is therefore the empirical
// proof that the elision (BULK_OR_NEVER) / static-free (INDIVIDUAL_
// NO_REFCOUNT) codegen was selected from the caps bits alone.
// ============================================================

// The custom-manager backend `.zig` files are the SINGLE SOURCE OF TRUTH for
// both this integration test and the standalone acceptance harness
// (`script_fixtures/run_custom_manager_proof.sh`); they live in the on-disk
// proof project so the harness can build it directly by the package
// convention. `src/` is the compiler module's `@embedFile` package root, so
// these (outside `src/`) are read at run time from the repo-relative path (the
// host test suite runs with cwd == repo root, the same assumption
// `resolveZapBinary` relies on for `zig-out/bin/zap`).
const CUSTOM_BULK_ARENA_MANAGER_PATH =
    "script_fixtures/custom_manager_proof/src/custom/bulk_arena/manager.zig";
const CUSTOM_TRACKING_POOL_MANAGER_PATH =
    "script_fixtures/custom_manager_proof/src/custom/tracking_pool/manager.zig";

fn readCustomManagerBackend(relative_path: []const u8) TestError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        getTestIo(),
        relative_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    ) catch return error.Unexpected;
}

fn customManagerBuildSource(manager_type_name: []const u8) []const u8 {
    // The manifest selects the custom manager by Type. The adapter `.zap`
    // (an empty `impl Memory.Manager for X {}` marker) lives under
    // `lib/custom/<stem>.zap` — the dotted struct name `Custom.<Stem>` MUST map
    // to that directory path (discovery enforces struct-name-to-path) — so the
    // package-convention backend resolver binds its sibling
    // `src/custom/<stem>/manager.zig`.
    return std.fmt.allocPrint(
        std.testing.allocator,
        \\pub struct TestProg.Builder {{
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {{
        \\    case env.target {{
        \\      :test_prog ->
        \\        %Zap.Manifest{{
        \\          name: "test_prog",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &TestProg.main/0,
        \\          paths: ["lib/**/*.zap"],
        \\          memory: {s}
        \\        }}
        \\      _ ->
        \\        panic("Unknown target")
        \\    }}
        \\  }}
        \\}}
    ,
        .{manager_type_name},
    ) catch @panic("OOM building custom-manager manifest source");
}

test "ZIR custom manager: BULK_OR_NEVER caps give Arena-identical elision (no name special-casing)" {
    // A program that builds and walks a refcounted recursive struct AND a
    // `List` — both refcounted-type surfaces that, under a manager declaring
    // REFCOUNTED, would emit retain/release ZIR ops. `Custom.BulkArena`
    // declares BULK_OR_NEVER (declared_caps=0x0), so the compiler must elide
    // ALL of them. The custom manager's retain/release slots are `@panic`
    // stubs, so any wrongly-emitted refcount op aborts the run. Running to
    // completion with the expected output proves the elision was selected
    // from the caps bits, not the (unknown) name.
    const build_source = customManagerBuildSource("Custom.BulkArena");
    defer std.testing.allocator.free(build_source);

    const adapter_source =
        \\pub struct Custom.BulkArena {
        \\}
        \\
        \\pub impl Memory.Manager for Custom.BulkArena {}
    ;

    const source =
        \\pub struct Node {
        \\  value :: i64
        \\  next :: Node | nil
        \\}
        \\
        \\pub struct TestProg {
        \\  pub fn sum(nil) -> i64 {
        \\    0 :: i64
        \\  }
        \\
        \\  pub fn sum(node :: Node) -> i64 {
        \\    node.value + TestProg.sum(node.next)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    tail = %Node{value: 9, next: nil}
        \\    head = %Node{value: 5, next: tail}
        \\    total = TestProg.sum(head) + TestProg.sum(tail)
        \\    items = [1, 2, 3]
        \\    list_len = List.length(items)
        \\    IO.puts(Integer.to_string(total + list_len))
        \\    0
        \\  }
        \\}
    ;

    const backend_source = try readCustomManagerBackend(CUSTOM_BULK_ARENA_MANAGER_PATH);
    defer std.testing.allocator.free(backend_source);

    var result = try compileAndRunCustomProject(build_source, source, &.{
        .{ .path = "lib/custom/bulk_arena.zap", .data = adapter_source },
        .{ .path = "src/custom/bulk_arena/manager.zig", .data = backend_source },
    });
    defer result.deinit();

    // sum(head)=5+9=14, sum(tail)=9, total=23; list_len=3; 23+3=26.
    try std.testing.expectEqualStrings("26\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // No refcount panic-stub fired (the caps-driven elision held).
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "does not implement REFCOUNT_V1") == null);
}

test "ZIR custom manager: INDIVIDUAL_NO_REFCOUNT caps give Tracking-identical static-free + clone-on-share" {
    // The recursive-struct + shared-ownership shape under a manager declaring
    // INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE (declared_caps=0x2). The compiler
    // must elide refcount ops AND emit static free-at-last-use + clone-on-share
    // — exactly `Memory.Tracking`'s codegen — selected from the caps bits
    // alone. `Custom.TrackingPool` really frees each block on `core.deallocate`
    // and prints a `Custom.TrackingPool LEAK:` survivor line at deinit if any
    // block outlives its proven last use. The program must therefore run to
    // completion with the expected output AND leave no survivor line: proof
    // that the static-free codegen reclaimed every allocation.
    const build_source = customManagerBuildSource("Custom.TrackingPool");
    defer std.testing.allocator.free(build_source);

    const adapter_source =
        \\pub struct Custom.TrackingPool {
        \\}
        \\
        \\pub impl Memory.Manager for Custom.TrackingPool {}
    ;

    const source =
        \\pub struct Node {
        \\  value :: i64
        \\  next :: Node | nil
        \\}
        \\
        \\pub struct TestProg {
        \\  pub fn sum(nil) -> i64 {
        \\    0 :: i64
        \\  }
        \\
        \\  pub fn sum(node :: Node) -> i64 {
        \\    node.value + TestProg.sum(node.next)
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    a = %Node{value: 4, next: nil}
        \\    b = %Node{value: 3, next: a}
        \\    c = %Node{value: 2, next: b}
        \\    list = %Node{value: 1, next: c}
        \\    IO.puts(Integer.to_string(TestProg.sum(list)))
        \\    0
        \\  }
        \\}
    ;

    const backend_source = try readCustomManagerBackend(CUSTOM_TRACKING_POOL_MANAGER_PATH);
    defer std.testing.allocator.free(backend_source);

    var result = try compileAndRunCustomProject(build_source, source, &.{
        .{ .path = "lib/custom/tracking_pool.zap", .data = adapter_source },
        .{ .path = "src/custom/tracking_pool/manager.zig", .data = backend_source },
    });
    defer result.deinit();

    // sum(1->2->3->4) = 10.
    try std.testing.expectEqualStrings("10\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // No refcount panic-stub fired (refcount ops elided under the caps).
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "does not implement REFCOUNT_V1") == null);
    // No survivor line: the static free-at-last-use codegen reclaimed all
    // allocations — the INDIVIDUAL_NO_REFCOUNT leak gate is clean.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Custom.TrackingPool LEAK:") == null);
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
        \\@compile_after_glob = "test/**/*_test.zap"
        \\
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

test "ZIR: raw tuple arithmetic is rejected outside Simd" {
    try expectCompileFails(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _sum = {1, 2} + {3, 4}
        \\    0
        \\  }
        \\}
    );
}

test "ZIR: unsupported Simd.reduce operation reports no matching macro clause" {
    try expectCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    values = Simd.vector(4, i32, {4, -2, 9, 1})
        \\    Simd.reduce(:median, values)
        \\    0
        \\  }
        \\}
    ,
        "no macro clause of `reduce/2` matches the arguments",
    );
}

test "ZIR: non-numeric tuple field access reports Zap source diagnostic" {
    try expectCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    values = Simd.vector(4, i32, {4, -2, 9, 1})
        \\    _wrong = values.reduce_max
        \\    0
        \\  }
        \\}
    ,
        "tuple field access requires a numeric index, got `reduce_max`",
    );
}

test "ZIR: macro-expanded non-numeric tuple field call reports Zap source diagnostic" {
    try expectCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub macro broken_reduce(value :: Expr) -> Expr {
        \\    quote { simd.reduce_max(unquote(value)) }
        \\  }
        \\
        \\  pub fn main() -> u8 {
        \\    values = Simd.vector(4, i32, {4, -2, 9, 1})
        \\    TestProg.broken_reduce(values)
        \\    0
        \\  }
        \\}
    ,
        "I cannot find a variable named `simd`",
    );
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

    const script_cache = scriptCacheDirForTmp(allocator, tmp_dir_path) catch
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

    const script_cache = scriptCacheDirForTmp(allocator, tmp_dir_path) catch
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
/// Per-test script-cache directory: a sibling of the test's tmp dir
/// (so the in-tmp "no-litter" assertion stays exact — the cache lives
/// OUTSIDE the tmp dir) whose name is suffixed with the tmp dir's own
/// unique basename so EACH test gets its OWN cache. A single shared
/// `zap-script-cache` under the common `.zig-cache/tmp/` parent let one
/// test's published script binary leak into another's view: every
/// script test writes `<cache>/zap/scripts/<hash>/script`, and
/// `findPublishedScriptBinary` returns the FIRST `<hash>` the directory
/// iterator yields — which, with a shared cache, could be a different
/// test's script (e.g. `atos` resolving `exit0.zap:1` instead of the
/// `phase0_split.zap` the Phase-0 test just built). Isolating per test
/// guarantees the cache holds exactly the binary under test.
/// Caller owns the returned slice.
fn scriptCacheDirForTmp(allocator: std.mem.Allocator, tmp_dir_path: []const u8) ![]const u8 {
    const unique = std.fs.path.basename(tmp_dir_path);
    const cache_name = try std.fmt.allocPrint(allocator, "zap-script-cache-{s}", .{unique});
    defer allocator.free(cache_name);
    return std.fs.path.join(allocator, &.{ tmp_dir_path, "..", cache_name });
}

fn findPublishedScriptBinary(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
) TestError![]const u8 {
    const tmp_dir_path = tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator) catch
        return error.Unexpected;
    defer allocator.free(tmp_dir_path);

    const script_cache = scriptCacheDirForTmp(allocator, tmp_dir_path) catch
        return error.OutOfMemory;
    defer allocator.free(script_cache);
    const scripts_dir = std.fs.path.join(allocator, &.{ script_cache, "zap", "scripts" }) catch
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

    // (c) The published sibling dSYM resolves the script's `main` to
    // its original `<file>.zap:<line>` so Phase 2's crash printer /
    // lldb / addr2line can surface user-meaningful frames on
    // optimized builds.
    //
    // ReleaseFast INLINES the Zap `main` into the Zig entry glue
    // (`_start.main`), so there is no standalone `_script.main`
    // Mach-O symbol to grep, and `atos` cannot reach the Zap source
    // either: `atos` reports the flat line-number-program row for an
    // address, and for the fully-inlined entry every row attributes
    // to a library file (`start.zig`, `fmt.zig`). The Zap source
    // mapping survives only as the `script.main` subprogram DIE
    // (`DW_AT_decl_file = <file>.zap`) and the `DW_AT_call_file` on
    // the inline-subroutine DIEs — i.e. exactly what an
    // inline-AWARE symbolizer walks. So resolve through `lldb image
    // lookup -n script.main`, which reads the DWARF function by name
    // and prints the full inline chain. lldb auto-loads the sibling
    // `.dSYM` by matching the binary's UUID; with the `.dSYM`
    // removed this lookup yields no Zap frame, so this still proves
    // the PUBLISHED dSYM (not embedded debug-info — the binary is
    // stripped, asserted in (a)) carries the mapping. This is
    // strictly stronger than the old `atos` round-trip: it verifies
    // the inlined Zap frame itself, not merely a line-table row.
    const lldb_result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "xcrun", "lldb", "--batch", "-o", "image lookup -n script.main", published },
        .stdout_limit = .limited(1 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.RunFailed;
    defer allocator.free(lldb_result.stdout);
    defer allocator.free(lldb_result.stderr);

    if (std.mem.indexOf(u8, lldb_result.stdout, "phase0_release_fast.zap") == null) {
        std.debug.print(
            "Phase 0 Gap E: lldb did not resolve `script.main` to a phase0_release_fast.zap location via the published dSYM.\n  stdout: {s}\n  stderr: {s}\n",
            .{ lldb_result.stdout, lldb_result.stderr },
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
    // Only the prologue is needed (the FP setup lands within the
    // first ~30 lines), but `otool -tv -p _main` disassembles from
    // `_main` to the end of the text section. As the script binary's
    // text grew (error system, closures, etc.) that listing now
    // exceeds 2 MB, so reading it whole overflows the subprocess
    // stdout limit with `error.StreamTooLong`. Pipe through `head` so
    // the closed pipe makes `otool` stop early; the bounded slice is
    // a few KB and still contains the whole prologue.
    const otool_cmd = std.fmt.allocPrint(
        allocator,
        "otool -tv -p _main '{s}' | head -n 80",
        .{binary_path},
    ) catch return error.OutOfMemory;
    defer allocator.free(otool_cmd);

    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ "sh", "-c", otool_cmd },
        .stdout_limit = .limited(256 * 1024),
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
        "Memory.ORC",
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

// A parametric struct implementing a MULTI-parameter protocol, genuinely
// boxed (passed to a helper whose param is `unique Stage(...)`) and
// dispatched through the synthesized existential vtable, must run leak-free
// under `Memory.Tracking`. The boxed inner carries an ARC-managed closure
// field, so this exercises the vtable `__drop__`/release path on the
// per-instantiation monomorph cell — the same seam the classifyTypeDef
// dot-based nested/top-level fix routes through the single canonical
// `@import("Mapper_i64_String")` type. Pre-fix this program did not even
// compile (nominal `expected 'Mapper.Mapper_i64_String', found
// 'Mapper_i64_String'` in the adapter). A surviving allocation prints a
// `LEAK: ptr=…` line to stderr at exit (see `lib/memory/tracking.zap`), so
// leak-freedom is a clean exit AND no `LEAK:` survivor line — a
// process-exit assertion that cannot be expressed from Zap. Value
// correctness lives in the Zap suite
// (`test/zap/parametric_multiparam_protocol_box_test.zap`).
test "boxed parametric multi-param protocol stage: leak-free under Memory.Tracking" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "stage_leak.zap",
        \\pub protocol Stage(input, output) {
        \\  fn step(x :: unique Stage(input, output), item :: input) -> {Atom, [output], Stage(input, output)}
        \\  fn flush(x :: unique Stage(input, output)) -> {Atom, [output]}
        \\}
        \\
        \\pub struct Mapper(input, output) {
        \\  transform :: fn(input) -> output
        \\}
        \\
        \\pub impl Stage(input, output) for Mapper(input, output) {
        \\  pub fn step(x :: unique Mapper(input, output), item :: input) -> {Atom, [output], Mapper(input, output)} {
        \\    {:cont, [x.transform(item)], x}
        \\  }
        \\  pub fn flush(x :: unique Mapper(input, output)) -> {Atom, [output]} {
        \\    {:done, ([] :: [output])}
        \\  }
        \\}
        \\
        \\pub struct Driver {
        \\  pub fn drive(stage :: unique Stage(i64, String), first :: i64, second :: i64) -> String {
        \\    case Stage.step(stage, first) {
        \\      {_c1, o1, n1} ->
        \\        case Stage.step(n1, second) {
        \\          {_c2, o2, n2} ->
        \\            case Stage.flush(n2) {
        \\              {_da, o3} -> List.head((o1 <> o2) <> o3)
        \\            }
        \\        }
        \\    }
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  stage = %Mapper(i64, String){transform: fn(v :: i64) -> String { Integer.to_string(v) <> "!" }}
        \\  result = Driver.drive(stage, 1, 2)
        \\  IO.puts("stage-leak-ok=" <> result)
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stage-leak-ok=1!") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "LEAK:") == null);
    try expectOnlyScriptInDir(&tmp_dir, "stage_leak.zap");
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

test "boxed-existential struct field: box-only iterating adapter is leak-free under Memory.Tracking" {
    // Regression for the boxed-existential-field partial-move defect. A
    // struct whose ONLY field is a concrete-parametric protocol box
    // (`source :: Enumerable(i64)`) and which CONSUMES that field via a
    // `unique`-receiver dispatch (`Enumerable.next(self.source)`) must:
    //   * be classified ARC-managed (so its param drops — otherwise the box
    //     LEAKS, invisible under refcount ARC but a `memory leak:` survivor
    //     under `Memory.Tracking`), AND
    //   * route the consumed box-field extraction through the clone-on-share
    //     so the consume does not steal the parent's single reference (which
    //     the parent's drop would otherwise re-release / double-free).
    // Both must hold together: the classification alone would turn the leak
    // into a double free. `Memory.Tracking` is per-allocation leak-checked at
    // deinit, so it is the manager that OBSERVES the leak — and the manager
    // can only be selected through the `-Dmemory` CLI flag, which Zest cannot
    // set, so this coverage lives here rather than in a Zest test.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "box_only.zap",
        \\pub struct BoxOnly {
        \\  source :: Enumerable(i64)
        \\}
        \\
        \\pub impl Enumerable(i64) for BoxOnly {
        \\  pub fn next(holder :: unique BoxOnly) -> {Atom, i64, BoxOnly} {
        \\    case Enumerable.next(holder.source) {
        \\      {:done, _, exhausted} -> {:done, 0, %BoxOnly{source: exhausted}}
        \\      {:cont, item, next_source} -> {:cont, item, %BoxOnly{source: next_source}}
        \\    }
        \\  }
        \\
        \\  pub fn dispose(holder :: unique BoxOnly) -> Nil {
        \\    Enumerable.dispose(holder.source)
        \\    nil
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  holder = %BoxOnly{source: [7, 8, 9]}
        \\  collected = Enum.to_list(holder)
        \\  IO.puts("box-only-count=" <> Integer.to_string(List.length(collected)))
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "box-only-count=3") != null);
    // No per-allocation leak survivor and no double-free/abort under the
    // leak-checked manager.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "LEAK:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "reached unreachable") == null);
}

test "boxed-existential struct field: PARAMETRIC iterating adapter is leak-free under Memory.Tracking" {
    // Regression for the PARAMETRIC boxed-existential-field ARC leak. A generic
    // struct that stores a boxed-existential protocol field
    // (`struct P(element) { source :: Enumerable(element) }`) was misclassified
    // `.trivial` and never dropped, so its boxed field LEAKED under
    // `Memory.Tracking` — while the byte-identical CONCRETE struct
    // (`Enumerable(i64)`, the test above) was clean. Root cause: the ARC
    // classifier (`structTypeHasArcManagedField`) gated a boxed protocol FIELD
    // on its type argument being concrete, but a generic struct's declared
    // field type keeps the formal `type_var` even for a fully concrete
    // instantiation (Zap monomorphizes struct BODIES by use-site substitution,
    // not by cloning the declaration). The fix classifies ANY parametric
    // protocol-constraint FIELD as boxed/ARC-managed regardless of
    // type-argument concreteness.
    //
    // This drives THREE untested parametric shapes, each to `:done` (full
    // drive) AND early-disposed (`Enum.take`, the partial path) — every boxed
    // field must be released exactly once on both paths:
    //   * a box-only parametric adapter (the misclassified shape), and
    //   * a two-boxed-field parametric `Transform` adapter
    //     (`source :: Enumerable(input)`, `stage :: Stage(input, output)`) with
    //     a bare `[output]` List buffer and String payloads, applying the stage
    //     per item.
    // Parametric inline protocol dispatch on a boxed field is rejected, so
    // `next`/`dispose` are helper-routed (the concrete-clean inline-reconstruct
    // shape is unavailable to a parametric adapter). `Memory.Tracking` is the
    // only manager that OBSERVES the leak and is selectable solely through the
    // `-Dmemory` CLI flag, which Zest cannot set — so this coverage lives here.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "parametric_box.zap",
        \\pub struct BoxOnlyP(element) {
        \\  source :: Enumerable(element)
        \\
        \\  fn step(source :: unique Enumerable(element)) -> {Atom, element, BoxOnlyP(element)} {
        \\    case Enumerable.next(source) {
        \\      {:done, d, exhausted} -> {:done, d, %BoxOnlyP(element){source: exhausted}}
        \\      {:cont, item, rest} -> {:cont, item, %BoxOnlyP(element){source: rest}}
        \\    }
        \\  }
        \\
        \\  fn drop_source(source :: unique Enumerable(element)) -> Nil {
        \\    Enumerable.dispose(source)
        \\    nil
        \\  }
        \\}
        \\
        \\pub impl Enumerable(element) for BoxOnlyP(element) {
        \\  pub fn next(self :: unique BoxOnlyP(element)) -> {Atom, element, BoxOnlyP(element)} {
        \\    BoxOnlyP.step(self.source)
        \\  }
        \\
        \\  pub fn dispose(self :: unique BoxOnlyP(element)) -> Nil {
        \\    BoxOnlyP.drop_source(self.source)
        \\    nil
        \\  }
        \\}
        \\
        \\pub protocol Stage(input, output) {
        \\  fn transform(self :: Stage(input, output), value :: input) -> output
        \\  fn dispose(self :: unique Stage(input, output)) -> Nil
        \\}
        \\
        \\pub struct PrefixStage {
        \\  prefix :: String
        \\}
        \\
        \\pub impl Stage(String, String) for PrefixStage {
        \\  pub fn transform(self :: PrefixStage, value :: String) -> String {
        \\    self.prefix <> value
        \\  }
        \\  pub fn dispose(self :: unique PrefixStage) -> Nil {
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct TransformLikeP(input, output) {
        \\  source :: Enumerable(input)
        \\  stage :: Stage(input, output)
        \\  buffer :: [output]
        \\
        \\  fn step(source :: unique Enumerable(input), stage :: Stage(input, output), buffer :: [output]) -> {Atom, output, TransformLikeP(input, output)} {
        \\    case Enumerable.next(source) {
        \\      {:done, _, exhausted} -> {:done, List.head(buffer), %TransformLikeP(input, output){source: exhausted, stage: stage, buffer: buffer}}
        \\      {:cont, item, rest} -> {:cont, Stage.transform(stage, item), %TransformLikeP(input, output){source: rest, stage: stage, buffer: buffer}}
        \\    }
        \\  }
        \\
        \\  fn drop_source(source :: unique Enumerable(input)) -> Nil {
        \\    Enumerable.dispose(source)
        \\    nil
        \\  }
        \\
        \\  fn drop_stage(stage :: unique Stage(input, output)) -> Nil {
        \\    Stage.dispose(stage)
        \\    nil
        \\  }
        \\}
        \\
        \\pub impl Enumerable(output) for TransformLikeP(input, output) {
        \\  pub fn next(self :: unique TransformLikeP(input, output)) -> {Atom, output, TransformLikeP(input, output)} {
        \\    TransformLikeP.step(self.source, self.stage, self.buffer)
        \\  }
        \\
        \\  pub fn dispose(self :: unique TransformLikeP(input, output)) -> Nil {
        \\    TransformLikeP.drop_source(self.source)
        \\    TransformLikeP.drop_stage(self.stage)
        \\    nil
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  drained = Enum.to_list(%BoxOnlyP(i64){source: [1, 2, 3]})
        \\  IO.puts("box-only-count=" <> Integer.to_string(List.length(drained)))
        \\  taken = Enum.take(%BoxOnlyP(i64){source: [1, 2, 3]}, 1)
        \\  IO.puts("box-only-take=" <> Integer.to_string(List.length(taken)))
        \\  tl_drained = Enum.to_list(%TransformLikeP(String, String){source: ["a", "b", "c"], stage: %PrefixStage{prefix: "x-"}, buffer: ["<eos>"]})
        \\  IO.puts("transform-count=" <> Integer.to_string(List.length(tl_drained)))
        \\  tl_taken = Enum.take(%TransformLikeP(String, String){source: ["a", "b", "c"], stage: %PrefixStage{prefix: "x-"}, buffer: ["<eos>"]}, 2)
        \\  IO.puts("transform-take=" <> Integer.to_string(List.length(tl_taken)))
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "box-only-count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "box-only-take=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "transform-count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "transform-take=2") != null);
    // No per-allocation leak survivor and no double-free/abort under the
    // leak-checked manager — the exactly-once release invariant for a boxed
    // field of a parametric struct, on both the drive-to-done and the
    // early-dispose path.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "LEAK:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "reached unreachable") == null);
}

test "multi-instantiation boxed parametric adapter is leak-free and crash-free under Memory.Tracking" {
    // Regression for GAP-C: a PARAMETRIC adapter (`Wrap(element)` — a struct
    // carrying a boxed `Enumerable(element)` field and implementing
    // `Enumerable(element)` itself) BOXED at MULTIPLE instantiations in one
    // program (`Enumerable(i64)` AND `Enumerable(String)`) crashed at runtime
    // in the boxed value's clone/share/drop machinery:
    //   * default `Memory.ARC`: `reached unreachable` double-free in
    //     `arcRelease`;
    //   * `-Dmemory=Memory.Tracking`: SIGSEGV in the box `drop`/`clone`
    //     adapters (`releaseProtocolBoxInner` -> `freeAnyNonRefcountedImpl`,
    //     `slabAllocSlot`).
    //
    // Two independent triggers, both covered here: (1) two coexisting boxed
    // instantiations of the same parametric adapter; (2) an ARC-payload
    // (String) boxed adapter EARLY-DISPOSED via `Enum.take`. Root cause: the
    // ARC drop-insertion box-retain rewrite classified a `.persistent` box
    // retain as a genuine new-owner SHARE (`.protocol_box_share`, which CLONES
    // under a clone-on-share manager) ONLY when the box was bound to a NAMED
    // local, so a box that is instead MOVE-consumed — copied out of an owned
    // aggregate (the `{:cont, value, next_state}` tuple) and moved into a
    // consuming callee (`Enum`'s internal `dispose_and_return`) while the
    // aggregate slot is also dropped — was wrongly downgraded to a no-op
    // `.protocol_box_retain`; the alias then double-freed the shared inner.
    // A sibling defect over-cloned a `unique` box PARAMETER stored into a
    // struct field (`%Wrap{source: source}`), orphaning the moved-in original
    // (a leak). Both are fixed so each boxed adapter cell — and its
    // ARC-managed inner (a `List`/`String` payload, a boxed source field) — is
    // retained/released exactly once regardless of how many instantiations
    // coexist.
    //
    // `Memory.Tracking` is the per-allocation leak-checked manager that
    // OBSERVES the leak/double-free and is selectable only through the
    // `-Dmemory` CLI flag, which Zest cannot set — so this coverage lives here;
    // the ARC counterpart is the Zest file
    // `test/zap/multi_instantiation_boxed_adapter_test.zap`.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "multi_inst_box.zap",
        \\pub struct Wrap(element) {
        \\  source :: Enumerable(element)
        \\}
        \\
        \\pub impl Enumerable(element) for Wrap(element) {
        \\  fn step(source :: unique Enumerable(element)) -> {Atom, element, Wrap(element)} {
        \\    case Enumerable.next(source) {
        \\      {:done, d, exhausted} -> {:done, d, %Wrap(element){source: exhausted}}
        \\      {:cont, item, rest} -> {:cont, item, %Wrap(element){source: rest}}
        \\    }
        \\  }
        \\
        \\  fn drop_source(source :: unique Enumerable(element)) -> Nil {
        \\    Enumerable.dispose(source)
        \\    nil
        \\  }
        \\
        \\  pub fn next(self :: unique Wrap(element)) -> {Atom, element, Wrap(element)} {
        \\    Wrap.step(self.source)
        \\  }
        \\
        \\  pub fn dispose(self :: unique Wrap(element)) -> Nil {
        \\    Wrap.drop_source(self.source)
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct H {
        \\  pub fn wi(source :: unique Enumerable(i64)) -> Enumerable(i64) { %Wrap(i64){source: source} }
        \\  pub fn ws(source :: unique Enumerable(String)) -> Enumerable(String) { %Wrap(String){source: source} }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  # String (ARC payload) boxed adapter EARLY-DISPOSED via Enum.take,
        \\  # then an i64 boxed adapter DRAINED to :done — the exact
        \\  # multi-instantiation coexistence that double-freed / bus-errored.
        \\  st = Enum.take(H.ws(["a", "b", "c"]), 2)
        \\  IO.puts("str-take=" <> Integer.to_string(List.length(st)))
        \\  di = Enum.to_list(H.wi([1, 2, 3]))
        \\  IO.puts("i64-drain=" <> Integer.to_string(List.length(di)))
        \\  # i64 early dispose + String drive-to-:done (both instantiations,
        \\  # both paths).
        \\  ti = Enum.take(H.wi([10, 20, 30, 40]), 1)
        \\  IO.puts("i64-take=" <> Integer.to_string(List.length(ti)))
        \\  ds = Enum.to_list(H.ws(["x", "y"]))
        \\  IO.puts("str-drain=" <> Integer.to_string(List.length(ds)))
        \\  # count == 0 early dispose (the consumed collection must still be
        \\  # disposed, for both instantiations).
        \\  zi = Enum.take(H.wi([7, 8, 9]), 0)
        \\  IO.puts("i64-zero=" <> Integer.to_string(List.length(zi)))
        \\  zs = Enum.take(H.ws(["p", "q"]), 0)
        \\  IO.puts("str-zero=" <> Integer.to_string(List.length(zs)))
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "str-take=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "i64-drain=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "i64-take=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "str-drain=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "i64-zero=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "str-zero=0") != null);
    // Exactly-once invariant: no per-allocation leak survivor and no
    // double-free / abort under the leak-checked manager, across BOTH
    // instantiations and BOTH the drive-to-:done and early-dispose paths.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "LEAK:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "reached unreachable") == null);
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

test "CLI manifest: -Dmemory overrides manifest memory: (override selects the named backend)" {
    const allocator = std.testing.allocator;
    // Manifest says Memory.ARC; `-Dmemory=Memory.Leak` overrides it.
    // The override flows through the unified `-D` override step into the
    // build pipeline, which resolves the named backend
    // (`lib/memory/leak.zap` + `src/memory/leak/manager.zig`), validates
    // its `.zapmem` section, threads its `declared_caps`, links it, and
    // runs the produced binary.
    //
    // Observability: `Memory.Leak` is the never-free, ZERO-capability
    // diagnostic manager (Phase 7). It declares no REFCOUNT_V1 and emits
    // NOTHING on exit — it is NOT the leak-REPORTING manager (that is
    // `Memory.Tracking`, whose `core.deinit` prints `LEAK: ...` for
    // surviving allocations). An earlier revision of this test wrongly
    // asserted "Memory.Leak emits a leak report to stderr"; that has
    // never been true under the Leak/Tracking split, so the assertion
    // is corrected to the override's actual, deterministic effect.
    //
    // A clean build+run to exit 0 with the marker on stdout — under the
    // zero-cap Leak backend whose refcount slots are panic stubs — is
    // the proof the override REPLACED the manifest's `Memory.ARC` with
    // `Memory.Leak`: had ARC's refcount codegen survived against the
    // zero-cap Leak runtime, a `does not implement REFCOUNT_V1` panic
    // stub would have fired on the first retain/release (non-zero exit +
    // that stub message on stderr).
    var r = try runManifestProject(allocator, "build", ":release_safe", "Memory.ARC", &.{"-Dmemory=Memory.Leak"});
    defer r.deinit();

    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "manifest-marker=abc") != null);
    // The Leak backend's refcount slots are panic stubs; selecting it via
    // the override and running clean proves ARC's refcount codegen was
    // NOT emitted — i.e. the override genuinely replaced the manifest
    // manager.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "does not implement REFCOUNT_V1") == null);
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

test "rescue: recovered boxed error drops cleanly under Memory.Tracking (no double-free / UAF)" {
    // Regression: a recoverable-raise–RECOVERED `ProtocolBox` (the box the
    // `try` body stashed into the thread-local side-channel, recovered via
    // `Kernel.take_recoverable_raise`) used to be dropped TWICE — once for
    // the original boxed-error local the `raise` constructed (`box_as_protocol`
    // → `recoverable_raise(box)`) and once for the recovered local — because
    // the side-channel transfer was invisible to the ARC ownership pipeline,
    // so the consumed box still got a scope-exit release. Under `Memory.ARC`
    // the second decrement was masked by slab reuse; under `Memory.Tracking`
    // (which `munmap`s freed pages and runs no refcounts) the second drop
    // dereferenced the already-freed inner and SIGSEGV'd in
    // `freeAnyNonRefcountedImpl`'s by-value child-walk load.
    //
    // The boxed `pub error` carries a `message :: String` AND an auto-injected
    // `cause :: Option(Error)` — both ARC-managed children — so the inner's
    // deep child-walk is real (not a trivial shallow free). A clean exit here
    // means the recovered box's inner is freed EXACTLY once and the
    // Tracking live-set ends balanced.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "recovered_box_tracking.zap",
        \\@code Z9301
        \\pub error KeyError {
        \\  key :: Atom
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  result = try {
        \\    raise %KeyError{key: :missing, message: "absent"}
        \\  } rescue {
        \\    %KeyError{key: k} -> Atom.to_string(k)
        \\  }
        \\  IO.puts("recovered-ok=" <> result)
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "recovered-box-tracking failed: exit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
    }
    // Clean exit = no SIGSEGV (255) and no abort. A double-free/UAF on the
    // recovered box's inner crashed here before the fix.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "recovered-ok=missing") != null);
    // The recovered box's inner must be freed EXACTLY once: an under-free
    // regression (the dual of the double-free) leaves a survivor that
    // `src/runtime.zig` renders at deinit as `leak summary:` (the canonical
    // Tracking summary marker) plus a per-allocation `memory leak: …` line.
    // The earlier `"LEAK:"` probe never matched either marker, so it silently
    // guarded only the SIGSEGV — not a leak; assert on the real markers (same
    // detection as the Gap D sibling below) so this genuinely guards BOTH the
    // double-free crash AND the under-free leak.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
}

test "rescue: terminal CROSS-FN catch releases the recovered box under Memory.Tracking (Gap D, no leak)" {
    // Gap D regression: a CROSS-FUNCTION raise that propagates through the
    // error-union side-channel and is caught by a TERMINAL `rescue` (handled,
    // NOT re-raised) used to LEAK the boxed `Error` existential under
    // `Memory.Tracking` (masked under `Memory.ARC` by the refcount path).
    //
    // Unlike the LOCAL-raise terminal catch (the sibling `recovered_box_tracking`
    // test above, where the body's tail is a `raise` so `lowerTryRescue` takes
    // the FAST path and the box is a top-level owned local the generic
    // scope-exit drop pass releases at the function `ret`), here the `try` body's
    // tail is a CALL to a raising callee (`CrossFnWorker.boom()`). That takes the
    // SLOW landing-pad path: the box is recovered via `take_recoverable_raise`
    // INSIDE the landing-pad `then` branch, so it is dead by the function-exit
    // point and the generic drain never scheduled its release — the 40-byte
    // boxed `%CrossFnError{}` inner leaked. `lowerTryRescue` now emits the
    // owner-drop at the rescue handler's scope exit on the terminal-catch
    // fall-through (gated on a non-diverging dispatch), releasing the box
    // exactly once. The re-raise path re-boxes a fresh copy and diverges before
    // the drop, so there is no double-free (consistent with the Gap B transfer
    // and the Gap A borrowed-binding model).
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "cross_fn_catch_tracking.zap",
        \\@code Z9301
        \\pub error CrossFnError {}
        \\
        \\pub struct CrossFnWorker {
        \\  fn boom() -> String raises CrossFnError {
        \\    raise %CrossFnError{message: "cross-fn boom"}
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  result = try {
        \\    CrossFnWorker.boom()
        \\  } rescue {
        \\    e :: CrossFnError -> "caught"
        \\  }
        \\  IO.puts("recovered-ok=" <> result)
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "cross-fn-catch-tracking failed: exit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "recovered-ok=caught") != null);
    // The recovered box's inner must be freed exactly once: a survivor renders
    // the `leak summary:` line at deinit (the canonical Tracking leak marker;
    // the per-allocation line is `warning: memory leak: …`). Before the fix this
    // fired with `1 x \`%CrossFnError{}\` (40 B)`.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
}

test "boxed consuming dispatch: container inner disposed exactly once under Memory.Tracking" {
    // Regression (Job 4-R1 gap analysis of the parametric-protocol boxing
    // commit): a CONSUMING (`unique`-receiver) boxed dispatch whose impl
    // function carries the `.owned` receiver convention (`List.dispose` /
    // `Map.dispose` consuming the container through `:zig.*.release`) used to
    // dispose the receiver's inner cell with `freeAny`, whose
    // INDIVIDUAL_NO_REFCOUNT branch deep-walks the cell's ARC children. The
    // impl call had already consumed the inner value, so the walk released
    // the container a SECOND time — SIGSEGV inside the release walk
    // (`List.isIterCell` / `Map.release` on freed memory) under
    // `Memory.Tracking` (masked by slab reuse under `Memory.ARC`). The
    // adapter now routes `.owned`-receiver disposal through
    // `freeAnyConsumedCell` (cell reclaim, no child walk).
    //
    // Three container shapes cross the broken path: a List(String) state
    // disposed mid-iteration, a Map({Atom, String}) state disposed
    // mid-iteration, and a nested List([String]) state (a parametric-target
    // impl bound through the monomorphizer's BoxedImplSpec table).
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "boxed_container_dispose_tracking.zap",
        \\pub struct Probe {
        \\  pub fn list_mid_dispose() -> i64 {
        \\    strings = ["alpha", "beta", "gamma", "delta"]
        \\    case Enumerable.next(strings) {
        \\      {:cont, first, state} -> Probe.dispose_and_measure(first, state)
        \\      {:done, _, _} -> -1
        \\    }
        \\  }
        \\
        \\  fn dispose_and_measure(first :: String, state :: unique Enumerable(String)) -> i64 {
        \\    Enumerable.dispose(state)
        \\    String.length(first)
        \\  }
        \\
        \\  pub fn map_mid_dispose() -> i64 {
        \\    entries = %{alpha: "a" <> "1", beta: "b" <> "22", gamma: "c" <> "333"}
        \\    case Enumerable.next(entries) {
        \\      {:cont, first, state} -> Probe.dispose_entry_state(first, state)
        \\      {:done, _, _} -> -1
        \\    }
        \\  }
        \\
        \\  fn dispose_entry_state(first :: {Atom, String}, state :: unique Enumerable({Atom, String})) -> i64 {
        \\    Enumerable.dispose(state)
        \\    case first {
        \\      {_, text} -> String.length(text)
        \\    }
        \\  }
        \\
        \\  pub fn nested_mid_dispose() -> i64 {
        \\    nested = [["x" <> "x"], ["y" <> "yy", "z" <> "zzz"]]
        \\    case Enumerable.next(nested) {
        \\      {:cont, inner, state} -> Probe.dispose_nested_state(inner, state)
        \\      {:done, _, _} -> -1
        \\    }
        \\  }
        \\
        \\  fn dispose_nested_state(inner :: [String], state :: unique Enumerable([String])) -> i64 {
        \\    Enumerable.dispose(state)
        \\    String.length(List.head(inner))
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("list=#{Probe.list_mid_dispose()} map=#{Probe.map_mid_dispose()} nested=#{Probe.nested_mid_dispose()}")
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "boxed-container-dispose-tracking failed: exit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
    }
    // Clean exit = no SIGSEGV in the release walk. The values pin correct
    // iteration semantics; the leak markers pin the exactly-once contract's
    // under-free dual.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "list=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "nested=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
}

test "boxed dispatch tuple: excluded box component not swept into aggregate release under Memory.Tracking" {
    // Regression (Job 4-R1 gap analysis): a MULTI-FORMAL parametric protocol
    // whose dispatch returns a tuple carrying BOTH an ARC container ([b])
    // AND the boxed next state (Pairing(a, b)) used to double-claim the box.
    // The tuple-component-release DISCOVERY pass correctly excluded the box
    // component (it is a fresh owner in `deep_release_owned_locals`), but the
    // SCHEDULE pass re-derived membership from ARC-managedness alone — the
    // list component registered the aggregate, and the box was swept into the
    // balancing `aggregate_component` release while still moving into the
    // callee: the next dispatch read a freed cell (SIGSEGV in the adapter
    // under `Memory.Tracking`; masked by slab reuse under `Memory.ARC`).
    // `activateExtraction` now honors the discovery pass's exclusion set.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "boxed_multi_formal_tuple_tracking.zap",
        \\pub protocol Pairing(a, b) {
        \\  fn step(state :: unique Pairing(a, b)) -> {a, [b], Pairing(a, b)}
        \\  fn halt(state :: unique Pairing(a, b)) -> Nil
        \\}
        \\
        \\pub struct LabelCounter {
        \\  label :: String
        \\  counter :: i64
        \\}
        \\
        \\pub impl Pairing(String, i64) for LabelCounter {
        \\  pub fn step(state :: unique LabelCounter) -> {String, [i64], LabelCounter} {
        \\    {state.label, [state.counter, state.counter + 1], %LabelCounter{label: state.label, counter: state.counter + 2}}
        \\  }
        \\
        \\  pub fn halt(_state :: unique LabelCounter) -> Nil {
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct Probe {
        \\  pub fn make() -> Pairing(String, i64) {
        \\    %LabelCounter{label: "tick", counter: 5}
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    boxed = Probe.make()
        \\    case Pairing.step(boxed) {
        \\      {label, values, next_state} -> Probe.second_step(label, values, next_state)
        \\    }
        \\  }
        \\
        \\  fn second_step(label :: String, values :: [i64], state :: unique Pairing(String, i64)) -> i64 {
        \\    case Pairing.step(state) {
        \\      {label2, values2, next_state} ->
        \\        Probe.halt_and_sum(label, label2, values, values2, next_state)
        \\    }
        \\  }
        \\
        \\  fn halt_and_sum(label :: String, label2 :: String, values :: [i64], values2 :: [i64], state :: unique Pairing(String, i64)) -> i64 {
        \\    Pairing.halt(state)
        \\    String.length(label) + String.length(label2) + List.head(values) + List.last(values) + List.head(values2) + List.last(values2)
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  IO.puts("multi-formal=#{Probe.run()}")
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "boxed-multi-formal-tuple-tracking failed: exit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
    }
    // 4 ("tick") + 4 ("tick") + 5 + 6 + 7 + 8 = 34 pins two consecutive
    // dispatches through the SAME re-wrapped cell plus the halt disposal.
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "multi-formal=34") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
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

    const script_cache = scriptCacheDirForTmp(allocator, tmp_dir_path) catch
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
// Gap E — first-class closures as RETURN VALUES and STRUCT FIELDS
//
// #201 made closures work as `call_closure` PARAMETERS (a closure value
// passed to a higher-order fn and invoked). Gap E extends closure VALUES
// to the RETURN-VALUE and STRUCT-FIELD positions, and to being CALLED from
// those positions. Before the fix, a function declared to return a closure
// type lowered its return type to `void` (`mapReturnType`'s `.function`
// arm fell through to `0`), so the body's `*const fn() i64` value tripped
// `expected void, found *const fn () i64`; a closure-typed struct field
// hit `EmitFailed` because `emitTypeRef`/`emitImportedTypeRef` had no
// `.function` arm. Both symptoms reproduce with PURE (non-raising)
// closures, so these are general closure-value plumbing tests, not
// error-system tests. The fix renders a `.function` ZigType as a Zig
// function-pointer type (`*const fn(P...) Ret`) — which is exactly the
// runtime representation of a 0-capture closure value — at the return,
// field, and type-ref positions, and routes a `call_closure` whose callee
// is a field-access / return-value bare fn-ptr through a direct `call_ref`.
// ============================================================

test "closure: returned/field closures leak-free under Memory.Tracking (Gap E ARC balance)" {
    // The non-capturing closure value is a bare `*const fn() i64` code
    // pointer — NOT ARC-managed — so neither the returned nor the field-
    // stored closure may schedule a spurious retain/release on the code
    // pointer. Under `Memory.Tracking` (munmap + no refcounts) a spurious
    // release of a code pointer would crash or leak; a clean run with no
    // `leak summary:` / `memory leak:` markers proves the bare fn-ptr
    // carries no ARC obligation through these positions.
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var r = try runScriptInTmpWithFlags(allocator, &tmp_dir, "closure_field_tracking.zap",
        \\pub struct Handler {
        \\  action :: fn() -> i64
        \\}
        \\
        \\pub struct Factory {
        \\  pub fn build() -> Handler {
        \\    %Handler{ action: fn() -> i64 { 99 } }
        \\  }
        \\
        \\  pub fn make() -> fn() -> i64 {
        \\    fn() -> i64 { 7 }
        \\  }
        \\}
        \\
        \\fn main(_args :: [String]) -> u8 {
        \\  h = Factory.build()
        \\  g = Factory.make()
        \\  IO.puts(Integer.to_string(h.action() + g()))
        \\  0
        \\}
    , &.{"-Dmemory=Memory.Tracking"}, &.{});
    defer r.deinit();

    if (r.exit_code != 0) {
        std.debug.print(
            "closure-field-tracking failed: exit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "106") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leak summary:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "memory leak:") == null);
}

// ============================================================
// P2-J2 concurrency surface — compile-fail contracts. These pin the
// static guarantees of `lib/process.zap` / `lib/pid.zap`: the typed
// `Pid(M)` send discipline, the Phase-2 sendable-payload scope, the
// spawn closure-soundness restriction, and the zero-cost gate. They
// live in the zir-test harness because Zest cannot yet express
// compile-fail expectations (see CLAUDE.md "Test Placement").
// ============================================================

test "ZIR concurrency: Process.send rejects a message whose type mismatches the typed Pid(M)" {
    // `echo : Pid(i64)` — sending a String is a compile error (ordinary
    // generic type-checking of `send(pid :: Pid(m), message :: m)`, NOT
    // compiler magic): the typed handle is what makes an undecodable
    // message impossible.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    echo = Process.pid(i64, Process.self())
        \\    _sent = Process.send(echo, "hi")
        \\    0
        \\  }
        \\}
    ,
        "got `String`",
    );
}

test "ZIR concurrency: Process.spawn rejects a closure with a captured environment" {
    // A closure capturing `captured` would share the spawner's heap into
    // the child unsoundly, and closure environments are deliberately not
    // walker-sendable (the same sendability rule messages follow), so the
    // spawn surface rejects it at compile time — a durable v1 posture, not
    // a pending TODO.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    captured = 5
        \\    _child = Process.spawn(fn() -> Nil {
        \\      _ignore = captured
        \\      nil
        \\    })
        \\    0
        \\  }
        \\}
    ,
        "Process.spawn requires a named (or capture-less) zero-parameter function",
    );
}

test "ZIR concurrency: Process.send_move consumes its message — a use after the move is a compile error (P3-J5)" {
    // `Process.send_move` takes its message by a CONSUMING convention
    // (`message :: unique message_type`): the same-model O(1) region-move
    // transfers ownership of the value to the receiver, so the value is MOVED
    // out of the sender. Reusing it afterward is a use-after-move — caught by
    // the type checker's move tracking (`markBindingMoved` on passing a value to
    // a `unique` parameter, emitting the "was already moved" ownership error at
    // `src/types.zig`). This is the compile-time TOOTH the concurrency verifier's
    // C3 invariant anchors to the move-send boundary; without it a moved value's
    // dangling reference (the receiver now owns the cell) would go undetected.
    // WRITTEN, not run here (`zig build zir-test` is driven separately).
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    values = List.new_filled(3, 0 :: i64)
        \\    echo = (Pid.of(Process.self()) :: Pid(List(i64)))
        \\    _sent = Process.send_move(echo, values)
        \\    _reuse = values
        \\    0
        \\  }
        \\}
    ,
        "already moved",
    );
}

test "ZIR concurrency: Process.send_move of a Map consumes it too — use-after-move is a compile error (P6-J1)" {
    // The Map counterpart of the P3-J5 List pin above: `send_move`'s consuming
    // convention is type-agnostic (the `unique message_type` parameter), so a
    // flat Map message is moved out of the sender identically — the compile-time
    // TOOTH that makes the P6-J1 O(1) Map region-move sound (the receiver owns
    // the cell after the move; a sender reuse would read a re-parented cell).
    // WRITTEN, not run here (`zig build zir-test` is driven separately).
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    table = %{1 => 10, 2 => 20}
        \\    echo = (Pid.of(Process.self()) :: Pid(%{i64 => i64}))
        \\    _sent = Process.send_move(echo, table)
        \\    _reuse = table
        \\    0
        \\  }
        \\}
    ,
        "already moved",
    );
}

test "ZIR concurrency: a live Socket is MOVE-ONLY — a plain copy-Process.send is a compile error (Phase S1, Decision B)" {
    // A `Socket`/`SocketListener` is a single-owner, move-only generational
    // handle (`docs/socket-implementation-plan.md`, Decision B): the reserved
    // `zap_socket_handle` field is recognized STRUCTURALLY (like `zap_blob_handle`)
    // and the type is rejected from the deep-copy send walker
    // (`runtime.zig` `walkerStructType`/`isWalkerSendable`) while admitted at the
    // top level only for the MOVE send (`isTopLevelSendable`). So a plain
    // `Process.send` (the COPY primitive) of a live socket — which would hand two
    // processes the same fd, a data race — is a compile error at the send
    // primitive (`socketMoveOnlyCopySendError`). The sanctioned transfer is
    // `Process.send_move` (which consumes the handle). WRITTEN, not run here
    // (`zig build zir-test` is driven separately).
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    case Socket.listen(SocketAddress.loopback(0), 1) {
        \\      Result.Ok(listener) -> {
        \\        echo = (Pid.of(Process.self()) :: Pid(SocketListener))
        \\        _sent = Process.send(echo, listener)
        \\        _closed = SocketListener.close(listener)
        \\        0
        \\      }
        \\      Result.Error(_e) -> 0
        \\    }
        \\  }
        \\}
    ,
        "MOVE-ONLY socket handle",
    );
}

test "ZIR concurrency: a Socket move-sends cleanly — Process.send_move of a socket compiles (Phase S1, Decision B)" {
    // The move-only counterpart of the copy-send rejection above: a socket is
    // TOP-LEVEL sendable via `Process.send_move` (the move primitive
    // `send_message_moved`, which `isTopLevelSendable` admits for the socket
    // handle shape). `send_move` transfers the one-word handle to the receiver;
    // this pins that the sanctioned transfer path COMPILES (the copy path does
    // not). WRITTEN, not run here.
    var result = try compileAndRunGatedConcurrency(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    case Socket.listen(SocketAddress.loopback(0), 1) {
        \\      Result.Ok(listener) -> {
        \\        echo = (Pid.of(Process.self()) :: Pid(SocketListener))
        \\        _sent = Process.send_move(echo, listener)
        \\        0
        \\      }
        \\      Result.Error(_e) -> 0
        \\    }
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR concurrency: Process.receive_raw rejects an unsendable payload type token" {
    // `String` is outside the Phase-2 sendable set (fixed-size scalars);
    // the raw-receive token macro has no clause for it, so an unsendable
    // receive is rejected at compile time rather than fabricating bytes.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _value = Process.receive_raw(String)
        \\    0
        \\  }
        \\}
    ,
        "no macro clause of `receive_raw/1` matches the arguments",
    );
}

test "ZIR concurrency: Process.pid rejects an unsendable message-type token" {
    // A `Pid(String)` handle is unconstructable through the typed-handle
    // surface: `String` is not in the Phase-2 sendable token set, so the
    // `pid` token macro has no matching clause — you cannot stamp a handle
    // for a message type the runtime cannot carry.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _p = Process.pid(String, Process.self())
        \\    0
        \\  }
        \\}
    ,
        "no macro clause of `pid/2` matches the arguments",
    );
}

test "ZIR concurrency: a first-op spawn_monitor DOWN carries :normal, not the unregistered term (P5-R1 S5)" {
    // A FRESH gate-ON program whose FIRST signal operation is
    // `Process.spawn_monitor`: the immediately-returning worker's `DOWN`
    // must carry the real `:normal` reason atom. Before P5-R1 S5 only
    // `link`/`monitor`/`exit_signal`/`kill`/`exit_with` registered the
    // kernel reason atoms, so a first-op spawn_monitor delivered the
    // unregistered term (0) instead. This ordering is only observable in a
    // fresh binary — inside the Zest suite an earlier test has always
    // registered the atoms — hence the harness-level compile-and-run.
    var result = try compileAndRunGatedConcurrency(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _pair = Process.spawn_monitor(&TestProg.worker/0)
        \\    reason = Process.await_signal()
        \\    case reason == :normal {
        \\      true ->
        \\        {
        \\          IO.puts("first-op DOWN reason: normal")
        \\          0
        \\        }
        \\      false ->
        \\        {
        \\          IO.puts("first-op DOWN reason: WRONG")
        \\          1
        \\        }
        \\    }
        \\  }
        \\
        \\  pub fn worker() -> Nil {
        \\    nil
        \\  }
        \\}
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("first-op DOWN reason: normal\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "ZIR concurrency: Process.* is a compile error when the runtime_concurrency gate is OFF" {
    // The zero-cost guarantee, enforced: a gate-OFF binary carries no
    // concurrency kernel, so referencing any `Process` operation is a
    // comptime error (not a link failure) with an actionable message.
    try expectGateOffConcurrencyCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _bits = Process.self()
        \\    0
        \\  }
        \\}
    ,
        "Process operations require the concurrency runtime",
    );
}

// ============================================================
// P2-J3 `receive`/`after` — compile-fail contracts. These pin the
// static guarantees of the receive construct: the Phase-2 scalar
// message-type scope and the zero-cost gate. WRITTEN, not run here
// (`zig build zir-test` is driven separately); Zest cannot yet express
// compile-fail expectations (CLAUDE.md "Test Placement").
// ============================================================

test "ZIR concurrency: receive rejects a non-sendable message type" {
    // A payload-BEARING union is outside the Phase-2 sendable set. Only a
    // payload-free union is walker-sendable (it travels as its `u32` atom
    // id); a variant carrying a payload needs a union deep-copy walker that
    // Phase 2 does not have, so `typeIsWalkerSendable` (types.zig) rejects
    // it and `checkReceiveMessageUnion` emits the sendability diagnostic
    // naming the offending type. (Contrast `receive String`, which IS
    // walker-sendable as of P2-J5 and carries positive coverage in the
    // gate-ON suite — `test_concurrency/rich_message_test.zap`.) The receive
    // desugar defers message-type validity to the type checker (it cannot
    // resolve types); the checker rejects the rich type here.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub union Parcel {
        \\    Data :: i64
        \\    Empty
        \\  }
        \\  pub fn main() -> u8 {
        \\    _value = receive Parcel {
        \\      _msg -> 0
        \\    }
        \\    0
        \\  }
        \\}
    ,
        "message type `Parcel` is not sendable",
    );
}

test "ZIR concurrency: receive over a closed union must be exhaustive" {
    // A `receive` over the payload-free message union `Signal` that handles
    // `Ping` but not `Pong`, with no catch-all, is a non-exhaustive-match
    // compile error naming the unhandled variant — the P2-J4 message-union
    // exhaustiveness rule. The compiler-synthesized dead-letter arm is the
    // runtime out-of-union safety net and does NOT discharge the missing
    // in-union variant. (Payload-free union variants match as atom-literal
    // patterns, the shape of their `u32` atom-id representation.)
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub union Signal {
        \\    Ping,
        \\    Pong
        \\  }
        \\  pub fn main() -> u8 {
        \\    _got = receive Signal {
        \\      :Ping -> 1
        \\    after
        \\      0 -> -1
        \\    }
        \\    0
        \\  }
        \\}
    ,
        "non-exhaustive `receive` over message union `Signal`",
    );
}

test "ZIR concurrency: Process.send rejects a value outside the typed Pid(M) union" {
    // `server : Pid(Signal)` — sending a value that is not a `Signal` is a
    // compile error at the send site (ordinary generic type-checking of
    // `send(pid :: Pid(m), message :: m)`): the typed union handle makes an
    // out-of-union message impossible, exactly as it does for a scalar `M`.
    try expectGatedCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub union Signal {
        \\    Ping,
        \\    Pong
        \\  }
        \\  pub fn main() -> u8 {
        \\    server = (Pid.of(Process.self()) :: Pid(Signal))
        \\    _sent = Process.send(server, "hi")
        \\    0
        \\  }
        \\}
    ,
        "got `String`",
    );
}

test "ZIR concurrency: receive is a compile error when the runtime_concurrency gate is OFF" {
    // The zero-cost guarantee reaches the language construct: `receive`
    // desugars onto the gated `:zig.ProcessRuntime.*` primitives, so a
    // gate-OFF binary rejects it at comptime rather than link time.
    try expectGateOffConcurrencyCompileFailsWithDiagnostic(
        \\pub struct TestProg {
        \\  pub fn main() -> u8 {
        \\    _value = receive i64 {
        \\      n -> n
        \\    after
        \\      0 -> -1
        \\    }
        \\    0
        \\  }
        \\}
    ,
        "Process operations require the concurrency runtime",
    );
}
