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
    /// Memory manager selected by the manifest. Initial build.zap CTFE
    /// records only the selected type so dependency resolution can
    /// complete first. The adapter source path is filled by evaluating
    /// `Memory.Manager.backend/1` after project and dependency sources
    /// are loaded.
    memory_manager: ?MemoryManager = null,
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

    pub const Kind = enum { bin, lib, obj };
    pub const Optimize = enum { debug, release_safe, release_fast, release_small };

    pub const MemoryManager = struct {
        /// Concrete manager type selected by `Zap.Manifest.memory`.
        type_name: []const u8,
        /// Source file that declared the adapter type, when available
        /// through build-time source reflection. The memory driver uses
        /// this to select the package root before applying the manager
        /// backend convention.
        adapter_source_path: ?[]const u8 = null,
    };

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
/// the builder struct to IR and runs the manifest function at compile time.
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
    }

    // Add build.zap as the final source unit
    try source_units.append(alloc, .{ .file_path = "build.zap", .source = build_source });

    // Run discovery so the staged macro pipeline has a topo order. Without
    // this, the legacy expansion path runs without a compiled IR, and any
    // macro `__using__` body that calls a regular Zap function via CTFE
    // (e.g. the glob helper from `Zap.Doc.Builder.__using__`) hits a null
    // `compiled_program` and falls through to AST evaluation that can't
    // execute `:zig.*` builtins. See `dispatchQualifiedComptimeCall` in
    // `macro_eval.zig` for the diagnostic path that surfaces the failure.
    const struct_order_data = computeStructOrder(alloc, build_source, source_units.items, zap_lib_dir) catch null;

    var collect_options = compiler.CompileOptions{
        .show_progress = false,
    };
    if (struct_order_data) |order| {
        collect_options.struct_order = order.struct_order;
        collect_options.level_boundaries = order.level_boundaries;
    }

    // Compile through the full frontend pipeline to get IR
    var ctx = compiler.collectAllFromUnits(alloc, source_units.items, collect_options) catch return error.CompileFailed;
    const result = compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = false,
    }) catch return error.CompileFailed;

    // Create CTFE interpreter with build capabilities and persistent cache
    var interp = ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = &ctx.interner;
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

    var config = try constValueToBuildConfig(alloc, manifest_result.value);
    config.memory_manager = try memoryManagerSelectionFromManifest(alloc, manifest_result.value);

    return .{
        .config = config,
        .dependencies = manifest_result.dependencies,
        .result_hash = manifest_result.result_hash,
    };
}

const StructOrderData = struct {
    struct_order: [][]const u8,
    level_boundaries: []u32,
};

/// Run import-driven discovery over `build.zap` + the supplied stdlib
/// source units to produce a topological compilation order. Returns the
/// ordered list of struct names plus the per-wave boundary indices.
///
/// Used by `ctfeManifestDetailed` to drive the staged macro-expansion
/// pipeline so a macro `__using__` body that CTFE-calls another stdlib
/// function (e.g. the glob helper) sees that function's IR by the time
/// the using struct is expanded. Failure to discover (e.g. missing
/// primary struct in build.zap) is non-fatal — the caller falls back
/// to the legacy expansion path and only macros that don't reach into
/// other structs' compiled bodies will succeed.
fn computeStructOrder(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    source_units: []const compiler.SourceUnit,
    zap_lib_dir: ?[]const u8,
) !StructOrderData {
    const entry = (try zap.discovery.primaryStructName(alloc, build_source)) orelse return error.NoPrimaryStruct;

    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    if (zap_lib_dir) |lib_dir| {
        try source_roots.append(alloc, .{ .name = "stdlib", .path = lib_dir });
    }

    var explicit_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (source_units) |unit| {
        try explicit_paths.append(alloc, unit.file_path);
    }

    var graph = try zap.discovery.discoverWithSourceFiles(
        alloc,
        entry,
        source_roots.items,
        &zap.discovery.BUILTIN_TYPE_NAMES,
        explicit_paths.items,
        null,
    );
    defer graph.deinit();

    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    for (graph.topo_order.items) |file_path| {
        if (graph.file_to_struct.get(file_path)) |struct_name| {
            try order.append(alloc, try alloc.dupe(u8, struct_name));
        }
    }

    var levels: std.ArrayListUnmanaged(u32) = .empty;
    for (graph.level_boundaries.items) |boundary| {
        try levels.append(alloc, boundary);
    }

    return .{
        .struct_order = try order.toOwnedSlice(alloc),
        .level_boundaries = try levels.toOwnedSlice(alloc),
    };
}

