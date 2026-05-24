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
    /// Phase 0 — DWARF foundation: optional per-build debug-info
    /// override. Null defers to the optimize-mode default
    /// (Debug/ReleaseSafe -> full DWARF embedded; ReleaseFast /
    /// ReleaseSmall -> stripped main binary + sibling split-debug
    /// artifact). The CLI flag `-Ddebug-info=<full|split|none>`
    /// sets this. See `main.zig`'s `resolveDebugInfoPolicy` for
    /// the full resolution rules.
    debug_info: ?DebugInfo = null,
    /// Phase 0 — DWARF foundation: optional frame-pointer override.
    /// Null defers to the optimize-mode default (Debug/ReleaseSafe
    /// keep frame pointers so sampling profilers work; ReleaseFast
    /// / ReleaseSmall drop them for the ~1-3% perf delta). The
    /// CLI flag `-Dframe-pointers=<on|off>` sets this.
    frame_pointers: ?bool = null,
    /// Cross-compilation target triple selected by the manifest
    /// (`Zap.Manifest.target`, e.g. "aarch64-linux-gnu"). Null means
    /// "native host" — the default when neither the manifest nor the
    /// CLI `-Dtarget=` flag specifies one. The CLI flag overrides this
    /// per-field (the command line is the ultimate source of truth).
    target: ?[]const u8 = null,
    /// Target CPU model/feature set selected by the manifest
    /// (`Zap.Manifest.cpu`, e.g. "baseline", "apple_m1"). Null means
    /// "the target's default CPU". Overridden per-field by the CLI
    /// `-Dcpu=` flag.
    cpu: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    deps: []const Dep = &.{},
    build_opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Memory manager type selected by the manifest. Initial build.zap
    /// CTFE records only the selected `Type` so dependency resolution can
    /// complete first. The adapter source path is filled by
    /// `resolveMemoryManagerBackendFromSourceGraph`, which scans the
    /// parsed source graph for the empty `impl Memory.Manager for <X>`
    /// decl and derives its declaring `.zap` file, after project and
    /// dependency sources are loaded. There is no callable backend
    /// resolver — `Memory.Manager` is a zero-method conformance marker.
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
    /// Optional manifest-level build pipeline. Null preserves the
    /// historical behavior: compile the manifest artifact only.
    pipeline: ?Pipeline = null,

    pub const DocGroup = struct {
        name: []const u8,
        pages: []const []const u8,
    };

    pub const Kind = enum { bin, lib, obj };
    pub const Optimize = enum { debug, release_safe, release_fast, release_small };
    /// Phase 0 — DWARF foundation: per-build override values.
    /// Mirrors `main.DebugInfoOverride` byte-for-byte; defined
    /// here so `BuildConfig` (a manifest-CTFE-visible struct) is
    /// self-contained.
    pub const DebugInfo = enum { full, split, none };

    pub const Pipeline = struct {
        steps: []const Step = &.{},
    };

    pub const Step = union(enum) {
        compile: Compile,
        run: Run,
    };

    pub const Compile = struct {};

    pub const Run = struct {
        args: []const []const u8 = &.{},
        forward_args: bool = true,
    };

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

/// Synthesize the `BuildConfig` for single-file script mode
/// (`zap run <script.zap>`), bypassing `build.zap` CTFE entirely.
///
/// A script has no manifest, no dependencies, and no project paths —
/// it is one synthetic module (the reserved wrapper struct holding the
/// hoisted top-level `main/1`) compiled against the stdlib only. The
/// root is the canonical `"<SyntheticStruct>.main/1"` string in the
/// exact same `"{s}.{s}/{d}"` shape `parseManifestRootFunction`
/// produces, so the existing root→IR-entry mangler in `buildTarget`
/// (`X.main/1` -> `X__main__1`) resolves the entry point unchanged.
///
/// This produces the script-mode BASE config: the synthetic defaults
/// (Debug optimize, `Memory.ARC`, native target/cpu) that stand in for
/// what `build.zap` CTFE yields on the manifest path. The CLI
/// `-D<key>=<value>` overrides are applied AFTERWARD by the single
/// shared `applyBuildOverrides` step, exactly as on the manifest path,
/// so the CLI is the ultimate per-field source of truth and there is
/// only one flag pipeline. No CTFE is performed here.
pub fn scriptManifest(
    alloc: std.mem.Allocator,
    synthetic_struct_name: []const u8,
) !BuildConfig {
    const root = try std.fmt.allocPrint(alloc, "{s}.main/1", .{synthetic_struct_name});
    return .{
        .name = "script",
        .version = "0.0.0",
        .kind = .bin,
        .root = root,
        .asset_name = null,
        // Synthetic script default; `applyBuildOverrides` overlays
        // `-Doptimize=` when present, matching the manifest path.
        .optimize = .debug,
        // Native by default; `-Dtarget=`/`-Dcpu=` overlay per-field.
        .target = null,
        .cpu = null,
        .paths = &.{},
        .deps = &.{},
        .build_opts = .empty,
        // Synthetic script default; `applyBuildOverrides` overlays
        // `-Dmemory=` (validated stdlib-only for script mode) when
        // present, matching the manifest path's `memory:` resolution.
        .memory_manager = SCRIPT_DEFAULT_MEMORY,
        .test_timeout = 0,
        .error_style = null,
        .multiline_errors = false,
        .source_url = null,
        .landing_page = null,
        .doc_groups = &.{},
    };
}

/// Default memory manager for script mode. Single source of truth so
/// the later flag-wiring phase overrides exactly one value. `Memory.ARC`
/// is the stdlib default the full manifest also defaults to (see
/// `lib/zap/manifest.zap`); `adapter_source_path` stays null because
/// the convention-resolved adapter is discovered from the stdlib source
/// roots by `evaluateMemoryManagerAdapterFromSources`, identical to the
/// manifest path.
pub const SCRIPT_DEFAULT_MEMORY: BuildConfig.MemoryManager = .{
    .type_name = "Memory.ARC",
    .adapter_source_path = null,
};

