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
    defer allocator.free(project_root);
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
    defer allocator.free(project_root);
    const output_path = try buildTarget(allocator, project_root, parsed.target.?, parsed.build_opts);
    defer allocator.free(output_path);

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
        \\          root: "{s}.main/1",
        \\          paths: ["lib/**/*.zap"],
        \\          # :debug | :release_safe | :release_fast | :release_small
        \\          optimize: :release_safe
        \\        }}
        \\      :test ->
        \\        %Zap.Manifest{{
        \\          name: "{s}_test",
        \\          version: "0.1.0",
        \\          kind: :bin,
        \\          root: "{s}Test.main/1",
        \\          paths: ["lib/**/*.zap", "test/**/*.zap"],
        \\          optimize: :debug
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
        \\defmodule {s} do
        \\  def main(_args :: [String]) do
        \\    IO.puts("Howdy!")
        \\  end
        \\end
        \\
    , .{module_name});
    defer allocator.free(lib_source);
    try writeFile(lib_path, lib_source);

    // test/<project_name>_test.zap
    const test_path = try std.fmt.allocPrint(allocator, "test/{s}_test.zap", .{project_name});
    defer allocator.free(test_path);
    const test_source = try std.fmt.allocPrint(allocator,
        \\defmodule {s}Test do
        \\  def main(_args :: [String]) do
        \\    IO.puts("Test Suite TBD")
        \\  end
        \\end
        \\
    , .{module_name});
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

    const builder = zap.builder;
    const stderr_w = std.fs.File.stderr().deprecatedWriter();

    // Read build.zap
    const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    const build_source = std.fs.cwd().readFileAlloc(alloc, build_file_path, 10 * 1024 * 1024) catch |err| {
        try stderr_w.print("Error reading build.zap: {}\n", .{err});
        std.process.exit(1);
    };

    // Extract manifest from build.zap AST.
    // The compiled builder path (compile build.zap as binary, execute, capture
    // output) is implemented but blocked by the Zig self-hosted linker producing
    // zero-filled binaries. AST extraction handles static manifests correctly.
    _ = build_opts;
    const config = builder.extractManifestFromAST(alloc, build_source, target_name) catch {
        std.process.exit(1);
    };

    // Compiled builder path — disabled until Zig linker produces valid binaries.
    // When enabled, this compiles build.zap as a builder binary, spawns it with
    // target/os/arch args, and captures the manifest output from stdout.
    if (false) { // TODO: enable when Zig linker is fixed
        const manifest_func_name = builder.findBuilderManifestName(alloc, build_source) catch |err| {
            switch (err) {
                error.ManifestNotFound => try stderr_w.print("Error: build.zap must define manifest/1\n", .{}),
                error.ParseFailed => try stderr_w.print("Error: failed to parse build.zap\n", .{}),
                else => try stderr_w.print("Error: {}\n", .{err}),
            }
            std.process.exit(1);
        };

        // Compile build.zap as a builder binary
        const builder_path = try std.fs.path.join(alloc, &.{ ".zap-cache", "builder" });
        const zig_lib_dir = zir_backend.detectZigLibDir(alloc) orelse blk: {
            break :blk extractEmbeddedZigLib(alloc) catch {
                try stderr_w.print("Error: could not find or extract Zig lib\n", .{});
                std.process.exit(1);
            };
        };

        std.fs.cwd().makePath(".zap-cache") catch {};

        // Compile build.zap through the full pipeline with builder_entry set
        const build_result = compiler.compileFrontend(alloc, build_source, build_file_path, .{
            .show_progress = false,
        }) catch {
            std.process.exit(1);
        };

        zir_backend.compile(alloc, build_result.ir_program, .{
            .zig_lib_dir = zig_lib_dir,
            .cache_dir = ".zap-cache",
            .global_cache_dir = ".zap-cache",
            .output_path = builder_path,
            .name = "builder",
            .runtime_source = compiler.getRuntimeSource(),
            .builder_entry = manifest_func_name,
            .analysis_context = if (build_result.analysis_context) |*ctx| ctx else null,
        }) catch {
            try stderr_w.print("Error: failed to compile build.zap\n", .{});
            std.process.exit(1);
        };

        // Spawn the builder binary: .zap-cache/builder <target> <os> <arch>
        const os_name = @tagName(@import("builtin").os.tag);
        const arch_name = @tagName(@import("builtin").cpu.arch);

        const spawn_result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ builder_path, target_name, os_name, arch_name },
            .max_output_bytes = 1024 * 1024,
        }) catch |err| {
            try stderr_w.print("Error: failed to run builder: {}\n", .{err});
            std.process.exit(1);
        };

        if (spawn_result.term != .Exited or spawn_result.term.Exited != 0) {
            if (spawn_result.stderr.len > 0) {
                try stderr_w.print("{s}", .{spawn_result.stderr});
            }
            try stderr_w.print("Error: builder failed\n", .{});
            std.process.exit(1);
        }

        // Parse the builder's stdout output into BuildConfig
        _ = builder.parseManifestOutput(alloc, spawn_result.stdout) catch {
            try stderr_w.print("Error: failed to parse builder output\n", .{});
            std.process.exit(1);
        };
    } // end if (false) compiled builder block

    // Detect zig lib dir
    const zig_lib_dir = zir_backend.detectZigLibDir(alloc) orelse blk: {
        break :blk extractEmbeddedZigLib(alloc) catch {
            try stderr_w.print("Error: could not find or extract Zig lib\n", .{});
            std.process.exit(1);
        };
    };

    // Scan source files from manifest path globs
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (config.paths) |pattern| {
        try globCollectFiles(alloc, project_root, pattern, &source_files);
    }

    if (source_files.items.len == 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: no .zap source files found in paths\n", .{});
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

    // Determine output path from manifest (needed for cache check)
    const output_name = if (config.asset_name) |an|
        if (an.len > 0) an else config.name
    else
        config.name;

    const out_dir: []const u8 = switch (config.kind) {
        .bin => "zap-out/bin",
        .lib => "zap-out/lib",
        .obj => "zap-out/obj",
    };
    std.fs.cwd().makePath(".zap-cache") catch {};
    std.fs.cwd().makePath(out_dir) catch {};

    const output_filename = switch (config.kind) {
        .bin => output_name,
        .lib => try std.fmt.allocPrint(alloc, "{s}.a", .{output_name}),
        .obj => try std.fmt.allocPrint(alloc, "{s}.o", .{output_name}),
    };
    const output_path = try std.fs.path.join(alloc, &.{ out_dir, output_filename });

    // Compilation caching: hash build.zap + all sources + target name
    const cache_key = blk: {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(build_source);
        hasher.update(merged_source);
        hasher.update(target_name);
        break :blk hasher.final();
    };
    const cache_key_hex = try std.fmt.allocPrint(alloc, "{x:0>16}", .{cache_key});
    const hash_file = try std.fmt.allocPrint(alloc, ".zap-cache/{s}.hash", .{target_name});

    const cache_valid = blk: {
        const stored = std.fs.cwd().readFileAlloc(alloc, hash_file, 16) catch break :blk false;
        defer alloc.free(stored);
        if (!std.mem.eql(u8, stored, cache_key_hex)) break :blk false;
        std.fs.cwd().access(output_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (cache_valid) {
        const progress = std.fs.File.stderr().deprecatedWriter();
        progress.print("[cached] {s}\n", .{output_path}) catch {};
        return try allocator.dupe(u8, output_path);
    }

    // Determine lib_mode from manifest kind
    const lib_mode = config.kind == .lib;

    // Compile through frontend
    const result = compiler.compileFrontend(alloc, merged_source, source_files.items[0], .{
        .lib_mode = lib_mode,
    }) catch {
        std.process.exit(1);
    };

    // Map optimize mode from manifest
    const optimize_mode: u8 = switch (config.optimize) {
        .debug => 0,
        .release_safe => 1,
        .release_fast => 2,
        .release_small => 3,
    };

    // Compile through ZIR backend (zig_lib_dir already resolved above)
    const output_mode_val: u8 = switch (config.kind) {
        .bin => 0,
        .lib => 1,
        .obj => 2,
    };
    zir_backend.compile(alloc, result.ir_program, .{
        .zig_lib_dir = zig_lib_dir,
        .cache_dir = ".zap-cache",
        .global_cache_dir = ".zap-cache",
        .output_path = output_path,
        .name = output_name,
        .runtime_source = compiler.getRuntimeSource(),
        .output_mode = output_mode_val,
        .optimize_mode = optimize_mode,
        .analysis_context = if (result.analysis_context) |*ctx| ctx else null,
    }) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: compilation failed\n", .{});
        std.process.exit(1);
    };

    // Save cache hash
    std.fs.cwd().writeFile(.{
        .sub_path = hash_file,
        .data = cache_key_hex,
    }) catch {};

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
// Glob-based source file collection
// ---------------------------------------------------------------------------

/// Match a file path against a simple glob pattern.
/// Supports: `*` (any non-/ chars), `**` (any path depth), literal chars.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0; // pattern index
    var si: usize = 0; // string (path) index
    var star_pi: ?usize = null; // pattern index after last `*`
    var star_si: usize = 0; // string index at last `*` match

    while (si < path.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            // Check for `**`
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                // `**` — skip the `**` and optional following `/`
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                // `**` can match everything remaining — try greedy with backtrack
                star_pi = pi;
                star_si = si;
                continue;
            }
            // Single `*` — matches non-/ characters
            star_pi = pi + 1;
            star_si = si;
            pi += 1;
            continue;
        }

        if (pi < pattern.len and (pattern[pi] == path[si] or pattern[pi] == '?')) {
            pi += 1;
            si += 1;
            continue;
        }

        // Mismatch — backtrack to last star
        if (star_pi) |sp| {
            pi = sp;
            star_si += 1;
            si = star_si;
            // For single `*`, skip over '/' in path (don't match across dirs)
            // Check if this was a `**` by looking back
            if (sp >= 2 and pattern[sp - 2] == '*' and pattern[sp - 1] == '*') {
                // `**` — can cross directory boundaries
                continue;
            }
            // Single `*` — cannot cross `/`
            if (si > 0 and path[si - 1] == '/') return false;
            continue;
        }

        return false;
    }

    // Consume trailing stars/wildcards in pattern
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}

    return pi == pattern.len;
}