/// Read all .zap files from a directory and its subdirectories recursively,
/// adding them as source units.
fn readLibSourceUnits(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
            try readLibSourceUnits(alloc, subdir_path, source_units);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch continue;
        try source_units.append(alloc, .{ .file_path = file_path, .source = source });
    }
}

fn readLibSourceUnitsUnique(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
            try readLibSourceUnitsUnique(alloc, subdir_path, source_units);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch continue;
        try appendUniqueSourceUnit(alloc, source_units, .{ .file_path = file_path, .source = source });
    }
}

fn appendUniqueSourceUnit(
    alloc: std.mem.Allocator,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
    source_unit: compiler.SourceUnit,
) !void {
    const source_key = canonicalSourcePath(alloc, source_unit.file_path) catch try alloc.dupe(u8, source_unit.file_path);
    defer alloc.free(source_key);
    for (source_units.items) |existing| {
        const existing_key = canonicalSourcePath(alloc, existing.file_path) catch try alloc.dupe(u8, existing.file_path);
        defer alloc.free(existing_key);
        if (std.mem.eql(u8, existing_key, source_key)) return;
    }
    try source_units.append(alloc, source_unit);
}

fn canonicalSourcePath(alloc: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, file_path, alloc) catch {
        return std.fs.path.resolve(alloc, &.{file_path});
    };
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

pub const MemoryAdapterEval = struct {
    manager: ?BuildConfig.MemoryManager,
    result_hash: u64 = 0,
};

pub fn evaluateMemoryManagerAdapterFromSources(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    source_units: []const compiler.SourceUnit,
    selected_manager: ?BuildConfig.MemoryManager,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
) !MemoryAdapterEval {
    var ctfe_source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    try appendUniqueSourceUnit(alloc, &ctfe_source_units, .{ .file_path = "build.zap", .source = build_source });
    if (zap_lib_dir) |lib_dir| {
        try readLibSourceUnitsUnique(alloc, lib_dir, &ctfe_source_units);
    }
    for (source_units) |unit| {
        try appendUniqueSourceUnit(alloc, &ctfe_source_units, unit);
    }

    const struct_order_data = computeStructOrder(alloc, build_source, ctfe_source_units.items, zap_lib_dir) catch null;
    var collect_options = compiler.CompileOptions{
        .show_progress = false,
    };
    if (struct_order_data) |order| {
        collect_options.struct_order = order.struct_order;
        collect_options.level_boundaries = order.level_boundaries;
    }

    var ctx = compiler.collectAllFromUnits(alloc, ctfe_source_units.items, collect_options) catch return error.CompileFailed;
    const result = compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = false,
    }) catch return error.CompileFailed;

    var interp = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = &ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;
    interp.build_opts = build_opts;
    interp.compile_options_hash = zap.ctfe.hashCompileOptions(target_name, build_opts.get("optimize") orelse "release_safe");

    const manifest_id = findManifestFunction(&result.ir_program) orelse
        return error.ManifestNotFound;
    const manifest_result = interp.evalAndExport(
        manifest_id,
        &.{buildEnvConst(target_name)},
        zap.ctfe.CapabilitySet.build,
    ) catch return error.CtfeFailed;

    const selected = (try memoryManagerSelectionFromManifest(alloc, manifest_result.value)) orelse
        selected_manager orelse return .{ .manager = null };
    if (selected.type_name.len == 0) return .{ .manager = null };

    const adapter_value = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = selected.type_name,
        .fields = &.{},
    } };
    return evaluateMemoryManagerAdapterValue(
        alloc,
        &interp,
        &ctx.collector.graph,
        &ctx.interner,
        selected.type_name,
        adapter_value,
    );
}

fn memoryManagerSelectionFromManifest(
    alloc: std.mem.Allocator,
    manifest_value: zap.ctfe.ConstValue,
) !?BuildConfig.MemoryManager {
    const adapter_value = findManifestField(manifest_value, "memory") orelse return null;
    const adapter_type_name = (try parseStructRefField(alloc, adapter_value)) orelse return null;
    return .{ .type_name = adapter_type_name };
}