/// Read every `.zap` file under `dir_path` (recursively) into
/// `source_units`. Public wrapper over the builder-internal stdlib
/// reader so the single-file script path in the CLI can assemble the
/// stdlib source units exactly the way the manifest path does, without
/// duplicating the recursive scan.
pub fn readStdlibSourceUnits(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    try readLibSourceUnits(alloc, dir_path, source_units);
}

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
    return ctfeManifestDetailedWithProgress(alloc, build_source, target_name, build_opts, zap_lib_dir, null);
}

pub fn ctfeManifestDetailedWithProgress(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
    progress: ?*zap.progress.Reporter,
) !ManifestEval {
    const ctfe = zap.ctfe;
    const show_progress = progress != null;

    // Build source units: stdlib lib files + build.zap
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;

    // Read stdlib files from zap lib dir if available
    if (progress) |reporter| reporter.stage("Manifest: reading stdlib sources", .{});
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
    if (progress) |reporter| reporter.stage("Manifest: resolving build graph", .{});
    const struct_order_data = computeStructOrder(alloc, build_source, source_units.items, zap_lib_dir) catch null;

    var collect_options = compiler.CompileOptions{
        .show_progress = show_progress,
        .progress = progress,
        .progress_context = "Manifest",
        .allow_external_static_references = true,
    };
    if (struct_order_data) |order| {
        collect_options.struct_order = order.struct_order;
        collect_options.level_boundaries = order.level_boundaries;
    }

    // Compile through the full frontend pipeline to get IR
    if (progress) |reporter| reporter.stage("Manifest: compiling build.zap", .{});
    var ctx = compiler.collectAllFromUnits(alloc, source_units.items, collect_options) catch return error.CompileFailed;
    const result = compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = show_progress,
        .progress = progress,
        .progress_context = "Manifest",
        .allow_external_static_references = true,
    }) catch return error.CompileFailed;

    // Create CTFE interpreter with build capabilities and persistent cache
    if (progress) |reporter| reporter.stage("Manifest: evaluating build.zap", .{});
    var interp = ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = ctx.interner;
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
        // Report CTFE errors through the embedder-owned diagnostic stderr sink
        // (silent by default in a test build) rather than hardwiring
        // `std.debug.print` to the global stderr.
        for (interp.errors.items) |err| {
            zap.diagnostics.emitStderrFmt("  ctfe error: {s}\n", .{err.message});
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

/// Extract a `target:`/`cpu:` manifest field. The manifest declares
/// these as `Atom` (consistent with `kind`/`optimize`), so the value
/// arrives as `.atom`. The sentinel `:native` and the empty atom both
/// mean "host native" and map to `null` so the override model and the
/// cross-path selection treat absence uniformly. A `.string` is also
/// accepted for ergonomics (a quoted triple works too); anything else
/// is `null` (native).
fn atomTargetField(alloc: std.mem.Allocator, value: zap.ctfe.ConstValue) !?[]const u8 {
    const raw: []const u8 = switch (value) {
        .atom => |a| a,
        .string => |s| s,
        else => return null,
    };
    if (raw.len == 0 or std.mem.eql(u8, raw, "native")) return null;
    return try alloc.dupe(u8, raw);
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
                    config.root = try parseManifestRootFunction(alloc, field.value);
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
                } else if (std.mem.eql(u8, field.name, "target")) {
                    // A Zig target-triple atom (e.g.
                    // `:"aarch64-linux-gnu"`), mirroring how `kind`
                    // and `optimize` are atoms. `:native` or empty
                    // means "host native" — stored as null so the
                    // override model treats absence uniformly and the
                    // cross path stays on `zir_compilation_create`.
                    config.target = atomTargetField(alloc, field.value) catch
                        return error.OutOfMemory;
                } else if (std.mem.eql(u8, field.name, "cpu")) {
                    config.cpu = atomTargetField(alloc, field.value) catch
                        return error.OutOfMemory;
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
                } else if (std.mem.eql(u8, field.name, "pipeline")) {
                    config.pipeline = try constValueToPipeline(alloc, field.value);
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
    source_roots: []const zap.discovery.SourceRoot,
    source_units: []const compiler.SourceUnit,
    selected_manager: ?BuildConfig.MemoryManager,
    target_name: []const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
) !MemoryAdapterEval {
    const selected = selected_manager orelse return .{ .manager = null };
    if (selected.type_name.len == 0) return .{ .manager = null };

    var graph = try discoverMemoryAdapterGraph(alloc, selected.type_name, source_roots, source_units);
    defer graph.deinit();
    if (!graph.struct_to_file.contains(selected.type_name)) return error.InvalidMemoryManagerAdapter;

    var collect_source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    try appendDiscoveredSourceUnits(alloc, &collect_source_units, graph.topo_order.items, source_units, &graph);

    var struct_order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer struct_order.deinit(alloc);
    for (graph.topo_order.items) |file_path| {
        if (graph.file_to_struct.get(file_path)) |struct_name| {
            try struct_order.append(alloc, struct_name);
        }
    }

    // The redesigned resolver derives the declaring `.zap` path
    // directly from the parsed source graph. It only needs the parse
    // + collect surface (which populates `scope_graph.impls` and
    // registers source files); no HIR/IR lowering or CTFE interpreter
    // is constructed here. `target_name`/`build_opts` no longer
    // participate in adapter resolution — the active backend `.zig`
    // content is still independently folded into the build cache key
    // by `hashActiveManagerSource` (main.zig), so cache correctness is
    // unchanged. They remain in the signature because every manifest
    // entry path (build/run/test/doc/script/watch) routes through this
    // unchanged caller signature.
    _ = target_name;
    _ = build_opts;

    var collect_options = compiler.CompileOptions{
        .show_progress = false,
    };
    collect_options.struct_order = struct_order.items;
    collect_options.level_boundaries = graph.level_boundaries.items;

    var ctx = compiler.collectAllFromUnits(alloc, collect_source_units.items, collect_options) catch return error.CompileFailed;

    const source_path = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        &ctx.collector.graph,
        ctx.interner,
        selected.type_name,
    );
    return buildMemoryAdapterEval(alloc, selected.type_name, source_path);
}

