//! Builder Phase
//!
//! Handles build.zap manifest evaluation via CTFE (compile-time function
//! execution). The build source is compiled through the full frontend pipeline
//! to IR, then the manifest/1 function is evaluated at compile time to produce
//! a BuildConfig.

const std = @import("std");
const zap = @import("root.zig");
const compiler = zap.compiler;

/// Parsed manifest from the builder output.
pub const BuildConfig = struct {
    name: []const u8,
    version: []const u8,
    kind: Kind,
    root: ?[]const u8 = null,
    asset_name: ?[]const u8 = null,
    optimize: Optimize = .debug,
    paths: []const []const u8 = &.{},
    deps: []const Dep = &.{},
    build_opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Test timeout in milliseconds (0 = no timeout). Zig 0.16 supports
    /// native unit test timeouts in the build system.
    test_timeout: i64 = 0,
    /// Zig 0.16 error formatting style: "short" or "long".
    error_style: ?[]const u8 = null,
    /// Zig 0.16: enable verbose multi-line error output.
    multiline_errors: bool = false,

    /// Base URL for source links in generated docs (e.g., "https://github.com/user/repo").
    source_url: ?[]const u8 = null,
    /// Path to a Markdown file used as the documentation landing page.
    landing_page: ?[]const u8 = null,
    /// Additional documentation page groups: [{group_name, [file_paths]}].
    doc_groups: []const DocGroup = &.{},

    pub const DocGroup = struct {
        name: []const u8,
        pages: []const []const u8,
    };

    pub const Kind = enum { bin, lib, obj, doc };
    pub const Optimize = enum { debug, release_safe, release_fast, release_small };

    pub const Dep = struct {
        name: []const u8,
        source: DepSource,
        /// Local path override for development (Zig 0.16 local package override).
        /// When set, overrides git/path source with a local directory during dev.
        local_override: ?[]const u8 = null,
    };

    pub const DepSource = union(enum) {
        path: []const u8,
        git: GitSource,
        // Future: zig, system
    };

    pub const GitSource = struct {
        url: []const u8,
        tag: ?[]const u8 = null,
        branch: ?[]const u8 = null,
        rev: ?[]const u8 = null,
    };
};

pub const ManifestEval = struct {
    config: BuildConfig,
    dependencies: []const zap.ctfe.CtDependency,
    result_hash: u64,
};

/// Extract a BuildConfig by compiling build.zap and evaluating manifest/1
/// through the CTFE interpreter. This is the production path — it compiles
/// the builder module to IR and runs the manifest function at compile time.
pub fn ctfeManifest(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
) !BuildConfig {
    return (try ctfeManifestDetailed(alloc, build_source, target_name, build_opts, zap_lib_dir)).config;
}

pub fn ctfeManifestDetailed(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
) !ManifestEval {
    const ctfe = zap.ctfe;

    // Build source units: stdlib lib files + build.zap
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;

    // Read stdlib files from zap lib dir if available
    if (zap_lib_dir) |lib_dir| {
        try readLibSourceUnits(alloc, lib_dir, &source_units);
        const zap_subdir = try std.fs.path.join(alloc, &.{ lib_dir, "zap" });
        try readLibSourceUnits(alloc, zap_subdir, &source_units);
    }

    // Add build.zap as the final source unit
    try source_units.append(alloc, .{ .file_path = "build.zap", .source = build_source });

    // Compile through the full frontend pipeline to get IR
    var ctx = compiler.collectAllFromUnits(alloc, source_units.items, .{
        .show_progress = false,
    }) catch return error.CompileFailed;
    const result = compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = false,
    }) catch return error.CompileFailed;

    // Create CTFE interpreter with build capabilities and persistent cache
    var interp = ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.capabilities = ctfe.CapabilitySet.build;
    interp.build_opts = build_opts;
    interp.compile_options_hash = ctfe.hashCompileOptions(target_name, build_opts.get("optimize") orelse "release_safe");
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, ".zap-cache/ctfe") catch {};
    interp.persistent_cache = ctfe.PersistentCache.init(".zap-cache/ctfe");

    // Find the manifest function by scanning IR functions for one ending in "__manifest"
    const manifest_id = findManifestFunction(&result.ir_program) orelse
        return error.ManifestNotFound;

    // Construct the env argument: %Zap.Env{target: :target_name, os: :os, arch: :arch}
    const os_name = @tagName(@import("builtin").os.tag);
    const arch_name = @tagName(@import("builtin").cpu.arch);

    const env_const = ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Env",
        .fields = &.{
            .{ .name = "target", .value = .{ .atom = target_name } },
            .{ .name = "os", .value = .{ .atom = os_name } },
            .{ .name = "arch", .value = .{ .atom = arch_name } },
        },
    } };

    // Evaluate manifest/1
    const manifest_result = interp.evalAndExport(manifest_id, &.{env_const}, ctfe.CapabilitySet.build) catch {
        // Report CTFE errors
        // stderr removed in 0.16
        for (interp.errors.items) |err| {
            std.debug.print("  ctfe error: {s}\n", .{err.message});
        }
        return error.CtfeFailed;
    };

    return .{
        .config = try constValueToBuildConfig(alloc, manifest_result.value),
        .dependencies = manifest_result.dependencies,
        .result_hash = manifest_result.result_hash,
    };
}

