const std = @import("std");

const OUTPUT_LIMIT = 8 * 1024 * 1024;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = .{
            .stdout = &.{},
            .stderr = &.{},
            .exit_code = 0,
            .allocator = self.allocator,
        };
    }
};

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

fn getTestIo() std.Io {
    return std.testing.io;
}

fn resolveZapBinary(allocator: std.mem.Allocator) ![:0]u8 {
    const zap_binary_raw: []const u8 = getenvSlice("ZAP_BINARY") orelse "zig-out/bin/zap";
    if (std.fs.path.isAbsolute(zap_binary_raw)) {
        return try allocator.dupeZ(u8, zap_binary_raw);
    }
    return std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), zap_binary_raw, allocator);
}

fn resolveRepoStdlibDir(allocator: std.mem.Allocator) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(getTestIo(), "lib", allocator);
}

fn writeProject(tmp_dir: *std.testing.TmpDir) !void {
    try tmp_dir.dir.createDirPath(getTestIo(), "lib");
    try tmp_dir.dir.createDirPath(getTestIo(), "test");

    try tmp_dir.dir.writeFile(getTestIo(), .{
        .sub_path = "build.zap",
        .data =
        \\pub struct CacheBug.Builder {
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
        \\    case env.target {
        \\      :test ->
        \\        %Zap.Manifest{
        \\          name: "cache_bug_test",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: &TestRunner.main/1,
        \\          paths: ["lib/**/*.zap", "test/**/*_test.zap", "test/test_runner.zap"]
        \\        }
        \\      _ ->
        \\        panic("Unknown target")
        \\    }
        \\  }
        \\}
        \\
        ,
    });

    try tmp_dir.dir.writeFile(getTestIo(), .{
        .sub_path = "test/test_runner.zap",
        .data =
        \\@compile_after_glob = "test/**/*_test.zap"
        \\
        \\pub struct TestRunner {
        \\  use Zest.Runner, pattern: "test/**/*_test.zap"
        \\}
        \\
        ,
    });

    try tmp_dir.dir.writeFile(getTestIo(), .{
        .sub_path = "test/bool_dep_test.zap",
        .data =
        \\pub struct BoolDepTest {
        \\  use Zest.Case
        \\
        \\  test("negate flips true") {
        \\    reject(BoolDep.negate(true))
        \\  }
        \\
        \\  test("negate flips false") {
        \\    assert(BoolDep.negate(false))
        \\  }
        \\}
        \\
        ,
    });
}

fn writeBoolDep(tmp_dir: *std.testing.TmpDir, comptime broken: bool) !void {
    const source = if (broken)
        \\pub struct BoolDep {
        \\  pub fn negate(true) -> Bool {
        \\    true
        \\  }
        \\
        \\  pub fn negate(false) -> Bool {
        \\    false
        \\  }
        \\}
        \\
    else
        \\pub struct BoolDep {
        \\  pub fn negate(true) -> Bool {
        \\    false
        \\  }
        \\
        \\  pub fn negate(false) -> Bool {
        \\    true
        \\  }
        \\}
        \\
    ;
    try tmp_dir.dir.writeFile(getTestIo(), .{ .sub_path = "lib/bool_dep.zap", .data = source });
}

fn runZapTest(
    allocator: std.mem.Allocator,
    zap_binary: []const u8,
    project_root: []const u8,
    repo_lib: []const u8,
) !RunResult {
    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();
    _ = env_map.swapRemove("ZAP_LIB_DIR");
    try env_map.put("ZAP_LIB_DIR", repo_lib);

    const result = try std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "test", "--seed", "123" },
        .cwd = .{ .path = project_root },
        .environ_map = &env_map,
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
    });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

fn shutdownManifestDaemons(
    allocator: std.mem.Allocator,
    zap_binary: []const u8,
    project_root: []const u8,
) void {
    const result = std.process.run(allocator, getTestIo(), .{
        .argv = &.{ zap_binary, "__manifest-incremental-daemon-shutdown-all" },
        .cwd = .{ .path = project_root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        std.debug.print("warning: could not shut down manifest daemon: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_successfully = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_successfully) {
        std.debug.print(
            \\warning: manifest daemon shutdown command failed
            \\stdout:
            \\{s}
            \\stderr:
            \\{s}
            \\
        , .{ result.stdout, result.stderr });
    }
}

fn outputContains(result: RunResult, needle: []const u8) bool {
    return std.mem.indexOf(u8, result.stdout, needle) != null or
        std.mem.indexOf(u8, result.stderr, needle) != null;
}

fn expectOutputContains(result: RunResult, needle: []const u8) !void {
    if (outputContains(result, needle)) return;
    std.debug.print(
        \\expected zap test output to contain:
        \\  {s}
        \\exit code: {d}
        \\stdout:
        \\{s}
        \\stderr:
        \\{s}
        \\
    , .{ needle, result.exit_code, result.stdout, result.stderr });
    return error.TestUnexpectedResult;
}

fn expectExitCode(result: RunResult, expected_exit_code: u8) !void {
    if (result.exit_code == expected_exit_code) return;
    std.debug.print(
        \\expected zap test exit code {d}, got {d}
        \\stdout:
        \\{s}
        \\stderr:
        \\{s}
        \\
    , .{ expected_exit_code, result.exit_code, result.stdout, result.stderr });
    return error.TestUnexpectedResult;
}

fn expectNonZeroExit(result: RunResult) !void {
    if (result.exit_code != 0) return;
    std.debug.print(
        \\expected zap test to fail, but it exited 0
        \\stdout:
        \\{s}
        \\stderr:
        \\{s}
        \\
    , .{ result.stdout, result.stderr });
    return error.TestUnexpectedResult;
}

fn expectPassed(result: RunResult) !void {
    try expectExitCode(result, 0);
}

fn expectBoolDepFailures(result: RunResult) !void {
    try expectNonZeroExit(result);
    try expectOutputContains(result, "BoolDepTest");
    try expectOutputContains(result, "negate flips true");
    try expectOutputContains(result, "negate flips false");
}

test "manifest cache invalidates dependency edits consistently with clean test builds" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeProject(&tmp_dir);
    try writeBoolDep(&tmp_dir, false);

    const project_root = try tmp_dir.dir.realPathFileAlloc(getTestIo(), ".", allocator);
    defer allocator.free(project_root);
    const repo_lib = try resolveRepoStdlibDir(allocator);
    defer allocator.free(repo_lib);
    const zap_binary = try resolveZapBinary(allocator);
    defer allocator.free(zap_binary);
    defer shutdownManifestDaemons(allocator, zap_binary, project_root);

    var clean_pass = try runZapTest(allocator, zap_binary, project_root, repo_lib);
    defer clean_pass.deinit();
    try expectPassed(clean_pass);

    try writeBoolDep(&tmp_dir, true);

    var incremental_fail = try runZapTest(allocator, zap_binary, project_root, repo_lib);
    defer incremental_fail.deinit();
    try expectBoolDepFailures(incremental_fail);

    try tmp_dir.dir.deleteTree(getTestIo(), ".zap-cache");

    var clean_fail = try runZapTest(allocator, zap_binary, project_root, repo_lib);
    defer clean_fail.deinit();
    try expectBoolDepFailures(clean_fail);

    try writeBoolDep(&tmp_dir, false);

    var incremental_pass = try runZapTest(allocator, zap_binary, project_root, repo_lib);
    defer incremental_pass.deinit();
    try expectPassed(incremental_pass);
}