fn discoverMemoryAdapterGraph(
    alloc: std.mem.Allocator,
    adapter_type_name: []const u8,
    source_roots: []const zap.discovery.SourceRoot,
    source_units: []const compiler.SourceUnit,
) !zap.discovery.FileGraph {
    var graph = try zap.discovery.discoverWithSourceFiles(
        alloc,
        adapter_type_name,
        source_roots,
        &zap.discovery.BUILTIN_TYPE_NAMES,
        &.{},
        null,
    );
    if (graph.struct_to_file.contains(adapter_type_name)) return graph;

    graph.deinit();

    const explicit_source_files = try explicitSourceFilesDeclaringStruct(alloc, source_units, adapter_type_name);
    var explicit_graph = try zap.discovery.discoverWithSourceFiles(
        alloc,
        adapter_type_name,
        source_roots,
        &zap.discovery.BUILTIN_TYPE_NAMES,
        explicit_source_files,
        null,
    );
    errdefer explicit_graph.deinit();
    return explicit_graph;
}

fn explicitSourceFilesDeclaringStruct(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    struct_name: []const u8,
) ![]const []const u8 {
    var file_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (source_units) |unit| {
        if (!try sourceDeclaresStructName(alloc, unit.source, struct_name)) continue;
        try file_paths.append(alloc, unit.file_path);
    }
    return try file_paths.toOwnedSlice(alloc);
}

fn sourceDeclaresStructName(
    alloc: std.mem.Allocator,
    source: []const u8,
    expected_struct_name: []const u8,
) !bool {
    var lexer = zap.Lexer.init(source);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) return false;
        if (tok.tag != .keyword_struct) continue;

        const name_tok = lexer.next();
        if (name_tok.tag != .type_identifier) continue;

        var name_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer name_buf.deinit(alloc);
        try name_buf.appendSlice(alloc, name_tok.slice(source));

        var peek = lexer;
        while (true) {
            const dot_tok = peek.next();
            if (dot_tok.tag != .dot) break;
            const next_tok = peek.next();
            if (next_tok.tag != .type_identifier) break;
            try name_buf.append(alloc, '.');
            try name_buf.appendSlice(alloc, next_tok.slice(source));
            lexer = peek;
        }

        if (std.mem.eql(u8, name_buf.items, expected_struct_name)) return true;
    }
}

fn appendDiscoveredSourceUnits(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(compiler.SourceUnit),
    file_paths: []const []const u8,
    provided_units: []const compiler.SourceUnit,
    graph: *const zap.discovery.FileGraph,
) !void {
    for (file_paths) |file_path| {
        const provided = try findProvidedSourceUnit(alloc, provided_units, file_path);
        if (provided) |unit| {
            try appendUniqueSourceUnit(alloc, out, unit);
            continue;
        }

        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch
            return error.ReadError;
        try appendUniqueSourceUnit(alloc, out, .{
            .file_path = file_path,
            .source = source,
            .primary_struct_name = graph.file_to_struct.get(file_path),
        });
    }
}

fn findProvidedSourceUnit(
    alloc: std.mem.Allocator,
    provided_units: []const compiler.SourceUnit,
    file_path: []const u8,
) !?compiler.SourceUnit {
    const target_key = canonicalSourcePath(alloc, file_path) catch try alloc.dupe(u8, file_path);
    defer alloc.free(target_key);

    for (provided_units) |unit| {
        const unit_key = canonicalSourcePath(alloc, unit.file_path) catch try alloc.dupe(u8, unit.file_path);
        defer alloc.free(unit_key);
        if (std.mem.eql(u8, unit_key, target_key)) return unit;
    }
    return null;
}

fn memoryManagerSelectionFromManifest(
    alloc: std.mem.Allocator,
    manifest_value: zap.ctfe.ConstValue,
) !?BuildConfig.MemoryManager {
    const memory_type_value = findManifestField(manifest_value, "memory") orelse return null;
    const adapter_type_name = try parseManifestMemoryType(alloc, memory_type_value);
    return .{ .type_name = adapter_type_name };
}

fn evaluateMemoryManagerAdapter(
    alloc: std.mem.Allocator,
    scope_graph: *const zap.scope.ScopeGraph,
    interner: *const zap.ast.StringInterner,
    manifest_value: zap.ctfe.ConstValue,
) !MemoryAdapterEval {
    const memory_type_value = findManifestField(manifest_value, "memory") orelse return .{ .manager = null };
    const adapter_type_name = try parseManifestMemoryType(alloc, memory_type_value);
    const source_path = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        scope_graph,
        interner,
        adapter_type_name,
    );
    return buildMemoryAdapterEval(alloc, adapter_type_name, source_path);
}

/// Resolve the `.zap` file that declares the `impl Memory.Manager for
/// <manager_type_name>` selected by the manifest, scanning the parsed
/// source graph directly. This is both the conformance gate and the
/// path resolver in a single pass over `scope_graph.impls` — there is
/// no separate scan and no CTFE execution.
///
/// The redesigned `Memory.Manager` protocol declares no methods and
/// adapters provide an empty `impl Memory.Manager for X {}`. The
/// declaring file is derived from the impl DECL span's `source_id`,
/// which the parser populates from the `impl`/`pub` keyword token
/// regardless of whether the impl body is empty (see
/// `Parser.parseImplDecl`: `meta.span = merge(start, ...)` where
/// `start` is captured at the keyword). Per-`.zap`-file `source_id`
/// is the unit index registered via `ScopeGraph.registerSourceFile`,
/// so `sourcePathById` round-trips it back to the file path.
///
/// Returns `error.InvalidMemoryManagerAdapter` with a precise
/// diagnostic when: (a) no `impl Memory.Manager for <X>` exists, (b)
/// the matching impl decl span has no `source_id`, or (c) the
/// `source_id` is not registered in the source graph.
fn resolveMemoryManagerBackendFromSourceGraph(
    alloc: std.mem.Allocator,
    scope_graph: *const zap.scope.ScopeGraph,
    interner: *const zap.ast.StringInterner,
    manager_type_name: []const u8,
) ![]const u8 {
    for (scope_graph.impls.items) |impl_entry| {
        if (!structNameMatchesDotted(interner, impl_entry.protocol_name, "Memory.Manager")) continue;
        if (!structNameMatchesDotted(interner, impl_entry.target_type, manager_type_name)) continue;

        const source_id = impl_entry.decl.meta.span.source_id orelse {
            zap.diagnostics.emitStderrFmt(
                "Error: memory manager '{s}' impl Memory.Manager has no source location\n",
                .{manager_type_name},
            );
            return error.InvalidMemoryManagerAdapter;
        };
        const path = scope_graph.sourcePathById(source_id) orelse {
            zap.diagnostics.emitStderrFmt(
                "Error: memory manager '{s}' impl Memory.Manager source file is not registered\n",
                .{manager_type_name},
            );
            return error.InvalidMemoryManagerAdapter;
        };
        return alloc.dupe(u8, path);
    }

    zap.diagnostics.emitStderrFmt(
        "Error: memory manager '{s}' selected by manifest does not implement Memory.Manager\n",
        .{manager_type_name},
    );
    return error.InvalidMemoryManagerAdapter;
}