/// Read all .zap files from a directory and add them as source units.
fn readLibSourceUnits(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch continue;
        try source_units.append(alloc, .{ .file_path = file_path, .source = source });
    }
}

fn findManifestFunction(program: *const zap.ir.Program) ?zap.ir.FunctionId {
    for (program.functions) |func| {
        if ((std.mem.endsWith(u8, func.name, "__manifest__1") or
            std.mem.endsWith(u8, func.name, "__manifest")) and func.arity == 1)
        {
            return func.id;
        }
        if ((std.mem.eql(u8, func.name, "manifest__1") or
            std.mem.eql(u8, func.name, "manifest")) and func.arity == 1)
        {
            return func.id;
        }
    }
    return null;
}

fn constValueToBuildConfig(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !BuildConfig {
    switch (val) {
        .struct_val => |sv| {
            var config = BuildConfig{
                .name = "",
                .version = "",
                .kind = .bin,
            };
            var paths_list: std.ArrayListUnmanaged([]const u8) = .empty;
            var deps_list: std.ArrayListUnmanaged(BuildConfig.Dep) = .empty;

            for (sv.fields) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    config.name = switch (field.value) {
                        .string => |s| try alloc.dupe(u8, s),
                        else => "",
                    };
                } else if (std.mem.eql(u8, field.name, "version")) {
                    config.version = switch (field.value) {
                        .string => |s| try alloc.dupe(u8, s),
                        else => "",
                    };
                } else if (std.mem.eql(u8, field.name, "kind")) {
                    config.kind = switch (field.value) {
                        .atom => |a| if (std.mem.eql(u8, a, "lib"))
                            .lib
                        else if (std.mem.eql(u8, a, "obj"))
                            .obj
                        else if (std.mem.eql(u8, a, "doc"))
                            .doc
                        else
                            .bin,
                        else => .bin,
                    };
                } else if (std.mem.eql(u8, field.name, "root")) {
                    config.root = switch (field.value) {
                        .string => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
                        else => null,
                    };
                } else if (std.mem.eql(u8, field.name, "asset_name")) {
                    config.asset_name = switch (field.value) {
                        .string => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
                        else => null,
                    };
                } else if (std.mem.eql(u8, field.name, "optimize")) {
                    config.optimize = switch (field.value) {
                        .atom => |a| if (std.mem.eql(u8, a, "debug"))
                            .debug
                        else if (std.mem.eql(u8, a, "release_fast"))
                            .release_fast
                        else if (std.mem.eql(u8, a, "release_small"))
                            .release_small
                        else
                            .release_safe,
                        else => .release_safe,
                    };
                } else if (std.mem.eql(u8, field.name, "paths")) {
                    switch (field.value) {
                        .list => |items| {
                            for (items) |item| {
                                switch (item) {
                                    .string => |s| try paths_list.append(alloc, try alloc.dupe(u8, s)),
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, field.name, "deps")) {
                    switch (field.value) {
                        .list => |items| {
                            for (items) |item| {
                                try deps_list.append(alloc, try constValueToDep(alloc, item));
                            }
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, field.name, "build_opts")) {
                    try loadBuildOpts(alloc, &config.build_opts, field.value);
                } else if (std.mem.eql(u8, field.name, "source_url")) {
                    config.source_url = switch (field.value) {
                        .string => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
                        else => null,
                    };
                } else if (std.mem.eql(u8, field.name, "landing_page")) {
                    config.landing_page = switch (field.value) {
                        .string => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
                        else => null,
                    };
                } else if (std.mem.eql(u8, field.name, "doc_groups")) {
                    switch (field.value) {
                        .list => |items| {
                            var groups_list: std.ArrayListUnmanaged(BuildConfig.DocGroup) = .empty;
                            for (items) |item| {
                                if (try constValueToDocGroup(alloc, item)) |group| {
                                    try groups_list.append(alloc, group);
                                }
                            }
                            config.doc_groups = try groups_list.toOwnedSlice(alloc);
                        },
                        else => {},
                    }
                }
            }

            config.paths = try paths_list.toOwnedSlice(alloc);
            config.deps = try deps_list.toOwnedSlice(alloc);
            return config;
        },
        else => return error.ManifestNotFound,
    }
}

fn constValueToDocGroup(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !?BuildConfig.DocGroup {
    // Expecting a tuple: {group_name, [page_paths]}
    switch (val) {
        .tuple => |fields| {
            if (fields.len != 2) return null;
            const name = switch (fields[0]) {
                .string => |s| try alloc.dupe(u8, s),
                else => return null,
            };
            const pages = switch (fields[1]) {
                .list => |items| blk: {
                    var page_list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (items) |item| {
                        switch (item) {
                            .string => |s| try page_list.append(alloc, try alloc.dupe(u8, s)),
                            else => {},
                        }
                    }
                    break :blk try page_list.toOwnedSlice(alloc);
                },
                else => return null,
            };
            return .{ .name = name, .pages = pages };
        },
        else => return null,
    }
}

fn constValueToDep(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !BuildConfig.Dep {
    var name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var git_url: ?[]const u8 = null;
    var git_tag: ?[]const u8 = null;
    var git_branch: ?[]const u8 = null;
    var git_rev: ?[]const u8 = null;

    switch (val) {
        .struct_val => |sv| {
            for (sv.fields) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    name = try constStringField(alloc, field.value);
                } else if (std.mem.eql(u8, field.name, "path")) {
                    path = try constOptionalStringField(alloc, field.value);
                } else if (std.mem.eql(u8, field.name, "git_url")) {
                    git_url = try constOptionalStringField(alloc, field.value);
                } else if (std.mem.eql(u8, field.name, "git_tag")) {
                    git_tag = try constOptionalStringField(alloc, field.value);
                } else if (std.mem.eql(u8, field.name, "git_branch")) {
                    git_branch = try constOptionalStringField(alloc, field.value);
                } else if (std.mem.eql(u8, field.name, "git_rev")) {
                    git_rev = try constOptionalStringField(alloc, field.value);
                }
            }
        },
        .map => |entries| {
            for (entries) |entry| {
                const key = constKeyName(entry.key) orelse continue;
                if (std.mem.eql(u8, key, "name")) {
                    name = try constStringField(alloc, entry.value);
                } else if (std.mem.eql(u8, key, "path")) {
                    path = try constOptionalStringField(alloc, entry.value);
                } else if (std.mem.eql(u8, key, "git_url")) {
                    git_url = try constOptionalStringField(alloc, entry.value);
                } else if (std.mem.eql(u8, key, "git_tag")) {
                    git_tag = try constOptionalStringField(alloc, entry.value);
                } else if (std.mem.eql(u8, key, "git_branch")) {
                    git_branch = try constOptionalStringField(alloc, entry.value);
                } else if (std.mem.eql(u8, key, "git_rev")) {
                    git_rev = try constOptionalStringField(alloc, entry.value);
                }
            }
        },
        .tuple => |elems| {
            // Tuple format: {:name, {:path, "path"}} or {:name, {:git, "url"}}
            // Also supports extended git: {:name, {:git, "url", tag: "v1"}}
            if (elems.len >= 2) {
                // First element: dep name (atom)
                switch (elems[0]) {
                    .atom => |a| name = try alloc.dupe(u8, a),
                    .string => |s| name = try alloc.dupe(u8, s),
                    else => {},
                }
                // Second element: source spec tuple {:path, "..."} or {:git, "..."}
                switch (elems[1]) {
                    .tuple => |source_elems| {
                        if (source_elems.len >= 2) {
                            const source_type = switch (source_elems[0]) {
                                .atom => |a| a,
                                else => "",
                            };
                            const source_val = switch (source_elems[1]) {
                                .string => |s| try alloc.dupe(u8, s),
                                else => null,
                            };
                            if (source_val) |sv| {
                                if (std.mem.eql(u8, source_type, "path")) {
                                    path = sv;
                                } else if (std.mem.eql(u8, source_type, "git")) {
                                    git_url = sv;
                                    // Optional extra fields: tag, branch, rev
                                    if (source_elems.len >= 3) {
                                        switch (source_elems[2]) {
                                            .string => |s| git_tag = try alloc.dupe(u8, s),
                                            else => {},
                                        }
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        else => return error.ManifestNotFound,
    }

    const dep_name = name orelse return error.ManifestNotFound;
    if (path) |dep_path| {
        return .{ .name = dep_name, .source = .{ .path = dep_path } };
    }
    if (git_url) |url| {
        return .{ .name = dep_name, .source = .{ .git = .{
            .url = url,
            .tag = git_tag,
            .branch = git_branch,
            .rev = git_rev,
        } } };
    }
    return error.ManifestNotFound;
}

fn loadBuildOpts(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged([]const u8),
    val: zap.ctfe.ConstValue,
) !void {
    switch (val) {
        .map => |entries| {
            for (entries) |entry| {
                const key = constKeyName(entry.key) orelse continue;
                const value = try constStringField(alloc, entry.value);
                try map.put(alloc, try alloc.dupe(u8, key), value);
            }
        },
        .list => |items| {
            for (items) |item| {
                switch (item) {
                    .tuple => |elems| {
                        if (elems.len != 2) continue;
                        const key = constKeyName(elems[0]) orelse continue;
                        const value = try constStringField(alloc, elems[1]);
                        try map.put(alloc, try alloc.dupe(u8, key), value);
                    },
                    .struct_val => |sv| {
                        var key: ?[]const u8 = null;
                        var value: ?[]const u8 = null;
                        for (sv.fields) |field| {
                            if (std.mem.eql(u8, field.name, "key")) key = try constStringField(alloc, field.value);
                            if (std.mem.eql(u8, field.name, "value")) value = try constStringField(alloc, field.value);
                        }
                        if (key != null and value != null) {
                            try map.put(alloc, key.?, value.?);
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn constStringField(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) ![]const u8 {
    return switch (val) {
        .string => |s| try alloc.dupe(u8, s),
        .atom => |s| try alloc.dupe(u8, s),
        else => error.ManifestNotFound,
    };
}

fn constOptionalStringField(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !?[]const u8 {
    return switch (val) {
        .nil => null,
        .string, .atom => try constStringField(alloc, val),
        else => null,
    };
}

fn constKeyName(val: zap.ctfe.ConstValue) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        .atom => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "constValueToBuildConfig parses deps and build opts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "deps", .value = .{ .list = &.{
                .{ .struct_val = .{
                    .type_name = "Zap_Dep",
                    .fields = &.{
                        .{ .name = "name", .value = .{ .string = "local_dep" } },
                        .{ .name = "path", .value = .{ .string = "../local_dep" } },
                    },
                } },
                .{ .struct_val = .{
                    .type_name = "Zap_Dep",
                    .fields = &.{
                        .{ .name = "name", .value = .{ .string = "git_dep" } },
                        .{ .name = "git_url", .value = .{ .string = "https://example.com/repo.git" } },
                        .{ .name = "git_tag", .value = .{ .string = "v1.2.3" } },
                    },
                } },
            } } },
            .{ .name = "build_opts", .value = .{ .list = &.{
                .{ .tuple = &.{ .{ .string = "optimize" }, .{ .string = "release_fast" } } },
                .{ .tuple = &.{ .{ .atom = "feature_x" }, .{ .string = "true" } } },
            } } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    try testing.expectEqual(@as(usize, 2), config.deps.len);
    try testing.expect(config.deps[0].source == .path);
    try testing.expectEqualStrings("../local_dep", config.deps[0].source.path);
    try testing.expect(config.deps[1].source == .git);
    try testing.expectEqualStrings("https://example.com/repo.git", config.deps[1].source.git.url);
    try testing.expectEqualStrings("v1.2.3", config.deps[1].source.git.tag.?);
    try testing.expectEqualStrings("release_fast", config.build_opts.get("optimize").?);
    try testing.expectEqualStrings("true", config.build_opts.get("feature_x").?);
}
