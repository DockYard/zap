const std = @import("std");
const Io = std.Io;
const zap = @import("zap");
const compiler = zap.compiler;
const zir_backend = zap.zir_backend;
const zir_builder = zap.zir_builder;
const zig_lib_archive = @import("zig_lib_archive");

/// Global Io instance for main thread operations.
var global_io: Io = std.Options.debug_io;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());

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
        try cmdRun(allocator, &.{"test"});
    } else if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator);
    } else if (std.mem.eql(u8, command, "deps")) {
        try cmdDeps(allocator, args[2..]);
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
        \\  test              Run the test suite (alias for `run test`)
        \\  init              Scaffold a new project in the current directory
        \\  deps update       Re-resolve all dependencies and rewrite zap.lock
        \\  deps update <name> Re-resolve a single dependency
        \\
        \\Options:
        \\  -Dkey=value       Pass build option to the builder
        \\  --build-file <path>  Use a specific build file (default: build.zap)
        \\  -- <args...>      Pass arguments to the program (run only)
        \\
        \\Examples:
        \\  zap build
        \\  zap run
        \\  zap build my_app -Doptimize=release_fast
        \\  zap run my_app -- arg1 arg2
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
    const output_path = try buildTarget(allocator, project_root, target, parsed.build_opts);
    allocator.free(output_path);
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
    const output_path = try buildTarget(allocator, project_root, target, parsed.build_opts);
    defer allocator.free(output_path);

    // Run the built binary
    const exit_code = compiler.runBinary(allocator, output_path, parsed.run_args) catch |err| {
        // stderr writer removed in 0.16
        std.debug.print("Error running program: {}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
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
    if (iter.next() catch null) |_| {
        // stderr writer removed in 0.16
        std.debug.print("Error: directory is not empty\n", .{});
        std.process.exit(1);
    }

    // Derive names from directory
    const cwd_path = try std.Io.Dir.cwd().realpathAlloc(global_io, ".", allocator);
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

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Created project '{s}'\n\n  zap build\n  zap run\n  zap run test\n", .{project_name});
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

    // Build source roots from deps — always done regardless of discovery mode.
    // This ensures dep files (stdlib, etc.) are available in both import-driven
    // and glob-based compilation paths.
    {
        const lib_dir = try std.fs.path.join(alloc, &.{ project_root, "lib" });
        if (std.Io.Dir.cwd().access(global_io, lib_dir, .{})) |_| {
            try source_roots.append(alloc, .{ .name = "project", .path = lib_dir });
        } else |_| {}
        try source_roots.append(alloc, .{ .name = "project", .path = project_root });
    }

    // Read lockfile if it exists
    const lock_entries = zap.lockfile.readLockfile(alloc, project_root);
    var new_lock_entries: std.ArrayListUnmanaged(zap.lockfile.LockEntry) = .empty;
    var lockfile_changed = false;

    for (config.deps) |dep| {
        const dep_name = try std.fmt.allocPrint(alloc, "dep:{s}", .{dep.name});

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
                        while (it.next() catch null) |entry| {
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
                    // Check lockfile for cached commit
                    const locked = if (lock_entries) |entries|
                        zap.lockfile.findEntry(entries, dep.name)
                    else
                        null;

                    const locked_commit: ?[]const u8 = if (locked) |l|
                        (if (std.mem.eql(u8, l.commit, "-")) null else l.commit)
                    else
                        null;

                    const ref = git.tag orelse git.branch orelse git.rev;

                    // Fetch (or use cache)
                    const result = zap.lockfile.fetchGitDep(
                        alloc,
                        dep.name,
                        git.url,
                        ref,
                        locked_commit,
                    ) catch {
                        std.debug.print("Error: failed to fetch dep `{s}`\n", .{dep.name});
                        std.process.exit(1);
                    };

                    // Add dep's lib dir as source root
                    const dep_lib_dir = try std.fs.path.join(alloc, &.{ result.path, "lib" });
                    if (std.Io.Dir.cwd().access(global_io, dep_lib_dir, .{})) |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = dep_lib_dir });
                    } else |_| {
                        try source_roots.append(alloc, .{ .name = dep_name, .path = result.path });
                    }

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
                    if (locked_commit == null or !std.mem.eql(u8, locked_commit.?, result.commit)) {
                        lockfile_changed = true;
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

    if (config.paths.len == 0 and config.root != null) {
        // Import-driven discovery from the entry point
        const root_spec = config.root.?;

        // Extract module name from root spec: "App.main/0" → "App"
        const slash_pos = std.mem.indexOfScalar(u8, root_spec, '/');
        const name_part = if (slash_pos) |pos| root_spec[0..pos] else root_spec;
        const last_dot = std.mem.lastIndexOfScalar(u8, name_part, '.');
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
    } else {
        // Glob-based file collection from paths
        for (config.paths) |pattern| {
            try globCollectFiles(alloc, project_root, pattern, &source_files);
        }
        // Also include dep source files (e.g., stdlib from deps)
        for (source_roots.items) |root| {
            if (std.mem.startsWith(u8, root.name, "dep:") or
                std.mem.eql(u8, root.name, "zap_stdlib"))
            {
                try globCollectFiles(alloc, root.path, "*.zap", &source_files);
            }
        }
    }

    // Deduplicate source files (explicit paths and dep paths may overlap)
    {
        var seen = std.StringHashMap(void).init(alloc);
        var deduped: std.ArrayListUnmanaged([]const u8) = .empty;
        for (source_files.items) |sf| {
            // Normalize: resolve to real path for comparison
            const key = std.Io.Dir.cwd().realpathAlloc(global_io, sf, alloc) catch sf;
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
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;

    // Validate one-module-per-file and name=path for each source file
    var validation_failed = false;
    for (source_files.items) |sf| {
        // Skip build.zap — it's build configuration, not project source
        if (std.mem.eql(u8, std.fs.path.basename(sf), "build.zap")) continue;

        const src = try std.Io.Dir.cwd().readFileAlloc(global_io, sf, alloc, .limited(10 * 1024 * 1024));
        try source_units.append(alloc, .{ .file_path = sf, .source = src });

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
            if (config.paths.len == 0) {
                // Import-driven: check the source_roots we built
                // Normalize paths by stripping leading "./" for consistent matching
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
                std.mem.trimLeft(u8, sf[project_root.len..], "/")
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

        if (compiler.validateOneModulePerFile(alloc, src, lib_rel)) |err_msg| {
            std.debug.print("Error: {s}\n", .{err_msg});
            validation_failed = true;
        }
    }
    if (validation_failed) {
        std.process.exit(1);
    }

    const merged_source = try compiler.mergeSourceUnits(alloc, source_units.items);

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
    std.Io.Dir.cwd().createDirPath(global_io, ".zap-cache") catch {};
    std.Io.Dir.cwd().createDirPath(global_io, out_dir) catch {};

    const output_filename = switch (config.kind) {
        .bin => output_name,
        .lib => try std.fmt.allocPrint(alloc, "{s}.a", .{output_name}),
        .obj => try std.fmt.allocPrint(alloc, "{s}.o", .{output_name}),
    };
    const output_path = try std.fs.path.join(alloc, &.{ out_dir, output_filename });

    // Compilation caching: hash build.zap + all sources + target name
    const cache_key = computeBuildCacheKey(build_source, merged_source, target_name, manifest_eval.result_hash);
    const cache_key_hex = try std.fmt.allocPrint(alloc, "{x:0>16}", .{cache_key});
    const hash_file = try std.fmt.allocPrint(alloc, ".zap-cache/{s}.hash", .{target_name});

    const cache_valid = blk: {
        const stored = std.Io.Dir.cwd().readFileAlloc(global_io, hash_file, alloc, .limited(16)) catch break :blk false;
        defer alloc.free(stored);
        if (!std.mem.eql(u8, stored, cache_key_hex)) break :blk false;
        std.Io.Dir.cwd().access(global_io, output_path, .{}) catch break :blk false;
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
    // Use per-file pipeline for import-driven discovery, legacy pipeline for glob
    const mod_order_slice: ?[]const []const u8 = if (module_order.items.len > 0)
        module_order.items
    else
        null;

    var result = compileProjectFrontend(alloc, source_units.items, .{
        .lib_mode = lib_mode,
        .module_order = mod_order_slice,
        .cache_dir = ".zap-cache/ctfe",
        .ctfe_target = target_name,
        .ctfe_optimize = @tagName(config.optimize),
    }) catch {
        std.process.exit(1);
    };


    // Resolve the manifest root (e.g. "Test.TestHelper.main/1") to an IR function ID
    // so the ZIR backend knows which function is the entry point.
    // IR naming: module parts joined by "_", then "__" before function name, then "__" arity.
    // e.g. "Test.TestHelper.main/1" -> "Test_TestHelper__main__1"
    if (config.root) |root| {
        // Extract arity suffix: "Test.TestHelper.main/1" -> arity="1"
        const arity_str = if (std.mem.lastIndexOfScalar(u8, root, '/')) |slash|
            root[slash + 1 ..]
        else
            "0";
        const without_arity = if (std.mem.lastIndexOfScalar(u8, root, '/')) |slash|
            root[0..slash]
        else
            root;
        // Split on last dot: module prefix vs function name
        // "Test.TestHelper.main" -> module="Test.TestHelper", func="main"
        var mangled: std.ArrayListUnmanaged(u8) = .empty;
        if (std.mem.lastIndexOfScalar(u8, without_arity, '.')) |last_dot| {
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
        // stderr writer removed in 0.16
        std.debug.print("Error: compilation failed\n", .{});
        std.process.exit(1);
    };

    // Save cache hash
    {
        var hash_f = std.Io.Dir.cwd().createFile(global_io, hash_file, .{}) catch return try allocator.dupe(u8, output_path);
        defer hash_f.close(global_io);
        hash_f.writeStreamingAll(global_io, cache_key_hex) catch {};
    }

    // Return a durable copy of the output path
    return try allocator.dupe(u8, output_path);
}

fn compileProjectFrontend(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    options: compiler.CompileOptions,
) !compiler.CompileResult {
    if (options.module_order) |module_order| {
        var ctx = try compiler.collectAllFromUnits(alloc, source_units, options);
        return try compiler.compileModuleByModule(alloc, &ctx, module_order, options);
    }
    const merged_source = try compiler.mergeSourceUnits(alloc, source_units);
    const file_path = if (source_units.len > 0) source_units[0].file_path else "<memory>";
    return try compiler.compileFrontend(alloc, merged_source, file_path, options);
}

fn computeBuildCacheKey(
    build_source: []const u8,
    merged_source: []const u8,
    target_name: []const u8,
    manifest_result_hash: u64,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(build_source);
    hasher.update(merged_source);
    hasher.update(target_name);
    hasher.update(std.mem.asBytes(&manifest_result_hash));
    return hasher.final();
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
                // stderr writer removed in 0.16
                std.debug.print("Error: --build-file requires a path\n", .{});
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
    const merged_source = "pub module App {}";
    const target_name = "default";

    const first = computeBuildCacheKey(build_source, merged_source, target_name, 111);
    const second = computeBuildCacheKey(build_source, merged_source, target_name, 222);

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
    var dir = std.Io.Dir.cwd().openDir(global_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(global_io);
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
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.FileNotFound);

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
