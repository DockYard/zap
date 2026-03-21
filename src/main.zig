const std = @import("std");
const zap = @import("zap");
const compiler = zap.compiler;
const zir_backend = zap.zir_backend;
const zir_builder = zap.zir_builder;
const zig_lib_archive = @import("zig_lib_archive");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(0);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        std.process.exit(0);
    } else if (std.mem.eql(u8, command, "build")) {
        try cmdBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "run")) {
        try cmdRun(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator);
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown command: {s}\n\nRun 'zap --help' for usage.\n", .{command});
        std.process.exit(1);
    }
}

fn printUsage() void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print(
        \\Usage: zap <command> [options]
        \\
        \\Commands:
        \\  build <target>    Build the specified target
        \\  run <target>      Build and run the specified bin target
        \\  init              Scaffold a new project in the current directory
        \\
        \\Options:
        \\  -Dkey=value       Pass build option to the builder
        \\  --build-file <path>  Use a specific build file (default: build.zap)
        \\  -- <args...>      Pass arguments to the program (run only)
        \\
        \\Examples:
        \\  zap build my_app
        \\  zap build my_app -Doptimize=release_fast
        \\  zap run my_app -- arg1 arg2
        \\  zap init
        \\
    , .{}) catch {};
}

// ---------------------------------------------------------------------------
// Command: build
// ---------------------------------------------------------------------------

fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    if (parsed.target == null) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: zap build requires a target name\n\nUsage: zap build <target> [-Dkey=value...]\n", .{});
        std.process.exit(1);
    }

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    const output_path = try buildTarget(allocator, project_root, parsed.target.?, parsed.build_opts);
    allocator.free(output_path);
}

// ---------------------------------------------------------------------------
// Command: run
// ---------------------------------------------------------------------------

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    if (parsed.target == null) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: zap run requires a target name\n\nUsage: zap run <target> [-Dkey=value...] [-- program-args...]\n", .{});
        std.process.exit(1);
    }

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    const output_path = try buildTarget(allocator, project_root, parsed.target.?, parsed.build_opts);

    // Run the built binary
    const exit_code = compiler.runBinary(allocator, output_path, parsed.run_args) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error running program: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: init
// ---------------------------------------------------------------------------

fn cmdInit(allocator: std.mem.Allocator) !void {
    // Check directory is empty
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: cannot open current directory\n", .{});
        std.process.exit(1);
    };
    defer dir.close();

    var iter = dir.iterate();
    if (iter.next() catch null) |_| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: directory is not empty\n", .{});
        std.process.exit(1);
    }

    // Derive names from directory
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const dir_name = std.fs.path.basename(cwd_path);

    // Convert to snake_case project name (handle kebab-case)
    const project_name = try toSnakeCase(allocator, dir_name);
    defer allocator.free(project_name);

    // Convert to PascalCase module name
    const module_name = try toPascalCase(allocator, project_name);
    defer allocator.free(module_name);

    // Generate files
    try std.fs.cwd().makePath("lib");
    try std.fs.cwd().makePath("test");

    // .gitignore
    try writeFile(".gitignore",
        \\.zap-cache/
        \\zap-out/
        \\
    );

    // README.md
    const readme = try std.fmt.allocPrint(allocator,
        \\# {s}
        \\
        \\## Build
        \\
        \\    zap build {s}
        \\
        \\## Run
        \\
        \\    zap run {s}
        \\
        \\## Test
        \\
        \\    zap run test
        \\
    , .{ project_name, project_name, project_name });
    defer allocator.free(readme);
    try writeFile("README.md", readme);

    // build.zap
    const build_zap = try std.fmt.allocPrint(allocator,
        \\defmodule {s}.Builder do
        \\  def manifest(env :: Zap.Env) :: Zap.Manifest do
        \\    case env.target do
        \\      :{s} ->
        \\        %Zap.Manifest{{
        \\          name: "{s}",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "{s}.main/0",
        \\          paths: ["lib"]
        \\        }}
        \\      :test ->
        \\        %Zap.Manifest{{
        \\          name: "{s}_test",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "{s}Test.main/0",
        \\          paths: ["lib", "test"]
        \\        }}
        \\      _ ->
        \\        panic("Unknown target: use '{s}' or 'test'")
        \\    end
        \\  end
        \\end
        \\
    , .{ module_name, project_name, project_name, module_name, project_name, module_name, project_name });
    defer allocator.free(build_zap);
    try writeFile("build.zap", build_zap);

    // lib/<project_name>.zap
    const lib_path = try std.fmt.allocPrint(allocator, "lib/{s}.zap", .{project_name});
    defer allocator.free(lib_path);
    const lib_source = try std.fmt.allocPrint(allocator,
        \\def main() do
        \\  IO.puts("Howdy!")
        \\end
        \\
    , .{});
    defer allocator.free(lib_source);
    try writeFile(lib_path, lib_source);

    // test/<project_name>_test.zap
    const test_path = try std.fmt.allocPrint(allocator, "test/{s}_test.zap", .{project_name});
    defer allocator.free(test_path);
    const test_source = try std.fmt.allocPrint(allocator,
        \\def main() do
        \\  IO.puts("Test Suite TBD")
        \\end
        \\
    , .{});
    defer allocator.free(test_source);
    try writeFile(test_path, test_source);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Created project '{s}'\n\n  zap build {s}\n  zap run {s}\n  zap run test\n", .{ project_name, project_name, project_name });
}