fn evaluateMemoryManagerAdapter(
    alloc: std.mem.Allocator,
    interp: *zap.ctfe.Interpreter,
    scope_graph: *const zap.scope.ScopeGraph,
    interner: *const zap.ast.StringInterner,
    manifest_value: zap.ctfe.ConstValue,
) !MemoryAdapterEval {
    const adapter_value = findManifestField(manifest_value, "memory") orelse return .{ .manager = null };
    const adapter_type_name = (try parseStructRefField(alloc, adapter_value)) orelse return .{ .manager = null };
    return evaluateMemoryManagerAdapterValue(alloc, interp, scope_graph, interner, adapter_type_name, adapter_value);
}

fn evaluateMemoryManagerAdapterValue(
    alloc: std.mem.Allocator,
    interp: *zap.ctfe.Interpreter,
    scope_graph: *const zap.scope.ScopeGraph,
    interner: *const zap.ast.StringInterner,
    adapter_type_name: []const u8,
    adapter_value: zap.ctfe.ConstValue,
) !MemoryAdapterEval {
    try requireMemoryManagerImpl(scope_graph, interner, adapter_type_name);

    interp.clearMemoryBackendBinding();
    const backend_eval = try evalAdapterFunction(alloc, interp, adapter_type_name, "backend", adapter_value);
    const backend_called = switch (backend_eval.value) {
        .bool_val => |value| value,
        else => return error.InvalidMemoryManagerAdapter,
    };
    if (!backend_called) return error.InvalidMemoryManagerAdapter;

    const backend_binding = interp.memory_backend_binding orelse return error.InvalidMemoryManagerAdapter;
    if (!std.mem.eql(u8, backend_binding.manager_type_name, adapter_type_name)) return error.InvalidMemoryManagerAdapter;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&backend_eval.result_hash));
    hasher.update(backend_binding.manager_type_name);
    if (backend_binding.adapter_source_path) |source_path| hasher.update(source_path);

    return .{
        .manager = .{
            .type_name = try alloc.dupe(u8, backend_binding.manager_type_name),
            .adapter_source_path = if (backend_binding.adapter_source_path) |source_path| try alloc.dupe(u8, source_path) else null,
        },
        .result_hash = hasher.final(),
    };
}

fn buildEnvConst(target_name: []const u8) zap.ctfe.ConstValue {
    const os_name = @tagName(@import("builtin").os.tag);
    const arch_name = @tagName(@import("builtin").cpu.arch);
    return zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Env",
        .fields = &.{
            .{ .name = "target", .value = .{ .atom = target_name } },
            .{ .name = "os", .value = .{ .atom = os_name } },
            .{ .name = "arch", .value = .{ .atom = arch_name } },
        },
    } };
}

fn requireMemoryManagerImpl(
    scope_graph: *const zap.scope.ScopeGraph,
    interner: *const zap.ast.StringInterner,
    adapter_type_name: []const u8,
) !void {
    for (scope_graph.impls.items) |impl_entry| {
        if (!structNameMatchesDotted(interner, impl_entry.protocol_name, "Memory.Manager")) continue;
        if (!structNameMatchesDotted(interner, impl_entry.target_type, adapter_type_name)) continue;
        return;
    }

    return error.InvalidMemoryManagerAdapter;
}

fn structNameMatchesDotted(
    interner: *const zap.ast.StringInterner,
    struct_name: zap.ast.StructName,
    dotted_name: []const u8,
) bool {
    var offset: usize = 0;
    for (struct_name.parts, 0..) |part_id, part_index| {
        if (part_index > 0) {
            if (offset >= dotted_name.len or dotted_name[offset] != '.') return false;
            offset += 1;
        }

        const part = interner.get(part_id);
        if (offset + part.len > dotted_name.len) return false;
        if (!std.mem.eql(u8, dotted_name[offset .. offset + part.len], part)) return false;
        offset += part.len;
    }

    return offset == dotted_name.len;
}

fn findManifestField(manifest_value: zap.ctfe.ConstValue, field_name: []const u8) ?zap.ctfe.ConstValue {
    switch (manifest_value) {
        .struct_val => |struct_value| {
            for (struct_value.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) return field.value;
            }
            return null;
        },
        else => return null,
    }
}

fn evalAdapterFunction(
    alloc: std.mem.Allocator,
    interp: *zap.ctfe.Interpreter,
    adapter_type_name: []const u8,
    method_name: []const u8,
    adapter_value: zap.ctfe.ConstValue,
) !zap.ctfe.CtEvalResult {
    const function_name = try adapterFunctionName(alloc, adapter_type_name, method_name);
    const function_id = interp.function_by_name.get(function_name) orelse return error.InvalidMemoryManagerAdapter;
    return interp.evalAndExport(function_id, &.{adapter_value}, zap.ctfe.CapabilitySet.build) catch return error.InvalidMemoryManagerAdapter;
}

