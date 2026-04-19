const std = @import("std");
const Io = std.Io;
const zap = @import("zap");
const compiler = zap.compiler;
const zir_backend = zap.zir_backend;
const zir_builder = zap.zir_builder;
const zig_lib_archive = @import("zig_lib_archive");
const env = zap.env;

/// Global Io instance for main thread operations.
var global_io: Io = std.Options.debug_io;

pub fn main(init: std.process.Init) !void {
    // Use Io and allocator from Init — no manual setup needed.
    global_io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
    } else if (std.mem.eql(u8, command, "test")) {
        try cmdTest(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator);
    } else if (std.mem.eql(u8, command, "deps")) {
        try cmdDeps(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "doc")) {
        try cmdDoc(allocator, args[2..]);
    } else {
        // stderr writer removed in 0.16
        std.debug.print("Error: unknown command: {s}\n\nRun 'zap --help' for usage.\n", .{command});
        std.process.exit(1);
    }
}

fn printUsage() void {
    // stderr writer removed in 0.16
    std.debug.print(
        \\Usage: zap <command> [options]
        \\
        \\Commands:
        \\  build [target]    Build the specified target (defaults to :default)
        \\  run [target]      Build and run the specified bin target (defaults to :default)
        \\  test [options]    Run the test suite
        \\  init              Scaffold a new project in the current directory
        \\  doc [options]     Generate documentation from @doc attributes
        \\  deps update       Re-resolve all dependencies and rewrite zap.lock
        \\  deps update <name> Re-resolve a single dependency
        \\
        \\Options:
        \\  -Dkey=value       Pass build option to the builder
        \\  --build-file <path>  Use a specific build file (default: build.zap)
        \\  --watch, -w       Watch source files and rebuild on changes
        \\  --target <triple> Cross-compile for target (e.g., wasm32-wasi)
        \\  --seed <integer>  Set the test seed for deterministic ordering
        \\  -- <args...>      Pass arguments to the program (run only)
        \\
        \\Examples:
        \\  zap build
        \\  zap run
        \\  zap build my_app -Doptimize=release_fast
        \\  zap run my_app -- arg1 arg2
        \\  zap build --watch
        \\  zap run -w
        \\  zap test --seed 12345
        \\  zap doc
        \\  zap doc --no-deps
        \\  zap init
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// Command: build
// ---------------------------------------------------------------------------

fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    const target = parsed.target orelse "default";

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);
    const output_path = try buildTarget(allocator, project_root, target, parsed.build_opts, parsed.compile_target);
    allocator.free(output_path);

    if (parsed.watch) {
        const source_paths = collectWatchPaths(allocator, project_root) catch |err| {
            std.debug.print("Error collecting watch paths: {}\n", .{err});
            return;
        };
        defer {
            for (source_paths) |p| allocator.free(p);
            allocator.free(source_paths);
        }
        std.debug.print("\n[watching for changes...]\n", .{});
        watchAndRebuild(allocator, source_paths, project_root, target, parsed.build_opts, false, &.{});
    }
}

// ---------------------------------------------------------------------------
// Command: run
// ---------------------------------------------------------------------------

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    const target = parsed.target orelse "default";

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);
    const output_path = try buildTarget(allocator, project_root, target, parsed.build_opts, parsed.compile_target);
    defer allocator.free(output_path);

    if (parsed.watch) {
        // In watch mode: run, then watch for changes and rebuild+rerun
        runBinaryIgnoreError(allocator, output_path, parsed.run_args);

        const source_paths = collectWatchPaths(allocator, project_root) catch |err| {
            std.debug.print("Error collecting watch paths: {}\n", .{err});
            return;
        };
        defer {
            for (source_paths) |p| allocator.free(p);
            allocator.free(source_paths);
        }
        std.debug.print("\n[watching for changes...]\n", .{});
        watchAndRebuild(allocator, source_paths, project_root, target, parsed.build_opts, true, parsed.run_args);
    } else {
        // Normal run: build, run, exit with the binary's exit code
        const exit_code = compiler.runBinary(allocator, global_io, output_path, parsed.run_args) catch |err| {
            std.debug.print("Error running program: {}\n", .{err});
            std.process.exit(1);
        };
        std.process.exit(exit_code);
    }
}

// ---------------------------------------------------------------------------
// Command: test
// ---------------------------------------------------------------------------