// ---------------------------------------------------------------------------
// Build pipeline
// ---------------------------------------------------------------------------

/// Build a target. Returns the output binary path (arena-allocated).
fn buildTarget(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read build.zap
    const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    const build_source = std.fs.cwd().readFileAlloc(alloc, build_file_path, 10 * 1024 * 1024) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error reading build.zap: {}\n", .{err});
        std.process.exit(1);
    };

    // TODO: Phase 3 — Compile build.zap as a separate binary, execute it,
    // capture the Zap.Manifest output.
    //
    // For now, parse build.zap to find manifest/1 and extract a minimal
    // manifest by scanning the AST for the target's configuration.
    // This is a temporary bridge until the builder runtime is implemented.

    _ = build_source;
    _ = build_opts;

    // Temporary: scan for source files in lib/ and compile directly
    const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;

    // Scan lib/ for .zap files
    if (std.fs.cwd().openDir(lib_dir, .{ .iterate = true })) |*dir| {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zap")) {
                const full_path = try std.fs.path.join(alloc, &.{ lib_dir, entry.name });
                try source_files.append(alloc, full_path);
            }
        }
    } else |_| {}

    // Also scan test/ if target is "test"
    if (std.mem.eql(u8, target_name, "test")) {
        const test_dir = try std.fs.path.join(alloc, &.{ project_root, "test" });
        if (std.fs.cwd().openDir(test_dir, .{ .iterate = true })) |*dir| {
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zap")) {
                    const full_path = try std.fs.path.join(alloc, &.{ test_dir, entry.name });
                    try source_files.append(alloc, full_path);
                }
            }
        } else |_| {}
    }

    if (source_files.items.len == 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: no .zap source files found for target '{s}'\n", .{target_name});
        std.process.exit(1);
    }

    // Read and concatenate all sources
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    for (source_files.items) |sf| {
        const src = try std.fs.cwd().readFileAlloc(alloc, sf, 10 * 1024 * 1024);
        try combined.appendSlice(alloc, src);
        try combined.append(alloc, '\n');
    }
    const merged_source = combined.items;

    // Compile through frontend
    const result = compiler.compileFrontend(alloc, merged_source, source_files.items[0], .{}) catch {
        std.process.exit(1);
    };

    // Determine output path
    std.fs.cwd().makePath(".zap-cache") catch {};
    const out_dir = "zap-out/bin";
    std.fs.cwd().makePath(out_dir) catch {};
    const output_path = try std.fs.path.join(alloc, &.{ out_dir, target_name });

    // Detect zig lib
    const zig_lib_dir = zir_backend.detectZigLibDir(alloc) orelse blk: {
        break :blk extractEmbeddedZigLib(alloc) catch {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Error: could not find or extract Zig lib\n", .{});
            std.process.exit(1);
        };
    };

    // Compile through ZIR backend
    zir_backend.compile(alloc, result.ir_program, .{
        .zig_lib_dir = zig_lib_dir,
        .cache_dir = ".zap-cache",
        .global_cache_dir = ".zap-cache",
        .output_path = output_path,
        .name = target_name,
        .runtime_source = compiler.getRuntimeSource(),
    }) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: compilation failed\n", .{});
        std.process.exit(1);
    };

    // Return a durable copy of the output path
    return try allocator.dupe(u8, output_path);
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const ParsedArgs = struct {
    target: ?[]const u8,
    build_file: ?[]const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    run_args: []const []const u8,

    fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        self.build_opts.deinit(allocator);
    }
};