/// Collect .zap files matching a glob pattern, relative to project_root.
/// Always excludes build.zap.
fn globCollectFiles(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    pattern: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    // Determine the base directory (everything before the first wildcard)
    var base_end: usize = 0;
    for (pattern, 0..) |c, i| {
        if (c == '*' or c == '?') break;
        if (c == '/') base_end = i + 1;
    }

    const base_rel = if (base_end > 0) pattern[0..base_end] else ".";
    const sub_pattern = if (base_end > 0) pattern[base_end..] else pattern;
    const has_double_star = std.mem.indexOf(u8, sub_pattern, "**") != null;

    const base_dir = if (std.mem.eql(u8, base_rel, "."))
        try alloc.dupe(u8, project_root)
    else
        try std.fs.path.join(alloc, &.{ project_root, base_rel });

    try walkAndMatch(alloc, base_dir, base_dir, sub_pattern, project_root, has_double_star, results);
}

fn walkAndMatch(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    base_dir: []const u8,
    pattern: []const u8,
    project_root: []const u8,
    recurse: bool,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        const full_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });

        if (entry.kind == .directory and recurse) {
            try walkAndMatch(alloc, full_path, base_dir, pattern, project_root, recurse, results);
        }

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;

        // Build path relative to base_dir for matching against sub_pattern
        const match_path = if (std.mem.startsWith(u8, dir_path, base_dir) and dir_path.len > base_dir.len)
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path[base_dir.len + 1 ..], entry.name })
        else
            try alloc.dupe(u8, entry.name);

        // Strip leading "./" from pattern for matching
        const clean_pattern = if (std.mem.startsWith(u8, pattern, "./"))
            pattern[2..]
        else
            pattern;

        if (!globMatch(clean_pattern, match_path)) continue;

        // Always exclude build.zap in the project root
        if (std.mem.eql(u8, std.fs.path.basename(full_path), "build.zap")) {
            const dir_of_file = std.fs.path.dirname(full_path) orelse ".";
            if (std.mem.eql(u8, dir_of_file, project_root)) continue;
        }

        // Avoid duplicates
        var dup = false;
        for (results.items) |existing| {
            if (std.mem.eql(u8, existing, full_path)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            try results.append(alloc, full_path);
        }
    }
}

test "globMatch basics" {
    // Exact match
    try std.testing.expect(globMatch("foo.zap", "foo.zap"));
    try std.testing.expect(!globMatch("foo.zap", "bar.zap"));

    // Single * matches filename chars but not /
    try std.testing.expect(globMatch("*.zap", "foo.zap"));
    try std.testing.expect(globMatch("*.zap", "bar.zap"));
    try std.testing.expect(!globMatch("*.zap", "lib/foo.zap"));

    // ** matches across directories
    try std.testing.expect(globMatch("**/*.zap", "foo.zap"));
    try std.testing.expect(globMatch("**/*.zap", "lib/foo.zap"));
    try std.testing.expect(globMatch("**/*.zap", "lib/sub/foo.zap"));

    // Prefixed glob
    try std.testing.expect(globMatch("lib/**/*.zap", "lib/foo.zap"));
    try std.testing.expect(globMatch("lib/**/*.zap", "lib/sub/foo.zap"));
    try std.testing.expect(!globMatch("lib/**/*.zap", "test/foo.zap"));

    // Specific file
    try std.testing.expect(globMatch("./hello.zap", "hello.zap"));
    try std.testing.expect(!globMatch("./hello.zap", "other.zap"));
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