fn adapterFunctionName(
    alloc: std.mem.Allocator,
    adapter_type_name: []const u8,
    method_name: []const u8,
) ![]const u8 {
    var prefix = std.ArrayListUnmanaged(u8).empty;
    defer prefix.deinit(alloc);
    for (adapter_type_name) |char| {
        try prefix.append(alloc, if (char == '.') '_' else char);
    }
    const mangled_method_name = try zap.ir.mangleSymbolForZig(alloc, method_name);
    return std.fmt.allocPrint(alloc, "{s}__{s}__1", .{ prefix.items, mangled_method_name });
}

pub fn hashManifestWithMemoryAdapter(manifest_hash: u64, memory_adapter_hash: u64) u64 {
    if (memory_adapter_hash == 0) return manifest_hash;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&manifest_hash));
    hasher.update(std.mem.asBytes(&memory_adapter_hash));
    return hasher.final();
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

/// Extract a dotted struct name from a manifest field whose value may be
/// any of:
///   * a 3-tuple `{:__aliases__, [], [:Foo, :Bar, :Baz]}` (the canonical
///     CTFE representation of a struct reference);
///   * an atom or string carrying the dotted name directly;
///   * a struct value (the CTFE form a `pub struct` evaluates to once
///     captured into a variable).
///
/// Returns null when the value is `nil` or any unsupported shape — the
/// caller treats this as "field absent" and falls back to defaults.
///
/// For `struct_val`, `sv.type_name` is always the canonical dotted form
/// produced by `ctfe.structNameToString` (which calls
/// `ast.StructName.toDottedString`) — see `src/ctfe.zig` near the
/// `struct_expr` evaluation in `evaluateConstExpr`. We return it
/// verbatim; we MUST NOT do underscore-to-dot translation because a
/// struct's actual name can legitimately contain underscores (e.g.,
/// `Foo_Bar.Manager`), and any heuristic that rewrites `_` → `.` would
/// silently mangle such names.
fn parseStructRefField(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !?[]const u8 {
    return switch (val) {
        .nil => null,
        .string => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
        .atom => |s| if (s.len > 0) try alloc.dupe(u8, s) else null,
        .tuple => |elems| blk: {
            if (elems.len != 3) break :blk null;
            if (elems[0] != .atom or !std.mem.eql(u8, elems[0].atom, "__aliases__")) break :blk null;
            if (elems[2] != .list) break :blk null;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            // `toOwnedSlice` clears `buf`'s pointer on success, so the
            // defer is a no-op on the happy path; on any OOM from
            // `buf.append`/`buf.appendSlice` the defer reclaims the
            // partial allocation.
            defer buf.deinit(alloc);
            for (elems[2].list, 0..) |part, idx| {
                const text = switch (part) {
                    .atom => |s| s,
                    .string => |s| s,
                    else => break :blk null,
                };
                if (idx > 0) try buf.append(alloc, '.');
                try buf.appendSlice(alloc, text);
            }
            break :blk try buf.toOwnedSlice(alloc);
        },
        .struct_val => |sv| if (sv.type_name.len > 0)
            try alloc.dupe(u8, sv.type_name)
        else
            null,
        else => null,
    };
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

test "parseStructRefField parses memory: struct reference (aliases form)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .tuple = &.{
        .{ .atom = "__aliases__" },
        .{ .list = &.{} },
        .{ .list = &.{
            .{ .atom = "Memory" },
            .{ .atom = "NoOp" },
        } },
    } };

    const parsed = (try parseStructRefField(alloc, val)) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("Memory.NoOp", parsed);
}

test "parseStructRefField parses memory: as a struct value with canonical dotted type_name" {
    // Production CTFE always populates `struct_val.type_name` with the
    // dotted form via `ctfe.structNameToString`. This test pins that
    // contract so `parseStructRefField` can return the name verbatim
    // without any heuristic translation.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Memory.ARC",
        .fields = &.{},
    } };

    const parsed = (try parseStructRefField(alloc, val)) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("Memory.ARC", parsed);
}