fn cmdTest(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);
    const output_path = try buildTarget(allocator, project_root, "test", parsed.build_opts, parsed.compile_target);
    defer allocator.free(output_path);

    // Build run_args: forward --seed to the test binary if provided
    var test_run_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer test_run_args.deinit(allocator);
    if (parsed.seed) |seed_value| {
        try test_run_args.append(allocator, "--seed");
        try test_run_args.append(allocator, seed_value);
    }
    // Also forward any explicit run_args from after --
    for (parsed.run_args) |arg| {
        try test_run_args.append(allocator, arg);
    }

    // Run the built test binary
    const exit_code = compiler.runBinary(allocator, global_io, output_path, test_run_args.items) catch |err| {
        std.debug.print("Error running tests: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Command: doc
// ---------------------------------------------------------------------------

fn cmdDoc(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = try parseTargetArgs(allocator, args);
    defer parsed.deinit(allocator);

    const project_root = try discoverBuildFile(allocator, parsed.build_file);
    defer allocator.free(project_root);

    // Check for --no-deps flag
    var no_deps = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-deps")) {
            no_deps = true;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builder = zap.builder;

    // Read build.zap
    const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading build.zap: {}\n", .{err});
        std.process.exit(1);
    };

    // Detect zap lib dir for stdlib
    const zap_lib_dir = detectZapLibDir(alloc);

    // Evaluate manifest with :doc target
    const manifest_eval = builder.ctfeManifestDetailed(alloc, build_source, "doc", parsed.build_opts, zap_lib_dir) catch |err| {
        std.debug.print("Error: failed to evaluate build.zap manifest for :doc target: {}\n", .{err});
        std.process.exit(1);
    };
    const config = manifest_eval.config;

    // Build source roots from deps
    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    {
        const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
        if (std.Io.Dir.cwd().access(global_io, lib_dir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "project", .path = lib_dir });
        } else |_| {}
        try source_roots.append(alloc, .{ .name = "project", .path = project_root });
    }

    // Process deps for source roots (unless --no-deps)
    if (!no_deps) {
        for (config.deps) |dep| {
            const dep_name = try std.fmt.allocPrint(alloc, "dep:{s}", .{dep.name});
            switch (dep.source) {
                .path => |dep_path| {
                    const dep_dir = try std.fs.path.join(alloc, &.{ project_root, dep_path });
                    const dep_lib_dir = try std.fs.path.join(alloc, &.{ dep_dir, "lib" });
                    if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
                    } else |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_dir });
                    }
                    // Scan subdirectories
                    const dep_resolved = if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{}))
                        dep_lib_dir
                    else |_|
                        dep_dir;
                    if (std.Io.Dir.cwd().openDir(global_io, dep_resolved, .{ .iterate = true })) |dir_handle| {
                        var dir = dir_handle;
                        defer dir.close(global_io);
                        var it = dir.iterate();
                        while (it.next(global_io) catch null) |entry| {
                            if (entry.kind == .directory) {
                                const subdir = try std.fs.path.join(alloc, &.{ dep_resolved, entry.name });
                                try source_roots.append(alloc, .{ .name = dep_name, .path = subdir });
                            }
                        }
                    } else |_| {}
                },
                .git => {},
            }
        }
    }

    // Add zap lib dir as a source root so stdlib modules are discovered
    if (zap_lib_dir) |zap_lib| {
        try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
        const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
        if (std.Io.Dir.cwd().access(global_io, zap_subdir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_subdir });
        } else |_| {}
        const zest_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zest" });
        if (std.Io.Dir.cwd().access(global_io, zest_subdir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zest_subdir });
        } else |_| {}
    }

    // Discover ALL .zap files from source roots (not import-driven — we want everything)
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (source_roots.items) |root| {
        if (std.Io.Dir.cwd().openDir(global_io, root.path, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close(global_io);
            var it = dir.iterate();
            while (it.next(global_io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
                const file_path = try std.fs.path.join(alloc, &.{ root.path, entry.name });
                try source_files.append(alloc, file_path);
            }
        } else |_| {}
    }

    // Deduplicate
    {
        var seen = std.StringHashMap(void).init(alloc);
        var deduped: std.ArrayListUnmanaged([]const u8) = .empty;
        for (source_files.items) |sf| {
            const key = std.fs.path.resolve(alloc, &.{sf}) catch sf;
            if (!seen.contains(key)) {
                seen.put(key, {}) catch {};
                deduped.append(alloc, sf) catch {};
            }
        }
        source_files = deduped;
    }

    if (source_files.items.len == 0) {
        std.debug.print("Error: no .zap source files found for documentation\n", .{});
        std.process.exit(1);
    }

    // Read and parse all source files
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    var mapped_files: std.ArrayListUnmanaged(compiler.MappedFile) = .empty;

    for (source_files.items) |sf| {
        if (std.mem.eql(u8, std.fs.path.basename(sf), "build.zap")) continue;
        const mapped = try compiler.mmapSourceFile(global_io, sf, alloc);
        try mapped_files.append(alloc, mapped);
        try source_units.append(alloc, .{ .file_path = sf, .source = mapped.bytes() });
    }

    // Parse and collect — this gives us the scope graph with all @doc attributes
    var ctx = compiler.collectAllFromUnits(alloc, source_units.items, .{
        .show_progress = false,
    }) catch {
        std.debug.print("Error: failed to parse source files for documentation\n", .{});
        std.process.exit(1);
    };

    // Generate documentation
    const doc_generator = zap.doc_generator;
    doc_generator.generate(alloc, &ctx, .{
        .project_name = config.name,
        .project_version = config.version,
        .source_url = config.source_url,
        .landing_page = config.landing_page,
        .doc_groups = config.doc_groups,
        .output_dir = "docs",
        .project_root = project_root,
        .source_units = source_units.items,
        .no_deps = no_deps,
    }) catch |err| {
        std.debug.print("Error generating documentation: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("Documentation generated in docs/\n", .{});
}

// ---------------------------------------------------------------------------
// Command: init
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Command: deps
// ---------------------------------------------------------------------------

fn cmdDeps(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // stderr writer removed in 0.16

    if (args.len == 0) {
        std.debug.print("Usage: zap deps update [name]\n", .{});
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, args[0], "update")) {
        std.debug.print("Error: unknown deps command: {s}\n\nUsage: zap deps update [name]\n", .{args[0]});
        std.process.exit(1);
    }

    const specific_dep: ?[]const u8 = if (args.len >= 2) args[1] else null;

    const project_root = try discoverBuildFile(allocator, null);
    const build_file_path = try std.fs.path.join(allocator, &.{ project_root, "build.zap" });
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("Error: could not read build.zap\n", .{});
        std.process.exit(1);
    };

    const zap_lib_dir = detectZapLibDir(allocator);
    const config = zap.builder.ctfeManifest(allocator, build_source, "default", .empty, zap_lib_dir) catch {
        std.debug.print("Error: could not evaluate build.zap manifest via CTFE\n", .{});
        std.process.exit(1);
    };

    var lock_entries: std.ArrayListUnmanaged(zap.lockfile.LockEntry) = .empty;

    for (config.deps) |dep| {
        // If specific dep requested, skip others
        if (specific_dep) |name| {
            if (!std.mem.eql(u8, dep.name, name)) {
                // Keep existing lock entry for skipped deps
                if (zap.lockfile.readLockfile(allocator, project_root)) |existing| {
                    if (zap.lockfile.findEntry(existing, dep.name)) |entry| {
                        try lock_entries.append(allocator, entry);
                    }
                }
                continue;
            }
        }

        switch (dep.source) {
            .path => |dep_path| {
                try lock_entries.append(allocator, .{
                    .name = dep.name,
                    .source_type = "path",
                    .url = dep_path,
                    .resolved_ref = "-",
                    .commit = "-",
                    .integrity = "-",
                });
                std.debug.print("  {s}: path dep (not locked)\n", .{dep.name});
            },
            .git => |git| {
                const ref = git.tag orelse git.branch orelse git.rev;
                std.debug.print("  {s}: fetching from {s}...\n", .{ dep.name, git.url });

                const result = zap.lockfile.fetchGitDep(
                    allocator,
                    dep.name,
                    git.url,
                    ref,
                    null, // force re-fetch by not passing locked commit
                ) catch {
                    std.debug.print("Error: failed to fetch dep `{s}`\n", .{dep.name});
                    std.process.exit(1);
                };

                try lock_entries.append(allocator, .{
                    .name = dep.name,
                    .source_type = "git",
                    .url = git.url,
                    .resolved_ref = ref orelse "-",
                    .commit = result.commit,
                    .integrity = result.integrity,
                });
                std.debug.print("  {s}: resolved to {s}\n", .{ dep.name, result.commit });
            },
        }
    }

    try zap.lockfile.writeLockfile(allocator, project_root, lock_entries.items);
    std.debug.print("Updated zap.lock\n", .{});
}

// ---------------------------------------------------------------------------
// Command: init
// ---------------------------------------------------------------------------

fn cmdInit(allocator: std.mem.Allocator) !void {
    // Check directory is empty
    var dir = std.Io.Dir.cwd().openDir(global_io, ".", .{ .iterate = true }) catch {
        // stderr writer removed in 0.16
        std.debug.print("Error: cannot open current directory\n", .{});
        std.process.exit(1);
    };
    defer dir.close(global_io);

    var iter = dir.iterate();
    if (iter.next(global_io) catch null) |_| {
        // stderr writer removed in 0.16
        std.debug.print("Error: directory is not empty\n", .{});
        std.process.exit(1);
    }

    // Derive names from directory
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(global_io, ".", allocator);
    defer allocator.free(cwd_path);
    const dir_name = std.fs.path.basename(cwd_path);

    // Convert to snake_case project name (handle kebab-case)
    const project_name = try toSnakeCase(allocator, dir_name);
    defer allocator.free(project_name);

    // Convert to PascalCase module name
    const module_name = try toPascalCase(allocator, project_name);
    defer allocator.free(module_name);

    // Generate files
    try std.Io.Dir.cwd().createDirPath(global_io, "lib");
    try std.Io.Dir.cwd().createDirPath(global_io, "test");

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
        \\    zap build
        \\
        \\## Run
        \\
        \\    zap run
        \\
        \\## Test
        \\
        \\    zap run test
        \\
    , .{project_name});
    defer allocator.free(readme);
    try writeFile("README.md", readme);

    // build.zap
    const build_zap = try std.fmt.allocPrint(allocator,
        \\pub module {s}.Builder {{
        \\  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {{
        \\    case env.target {{
        \\      :{s} -> {s}(env)
        \\      :test -> test(env)
        \\      _default -> {s}(env)
        \\    }}
        \\  }}
        \\
        \\  fn {s}(env :: Zap.Env) -> Zap.Manifest {{
        \\    %Zap.Manifest{{
        \\      name: "{s}",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: "{s}.main/1",
        \\      paths: ["lib/**/*.zap"],
        \\      # :debug | :release_safe | :release_fast | :release_small
        \\      optimize: :release_safe
        \\    }}
        \\  }}
        \\
        \\  fn test(env :: Zap.Env) -> Zap.Manifest {{
        \\    %Zap.Manifest{{
        \\      name: "{s}_test",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: "{s}Test.main/1",
        \\      paths: ["lib/**/*.zap", "test/**/*.zap"],
        \\      optimize: :debug
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ module_name, project_name, project_name, project_name, project_name, project_name, module_name, project_name, module_name });
    defer allocator.free(build_zap);
    try writeFile("build.zap", build_zap);

    // lib/<project_name>.zap
    const lib_path = try std.fmt.allocPrint(allocator, "lib/{s}.zap", .{project_name});
    defer allocator.free(lib_path);
    const lib_source = try std.fmt.allocPrint(allocator,
        \\pub module {s} {{
        \\  pub fn main(_args :: [String]) {{
        \\    IO.puts("Howdy!")
        \\  }}
        \\}}
        \\
    , .{module_name});
    defer allocator.free(lib_source);
    try writeFile(lib_path, lib_source);

    // test/<project_name>_test.zap
    const test_path = try std.fmt.allocPrint(allocator, "test/{s}_test.zap", .{project_name});
    defer allocator.free(test_path);
    const test_source = try std.fmt.allocPrint(allocator,
        \\pub module {s}Test {{
        \\  pub fn main(_args :: [String]) {{
        \\    IO.puts("Test Suite TBD")
        \\  }}
        \\}}
        \\
    , .{module_name});
    defer allocator.free(test_source);
    try writeFile(test_path, test_source);

    std.debug.print("Created project '{s}'\n\n  zap build\n  zap run\n  zap run test\n", .{project_name});
}

// ---------------------------------------------------------------------------
// Zap lib dir detection
// ---------------------------------------------------------------------------

/// Detect the zap stdlib lib directory by walking up from the executable path
/// looking for a `lib/` directory containing `kernel.zap`.
fn detectZapLibDir(allocator: std.mem.Allocator) ?[]const u8 {
    const exe_path = std.process.executablePathAlloc(global_io, allocator) catch return null;
    defer allocator.free(exe_path);

    // Walk up directories from the executable
    var dir_path = std.fs.path.dirname(exe_path);
    while (dir_path) |dp| {
        const lib_dir = std.fs.path.join(allocator, &.{ dp, "lib" }) catch return null;
        const kernel_path = std.fs.path.join(allocator, &.{ lib_dir, "kernel.zap" }) catch {
            allocator.free(lib_dir);
            return null;
        };
        defer allocator.free(kernel_path);

        if (std.Io.Dir.cwd().access(global_io, kernel_path, .{})) |_| {
            return lib_dir;
        } else |_| {
            allocator.free(lib_dir);
        }
        dir_path = std.fs.path.dirname(dp);
    }

    // Fallback: check if ./lib/kernel.zap exists (for running from project root)
    if (std.Io.Dir.cwd().access(global_io, "lib/kernel.zap", .{})) |_| {
        return allocator.dupe(u8, "lib") catch null;
    } else |_| {}

    return null;
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
    compile_target: ?[]const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builder = zap.builder;
    // stderr writer removed in 0.16

    // Read build.zap
    const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
    const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading build.zap: {}\n", .{err});
        std.process.exit(1);
    };

    // Detect zap lib dir for stdlib
    const zap_lib_dir = detectZapLibDir(alloc);

    // Extract manifest from build.zap via CTFE.
    // Compiles build.zap to IR and evaluates manifest/1 at compile time.
    const manifest_eval = builder.ctfeManifestDetailed(alloc, build_source, target_name, build_opts, zap_lib_dir) catch |err| {
        std.debug.print("Error: failed to evaluate build.zap manifest via CTFE: {}\n", .{err});
        std.process.exit(1);
    };
    const config = manifest_eval.config;

    // Detect zig lib dir
    const zig_lib_dir = zir_backend.detectZigLibDir(alloc) orelse blk: {
        break :blk extractEmbeddedZigLib(alloc) catch {
            std.debug.print("Error: could not find or extract Zig lib\n", .{});
            std.process.exit(1);
        };
    };

    // Discover source files — either via import-driven discovery from the
    // entry point (when paths is empty) or via glob patterns (legacy).
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    // Source roots for import-driven discovery (populated below, used by validation)
    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    // Module names in topological order for CTFE evaluation
    var module_order: std.ArrayListUnmanaged([]const u8) = .empty;
    // Level boundaries from dependency-level discovery (indices into module_order
    // where each parallel compilation level ends)
    var level_boundaries: std.ArrayListUnmanaged(u32) = .empty;

    // Build source roots from deps — always done regardless of discovery mode.
    // This ensures dep files (stdlib, etc.) are available in both import-driven
    // and glob-based compilation paths.
    {
        const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
        if (std.Io.Dir.cwd().access(global_io, lib_dir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "project", .path = lib_dir });
            // Scan subdirectories so impl files (e.g., lib/list/enumerable.zap) are discovered
            if (std.Io.Dir.cwd().openDir(global_io, lib_dir, .{ .iterate = true })) |dir_handle| {
                var dir = dir_handle;
                defer dir.close(global_io);
                var it = dir.iterate();
                while (it.next(global_io) catch null) |entry| {
                    if (entry.kind == .directory) {
                        const subdir = try std.fs.path.join(alloc, &.{ lib_dir, entry.name });
                        try source_roots.append(alloc, .{ .name = "project", .path = subdir });
                    }
                }
            } else |_| {}
        } else |_| {}
        const test_dir = try std.fs.path.join(alloc, &.{ project_root, "test" });
        if (std.Io.Dir.cwd().access(global_io, test_dir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "project", .path = test_dir });
        } else |_| {}
        try source_roots.append(alloc, .{ .name = "project", .path = project_root });
    }

    // Read lockfile if it exists
    const lock_entries = zap.lockfile.readLockfile(alloc, project_root);
    var new_lock_entries: std.ArrayListUnmanaged(zap.lockfile.LockEntry) = .empty;
    var lockfile_changed = false;

    // Collect git dep requests for parallel fetching
    var git_requests: std.ArrayListUnmanaged(zap.lockfile.GitDepRequest) = .empty;
    var git_dep_indices: std.ArrayListUnmanaged(usize) = .empty;

    for (config.deps, 0..) |dep, dep_idx| {
        switch (dep.source) {
            .git => |git| {
                const locked = if (lock_entries) |entries|
                    zap.lockfile.findEntry(entries, dep.name)
                else
                    null;
                const locked_commit: ?[]const u8 = if (locked) |l|
                    (if (std.mem.eql(u8, l.commit, "-")) null else l.commit)
                else
                    null;
                const ref = git.tag orelse git.branch orelse git.rev;
                try git_requests.append(alloc, .{
                    .name = dep.name,
                    .url = git.url,
                    .ref = ref,
                    .locked_commit = locked_commit,
                });
                try git_dep_indices.append(alloc, dep_idx);
            },
            else => {},
        }
    }

    // Fetch all git deps in parallel
    const git_results = zap.lockfile.fetchGitDepsParallel(alloc, git_requests.items) catch &.{};
    var git_result_idx: usize = 0;

    // Process all deps in order
    for (config.deps) |dep| {
        const dep_name = try std.fmt.allocPrint(alloc, "dep:{s}", .{dep.name});

        // Zig 0.16 local package override: when local_override is set,
        // use it as a path dep regardless of the original source type.
        // This allows overriding a git dep with a local path during development.
        if (dep.local_override) |override_path| {
            const dep_dir = try std.fs.path.join(alloc, &.{ project_root, override_path });
            const dep_lib_dir = try std.fs.path.join(alloc, &.{ dep_dir, "lib" });
            if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
            } else |_| {
                try source_roots.append(alloc, .{ .name = dep_name, .path = dep_dir });
            }
            // Scan subdirectories
            const dep_resolved = if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{}))
                dep_lib_dir
            else |_|
                dep_dir;
            if (std.Io.Dir.cwd().openDir(global_io, dep_resolved, .{ .iterate = true })) |dir_handle| {
                var dir = dir_handle;
                defer dir.close(global_io);
                var it = dir.iterate();
                while (it.next(global_io) catch null) |entry| {
                    if (entry.kind == .directory) {
                        const subdir = try std.fs.path.join(alloc, &.{ dep_resolved, entry.name });
                        try source_roots.append(alloc, .{ .name = dep_name, .path = subdir });
                    }
                }
            } else |_| {}
            try new_lock_entries.append(alloc, .{
                .name = dep.name,
                .source_type = "path",
                .url = override_path,
                .resolved_ref = "-",
                .commit = "-",
                .integrity = "-",
            });
            std.debug.print("  {s}: local override → {s}\n", .{ dep.name, override_path });
            continue;
        }

        switch (dep.source) {
                .path => |dep_path| {
                    // Resolve dep path relative to the project root
                    const dep_dir = try std.fs.path.join(alloc, &.{ project_root, dep_path });

                    // Try dep_dir/lib/ first (standard layout), fall back to dep_dir/
                    const dep_lib_dir = try std.fs.path.join(alloc, &.{ dep_dir, "lib" });
                    if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
                    } else |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_dir });
                    }

                    // Also add subdirectories that contain modules (e.g., lib/zap/ for Zap.Env)
                    const dep_resolved = if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{}))
                        dep_lib_dir
                    else |_|
                        dep_dir;
                    // Scan for subdirectories containing .zap files
                    if (std.Io.Dir.cwd().openDir(global_io, dep_resolved, .{ .iterate = true })) |dir_handle| {
                        var dir = dir_handle;
                        defer dir.close(global_io);
                        var it = dir.iterate();
                        while (it.next(global_io) catch null) |entry| {
                            if (entry.kind == .directory) {
                                const subdir = try std.fs.path.join(alloc, &.{ dep_resolved, entry.name });
                                try source_roots.append(alloc, .{ .name = dep_name, .path = subdir });
                            }
                        }
                    } else |_| {}

                    // Path deps are recorded in lockfile but not locked
                    try new_lock_entries.append(alloc, .{
                        .name = dep.name,
                        .source_type = "path",
                        .url = dep_path,
                        .resolved_ref = "-",
                        .commit = "-",
                        .integrity = "-",
                    });
                },
                .git => |git| {
                    // Use pre-fetched parallel result
                    if (git_result_idx < git_results.len) {
                        const result = git_results[git_result_idx];
                        git_result_idx += 1;

                        if (result.fetch_error) {
                            std.debug.print("Error: failed to fetch dep `{s}`\n", .{dep.name});
                            std.process.exit(1);
                        }

                        // Add dep's lib dir as source root
                        const dep_lib_dir = try std.fs.path.join(alloc, &.{ result.path, "lib" });
                        if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                            try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
                        } else |_| {
                            try source_roots.append(alloc, .{ .name = dep_name, .path = result.path });
                        }

                        const ref = git.tag orelse git.branch orelse git.rev;
                        // Record in lockfile
                        try new_lock_entries.append(alloc, .{
                            .name = dep.name,
                            .source_type = "git",
                            .url = git.url,
                            .resolved_ref = ref orelse "-",
                            .commit = result.commit,
                            .integrity = result.integrity,
                        });

                        // Check if lockfile needs updating
                        const locked = if (lock_entries) |entries|
                            zap.lockfile.findEntry(entries, dep.name)
                        else
                            null;
                        const locked_commit: ?[]const u8 = if (locked) |l|
                            (if (std.mem.eql(u8, l.commit, "-")) null else l.commit)
                        else
                            null;
                        if (locked_commit == null or !std.mem.eql(u8, locked_commit.?, result.commit)) {
                            lockfile_changed = true;
                        }
                    }
                },
            }
        }

    // Write lockfile if it changed or doesn't exist
    if (lock_entries == null or lockfile_changed) {
        zap.lockfile.writeLockfile(alloc, project_root, new_lock_entries.items) catch |err| {
            std.debug.print("Warning: could not write zap.lock: {}\n", .{err});
        };
    }

    // Add zap lib dir as a source root so stdlib modules are discovered
    if (zap_lib_dir) |zap_lib| {
        try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
        const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
        if (std.Io.Dir.cwd().access(global_io, zap_subdir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_subdir });
        } else |_| {}
    }

    if (config.root == null) {
        std.debug.print("Error: build.zap must specify a root entry point\n", .{});
        std.process.exit(1);
    }

    {
        // Import-driven discovery from the entry point
        const root_spec = config.root.?;

        // Extract module name from root spec: "App.main/0" → "App"
        const slash_pos = std.mem.findScalar(u8, root_spec, '/');
        const name_part = if (slash_pos) |pos| root_spec[0..pos] else root_spec;
        const last_dot = std.mem.findScalarLast(u8, name_part, '.');
        const entry_module = if (last_dot) |pos| name_part[0..pos] else name_part;

        var discovery_err_info: zap.discovery.ErrorInfo = .{};
        var file_graph = zap.discovery.discover(
            alloc,
            entry_module,
            source_roots.items,
            &zap.discovery.BUILTIN_TYPE_NAMES,
            &discovery_err_info,
        ) catch |err| switch (err) {
            error.ModuleNotFound => {
                if (discovery_err_info.unresolved_module) |mod| {
                    const expected = zap.discovery.moduleNameToRelPath(alloc, mod) catch "?";
                    std.debug.print("Error: Module `{s}` not found — expected {s} in one of the source roots\n", .{ mod, expected });
                } else if (discovery_err_info.boundary_module) |mod| {
                    std.debug.print("Error: Module `{s}` is private (module without pub) in {s} — cannot be accessed from {s}\n", .{
                        mod,
                        discovery_err_info.boundary_dep orelse "?",
                        discovery_err_info.boundary_from orelse "?",
                    });
                } else {
                    std.debug.print("Error: Module not found during discovery\n", .{});
                }
                std.process.exit(1);
            },
            error.CircularDependency => {
                std.debug.print("Error: Circular module dependency detected\n", .{});
                std.process.exit(1);
            },
            error.ReadError => {
                std.debug.print("Error: could not read source file\n", .{});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Error: file discovery failed\n", .{});
                std.process.exit(1);
            },
        };
        defer file_graph.deinit();

        // Collect discovered files in topological order
        for (file_graph.topo_order.items) |file_path| {
            try source_files.append(alloc, file_path);
        }

        // Also scan source roots for protocol/impl files that aren't discovered
        // through import-driven resolution (impl files have no module declaration)
        {
            var discovered = std.StringHashMap(void).init(alloc);
            for (source_files.items) |sf| {
                const key = std.fs.path.resolve(alloc, &.{sf}) catch sf;
                discovered.put(key, {}) catch {};
            }
            for (source_roots.items) |root| {
                if (std.Io.Dir.cwd().openDir(global_io, root.path, .{ .iterate = true })) |dir_handle| {
                    var dir = dir_handle;
                    defer dir.close(global_io);
                    var it = dir.iterate();
                    while (it.next(global_io) catch null) |entry| {
                        if (entry.kind != .file) continue;
                        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
                        if (std.mem.eql(u8, entry.name, "build.zap")) continue;
                        const file_path = try std.fs.path.join(alloc, &.{ root.path, entry.name });
                        const key = std.fs.path.resolve(alloc, &.{file_path}) catch file_path;
                        if (!discovered.contains(key)) {
                            try source_files.append(alloc, file_path);
                            discovered.put(key, {}) catch {};
                        }
                    }
                } else |_| {}
            }
        }

        // Build module order for CTFE: reverse-map file paths to module names
        var file_to_module = std.StringHashMap([]const u8).init(alloc);
        {
            var iter = file_graph.module_to_file.iterator();
            while (iter.next()) |entry| {
                try file_to_module.put(entry.value_ptr.*, entry.key_ptr.*);
            }
        }
        for (file_graph.topo_order.items) |file_path| {
            if (file_to_module.get(file_path)) |mod_name| {
                try module_order.append(alloc, mod_name);
            }
        }

        // Copy level boundaries from the file graph. These mark where each
        // dependency level ends in module_order — modules within the same
        // level have no inter-dependencies and can be compiled in parallel.
        for (file_graph.level_boundaries.items) |boundary| {
            try level_boundaries.append(alloc, boundary);
        }
    }

    // Deduplicate source files (explicit paths and dep paths may overlap)
    {
        var seen = std.StringHashMap(void).init(alloc);
        var deduped: std.ArrayListUnmanaged([]const u8) = .empty;
        for (source_files.items) |sf| {
            // Normalize: resolve to real path for comparison
            const key = std.fs.path.resolve(alloc, &.{sf}) catch sf;
            if (!seen.contains(key)) {
                seen.put(key, {}) catch {};
                deduped.append(alloc, sf) catch {};
            }
        }
        source_files = deduped;
    }

    if (source_files.items.len == 0) {
        // stderr writer removed in 0.16
        std.debug.print("Error: no .zap source files found\n", .{});
        std.process.exit(1);
    }

    // Read sources once up front so validation, cache hashing, and frontend
    // compilation all operate on the same explicit source units.
    // On POSIX platforms, source files are memory-mapped for zero-copy access
    // which reduces allocation pressure and lets the OS manage paging.
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    var mapped_files: std.ArrayListUnmanaged(compiler.MappedFile) = .empty;
    defer for (mapped_files.items) |*mf| mf.deinit(global_io);

    // Validate one-module-per-file and name=path for each source file
    var validation_failed = false;
    for (source_files.items) |sf| {
        // Skip build.zap — it's build configuration, not project source
        if (std.mem.eql(u8, std.fs.path.basename(sf), "build.zap")) continue;

        const mapped = try compiler.mmapSourceFile(global_io, sf, alloc);
        try mapped_files.append(alloc, mapped);
        try source_units.append(alloc, .{ .file_path = sf, .source = mapped.bytes() });

        // Skip validation for dep/stdlib source files — they're external code
        const is_dep_file = blk: {
            const norm_sf = if (std.mem.startsWith(u8, sf, "./")) sf[2..] else sf;
            for (source_roots.items) |root| {
                if (std.mem.startsWith(u8, root.name, "dep:") or
                    std.mem.eql(u8, root.name, "zap_stdlib"))
                {
                    const norm_root = if (std.mem.startsWith(u8, root.path, "./"))
                        root.path[2..]
                    else
                        root.path;
                    const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{norm_root});
                    if (std.mem.startsWith(u8, norm_sf, root_slash)) break :blk true;
                }
            }
            break :blk false;
        };
        if (is_dep_file) continue;

        // Compute the relative path from its source root for validation.
        // Check each source root to find which one this file is under.
        const lib_rel = blk: {
            {
                // Check source_roots to find which one this file is under.
                const norm_sf = if (std.mem.startsWith(u8, sf, "./")) sf[2..] else sf;
                for (source_roots.items) |root| {
                    const norm_root = if (std.mem.startsWith(u8, root.path, "./"))
                        root.path[2..]
                    else
                        root.path;
                    const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{norm_root});
                    if (std.mem.startsWith(u8, norm_sf, root_slash)) {
                        break :blk norm_sf[root_slash.len..];
                    }
                }
            }

            // Fallback: strip project root and common prefixes
            const rel_path = if (std.mem.startsWith(u8, sf, project_root))
                std.mem.trimStart(u8, sf[project_root.len..], "/")
            else
                sf;

            if (std.mem.startsWith(u8, rel_path, "lib/")) {
                break :blk rel_path[4..];
            }
            if (std.mem.startsWith(u8, rel_path, "./")) {
                break :blk rel_path[2..];
            }
            break :blk rel_path;
        };

        // Determine if this file is under a named source root (like `test/`)
        // that adds a module name prefix. Files in `test/` directory use `Test.`
        // prefix convention: `test/string_test.zap` → `Test.StringTest`.
        const source_root_dir_name: ?[]const u8 = blk: {
            const norm_sf = if (std.mem.startsWith(u8, sf, "./")) sf[2..] else sf;
            for (source_roots.items) |root| {
                if (std.mem.eql(u8, root.name, "project")) {
                    const norm_root = if (std.mem.startsWith(u8, root.path, "./"))
                        root.path[2..]
                    else
                        root.path;
                    const root_slash = try std.fmt.allocPrint(alloc, "{s}/", .{norm_root});
                    if (std.mem.startsWith(u8, norm_sf, root_slash)) {
                        // Return the directory basename (e.g., "test" from "./test/")
                        break :blk std.fs.path.basename(norm_root);
                    }
                }
            }
            break :blk null;
        };

        // For files under `test/`, prepend "test/" to the relative path so
        // validation expects `Test.ModuleName` to match `test/module_name.zap`.
        const validation_path = if (source_root_dir_name) |dir_name| blk: {
            if (!std.mem.eql(u8, dir_name, "lib")) {
                break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_name, lib_rel });
            }
            break :blk lib_rel;
        } else lib_rel;

        if (compiler.validateOneModulePerFile(alloc, mapped.bytes(), validation_path)) |err_msg| {
            std.debug.print("Error: {s}\n", .{err_msg});
            validation_failed = true;
        }
    }
    if (validation_failed) {
        std.process.exit(1);
    }

    // Determine output path from manifest (needed for cache check)
    const output_name = if (config.asset_name) |an|
        if (an.len > 0) an else config.name
    else
        config.name;

    const out_dir: []const u8 = switch (config.kind) {
        .bin => "zap-out/bin",
        .lib => "zap-out/lib",
        .obj => "zap-out/obj",
        .doc => "docs",
    };
    std.Io.Dir.cwd().createDirPath(global_io, ".zap-cache") catch {};
    std.Io.Dir.cwd().createDirPath(global_io, out_dir) catch {};

    const output_filename = switch (config.kind) {
        .bin => output_name,
        .lib => try std.fmt.allocPrint(alloc, "{s}.a", .{output_name}),
        .obj => try std.fmt.allocPrint(alloc, "{s}.o", .{output_name}),
        .doc => output_name,
    };
    const output_path = try std.fs.path.join(alloc, &.{ out_dir, output_filename });

    // Compilation caching: hash build.zap + all sources + target name
    const cache_key = computeBuildCacheKey(build_source, source_units.items, target_name, manifest_eval.result_hash);
    const cache_key_hex = try std.fmt.allocPrint(alloc, "{x:0>16}", .{cache_key});
    const hash_file = try std.fmt.allocPrint(alloc, ".zap-cache/{s}.hash", .{target_name});

    const cache_valid = blk: {
        const stored = std.Io.Dir.cwd().readFileAlloc(global_io, hash_file, alloc, .limited(64)) catch break :blk false;
        defer alloc.free(stored);
        if (!std.mem.eql(u8, stored, cache_key_hex)) break :blk false;
        std.Io.Dir.cwd().access(global_io, output_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (cache_valid) {
        std.debug.print("[cached] {s}\n", .{output_path});
        return try allocator.dupe(u8, output_path);
    }

    // Determine lib_mode from manifest kind
    const lib_mode = config.kind == .lib;

    // Compile through frontend
    // Use per-file pipeline for import-driven discovery, legacy pipeline for glob
    const mod_order_slice: ?[]const []const u8 = if (module_order.items.len > 0)
        module_order.items
    else
        null;
    const level_boundaries_slice: ?[]const u32 = if (level_boundaries.items.len > 0)
        level_boundaries.items
    else
        null;

    var result = compileProjectFrontend(alloc, source_units.items, .{
        .lib_mode = lib_mode,
        .module_order = mod_order_slice,
        .level_boundaries = level_boundaries_slice,
        .cache_dir = ".zap-cache/ctfe",
        .ctfe_target = target_name,
        .ctfe_optimize = @tagName(config.optimize),
        .io = global_io,
    }) catch {
        std.process.exit(1);
    };


    // Resolve the manifest root (e.g. "Test.TestHelper.main/1") to an IR function ID
    // so the ZIR backend knows which function is the entry point.
    // IR naming: module parts joined by "_", then "__" before function name, then "__" arity.
    // e.g. "Test.TestHelper.main/1" -> "Test_TestHelper__main__1"
    if (config.root) |root| {
        // Extract arity suffix: "Test.TestHelper.main/1" -> arity="1"
        const arity_str = if (std.mem.findScalarLast(u8, root, '/')) |slash|
            root[slash + 1 ..]
        else
            "0";
        const without_arity = if (std.mem.findScalarLast(u8, root, '/')) |slash|
            root[0..slash]
        else
            root;
        // Split on last dot: module prefix vs function name
        // "Test.TestHelper.main" -> module="Test.TestHelper", func="main"
        var mangled: std.ArrayListUnmanaged(u8) = .empty;
        if (std.mem.findScalarLast(u8, without_arity, '.')) |last_dot| {
            const module_part = without_arity[0..last_dot];
            const func_part = without_arity[last_dot + 1 ..];
            // Module parts: dots become single underscores
            for (module_part) |c| {
                if (c == '.') {
                    mangled.append(alloc, '_') catch break;
                } else {
                    mangled.append(alloc, c) catch break;
                }
            }
            // Double underscore separator between module and function
            mangled.appendSlice(alloc, "__") catch {};
            mangled.appendSlice(alloc, func_part) catch {};
            // Arity suffix
            mangled.appendSlice(alloc, "__") catch {};
            mangled.appendSlice(alloc, arity_str) catch {};
        } else {
            // No dot — bare function name with arity
            mangled.appendSlice(alloc, without_arity) catch {};
            mangled.appendSlice(alloc, "__") catch {};
            mangled.appendSlice(alloc, arity_str) catch {};
        }
        const mangled_name = mangled.items;
        for (result.ir_program.functions) |func| {
            if (std.mem.eql(u8, func.name, mangled_name)) {
                result.ir_program.entry = func.id;
                break;
            }
        }
    }


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
        .doc => 0, // doc target handled by cmdDoc, not buildTarget
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
        .target = compile_target,
        .analysis_context = if (result.analysis_context) |*ctx| ctx else null,
        // Zig 0.16 error formatting options from manifest
        .error_style = config.error_style,
        .multiline_errors = config.multiline_errors,
    }) catch {
        // stderr writer removed in 0.16
        std.debug.print("Error: compilation failed\n", .{});
        std.process.exit(1);
    };

    // Save cache hash atomically (write to .tmp then rename)
    {
        const tmp_hash_file = try std.fmt.allocPrint(alloc, "{s}.tmp", .{hash_file});
        var hash_f = std.Io.Dir.cwd().createFile(global_io, tmp_hash_file, .{}) catch return try allocator.dupe(u8, output_path);
        hash_f.writeStreamingAll(global_io, cache_key_hex) catch {};
        hash_f.close(global_io);
        std.Io.Dir.cwd().rename(tmp_hash_file, std.Io.Dir.cwd(), hash_file, global_io) catch {};
    }

    // Return a durable copy of the output path
    return try allocator.dupe(u8, output_path);
}