/// Build the observable `MemoryAdapterEval` contract from the resolved
/// manager type name and its declaring `.zap` path. `result_hash` is a
/// stable Wyhash over `(type_name ++ resolved source path)` — the same
/// `std.hash.Wyhash` approach the cache-key helpers use. It changes
/// whenever the selected manager or its declaring file changes;
/// backend `.zig` content changes are independently folded into the
/// build cache key by `hashActiveManagerSource` (main.zig), so the
/// combined cache key still invalidates on both axes.
fn buildMemoryAdapterEval(
    alloc: std.mem.Allocator,
    manager_type_name: []const u8,
    source_path: []const u8,
) !MemoryAdapterEval {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(manager_type_name);
    hasher.update(source_path);

    return .{
        .manager = .{
            .type_name = try alloc.dupe(u8, manager_type_name),
            .adapter_source_path = source_path,
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
        .struct_val => |struct_value| return findConstStructField(struct_value, field_name),
        else => return null,
    }
}

fn findConstStructField(
    struct_value: zap.ctfe.ConstValue.ConstStructValue,
    field_name: []const u8,
) ?zap.ctfe.ConstValue {
    for (struct_value.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return field.value;
    }
    return null;
}

pub fn hashManifestWithMemoryAdapter(manifest_hash: u64, memory_adapter_hash: u64) u64 {
    if (memory_adapter_hash == 0) return manifest_hash;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&manifest_hash));
    hasher.update(std.mem.asBytes(&memory_adapter_hash));
    return hasher.final();
}

fn constValueToPipeline(
    alloc: std.mem.Allocator,
    val: zap.ctfe.ConstValue,
) !?BuildConfig.Pipeline {
    if (val == .nil) return null;
    if (val != .struct_val) return error.InvalidManifestPipeline;

    const pipeline_value = val.struct_val;
    const steps_value = findConstStructField(pipeline_value, "steps") orelse
        return error.InvalidManifestPipeline;
    const step_values = switch (steps_value) {
        .list => |items| items,
        else => return error.InvalidManifestPipeline,
    };

    var steps: std.ArrayListUnmanaged(BuildConfig.Step) = .empty;
    for (step_values) |step_value| {
        try steps.append(alloc, try constValueToPipelineStep(alloc, step_value));
    }
    if (steps.items.len == 0) return error.InvalidManifestPipeline;
    return BuildConfig.Pipeline{ .steps = try steps.toOwnedSlice(alloc) };
}

fn constValueToPipelineStep(
    alloc: std.mem.Allocator,
    val: zap.ctfe.ConstValue,
) !BuildConfig.Step {
    if (val != .struct_val) return error.InvalidManifestPipeline;

    var parsed_step: ?BuildConfig.Step = null;
    for (val.struct_val.fields) |field| {
        if (std.mem.eql(u8, field.name, "compile")) {
            if (field.value == .nil) continue;
            if (parsed_step != null) return error.InvalidManifestPipeline;
            parsed_step = .{ .compile = try constValueToPipelineCompile(field.value) };
        } else if (std.mem.eql(u8, field.name, "run")) {
            if (field.value == .nil) continue;
            if (parsed_step != null) return error.InvalidManifestPipeline;
            parsed_step = .{ .run = try constValueToPipelineRun(alloc, field.value) };
        }
    }

    return parsed_step orelse error.InvalidManifestPipeline;
}

fn constValueToPipelineCompile(val: zap.ctfe.ConstValue) !BuildConfig.Compile {
    if (val != .struct_val) return error.InvalidManifestPipeline;
    return .{};
}

fn constValueToPipelineRun(
    alloc: std.mem.Allocator,
    val: zap.ctfe.ConstValue,
) !BuildConfig.Run {
    if (val != .struct_val) return error.InvalidManifestPipeline;

    var run: BuildConfig.Run = .{};
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }
    for (val.struct_val.fields) |field| {
        if (std.mem.eql(u8, field.name, "args")) {
            const arg_values = switch (field.value) {
                .list => |items| items,
                else => return error.InvalidManifestPipeline,
            };
            for (arg_values) |arg_value| {
                switch (arg_value) {
                    .string => |arg| try args.append(alloc, try alloc.dupe(u8, arg)),
                    else => return error.InvalidManifestPipeline,
                }
            }
        } else if (std.mem.eql(u8, field.name, "forward_args")) {
            run.forward_args = switch (field.value) {
                .bool_val => |forward_args| forward_args,
                else => return error.InvalidManifestPipeline,
            };
        }
    }
    run.args = try args.toOwnedSlice(alloc);
    return run;
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

fn parseManifestRootFunction(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) !?[]const u8 {
    if (val == .nil) return null;
    if (val != .struct_val) return error.InvalidManifestRoot;

    const function_value = val.struct_val;
    if (!std.mem.eql(u8, function_value.type_name, "Function")) return error.InvalidManifestRoot;

    const root_struct_value = findConstStructField(function_value, "struct") orelse return error.InvalidManifestRoot;
    const root_struct_name = try parseTypeReferenceName(root_struct_value, error.InvalidManifestRoot);
    const function_name_value = findConstStructField(function_value, "name") orelse return error.InvalidManifestRoot;
    const arity_value = findConstStructField(function_value, "arity") orelse return error.InvalidManifestRoot;

    const function_name = switch (function_name_value) {
        .atom => |name| if (name.len > 0) name else return error.InvalidManifestRoot,
        else => return error.InvalidManifestRoot,
    };
    const arity = switch (arity_value) {
        .int => |value| if (value >= 0)
            @as(u8, @truncate(@as(u64, @intCast(value))))
        else
            return error.InvalidManifestRoot,
        else => return error.InvalidManifestRoot,
    };

    return try std.fmt.allocPrint(alloc, "{s}.{s}/{d}", .{ root_struct_name, function_name, arity });
}