test "ctfe manifest evaluates Memory.Manager backend through one protocol method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\  fn backend(manager) -> Bool
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\  pub fn backend(manager :: Memory.ARC) -> Bool {
        \\    :zig.Memory.backend(manager)
        \\  }
        \\}
        \\
        \\pub struct Memory.NoOp {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.NoOp {
        \\  pub fn backend(manager :: Memory.NoOp) -> Bool {
        \\    :zig.Memory.backend(manager)
        \\  }
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  memory :: Memory.Manager = Memory.ARC
        \\}
        \\
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "app",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      memory: Memory.NoOp
        \\    }
        \\  }
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });
    const result = try compiler.compileForCtfe(alloc, &ctx, .{ .show_progress = false });

    var interp = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = &ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_id = findManifestFunction(&result.ir_program) orelse return error.ManifestNotFound;
    const env_const = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Env",
        .fields = &.{},
    } };

    const manifest_result = try interp.evalAndExport(manifest_id, &.{env_const}, zap.ctfe.CapabilitySet.build);
    var config = try constValueToBuildConfig(alloc, manifest_result.value);
    const memory_eval = try evaluateMemoryManagerAdapter(
        alloc,
        &interp,
        &ctx.collector.graph,
        &ctx.interner,
        manifest_result.value,
    );
    config.memory_manager = memory_eval.manager;

    try testing.expectEqualStrings("app", config.name);
    try testing.expectEqualStrings("0.1.0", config.version);
    try testing.expect(config.memory_manager != null);
    try testing.expectEqualStrings("Memory.NoOp", config.memory_manager.?.type_name);
    try testing.expectEqualStrings("build.zap", config.memory_manager.?.adapter_source_path.?);
}

test "ctfe manifest rejects backend methods without Memory.Manager impl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\  fn backend(manager) -> Bool
        \\}
        \\
        \\pub struct FakeManager {
        \\  pub fn backend(manager :: FakeManager) -> Bool {
        \\    :zig.Memory.backend(manager)
        \\  }
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });
    const result = try compiler.compileForCtfe(alloc, &ctx, .{ .show_progress = false });

    var interp = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = &ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_value = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "memory", .value = .{ .struct_val = .{
                .type_name = "FakeManager",
                .fields = &.{},
            } } },
        },
    } };
    try testing.expectError(
        error.InvalidMemoryManagerAdapter,
        evaluateMemoryManagerAdapter(
            alloc,
            &interp,
            &ctx.collector.graph,
            &ctx.interner,
            manifest_value,
        ),
    );
}

test "ctfe manifest evaluates default Memory.Manager backend when memory omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\  fn backend(manager) -> Bool
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\  pub fn backend(manager :: Memory.ARC) -> Bool {
        \\    :zig.Memory.backend(manager)
        \\  }
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  memory :: Memory.Manager = Memory.ARC
        \\}
        \\
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "app",
        \\      version: "0.1.0",
        \\      kind: :bin
        \\    }
        \\  }
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });
    const result = try compiler.compileForCtfe(alloc, &ctx, .{ .show_progress = false });

    var interp = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = &ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_id = findManifestFunction(&result.ir_program) orelse return error.ManifestNotFound;
    const env_const = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Env",
        .fields = &.{},
    } };

    const manifest_result = try interp.evalAndExport(manifest_id, &.{env_const}, zap.ctfe.CapabilitySet.build);
    var config = try constValueToBuildConfig(alloc, manifest_result.value);
    const memory_eval = try evaluateMemoryManagerAdapter(
        alloc,
        &interp,
        &ctx.collector.graph,
        &ctx.interner,
        manifest_result.value,
    );
    config.memory_manager = memory_eval.manager;

    try testing.expect(config.memory_manager != null);
    try testing.expectEqualStrings("Memory.ARC", config.memory_manager.?.type_name);
    try testing.expectEqualStrings("build.zap", config.memory_manager.?.adapter_source_path.?);
}

test "parseStructRefField preserves underscores in struct names" {
    // Regression: struct names like `Foo_Bar.Manager` legitimately
    // contain underscores. An earlier heuristic that rewrote `_` → `.`
    // silently mangled such names; the fix is to return `type_name`
    // verbatim from production CTFE (which emits the canonical dotted
    // form via `structNameToString`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Foo_Bar.Manager",
        .fields = &.{},
    } };
    const got = (try parseStructRefField(alloc, val)) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("Foo_Bar.Manager", got);
}

test "constValueToBuildConfig leaves memory: null when omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    try testing.expectEqual(@as(?BuildConfig.MemoryManager, null), config.memory_manager);
}