fn compileProjectFrontend(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    options: compiler.CompileOptions,
) !compiler.CompileResult {
    var ctx = try compiler.collectAllFromUnits(alloc, source_units, options);

    // Derive module_order from the parsed module programs and compile
    // each module independently through the per-module pipeline.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ctx.module_programs) |mp| {
        names.append(alloc, mp.name) catch {};
    }

    return try compiler.compileModuleByModule(alloc, &ctx, names.items, options);
}

/// Compute a build cache key using SHA-256 (Zig 0.16 std.crypto) for
/// cryptographic integrity. Returns a truncated u64 for backward-compatible
/// hex formatting, but the full hash provides collision resistance.
fn computeBuildCacheKey(
    build_source: []const u8,
    source_units: []const compiler.SourceUnit,
    target_name: []const u8,
    manifest_result_hash: u64,
) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(build_source);
    // Hash each source file individually — no concatenation needed
    for (source_units) |unit| {
        hasher.update(unit.file_path);
        hasher.update(unit.source);
    }
    hasher.update(target_name);
    hasher.update(std.mem.asBytes(&manifest_result_hash));
    const digest = hasher.finalResult();
    // Truncate to u64 for backward-compatible cache key format
    return std.mem.readInt(u64, digest[0..8], .little);
}

// ---------------------------------------------------------------------------
// Watch mode
// ---------------------------------------------------------------------------