fn parseManifestMemoryType(alloc: std.mem.Allocator, val: zap.ctfe.ConstValue) ![]const u8 {
    const type_name = try parseTypeReferenceName(val, error.InvalidManifestMemory);
    return try alloc.dupe(u8, type_name);
}

fn parseTypeReferenceName(
    val: zap.ctfe.ConstValue,
    comptime invalid_error: anyerror,
) ![]const u8 {
    if (val != .struct_val) return invalid_error;

    const type_value = val.struct_val;
    if (!std.mem.eql(u8, type_value.type_name, "Type")) return invalid_error;

    const name_value = findConstStructField(type_value, "name") orelse return invalid_error;
    return switch (name_value) {
        .atom => |name| if (name.len > 0) name else invalid_error,
        else => invalid_error,
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

test "constValueToBuildConfig leaves pipeline null when omitted" {
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
    try testing.expect(config.pipeline == null);
}

test "constValueToBuildConfig parses compile and run pipeline steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "pipeline", .value = .{ .struct_val = .{
                .type_name = "Zap.Build.Pipeline",
                .fields = &.{
                    .{ .name = "steps", .value = .{ .list = &.{
                        .{ .struct_val = .{
                            .type_name = "Zap.Build.Step",
                            .fields = &.{
                                .{ .name = "compile", .value = .{ .struct_val = .{
                                    .type_name = "Zap.Build.Compile",
                                    .fields = &.{},
                                } } },
                            },
                        } },
                        .{ .struct_val = .{
                            .type_name = "Zap.Build.Step",
                            .fields = &.{
                                .{ .name = "run", .value = .{ .struct_val = .{
                                    .type_name = "Zap.Build.Run",
                                    .fields = &.{
                                        .{ .name = "args", .value = .{ .list = &.{
                                            .{ .string = "--only" },
                                            .{ .string = "math" },
                                        } } },
                                        .{ .name = "forward_args", .value = .{ .bool_val = true } },
                                    },
                                } } },
                            },
                        } },
                    } } },
                },
            } } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    const pipeline = config.pipeline orelse return error.ExpectedPipeline;
    try testing.expectEqual(@as(usize, 2), pipeline.steps.len);
    try testing.expect(pipeline.steps[0] == .compile);
    try testing.expect(pipeline.steps[1] == .run);
    try testing.expectEqualStrings("--only", pipeline.steps[1].run.args[0]);
    try testing.expectEqualStrings("math", pipeline.steps[1].run.args[1]);
    try testing.expect(pipeline.steps[1].run.forward_args);
}

test "constValueToBuildConfig rejects an empty pipeline override" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "pipeline", .value = .{ .struct_val = .{
                .type_name = "Zap.Build.Pipeline",
                .fields = &.{
                    .{ .name = "steps", .value = .{ .list = &.{} } },
                },
            } } },
        },
    } };

    try testing.expectError(error.InvalidManifestPipeline, constValueToBuildConfig(alloc, val));
}

test "constValueToBuildConfig rejects a pipeline override without steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "pipeline", .value = .{ .struct_val = .{
                .type_name = "Zap.Build.Pipeline",
                .fields = &.{},
            } } },
        },
    } };

    try testing.expectError(error.InvalidManifestPipeline, constValueToBuildConfig(alloc, val));
}

test "constValueToBuildConfig rejects a pipeline step with multiple actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "pipeline", .value = .{ .struct_val = .{
                .type_name = "Zap.Build.Pipeline",
                .fields = &.{
                    .{ .name = "steps", .value = .{ .list = &.{
                        .{ .struct_val = .{
                            .type_name = "Zap.Build.Step",
                            .fields = &.{
                                .{ .name = "compile", .value = .{ .struct_val = .{
                                    .type_name = "Zap.Build.Compile",
                                    .fields = &.{},
                                } } },
                                .{ .name = "run", .value = .{ .struct_val = .{
                                    .type_name = "Zap.Build.Run",
                                    .fields = &.{},
                                } } },
                            },
                        } },
                    } } },
                },
            } } },
        },
    } };

    try testing.expectError(error.InvalidManifestPipeline, constValueToBuildConfig(alloc, val));
}

test "constValueToBuildConfig parses root Function value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "root", .value = .{ .struct_val = .{
                .type_name = "Function",
                .fields = &.{
                    .{ .name = "struct", .value = .{ .struct_val = .{
                        .type_name = "Type",
                        .fields = &.{
                            .{ .name = "name", .value = .{ .atom = "Arena" } },
                        },
                    } } },
                    .{ .name = "name", .value = .{ .atom = "main" } },
                    .{ .name = "arity", .value = .{ .int = 1 } },
                },
            } } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    try testing.expect(config.root != null);
    try testing.expectEqualStrings("Arena.main/1", config.root.?);
}

test "constValueToBuildConfig narrows root Function arity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "root", .value = .{ .struct_val = .{
                .type_name = "Function",
                .fields = &.{
                    .{ .name = "struct", .value = .{ .struct_val = .{
                        .type_name = "Type",
                        .fields = &.{
                            .{ .name = "name", .value = .{ .atom = "Arena" } },
                        },
                    } } },
                    .{ .name = "name", .value = .{ .atom = "main" } },
                    .{ .name = "arity", .value = .{ .int = 300 } },
                },
            } } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    try testing.expect(config.root != null);
    try testing.expectEqualStrings("Arena.main/44", config.root.?);
}

test "constValueToBuildConfig rejects legacy string root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "root", .value = .{ .string = "Arena.main/1" } },
        },
    } };

    try testing.expectError(error.InvalidManifestRoot, constValueToBuildConfig(alloc, val));
}