fn parseTargetArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var result = ParsedArgs{
        .target = null,
        .build_file = null,
        .build_opts = .empty,
        .run_args = &.{},
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is program args
            if (i + 1 < args.len) {
                result.run_args = args[i + 1 ..];
            }
            break;
        } else if (std.mem.eql(u8, arg, "--build-file")) {
            i += 1;
            if (i < args.len) {
                result.build_file = args[i];
            } else {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                try stderr.print("Error: --build-file requires a path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            // Parse -Dkey=value
            const kv = arg[2..];
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                try result.build_opts.put(allocator, kv[0..eq], kv[eq + 1 ..]);
            } else {
                try result.build_opts.put(allocator, kv, "true");
            }
        } else if (result.target == null) {
            result.target = arg;
        } else {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Error: unexpected argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Build file discovery
// ---------------------------------------------------------------------------

/// Find build.zap and return the project root directory.
fn discoverBuildFile(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |path| {
        // Verify the override file exists
        std.fs.cwd().access(path, .{}) catch {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Error: build file not found: {s}\n", .{path});
            std.process.exit(1);
        };
        // Project root is the directory containing the build file
        if (std.fs.path.dirname(path)) |dir| {
            return try allocator.dupe(u8, dir);
        }
        return try allocator.dupe(u8, ".");
    }

    // Default: look for build.zap in cwd
    std.fs.cwd().access("build.zap", .{}) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: no build.zap found in current directory\n", .{});
        std.process.exit(1);
    };

    return try allocator.dupe(u8, ".");
}

// ---------------------------------------------------------------------------
// String utilities
// ---------------------------------------------------------------------------

fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (input) |c| {
        if (c == '-') {
            try result.append(allocator, '_');
        } else {
            try result.append(allocator, c);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn toPascalCase(allocator: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var capitalize_next = true;
    for (snake) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next and c >= 'a' and c <= 'z') {
                try result.append(allocator, c - 32);
            } else {
                try result.append(allocator, c);
            }
            capitalize_next = false;
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn extractEmbeddedZigLib(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.FileNotFound;
    defer allocator.free(home);

    const lib_dir = try std.fs.path.join(allocator, &.{ home, ".cache", "zap", "zig-lib" });

    const marker = try std.fs.path.join(allocator, &.{ lib_dir, "std", "std.zig" });
    defer allocator.free(marker);

    if (std.fs.cwd().access(marker, .{})) |_| {
        return lib_dir;
    } else |_| {}

    std.fs.cwd().makePath(lib_dir) catch {};

    var dir = std.fs.cwd().openDir(lib_dir, .{}) catch return error.FileNotFound;
    defer dir.close();

    var reader = std.Io.Reader.fixed(zig_lib_archive.data);
    std.tar.pipeToFileSystem(dir, &reader, .{}) catch return error.FileNotFound;

    return lib_dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Error writing {s}: {}\n", .{ path, err }) catch {};
        return err;
    };
}