/// Collect all .zap file paths under the project root (lib/, test/, and build.zap)
/// for watching. Returns owned slices that the caller must free.
fn collectWatchPaths(allocator: std.mem.Allocator, project_root: []const u8) ![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    // Always watch build.zap
    const build_zap_path = try std.fs.path.join(allocator, &.{ project_root, "build.zap" });
    if (std.Io.Dir.cwd().access(global_io, build_zap_path, .{})) |_| {
        try paths.append(allocator, build_zap_path);
    } else |_| {
        allocator.free(build_zap_path);
    }

    // Watch lib/ and test/ directories
    const watch_dirs = [_][]const u8{ "lib", "test" };
    for (&watch_dirs) |dir_name| {
        const dir_path = try std.fs.path.join(allocator, &.{ project_root, dir_name });
        defer allocator.free(dir_path);
        collectZapFilesRecursive(allocator, dir_path, &paths) catch {};
    }

    return try paths.toOwnedSlice(allocator);
}

/// Recursively collect all .zap files under a directory using the
/// std.Io.Dir.Walker API (Zig 0.16) for efficient selective tree traversal.
/// Skips hidden directories (starting with '.') and non-.zap files.
fn collectZapFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(global_io);
    var walker = std.Io.Dir.walk(dir, allocator) catch return;
    defer walker.deinit();

    while (walker.next(global_io) catch null) |entry| {
        // Skip hidden entries (e.g. .git, .zap-cache)
        if (entry.basename.len > 0 and entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(global_io);
            continue;
        }

        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zap")) {
            const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
            results.append(allocator, full_path) catch {
                allocator.free(full_path);
            };
        }
    }
}