test "ctfe manifest extracts root Function reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  root :: Function | Nil = nil
        \\}
        \\
        \\pub struct App {
        \\  pub fn main(_args :: Nil) -> Nil {
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "app",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &App.main/1
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
    interp.interner = ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_id = findManifestFunction(&result.ir_program) orelse return error.ManifestNotFound;
    const env_const = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Env",
        .fields = &.{},
    } };

    const manifest_result = try interp.evalAndExport(manifest_id, &.{env_const}, zap.ctfe.CapabilitySet.build);
    const config = try constValueToBuildConfig(alloc, manifest_result.value);

    try testing.expect(config.root != null);
    try testing.expectEqualStrings("App.main/1", config.root.?);
}

test "ctfe manifest permits target-source Type and Function references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  root :: Function | Nil = nil
        \\  memory :: Type | Nil = nil
        \\}
        \\
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "app",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &App.main/1,
        \\      memory: ThirdParty.ProjectArena
        \\    }
        \\  }
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });
    const result = try compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = false,
        .allow_external_static_references = true,
    });

    var interp = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_id = findManifestFunction(&result.ir_program) orelse return error.ManifestNotFound;
    const env_const = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Env",
        .fields = &.{},
    } };

    const manifest_result = try interp.evalAndExport(manifest_id, &.{env_const}, zap.ctfe.CapabilitySet.build);
    const config = try constValueToBuildConfig(alloc, manifest_result.value);
    const selected_memory = try memoryManagerSelectionFromManifest(alloc, manifest_result.value);

    try testing.expect(config.root != null);
    try testing.expectEqualStrings("App.main/1", config.root.?);
    try testing.expect(selected_memory != null);
    try testing.expectEqualStrings("ThirdParty.ProjectArena", selected_memory.?.type_name);
}

test "ctfe manifest staged discovery permits target-source Type and Function references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Zap.Env {
        \\  target :: Atom
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  root :: Function | Nil = nil
        \\  memory :: Type | Nil = nil
        \\}
        \\
        \\pub struct TestProg.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "test_prog",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &TestProg.main/0,
        \\      memory: ThirdParty.ProjectArena
        \\    }
        \\  }
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };
    const struct_order = [_][]const u8{"TestProg.Builder"};
    const level_boundaries = [_]u32{1};

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .struct_order = &struct_order,
        .level_boundaries = &level_boundaries,
        .allow_external_static_references = true,
    });
    const ctfe_result = try compiler.compileForCtfe(alloc, &ctx, .{
        .show_progress = false,
        .allow_external_static_references = true,
    });

    var interp = zap.ctfe.Interpreter.init(alloc, &ctfe_result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = ctx.interner;
    interp.capabilities = zap.ctfe.CapabilitySet.build;

    const manifest_id = findManifestFunction(&ctfe_result.ir_program) orelse return error.ManifestNotFound;
    const manifest_result = try interp.evalAndExport(
        manifest_id,
        &.{buildEnvConst("test_prog")},
        zap.ctfe.CapabilitySet.build,
    );
    const config = try constValueToBuildConfig(alloc, manifest_result.value);
    const selected_memory = try memoryManagerSelectionFromManifest(alloc, manifest_result.value);

    try testing.expect(config.root != null);
    try testing.expectEqualStrings("TestProg.main/0", config.root.?);
    try testing.expect(selected_memory != null);
    try testing.expectEqualStrings("ThirdParty.ProjectArena", selected_memory.?.type_name);
}

test "memoryManagerSelectionFromManifest parses memory Type value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "memory", .value = .{ .struct_val = .{
                .type_name = "Type",
                .fields = &.{
                    .{ .name = "name", .value = .{ .atom = "ThirdParty.ProjectArena" } },
                },
            } } },
        },
    } };

    const selected = (try memoryManagerSelectionFromManifest(alloc, val)) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("ThirdParty.ProjectArena", selected.type_name);
}

test "memoryManagerSelectionFromManifest rejects legacy memory string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "memory", .value = .{ .string = "Memory.ARC" } },
        },
    } };

    try testing.expectError(error.InvalidManifestMemory, memoryManagerSelectionFromManifest(alloc, val));
}

test "ctfe manifest evaluates third-party Memory.Manager backend through protocol metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\}
        \\
        \\pub struct ThirdParty.ProjectArena {
        \\}
        \\
        \\pub impl Memory.Manager for ThirdParty.ProjectArena {
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  memory :: Type = Memory.ARC
        \\}
        \\
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "app",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      memory: ThirdParty.ProjectArena
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
    interp.interner = ctx.interner;
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
        &ctx.collector.graph,
        ctx.interner,
        manifest_result.value,
    );
    config.memory_manager = memory_eval.manager;

    try testing.expectEqualStrings("app", config.name);
    try testing.expectEqualStrings("0.1.0", config.version);
    try testing.expect(config.memory_manager != null);
    try testing.expectEqualStrings("ThirdParty.ProjectArena", config.memory_manager.?.type_name);
    try testing.expectEqualStrings("build.zap", config.memory_manager.?.adapter_source_path.?);
}

test "ctfe manifest rejects manager without Memory.Manager impl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Under the redesign there is no `backend` method to inspect; a
    // struct that simply never declares `impl Memory.Manager for it`
    // must be rejected by the resolver's conformance gate.
    const source =
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct FakeManager {
        \\}
    ;

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    const manifest_value = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "memory", .value = .{ .struct_val = .{
                .type_name = "Type",
                .fields = &.{
                    .{ .name = "name", .value = .{ .atom = "FakeManager" } },
                },
            } } },
        },
    } };
    try testing.expectError(
        error.InvalidMemoryManagerAdapter,
        evaluateMemoryManagerAdapter(
            alloc,
            &ctx.collector.graph,
            ctx.interner,
            manifest_value,
        ),
    );
}

test "ctfe manifest evaluates default Memory.Manager backend when memory omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\}
        \\
        \\pub struct Zap.Env {
        \\}
        \\
        \\pub struct Zap.Manifest {
        \\  name :: String
        \\  version :: String
        \\  kind :: Atom
        \\  memory :: Type = Memory.ARC
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
    interp.interner = ctx.interner;
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
        &ctx.collector.graph,
        ctx.interner,
        manifest_result.value,
    );
    config.memory_manager = memory_eval.manager;

    try testing.expect(config.memory_manager != null);
    try testing.expectEqualStrings("Memory.ARC", config.memory_manager.?.type_name);
    try testing.expectEqualStrings("build.zap", config.memory_manager.?.adapter_source_path.?);
}