/// Get the mtime of a file as an Io.Timestamp, or null if the file cannot be stat'd.
/// Uses Zig 0.16's std.Io.Timestamp for portable, resolution-aware time comparison.
fn getFileMtime(path: []const u8) ?std.Io.Timestamp {
    const file_stat = std.Io.Dir.cwd().statFile(global_io, path, .{}) catch return null;
    return file_stat.mtime;
}

/// Run a binary, printing errors but not exiting the process.
fn runBinaryIgnoreError(allocator: std.mem.Allocator, output_path: []const u8, run_args: []const []const u8) void {
    _ = compiler.runBinary(allocator, global_io, output_path, run_args) catch |err| {
        std.debug.print("Error running program: {}\n", .{err});
    };
}

/// Persistent state for incremental watch-mode compilation.
///
/// Holds a Zig ZirContext that persists across rebuilds so the Zig compiler's
/// incremental Sema can diff prev_zir vs new_zir and only re-analyze changed
/// code. The frontend (parse→IR) is re-run fully on each change, but the
/// expensive backend (Sema→codegen→link) is incremental.
const IncrementalWatchState = struct {
    zir_ctx: *zir_builder.ZirContext,
    /// Duped backend compile options that outlive buildTarget's arena.
    zig_lib_dir: []const u8,
    output_path: []const u8,
    output_name: []const u8,
    output_mode: u8,
    optimize_mode: u8,
    lib_mode: bool,
    link_libc: bool,
    allocator: std.mem.Allocator,
    /// Whether the context has had at least one successful inject+update.
    baseline_established: bool = false,

    fn deinit(self: *IncrementalWatchState) void {
        zir_backend.destroyContext(self.zir_ctx);
        self.allocator.free(self.zig_lib_dir);
        self.allocator.free(self.output_path);
        self.allocator.free(self.output_name);
    }

    /// Create incremental state by deriving the same config buildTarget uses.
    fn init(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        target_name: []const u8,
        build_opts: std.StringHashMapUnmanaged([]const u8),
        compile_target: ?[]const u8,
    ) ?IncrementalWatchState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Re-derive build config (same logic as buildTarget)
        const build_file_path = std.fs.path.join(alloc, &.{ project_root, "build.zap" }) catch return null;
        const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch return null;
        const zap_lib_dir = detectZapLibDir(alloc);
        const manifest_eval = zap.builder.ctfeManifestDetailed(alloc, build_source, target_name, build_opts, zap_lib_dir) catch return null;
        const config = manifest_eval.config;

        const zig_lib_dir = zir_backend.detectZigLibDir(alloc) orelse (extractEmbeddedZigLib(alloc) catch return null);
        const output_name_raw = if (config.asset_name) |an| (if (an.len > 0) an else config.name) else config.name;
        const out_dir: []const u8 = switch (config.kind) {
            .bin => "zap-out/bin",
            .lib => "zap-out/lib",
            .obj => "zap-out/obj",
            .doc => "docs",
        };
        const output_filename = switch (config.kind) {
            .bin => output_name_raw,
            .lib => std.fmt.allocPrint(alloc, "{s}.a", .{output_name_raw}) catch return null,
            .obj => std.fmt.allocPrint(alloc, "{s}.o", .{output_name_raw}) catch return null,
            .doc => output_name_raw,
        };
        const output_path = std.fs.path.join(alloc, &.{ out_dir, output_filename }) catch return null;

        const output_mode_val: u8 = switch (config.kind) {
            .bin => 0,
            .lib => 1,
            .obj => 2,
            .doc => 0,
        };
        const optimize_mode_val: u8 = switch (config.optimize) {
            .debug => 0,
            .release_safe => 1,
            .release_fast => 2,
            .release_small => 3,
        };

        // Dupe strings into the persistent allocator
        const zig_lib_duped = allocator.dupe(u8, zig_lib_dir) catch return null;
        const output_path_duped = allocator.dupe(u8, output_path) catch {
            allocator.free(zig_lib_duped);
            return null;
        };
        const output_name_duped = allocator.dupe(u8, output_name_raw) catch {
            allocator.free(zig_lib_duped);
            allocator.free(output_path_duped);
            return null;
        };

        // Create persistent ZirContext
        const ctx = zir_backend.createContext(allocator, .{
            .zig_lib_dir = zig_lib_duped,
            .cache_dir = ".zap-cache",
            .global_cache_dir = ".zap-cache",
            .output_path = output_path_duped,
            .name = output_name_duped,
            .runtime_source = compiler.getRuntimeSource(),
            .output_mode = output_mode_val,
            .optimize_mode = optimize_mode_val,
            .target = compile_target,
            .link_libc = true,
        }) catch {
            allocator.free(zig_lib_duped);
            allocator.free(output_path_duped);
            allocator.free(output_name_duped);
            return null;
        };

        return .{
            .zir_ctx = ctx,
            .zig_lib_dir = zig_lib_duped,
            .output_path = output_path_duped,
            .output_name = output_name_duped,
            .output_mode = output_mode_val,
            .optimize_mode = optimize_mode_val,
            .lib_mode = config.kind == .lib,
            .link_libc = true,
            .allocator = allocator,
        };
    }

    /// Run an incremental rebuild: full frontend re-compile, then
    /// prepareUpdate → invalidateFile → injectAndUpdate on the persistent context.
    fn rebuild(
        self: *IncrementalWatchState,
        allocator: std.mem.Allocator,
        project_root: []const u8,
        target_name: []const u8,
        build_opts: std.StringHashMapUnmanaged([]const u8),
        changed_paths: []const []const u8,
    ) !void {
        var build_arena = std.heap.ArenaAllocator.init(allocator);
        defer build_arena.deinit();
        const alloc = build_arena.allocator();

        // Re-read build config and sources (same as buildTarget)
        const build_file_path = try std.fs.path.join(alloc, &.{ project_root, "build.zap" });
        const build_source = std.Io.Dir.cwd().readFileAlloc(global_io, build_file_path, alloc, .limited(10 * 1024 * 1024)) catch return error.ReadError;
        const zap_lib_dir = detectZapLibDir(alloc);
        const manifest_eval = zap.builder.ctfeManifestDetailed(alloc, build_source, target_name, build_opts, zap_lib_dir) catch return error.ManifestError;
        const config = manifest_eval.config;

        // Discover and read source files
        var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
        {
            const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
            if (std.Io.Dir.cwd().access(global_io, lib_dir, .{})) |_| {
                try source_roots.append(alloc, .{ .name = "project", .path = lib_dir });
            } else |_| {}
            try source_roots.append(alloc, .{ .name = "project", .path = project_root });
        }
        if (zap_lib_dir) |zap_lib| {
            try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_lib });
            const zap_subdir = try std.fs.path.join(alloc, &.{ zap_lib, "zap" });
            if (std.Io.Dir.cwd().access(global_io, zap_subdir, .{})) |_| {
                try source_roots.append(alloc, .{ .name = "zap_stdlib", .path = zap_subdir });
            } else |_| {}
        }

        // Also add dep source roots
        for (config.deps) |dep| {
            const dep_name = try std.fmt.allocPrint(alloc, "dep:{s}", .{dep.name});
            switch (dep.source) {
                .path => |dep_path| {
                    const dep_dir = try std.fs.path.join(alloc, &.{ project_root, dep_path });
                    const dep_lib_dir = try std.fs.path.join(alloc, &.{ dep_dir, "lib" });
                    if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
                    } else |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_dir });
                    }
                },
                else => {},
            }
        }

        // Import-driven discovery
        var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
        var module_order: std.ArrayListUnmanaged([]const u8) = .empty;
        var level_boundaries: std.ArrayListUnmanaged(u32) = .empty;
        var file_to_module = std.StringHashMap([]const u8).init(alloc);

        if (config.root) |root_spec| {
            const slash_pos = std.mem.findScalar(u8, root_spec, '/');
            const name_part = if (slash_pos) |pos| root_spec[0..pos] else root_spec;
            const last_dot = std.mem.findScalarLast(u8, name_part, '.');
            const entry_module = if (last_dot) |pos| name_part[0..pos] else name_part;

            var discovery_err_info: zap.discovery.ErrorInfo = .{};
            var file_graph = zap.discovery.discover(
                alloc, entry_module, source_roots.items,
                &zap.discovery.BUILTIN_TYPE_NAMES, &discovery_err_info,
            ) catch return error.DiscoveryError;
            defer file_graph.deinit();

            for (file_graph.topo_order.items) |file_path| {
                try source_files.append(alloc, file_path);
            }
            // Build file→module mapping
            {
                var iter = file_graph.module_to_file.iterator();
                while (iter.next()) |entry| {
                    try file_to_module.put(entry.value_ptr.*, entry.key_ptr.*);
                }
            }
            for (file_graph.topo_order.items) |file_path| {
                if (file_to_module.get(file_path)) |mod_name| {
                    try module_order.append(alloc, mod_name);
                }
            }
            for (file_graph.level_boundaries.items) |boundary| {
                try level_boundaries.append(alloc, boundary);
            }
        } else {
            std.debug.print("Error: build.zap must specify a root entry point\n", .{});
            return error.ManifestError;
        }

        // Read source units
        var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
        var mapped_files: std.ArrayListUnmanaged(compiler.MappedFile) = .empty;
        defer for (mapped_files.items) |*mf| mf.deinit(global_io);

        for (source_files.items) |sf| {
            if (std.mem.eql(u8, std.fs.path.basename(sf), "build.zap")) continue;
            const mapped = try compiler.mmapSourceFile(global_io, sf, alloc);
            try mapped_files.append(alloc, mapped);
            try source_units.append(alloc, .{ .file_path = sf, .source = mapped.bytes() });
        }

        // Frontend compile
        const mod_order_slice: ?[]const []const u8 = if (module_order.items.len > 0) module_order.items else null;
        const level_boundaries_slice: ?[]const u32 = if (level_boundaries.items.len > 0) level_boundaries.items else null;

        var result = compileProjectFrontend(alloc, source_units.items, .{
            .lib_mode = self.lib_mode,
            .module_order = mod_order_slice,
            .level_boundaries = level_boundaries_slice,
            .cache_dir = ".zap-cache/ctfe",
            .ctfe_target = target_name,
            .ctfe_optimize = @tagName(config.optimize),
            .io = global_io,
        }) catch return error.FrontendError;

        // Resolve entry point
        if (config.root) |root| {
            const arity_str = if (std.mem.findScalarLast(u8, root, '/')) |slash| root[slash + 1 ..] else "0";
            const without_arity = if (std.mem.findScalarLast(u8, root, '/')) |slash| root[0..slash] else root;
            var mangled: std.ArrayListUnmanaged(u8) = .empty;
            if (std.mem.findScalarLast(u8, without_arity, '.')) |last_dot| {
                const module_part = without_arity[0..last_dot];
                const func_part = without_arity[last_dot + 1 ..];
                for (module_part) |c| {
                    mangled.append(alloc, if (c == '.') '_' else c) catch break;
                }
                mangled.appendSlice(alloc, "__") catch {};
                mangled.appendSlice(alloc, func_part) catch {};
                mangled.appendSlice(alloc, "__") catch {};
                mangled.appendSlice(alloc, arity_str) catch {};
            } else {
                mangled.appendSlice(alloc, without_arity) catch {};
                mangled.appendSlice(alloc, "__") catch {};
                mangled.appendSlice(alloc, arity_str) catch {};
            }
            for (result.ir_program.functions) |func| {
                if (std.mem.eql(u8, func.name, mangled.items)) {
                    result.ir_program.entry = func.id;
                    break;
                }
            }
        }

        // Incremental backend: prepareUpdate before re-injection
        if (self.baseline_established) {
            zir_backend.prepareUpdate(self.zir_ctx) catch {
                return error.IncrementalError;
            };

            // Invalidate changed modules
            for (changed_paths) |changed_path| {
                if (file_to_module.get(changed_path)) |mod_name| {
                    zir_backend.invalidateFile(self.zir_ctx, mod_name, alloc) catch {};
                }
            }
        }

        // Inject new ZIR and run Sema+codegen+link
        zir_backend.injectAndUpdate(alloc, result.ir_program, self.zir_ctx, .{
            .zig_lib_dir = self.zig_lib_dir,
            .cache_dir = ".zap-cache",
            .global_cache_dir = ".zap-cache",
            .output_path = self.output_path,
            .name = self.output_name,
            .runtime_source = compiler.getRuntimeSource(),
            .output_mode = self.output_mode,
            .optimize_mode = self.optimize_mode,
            .link_libc = self.link_libc,
            .analysis_context = if (result.analysis_context) |*ctx| ctx else null,
        }) catch return error.BackendError;

        self.baseline_established = true;
    }

    const IncrementalError = error{
        ReadError,
        ManifestError,
        DiscoveryError,
        FrontendError,
        IncrementalError,
        BackendError,
        OutOfMemory,
    };
};