test "memoryManagerSelectionFromManifest preserves underscores in Type names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "memory", .value = .{ .struct_val = .{
                .type_name = "Type",
                .fields = &.{
                    .{ .name = "name", .value = .{ .atom = "Foo_Bar.Manager" } },
                },
            } } },
        },
    } };
    const selected = (try memoryManagerSelectionFromManifest(alloc, val)) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("Foo_Bar.Manager", selected.type_name);
}

test "memory adapter source evaluation ignores unrelated project sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.Options.debug_io, "lib/third_party");

    // This test routes through `evaluateMemoryManagerAdapterFromSources`
    // with the real Zap stdlib in `source_roots`, so collection runs
    // `validateImplConformance` against the real `lib/memory/manager.zap`
    // protocol. Phase 3 made `Memory.Manager` a zero-method conformance
    // marker, so the conformant adapter is an empty
    // `impl Memory.Manager for X {}`. The resolver keys off the impl
    // DECL span, so the empty marker resolves to the adapter's source
    // path exactly as before.
    const manager_source =
        \\pub struct ThirdParty.ProjectArena {
        \\}
        \\
        \\pub impl Memory.Manager for ThirdParty.ProjectArena {}
    ;
    const unrelated_source =
        \\pub struct TestProg {
        \\  pub fn main() -> String {
        \\    Missing.call()
        \\    "done"
        \\  }
        \\}
    ;

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "lib/third_party/project_arena.zap",
        .data = manager_source,
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "lib/test_prog.zap",
        .data = unrelated_source,
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const project_lib_path = try std.fs.path.join(alloc, &.{ tmp_path, "lib" });
    const zap_lib_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "lib", alloc);
    const manager_path = try std.fs.path.join(alloc, &.{ project_lib_path, "third_party", "project_arena.zap" });
    const unrelated_path = try std.fs.path.join(alloc, &.{ project_lib_path, "test_prog.zap" });

    const source_roots = &[_]zap.discovery.SourceRoot{
        .{ .name = "project", .path = project_lib_path },
        .{ .name = "zap_stdlib", .path = zap_lib_path },
    };
    const source_units = &[_]compiler.SourceUnit{
        .{ .file_path = manager_path, .source = manager_source },
        .{ .file_path = unrelated_path, .source = unrelated_source },
    };

    const build_opts = std.StringHashMapUnmanaged([]const u8).empty;
    const memory_eval = try evaluateMemoryManagerAdapterFromSources(
        alloc,
        source_roots,
        source_units,
        .{ .type_name = "ThirdParty.ProjectArena" },
        "test_prog",
        build_opts,
    );

    try testing.expect(memory_eval.manager != null);
    try testing.expectEqualStrings("ThirdParty.ProjectArena", memory_eval.manager.?.type_name);
    try testing.expectEqualStrings(manager_path, memory_eval.manager.?.adapter_source_path.?);
}

test "resolveMemoryManagerBackendFromSourceGraph resolves default Memory.ARC empty impl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\}
    ;
    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/memory/arc.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    const resolved = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        &ctx.collector.graph,
        ctx.interner,
        "Memory.ARC",
    );
    try testing.expectEqualStrings("lib/memory/arc.zap", resolved);
}

test "resolveMemoryManagerBackendFromSourceGraph resolves explicitly selected manager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\}
        \\
        \\pub struct ThirdParty.ProjectArena {
        \\}
        \\
        \\pub impl Memory.Manager for ThirdParty.ProjectArena {
        \\}
    ;
    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    const resolved = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        &ctx.collector.graph,
        ctx.interner,
        "ThirdParty.ProjectArena",
    );
    try testing.expectEqualStrings("build.zap", resolved);
}

test "resolveMemoryManagerBackendFromSourceGraph rejects manager with no conforming impl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub protocol Memory.Manager {
        \\}
        \\
        \\pub struct Memory.ARC {
        \\}
        \\
        \\pub impl Memory.Manager for Memory.ARC {
        \\}
        \\
        \\pub struct NotAManager {
        \\}
    ;
    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    try testing.expectError(
        error.InvalidMemoryManagerAdapter,
        resolveMemoryManagerBackendFromSourceGraph(
            alloc,
            &ctx.collector.graph,
            ctx.interner,
            "NotAManager",
        ),
    );
}

// ---------------------------------------------------------------------------
// Stdlib manager selection matrix.
//
// This is the build-time replacement for the deleted runtime
// `Memory.Manager.backend(...)` Zest cases (`test/zap/memory_manager_test.zap`
// and the WIP `test/zap/memory/manager_test.zap`). Backend resolution is a
// build-time concern (Phase 3 removed the runtime `backend/1` mechanism), so
// the correct surface is the source-graph resolver plus the real stdlib
// adapter/backend files — not a runtime protocol call.
//
// The deleted .zap cases only ever asserted `backend(X) == true` for ARC,
// Arena, Leak, Tracking, NoOp. This matrix is strictly stronger: for each of
// those five managers it asserts the REAL `lib/memory/<x>.zap` adapter
// resolves through `resolveMemoryManagerBackendFromSourceGraph` to that
// adapter's own source file (selection -> backend source), AND that the
// REAL `src/memory/<x>/manager.zig` backend declares `REFCOUNT_V1` iff the
// manager is `Memory.ARC` (selection -> backend -> caps). It also covers the
// default/omitted case (`Memory.ARC`).

// Backend `.zig` sources live inside this module's package (`src/`),
// so `@embedFile` binds the test directly to the real production
// source the build driver compiles for each manager.
const REAL_ARC_BACKEND_SOURCE = @embedFile("memory/arc/manager.zig");
const REAL_ARENA_BACKEND_SOURCE = @embedFile("memory/arena/manager.zig");
const REAL_LEAK_BACKEND_SOURCE = @embedFile("memory/leak/manager.zig");
const REAL_TRACKING_BACKEND_SOURCE = @embedFile("memory/tracking/manager.zig");
const REAL_NO_OP_BACKEND_SOURCE = @embedFile("memory/no_op/manager.zig");

const StdlibManagerCase = struct {
    /// Manager type as it appears in `Zap.Manifest.memory`.
    type_name: []const u8,
    /// Workspace-relative path of the real adapter `.zap` source. The
    /// real file is read from disk at test time (cwd is the repo root
    /// during `zig build test`); adapter `.zap` files live outside this
    /// module's package so `@embedFile` cannot reach them.
    adapter_path: []const u8,
    /// Real backend source embedded from `src/memory/<x>/manager.zig`.
    backend_source: []const u8,
    /// Whether the real backend declares the `REFCOUNT_V1` capability.
    /// True only for `Memory.ARC`; the other four declare none.
    declares_refcount: bool,
};

const stdlib_manager_matrix = [_]StdlibManagerCase{
    .{
        .type_name = "Memory.ARC",
        .adapter_path = "lib/memory/arc.zap",
        .backend_source = REAL_ARC_BACKEND_SOURCE,
        .declares_refcount = true,
    },
    .{
        .type_name = "Memory.Arena",
        .adapter_path = "lib/memory/arena.zap",
        .backend_source = REAL_ARENA_BACKEND_SOURCE,
        .declares_refcount = false,
    },
    .{
        .type_name = "Memory.Leak",
        .adapter_path = "lib/memory/leak.zap",
        .backend_source = REAL_LEAK_BACKEND_SOURCE,
        .declares_refcount = false,
    },
    .{
        .type_name = "Memory.Tracking",
        .adapter_path = "lib/memory/tracking.zap",
        .backend_source = REAL_TRACKING_BACKEND_SOURCE,
        .declares_refcount = false,
    },
    .{
        .type_name = "Memory.NoOp",
        .adapter_path = "lib/memory/no_op.zap",
        .backend_source = REAL_NO_OP_BACKEND_SOURCE,
        .declares_refcount = false,
    },
};

/// Read a workspace-relative file from disk. During `zig build test`
/// the cwd is the repo root, so `lib/memory/<x>.zap` resolves to the
/// real production adapter source — the same file collection sees in a
/// real build. This is the established builder-test file-read pattern
/// (see the `.zap-cache` recall helpers above).
fn readWorkspaceFile(alloc: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        rel_path,
        alloc,
        .limited(10 * 1024 * 1024),
    );
}

/// True iff the real backend source declares the `REFCOUNT_V1`
/// capability bit in its `ZapMemoryManagerMetaV1.declared_caps`. ARC
/// declares `CAP_REFCOUNT_V1_BIT`; the other four set `declared_caps = 0`.
/// Asserting against the embedded backend text keeps the invariant tied
/// to the real source the build driver compiles, not a restated copy.
fn realBackendDeclaresRefcount(backend_source: []const u8) bool {
    const declares_bit =
        std.mem.indexOf(u8, backend_source, ".declared_caps = CAP_REFCOUNT_V1_BIT") != null;
    const declares_zero =
        std.mem.indexOf(u8, backend_source, ".declared_caps = 0") != null;
    // Exactly one of the two forms must appear so a future refactor that
    // changes the constant name fails loudly instead of silently
    // mis-classifying the manager.
    std.debug.assert(declares_bit != declares_zero);
    return declares_bit;
}

test "stdlib manager matrix: each real adapter resolves to its own backend source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The real adapter files reference the `Memory.Manager` protocol,
    // which is declared in its own file. A real build collects both;
    // the matrix mirrors that by feeding the REAL protocol source
    // alongside each REAL adapter source.
    const protocol_source = try readWorkspaceFile(alloc, "lib/memory/manager.zap");

    inline for (stdlib_manager_matrix) |case| {
        const adapter_source = try readWorkspaceFile(alloc, case.adapter_path);

        var source_units = [_]compiler.SourceUnit{
            .{ .file_path = "lib/memory/manager.zap", .source = protocol_source },
            .{ .file_path = case.adapter_path, .source = adapter_source },
        };

        var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

        const resolved = try resolveMemoryManagerBackendFromSourceGraph(
            alloc,
            &ctx.collector.graph,
            ctx.interner,
            case.type_name,
        );
        // The resolver keys off the `impl Memory.Manager for <X>` decl
        // span, so the selected manager binds to ITS OWN adapter file —
        // the package-backend convention (`lib/<pkg>/<name>.zap` ->
        // `<root>/src/<stem>/manager.zig`) is applied to this path
        // downstream by the memory driver.
        try testing.expectEqualStrings(case.adapter_path, resolved);

        // Selection -> backend -> caps: the real backend the driver would
        // compile for this manager declares REFCOUNT_V1 iff it is ARC.
        try testing.expectEqual(
            case.declares_refcount,
            realBackendDeclaresRefcount(case.backend_source),
        );
        try testing.expectEqual(
            case.declares_refcount,
            std.mem.eql(u8, case.type_name, "Memory.ARC"),
        );
    }
}

test "stdlib manager matrix: omitted memory: selects Memory.ARC adapter and REFCOUNT_V1 backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A manifest that omits `memory:` defaults to `Memory.ARC`
    // (`constValueToBuildConfig` leaves it null; the driver substitutes
    // ARC). The resolver consumes only the resolved type name, so the
    // default path is exercised by resolving "Memory.ARC" against the
    // REAL `lib/memory/arc.zap` adapter — the same file the default
    // build links.
    const protocol_source = try readWorkspaceFile(alloc, "lib/memory/manager.zap");
    const adapter_source = try readWorkspaceFile(alloc, "lib/memory/arc.zap");

    var source_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/memory/manager.zap", .source = protocol_source },
        .{ .file_path = "lib/memory/arc.zap", .source = adapter_source },
    };

    var ctx = try compiler.collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    const resolved = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        &ctx.collector.graph,
        ctx.interner,
        "Memory.ARC",
    );
    try testing.expectEqualStrings("lib/memory/arc.zap", resolved);
    try testing.expect(realBackendDeclaresRefcount(REAL_ARC_BACKEND_SOURCE));
    try testing.expectEqual(
        zap.memory_abi.REFCOUNT_V1_BIT,
        @as(u64, 0x0000_0000_0000_0001),
    );
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