/// Watch source files for changes and rebuild (and optionally re-run) on change.
/// This function loops forever until the process is killed (e.g. Ctrl+C).
///
/// Uses Zig 0.16's Io.Timestamp for portable mtime comparison. On the first
/// detected change, performs a full build via `buildTarget`. Then creates a
/// persistent ZirContext for incremental compilation — subsequent changes
/// use prepareUpdate/invalidateFile/injectAndUpdate so the Zig Sema only
/// re-analyzes changed code.
///
/// Falls back to full rebuild if incremental compilation fails.
fn watchAndRebuild(
    allocator: std.mem.Allocator,
    source_paths: []const []const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    run_after_build: bool,
    run_args: []const []const u8,
) void {
    // Initialize last-known mtimes using Io.Timestamp (Zig 0.16)
    var last_mtimes = allocator.alloc(std.Io.Timestamp, source_paths.len) catch return;
    defer allocator.free(last_mtimes);
    for (source_paths, 0..) |path, i| {
        last_mtimes[i] = getFileMtime(path) orelse std.Io.Timestamp.zero;
    }

    const poll_duration = std.Io.Duration.fromMilliseconds(500);

    // Persistent incremental compilation state. Created after the first
    // successful build and reused for all subsequent changes.
    var incr_state: ?IncrementalWatchState = null;
    defer if (incr_state) |*s| s.deinit();

    while (true) {
        // Sleep for the poll interval
        global_io.sleep(poll_duration, .awake) catch {};

        // Check for any changed files, collecting their paths
        var changed = false;
        var changed_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer changed_paths.deinit(allocator);
        for (source_paths, 0..) |path, i| {
            const current_mtime = getFileMtime(path) orelse continue;
            if (current_mtime.nanoseconds != last_mtimes[i].nanoseconds) {
                last_mtimes[i] = current_mtime;
                changed = true;
                changed_paths.append(allocator, path) catch {};
            }
        }

        if (changed) {
            // Clear terminal screen
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(global_io, "\x1b[2J\x1b[H") catch {};

            // Check if build.zap itself changed — if so, tear down incremental
            // state since the manifest may have changed
            var build_zap_changed = false;
            for (changed_paths.items) |cp| {
                if (std.mem.eql(u8, std.fs.path.basename(cp), "build.zap")) {
                    build_zap_changed = true;
                    break;
                }
            }
            if (build_zap_changed) {
                if (incr_state) |*s| {
                    s.deinit();
                    incr_state = null;
                }
            }

            // Try incremental rebuild if state exists
            var build_succeeded = false;
            var output_path: ?[]const u8 = null;
            if (incr_state) |*state| {
                state.rebuild(allocator, project_root, target_name, build_opts, changed_paths.items) catch |err| {
                    std.debug.print("Incremental build failed ({s}), falling back to full rebuild\n", .{@errorName(err)});
                    state.deinit();
                    incr_state = null;
                };
                if (incr_state != null) {
                    build_succeeded = true;
                    output_path = incr_state.?.output_path;
                }
            }

            // Fall back to full rebuild
            if (!build_succeeded) {
                const result_path = buildTarget(allocator, project_root, target_name, build_opts, null) catch |err| {
                    std.debug.print("Build error: {}\n", .{err});
                    std.debug.print("\n[watching for changes...]\n", .{});
                    changed_paths = .empty;
                    continue;
                };
                output_path = result_path;
                build_succeeded = true;

                // Set up incremental state for subsequent builds
                incr_state = IncrementalWatchState.init(allocator, project_root, target_name, build_opts, null);
            }

            if (build_succeeded) {
                if (run_after_build) {
                    if (output_path) |op| {
                        runBinaryIgnoreError(allocator, op, run_args);
                    }
                }
                std.debug.print("\n[watching for changes...]\n", .{});
                // Free output_path only if it came from buildTarget (duped),
                // not if it's the incremental state's persistent path.
                if (output_path) |op| {
                    const is_incr_path = if (incr_state) |s| std.mem.eql(u8, op, s.output_path) else false;
                    if (!is_incr_path) allocator.free(op);
                }
            }

            changed_paths = .empty;
        }
    }
}

/// Result from an async build task in watch mode (used for first non-incremental build).
const WatchBuildResult = struct {
    output_path: ?[]const u8 = null,
    failed: bool = false,
};

/// Task function for async watch builds. Returns a WatchBuildResult
/// suitable for use with Io.Future.
fn watchBuildTask(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) WatchBuildResult {
    const output_path = buildTarget(allocator, project_root, target_name, build_opts, null) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        return .{ .failed = true };
    };
    return .{ .output_path = output_path };
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const ParsedArgs = struct {
    target: ?[]const u8,
    build_file: ?[]const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    run_args: []const []const u8,
    seed: ?[]const u8 = null,
    watch: bool = false,
    compile_target: ?[]const u8 = null,

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
                // stderr writer removed in 0.16
                std.debug.print("Error: --build-file requires a path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            result.watch = true;
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i < args.len) {
                result.compile_target = args[i];
            } else {
                std.debug.print("Error: --target requires a triple (e.g., wasm32-wasi)\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i < args.len) {
                result.seed = args[i];
            } else {
                std.debug.print("Error: --seed requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            // Parse -Dkey=value
            const kv = arg[2..];
            if (std.mem.findScalar(u8, kv, '=')) |eq| {
                try result.build_opts.put(allocator, kv[0..eq], kv[eq + 1 ..]);
            } else {
                try result.build_opts.put(allocator, kv, "true");
            }
        } else if (result.target == null) {
            result.target = arg;
        } else {
            // stderr writer removed in 0.16
            std.debug.print("Error: unexpected argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    return result;
}

const testing = std.testing;

test "computeBuildCacheKey includes manifest result hash" {
    const build_source = "pub module App.Builder {}";
    const units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/app.zap", .source = "pub module App {}" },
    };
    const target_name = "default";

    const first = computeBuildCacheKey(build_source, &units, target_name, 111);
    const second = computeBuildCacheKey(build_source, &units, target_name, 222);

    try testing.expect(first != second);
}

// ---------------------------------------------------------------------------
// Build file discovery
// ---------------------------------------------------------------------------

/// Find build.zap and return the project root directory.
fn discoverBuildFile(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |path| {
        // Verify the override file exists
        std.Io.Dir.cwd().access(global_io, path, .{}) catch {
            // stderr writer removed in 0.16
            std.debug.print("Error: build file not found: {s}\n", .{path});
            std.process.exit(1);
        };
        // Project root is the directory containing the build file
        if (std.fs.path.dirname(path)) |dir| {
            return try allocator.dupe(u8, dir);
        }
        return try allocator.dupe(u8, ".");
    }

    // Default: look for build.zap in cwd
    std.Io.Dir.cwd().access(global_io, "build.zap", .{}) catch {
        // stderr writer removed in 0.16
        std.debug.print("Error: no build.zap found in current directory\n", .{});
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
    const has_double_star = std.mem.find(u8, sub_pattern, "**") != null;

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
    var dir = std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(global_io);
    var iter = dir.iterate();

    while (iter.next(global_io) catch null) |entry| {
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
    const home = env.getenv("HOME") orelse return error.FileNotFound;

    const lib_dir = try std.fs.path.join(allocator, &.{ home, ".cache", "zap", "zig-lib" });

    const marker = try std.fs.path.join(allocator, &.{ lib_dir, "std", "std.zig" });
    defer allocator.free(marker);

    if (std.Io.Dir.cwd().access(global_io, marker, .{})) |_| {
        return lib_dir;
    } else |_| {}

    std.Io.Dir.cwd().createDirPath(global_io, lib_dir) catch {};

    var dir = std.Io.Dir.cwd().openDir(global_io, lib_dir, .{}) catch return error.FileNotFound;
    defer dir.close(global_io);

    var reader = std.Io.Reader.fixed(zig_lib_archive.data);
    std.tar.extract(global_io, dir, &reader, .{}) catch return error.FileNotFound;

    return lib_dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = global_io;
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("Error writing {s}: {}\n", .{ path, err });
        return err;
    };
    defer file.close(global_io);
    file.writeStreamingAll(io, content) catch |err| {
        std.debug.print("Error writing {s}: {}\n", .{ path, err });
        return err;
    };
}
