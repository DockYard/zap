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
    /// Comptime concurrency gate (`Zap.Manifest.runtime_concurrency`,
    /// overridable by `-Druntime-concurrency=on|off`). This is the RESOLVED
    /// effective gate. Concurrency is **opt-out**: when neither the manifest
    /// nor `-D` specifies it (`runtime_concurrency_explicit == false`), the
    /// build resolves this to `concurrency_driver.kernelTargetSupported(target)`
    /// — ON wherever the kernel can run, silently OFF on targets it cannot host
    /// (single-threaded wasm, unported OSes). `false` links no kernel object and
    /// emits no `zap_proc_*` symbol; `true` links the per-target kernel object
    /// (`src/concurrency_driver.zig`) and enables the runtime bootstrap. An
    /// explicit `true` on an unsupported target errors at kernel resolution.
    runtime_concurrency: bool = false,
    /// Whether `runtime_concurrency` was set explicitly (by the manifest field
    /// or `-Druntime-concurrency=`) versus left to the opt-out default. When
    /// `false`, `resolveConcurrencyGate` computes `runtime_concurrency` from the
    /// target's capability; when `true`, the specified value is honored verbatim.
    runtime_concurrency_explicit: bool = false,
    /// P6-J6 comptime message-flow trace gate
    /// (`Zap.Manifest.runtime_tracing`, overridable by
    /// `-Druntime-tracing=on|off`). `false` — the default — compiles the
    /// kernel with ZERO trace instructions on the send/receive/spawn/
    /// exit/signal paths (the zero-cost posture); `true` compiles the
    /// kernel object from a staged copy with the trace marker rewritten
    /// (`src/concurrency_driver.zig`), enabling the bounded in-memory
    /// trace ring read via `RuntimeInfo.trace_*`. Requires
    /// `runtime_concurrency` — enabling it on a gate-off build is a
    /// build error.
    runtime_tracing: bool = false,
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

/// Owned manifest evaluation result. Callers must either call `deinit`, or
/// keep all owned fields inside a broader allocator lifetime such as an arena.
pub const ManifestEval = struct {
    config: BuildConfig,
    dependencies: []const zap.ctfe.CtDependency,
    result_hash: u64,
    owns_config: bool = true,
    owns_dependencies: bool = true,

    /// Free owned manifest config and dependency data. Call `takeConfig`
    /// first when returning only the `BuildConfig` wrapper result.
    pub fn deinit(self: *ManifestEval, alloc: std.mem.Allocator) void {
        if (self.owns_config) {
            freeConstValueBuildConfig(alloc, self.config);
        }
        if (self.owns_dependencies) {
            deinitManifestEvalDependencies(alloc, self.dependencies);
        }
        self.owns_config = false;
        self.owns_dependencies = false;
        self.dependencies = &.{};
    }

    /// Transfer config ownership to the caller. The remaining
    /// `ManifestEval` still owns dependencies until `deinit` is called.
    pub fn takeConfig(self: *ManifestEval) BuildConfig {
        std.debug.assert(self.owns_config);
        self.owns_config = false;
        return self.config;
    }
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
        // Concurrency gate defaults OFF (zero-cost posture);
        // `applyBuildOverrides` overlays `-Druntime-concurrency=` when
        // present, matching the manifest path's field resolution.
        .runtime_concurrency = false,
        .runtime_tracing = false,
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
    cross_target: ?[]const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
) !BuildConfig {
    var manifest_eval = try ctfeManifestDetailed(alloc, build_source, target_name, cross_target, build_opts, zap_lib_dir);
    defer manifest_eval.deinit(alloc);
    return manifest_eval.takeConfig();
}

pub fn ctfeManifestDetailed(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
    cross_target: ?[]const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
) !ManifestEval {
    return ctfeManifestDetailedWithProgress(alloc, build_source, target_name, cross_target, build_opts, zap_lib_dir, null);
}

/// `target_name` is the manifest TARGET LABEL the `build.zap` dispatches on
/// (`case env.target { :release -> … }`) — the build-config selector, NOT a
/// cross triple. `cross_target` is the `-Dtarget=<triple>` cross-compile
/// target (or `null` for native), which feeds `env.os`/`env.arch` only.
/// Keeping these distinct is essential: a `-Dtarget=aarch64-linux-musl`
/// cross-build must still match the manifest's `:test_prog`/`:release`
/// label while reporting the cross os/arch.
pub fn ctfeManifestDetailedWithProgress(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    target_name: []const u8,
    cross_target: ?[]const u8,
    build_opts: std.StringHashMapUnmanaged([]const u8),
    zap_lib_dir: ?[]const u8,
    progress: ?*zap.progress.Reporter,
) !ManifestEval {
    const ctfe = zap.ctfe;
    const show_progress = progress != null;

    // Build source units: stdlib lib files + build.zap
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    var owned_stdlib_source_unit_count: usize = 0;
    defer deinitManifestSourceUnitList(alloc, &source_units, owned_stdlib_source_unit_count);

    // Read stdlib files from zap lib dir if available
    if (progress) |reporter| reporter.stage("Manifest: reading stdlib sources", .{});
    if (zap_lib_dir) |lib_dir| {
        readLibSourceUnits(alloc, lib_dir, &source_units) catch |err| {
            owned_stdlib_source_unit_count = source_units.items.len;
            return err;
        };
        owned_stdlib_source_unit_count = source_units.items.len;
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
    var discovery_err_info: zap.discovery.ErrorInfo = .{};
    const struct_order_data = computeStructOrder(
        alloc,
        build_source,
        source_units.items,
        zap_lib_dir,
        &discovery_err_info,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try emitManifestStructOrderError(err, &discovery_err_info);
            return error.ManifestDiscoveryFailed;
        },
    };
    defer deinitStructOrderData(alloc, struct_order_data);

    var collect_options = compiler.CompileOptions{
        .show_progress = show_progress,
        .progress = progress,
        .progress_context = "Manifest",
        .allow_external_static_references = true,
    };
    collect_options.struct_order = struct_order_data.struct_order;
    collect_options.level_boundaries = struct_order_data.level_boundaries;

    // Compile through the full frontend pipeline to get IR
    if (progress) |reporter| reporter.stage("Manifest: compiling build.zap", .{});
    var ctx = try collectManifestFrontend(alloc, source_units.items, collect_options);
    const result = try compileManifestFrontendForCtfe(alloc, &ctx, .{
        .show_progress = show_progress,
        .progress = progress,
        .progress_context = "Manifest",
        .allow_external_static_references = true,
    });

    // Create CTFE interpreter with build capabilities and persistent cache
    if (progress) |reporter| reporter.stage("Manifest: evaluating build.zap", .{});
    var interp = try ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interp.deinit();
    interp.scope_graph = &ctx.collector.graph;
    interp.interner = ctx.interner;
    interp.capabilities = ctfe.CapabilitySet.build;
    interp.build_opts = build_opts;
    interp.compile_options_hash = ctfe.hashCompileOptions(target_name, build_opts.get("optimize") orelse "release_safe");
    try configureManifestPersistentCache(&interp, ".zap-cache/ctfe");

    // Find the manifest function by scanning IR functions for one ending in "__manifest"
    const manifest_id = findManifestFunction(&result.ir_program) orelse
        return error.ManifestNotFound;

    // Construct the env argument: %Zap.Env{target: :target_name, os: :os, arch: :arch}.
    //
    // `env.target` is the manifest TARGET LABEL the `build.zap` dispatches
    // on (`case env.target { :test_prog -> … }`) — the build-config
    // selector. It is ALWAYS `target_name` (the invocation label:
    // `"default"`/`"test"`/`"script"` or a manifest target name), and is
    // NEVER overwritten by a `-Dtarget=` cross triple — conflating the two
    // breaks the manifest's label match under cross-compilation.
    //
    // `env.os`/`env.arch` MUST reflect the *requested compilation target*,
    // not the host the manifest evaluator runs on. They derive from
    // `cross_target` (the `-Dtarget=<triple>` override) when present, else
    // fall back to the label (a non-triple → host). `resolveOrHost` maps a
    // triple to its atoms and any non-triple to the host's, never erroring
    // (a genuinely-malformed `-Dtarget=` is policed by the stricter compile
    // path). Surfacing HOST os/arch unconditionally (the old
    // `builtin.os.tag`/`builtin.cpu.arch`) was a latent cross-compile bug.
    // This is the same resolution `@target` surfaces to all Zap CTFE,
    // single-sourced in `target_triple`.
    const target_atoms = zap.target_triple.resolveOrHost(cross_target orelse target_name);

    const env_const = ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Env",
        .fields = &.{
            .{ .name = "target", .value = .{ .atom = target_name } },
            .{ .name = "os", .value = .{ .atom = target_atoms.os } },
            .{ .name = "arch", .value = .{ .atom = target_atoms.arch } },
        },
    } };

    // Evaluate manifest/1
    const manifest_result = try evalManifestFunction(&interp, manifest_id, &.{env_const});
    defer manifest_result.deinit(alloc);

    var config = try constValueToBuildConfig(alloc, manifest_result.value);
    var config_transferred = false;
    errdefer if (!config_transferred) freeConstValueBuildConfig(alloc, config);
    config.memory_manager = try memoryManagerSelectionFromManifest(alloc, manifest_result.value);

    const dependencies = try manifestEvalDependencies(
        alloc,
        struct_order_data.source_files,
        source_units.items,
        manifest_result.dependencies,
    );
    var dependencies_transferred = false;
    errdefer if (!dependencies_transferred) deinitManifestEvalDependencies(alloc, dependencies);

    config_transferred = true;
    dependencies_transferred = true;
    return .{
        .config = config,
        .dependencies = dependencies,
        .result_hash = manifest_result.result_hash,
    };
}

fn collectManifestFrontend(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    options: compiler.CompileOptions,
) error{ OutOfMemory, CompileFailed }!compiler.CompilationContext {
    return compiler.collectAllFromUnits(alloc, source_units, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompileFailed,
    };
}

fn compileManifestFrontendForCtfe(
    alloc: std.mem.Allocator,
    ctx: *compiler.CompilationContext,
    options: compiler.CompileOptions,
) error{ OutOfMemory, CompileFailed }!compiler.CompileResult {
    return compiler.compileForCtfe(alloc, ctx, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompileFailed,
    };
}

fn evalManifestFunction(
    interp: *zap.ctfe.Interpreter,
    manifest_id: zap.ir.FunctionId,
    args: []const zap.ctfe.ConstValue,
) error{ OutOfMemory, CtfeFailed }!zap.ctfe.CtEvalResult {
    return interp.evalAndExport(manifest_id, args, zap.ctfe.CapabilitySet.build) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try emitManifestCtfeErrors(interp.errors.items);
            return error.CtfeFailed;
        },
    };
}

fn emitManifestCtfeErrors(errors: []const zap.ctfe.CtfeError) std.mem.Allocator.Error!void {
    // Report CTFE errors through the embedder-owned diagnostic stderr sink
    // (silent by default in a test build) rather than hardwiring
    // `std.debug.print` to the global stderr.
    for (errors) |err| {
        try zap.diagnostics.emitStderrFmtChecked("  ctfe error: {s}\n", .{err.message});
    }
}

fn configureManifestPersistentCache(
    interp: *zap.ctfe.Interpreter,
    cache_dir: []const u8,
) std.Io.Dir.CreateDirPathError!void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cache_dir);
    interp.persistent_cache = zap.ctfe.PersistentCache.init(cache_dir);
}

test "builder manifest persistent cache setup propagates directory creation failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "blocked",
        .data = "not a directory",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const blocked_cache_dir = try std.fs.path.join(alloc, &.{ tmp_path, "blocked", "ctfe" });

    const program = testManifestIrProgram();
    var interp = try zap.ctfe.Interpreter.init(alloc, &program);
    defer interp.deinit();

    try testing.expectError(error.NotDir, configureManifestPersistentCache(&interp, blocked_cache_dir));
    try testing.expect(interp.persistent_cache == null);
}

test "builder manifest collect preserves OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Nil) -> Nil {
        \\    nil
        \\  }
        \\}
    ;
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };

    var failing_allocator = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        collectManifestFrontend(
            failing_allocator.allocator(),
            &source_units,
            .{ .show_progress = false },
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "builder manifest compile preserves OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Nil) -> Nil {
        \\    nil
        \\  }
        \\}
    ;
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };
    var ctx = try collectManifestFrontend(alloc, &source_units, .{ .show_progress = false });

    var failing_allocator = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        compileManifestFrontendForCtfe(
            failing_allocator.allocator(),
            &ctx,
            .{ .show_progress = false },
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "builder manifest compile semantic failure remains CompileFailed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct App.Builder {
        \\  pub fn manifest(_env :: Nil) -> i64 {
        \\    "not an integer"
        \\  }
        \\}
    ;
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = source },
    };
    var ctx = try collectManifestFrontend(alloc, &source_units, .{ .show_progress = false });

    try testing.expectError(
        error.CompileFailed,
        compileManifestFrontendForCtfe(
            alloc,
            &ctx,
            .{ .show_progress = false },
        ),
    );
}

fn testManifestIrProgram() zap.ir.Program {
    const manifest_function = zap.ir.Function{
        .id = 0,
        .name = "App__Builder__manifest__1",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "env", .type_expr = .nil }},
        .return_type = .nil,
        .body = &.{.{
            .label = 0,
            .instructions = &.{
                .{ .param_get = .{ .dest = 0, .index = 0 } },
                .{ .ret = .{ .value = 0 } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
    };
    return .{
        .functions = &.{manifest_function},
        .type_defs = &.{},
        .entry = null,
    };
}

test "builder manifest eval preserves OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const program = testManifestIrProgram();
    var interp = try zap.ctfe.Interpreter.init(alloc, &program);
    defer interp.deinit();

    const original_allocator = interp.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 0 });
    interp.allocator = failing_allocator.allocator();
    defer interp.allocator = original_allocator;

    try testing.expectError(
        error.OutOfMemory,
        evalManifestFunction(&interp, 0, &.{.{ .nil = {} }}),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "builder manifest eval semantic failure remains CtfeFailed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const program = testManifestIrProgram();
    var interp = try zap.ctfe.Interpreter.init(alloc, &program);
    defer interp.deinit();

    var captured_stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer captured_stderr.deinit(alloc);
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured_stderr,
        .allocator = alloc,
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    try testing.expectError(
        error.CtfeFailed,
        evalManifestFunction(&interp, 99, &.{}),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        captured_stderr.items,
        "ctfe error: invalid function id",
    ) != null);
}

test "builder manifest eval diagnostic reporting preserves OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const program = testManifestIrProgram();
    var interp = try zap.ctfe.Interpreter.init(alloc, &program);
    defer interp.deinit();

    var captured_stderr: std.ArrayListUnmanaged(u8) = .empty;
    var failing_allocator = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 0 });
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured_stderr,
        .allocator = failing_allocator.allocator(),
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    try testing.expectError(
        error.OutOfMemory,
        evalManifestFunction(&interp, 99, &.{}),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

const StructOrderData = struct {
    struct_order: [][]const u8,
    level_boundaries: []u32,
    source_files: [][]const u8,
};

fn freeOwnedStringSlice(alloc: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| alloc.free(string);
    alloc.free(strings);
}

fn deinitOwnedStringList(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |string| alloc.free(string);
    list.deinit(alloc);
}

fn freeBuildConfigDep(alloc: std.mem.Allocator, dep: BuildConfig.Dep) void {
    alloc.free(dep.name);
    switch (dep.source) {
        .path => |path| alloc.free(path),
        .git => |git| {
            alloc.free(git.url);
            if (git.tag) |tag| alloc.free(tag);
            if (git.branch) |branch| alloc.free(branch);
            if (git.rev) |rev| alloc.free(rev);
        },
    }
    if (dep.local_override) |local_override| alloc.free(local_override);
}

fn deinitBuildConfigDepList(
    alloc: std.mem.Allocator,
    deps: *std.ArrayListUnmanaged(BuildConfig.Dep),
) void {
    for (deps.items) |dep| freeBuildConfigDep(alloc, dep);
    deps.deinit(alloc);
}

fn freeBuildConfigBuildOpts(
    alloc: std.mem.Allocator,
    build_opts: *std.StringHashMapUnmanaged([]const u8),
) void {
    var iterator = build_opts.iterator();
    while (iterator.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.*);
    }
    build_opts.deinit(alloc);
    build_opts.* = .empty;
}

fn freeBuildConfigStep(alloc: std.mem.Allocator, step: BuildConfig.Step) void {
    switch (step) {
        .compile => {},
        .run => |run| {
            for (run.args) |arg| alloc.free(arg);
            alloc.free(run.args);
        },
    }
}

fn deinitBuildConfigStepList(
    alloc: std.mem.Allocator,
    steps: *std.ArrayListUnmanaged(BuildConfig.Step),
) void {
    for (steps.items) |step| freeBuildConfigStep(alloc, step);
    steps.deinit(alloc);
}

fn freeBuildConfigPipeline(alloc: std.mem.Allocator, pipeline: BuildConfig.Pipeline) void {
    for (pipeline.steps) |step| freeBuildConfigStep(alloc, step);
    alloc.free(pipeline.steps);
}

fn freeConstValueBuildConfig(alloc: std.mem.Allocator, config: BuildConfig) void {
    alloc.free(config.name);
    alloc.free(config.version);
    if (config.root) |root| alloc.free(root);
    if (config.asset_name) |asset_name| alloc.free(asset_name);
    if (config.target) |target| alloc.free(target);
    if (config.cpu) |cpu| alloc.free(cpu);
    freeOwnedStringSlice(alloc, config.paths);
    for (config.deps) |dep| freeBuildConfigDep(alloc, dep);
    alloc.free(config.deps);
    var build_opts = config.build_opts;
    freeBuildConfigBuildOpts(alloc, &build_opts);
    if (config.memory_manager) |memory_manager| {
        alloc.free(memory_manager.type_name);
        if (memory_manager.adapter_source_path) |adapter_source_path| {
            alloc.free(adapter_source_path);
        }
    }
    if (config.error_style) |error_style| alloc.free(error_style);
    if (config.source_url) |source_url| alloc.free(source_url);
    if (config.landing_page) |landing_page| alloc.free(landing_page);
    for (config.doc_groups) |group| freeDocGroup(alloc, group);
    alloc.free(config.doc_groups);
    if (config.pipeline) |pipeline| freeBuildConfigPipeline(alloc, pipeline);
}

fn deinitStructOrderData(alloc: std.mem.Allocator, data: StructOrderData) void {
    freeOwnedStringSlice(alloc, data.struct_order);
    alloc.free(data.level_boundaries);
    freeOwnedStringSlice(alloc, data.source_files);
}

/// Run import-driven discovery over `build.zap` + the supplied stdlib
/// source units to produce a topological compilation order. Returns the
/// ordered list of struct names plus the per-wave boundary indices.
///
/// Used by `ctfeManifestDetailed` to drive the staged macro-expansion
/// pipeline so a macro `__using__` body that CTFE-calls another stdlib
/// function (e.g. the glob helper) sees that function's IR by the time
/// the using struct is expanded. Discovery is required for manifest CTFE:
/// disabling the order would hide graph/read/parse failures and can produce
/// different compile-time behavior for manifests that rely on staged order.
fn computeStructOrder(
    alloc: std.mem.Allocator,
    build_source: []const u8,
    source_units: []const compiler.SourceUnit,
    zap_lib_dir: ?[]const u8,
    err_info: ?*zap.discovery.ErrorInfo,
) !StructOrderData {
    const entry = (try zap.discovery.primaryStructName(alloc, build_source)) orelse return error.NoPrimaryStruct;
    defer alloc.free(entry);

    var source_roots: std.ArrayListUnmanaged(zap.discovery.SourceRoot) = .empty;
    defer source_roots.deinit(alloc);
    if (zap_lib_dir) |lib_dir| {
        try source_roots.append(alloc, .{ .name = "stdlib", .path = lib_dir });
    }

    var explicit_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer explicit_paths.deinit(alloc);
    for (source_units) |unit| {
        try explicit_paths.append(alloc, unit.file_path);
    }

    var graph = try zap.discovery.discoverWithSourceFiles(
        alloc,
        entry,
        source_roots.items,
        &zap.discovery.BUILTIN_TYPE_NAMES,
        explicit_paths.items,
        err_info,
    );
    defer graph.deinit();

    return try structOrderDataFromGraph(alloc, &graph);
}

fn structOrderDataFromGraph(
    alloc: std.mem.Allocator,
    graph: *const zap.discovery.FileGraph,
) !StructOrderData {
    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    var order_transferred = false;
    var source_files_transferred = false;
    errdefer if (!order_transferred) deinitOwnedStringList(alloc, &order);
    errdefer if (!source_files_transferred) deinitOwnedStringList(alloc, &source_files);
    for (graph.topo_order.items) |file_path| {
        const source_file = try alloc.dupe(u8, file_path);
        var source_file_transferred = false;
        errdefer if (!source_file_transferred) alloc.free(source_file);
        try source_files.append(alloc, source_file);
        source_file_transferred = true;
        if (graph.file_to_struct.get(file_path)) |struct_name| {
            const ordered_struct = try alloc.dupe(u8, struct_name);
            var ordered_struct_transferred = false;
            errdefer if (!ordered_struct_transferred) alloc.free(ordered_struct);
            try order.append(alloc, ordered_struct);
            ordered_struct_transferred = true;
        }
    }

    var levels: std.ArrayListUnmanaged(u32) = .empty;
    var levels_transferred = false;
    errdefer if (!levels_transferred) levels.deinit(alloc);
    for (graph.level_boundaries.items) |boundary| {
        try levels.append(alloc, boundary);
    }

    const struct_order = try order.toOwnedSlice(alloc);
    order_transferred = true;
    var struct_order_transferred = false;
    errdefer if (!struct_order_transferred) freeOwnedStringSlice(alloc, struct_order);

    const level_boundaries = try levels.toOwnedSlice(alloc);
    levels_transferred = true;
    var level_boundaries_transferred = false;
    errdefer if (!level_boundaries_transferred) alloc.free(level_boundaries);

    const owned_source_files = try source_files.toOwnedSlice(alloc);
    source_files_transferred = true;

    struct_order_transferred = true;
    level_boundaries_transferred = true;
    return .{
        .struct_order = struct_order,
        .level_boundaries = level_boundaries,
        .source_files = owned_source_files,
    };
}

fn emitManifestStructOrderError(err: anyerror, err_info: *const zap.discovery.ErrorInfo) std.mem.Allocator.Error!void {
    switch (err) {
        error.NoPrimaryStruct => {
            try zap.diagnostics.emitStderrFmtChecked(
                "Error: manifest discovery failed: build.zap does not declare a primary struct\n",
                .{},
            );
        },
        error.StructNotFound => {
            if (err_info.unresolved_struct) |struct_name| {
                try zap.diagnostics.emitStderrFmtChecked(
                    "Error: manifest discovery failed: struct `{s}` not found\n",
                    .{struct_name},
                );
            } else if (err_info.boundary_struct) |struct_name| {
                try zap.diagnostics.emitStderrFmtChecked(
                    "Error: manifest discovery failed: struct `{s}` is private in {s} and cannot be accessed from {s}\n",
                    .{
                        struct_name,
                        err_info.boundary_dep orelse "?",
                        err_info.boundary_from orelse "?",
                    },
                );
            } else {
                try zap.diagnostics.emitStderrFmtChecked(
                    "Error: manifest discovery failed: struct not found\n",
                    .{},
                );
            }
        },
        error.CircularDependency => {
            try zap.diagnostics.emitStderrFmtChecked(
                "Error: manifest discovery failed: circular struct dependency detected\n",
                .{},
            );
        },
        error.ReadError => {
            try zap.diagnostics.emitStderrFmtChecked(
                "Error: manifest discovery failed: could not read a source file\n",
                .{},
            );
        },
        error.ParseFailed => {
            try zap.diagnostics.emitStderrFmtChecked(
                "Error: manifest discovery failed: could not parse a source file\n",
                .{},
            );
        },
        else => {
            try zap.diagnostics.emitStderrFmtChecked(
                "Error: manifest discovery failed: {s}\n",
                .{@errorName(err)},
            );
        },
    }
}

test "builder manifest struct order propagates discovery failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var captured_stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer captured_stderr.deinit(alloc);
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured_stderr,
        .allocator = alloc,
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    try testing.expectError(
        error.ManifestDiscoveryFailed,
        ctfeManifestDetailedWithProgress(
            alloc,
            "",
            "default",
            null,
            std.StringHashMapUnmanaged([]const u8).empty,
            null,
            null,
        ),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        captured_stderr.items,
        "build.zap does not declare a primary struct",
    ) != null);
}

test "builder manifest struct order preserves discovered dependency order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const build_source =
        \\pub struct App.Builder {
        \\  pub fn manifest() -> Nil {
        \\    Helper.value()
        \\  }
        \\}
    ;
    const helper_source =
        \\pub struct Helper {
        \\  pub fn value() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "build.zap",
        .data = build_source,
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "helper.zap",
        .data = helper_source,
    });

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const build_path = try std.fs.path.join(alloc, &.{ tmp_path, "build.zap" });
    const helper_path = try std.fs.path.join(alloc, &.{ tmp_path, "helper.zap" });

    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = build_path, .source = build_source },
        .{ .file_path = helper_path, .source = helper_source },
    };

    var discovery_err_info: zap.discovery.ErrorInfo = .{};
    const struct_order_data = try computeStructOrder(
        alloc,
        build_source,
        &source_units,
        tmp_path,
        &discovery_err_info,
    );

    try testing.expectEqual(@as(usize, 2), struct_order_data.struct_order.len);
    try testing.expectEqualStrings("Helper", struct_order_data.struct_order[0]);
    try testing.expectEqualStrings("App.Builder", struct_order_data.struct_order[1]);
    try testing.expectEqual(@as(usize, 2), struct_order_data.level_boundaries.len);
    try testing.expectEqual(@as(u32, 1), struct_order_data.level_boundaries[0]);
    try testing.expectEqual(@as(u32, 2), struct_order_data.level_boundaries[1]);
    try testing.expectEqual(@as(usize, 2), struct_order_data.source_files.len);
    try testing.expectEqualStrings(helper_path, struct_order_data.source_files[0]);
    try testing.expectEqualStrings(build_path, struct_order_data.source_files[1]);
}

fn exerciseStructOrderDataFromGraphAllocationFailures(
    alloc: std.mem.Allocator,
    graph: *const zap.discovery.FileGraph,
) !void {
    const struct_order_data = try structOrderDataFromGraph(alloc, graph);
    defer deinitStructOrderData(alloc, struct_order_data);

    try testing.expectEqual(@as(usize, 2), struct_order_data.struct_order.len);
    try testing.expectEqualStrings("Helper", struct_order_data.struct_order[0]);
    try testing.expectEqualStrings("App.Builder", struct_order_data.struct_order[1]);
}

test "P4J2: struct order graph conversion frees duplicated path and struct names on allocation failure" {
    const alloc = std.testing.allocator;

    var graph = zap.discovery.FileGraph.init(alloc);
    defer graph.deinit();
    try graph.topo_order.append(alloc, "helper.zap");
    try graph.topo_order.append(alloc, "build.zap");
    try graph.file_to_struct.put("helper.zap", "Helper");
    try graph.file_to_struct.put("build.zap", "App.Builder");
    try graph.level_boundaries.append(alloc, 1);
    try graph.level_boundaries.append(alloc, 2);

    try std.testing.checkAllAllocationFailures(
        alloc,
        exerciseStructOrderDataFromGraphAllocationFailures,
        .{&graph},
    );
}

fn manifestEvalDependencies(
    alloc: std.mem.Allocator,
    reachable_source_files: []const []const u8,
    source_units: []const compiler.SourceUnit,
    runtime_dependencies: []const zap.ctfe.CtDependency,
) ![]const zap.ctfe.CtDependency {
    var dependencies: std.ArrayListUnmanaged(zap.ctfe.CtDependency) = .empty;
    var dependencies_transferred = false;
    errdefer if (!dependencies_transferred) deinitManifestEvalDependencyList(alloc, &dependencies);

    for (reachable_source_files) |source_file| {
        var owned_source: ?[]u8 = null;
        defer if (owned_source) |source| alloc.free(source);
        const source = sourceForManifestDependency(source_units, source_file) orelse blk: {
            const read_source = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, source_file, alloc, .limited(10 * 1024 * 1024));
            owned_source = read_source;
            break :blk read_source;
        };
        try appendManifestFileDependency(alloc, &dependencies, source_file, source);
    }

    for (runtime_dependencies) |dependency| {
        const owned_dependency = try dependency.cloneOwned(alloc);
        var dependency_transferred = false;
        errdefer if (!dependency_transferred) owned_dependency.deinitOwned(alloc);
        try dependencies.append(alloc, owned_dependency);
        dependency_transferred = true;
    }

    const owned_dependencies = try dependencies.toOwnedSlice(alloc);
    dependencies_transferred = true;
    return owned_dependencies;
}

fn deinitManifestEvalDependencies(
    alloc: std.mem.Allocator,
    dependencies: []const zap.ctfe.CtDependency,
) void {
    for (dependencies) |dependency| {
        dependency.deinitOwned(alloc);
    }
    alloc.free(dependencies);
}

fn deinitManifestEvalDependencyList(
    alloc: std.mem.Allocator,
    dependencies: *std.ArrayListUnmanaged(zap.ctfe.CtDependency),
) void {
    for (dependencies.items) |dependency| {
        dependency.deinitOwned(alloc);
    }
    dependencies.deinit(alloc);
}

fn sourceForManifestDependency(
    source_units: []const compiler.SourceUnit,
    source_file: []const u8,
) ?[]const u8 {
    for (source_units) |source_unit| {
        if (std.mem.eql(u8, source_unit.file_path, source_file)) return source_unit.source;
    }
    return null;
}

fn appendManifestFileDependency(
    alloc: std.mem.Allocator,
    dependencies: *std.ArrayListUnmanaged(zap.ctfe.CtDependency),
    path: []const u8,
    source: []const u8,
) !void {
    for (dependencies.items) |existing| {
        if (existing == .file and std.mem.eql(u8, existing.file.path, path)) return;
    }
    const owned_path = try alloc.dupe(u8, path);
    var path_transferred = false;
    errdefer if (!path_transferred) alloc.free(owned_path);
    try dependencies.append(alloc, .{ .file = .{
        .path = owned_path,
        .content_hash = std.hash.Wyhash.hash(0, source),
    } });
    path_transferred = true;
}

test "manifestEvalDependencies uses reachable compile inputs when discovery succeeds" {
    const alloc = std.testing.allocator;

    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = "manifest" },
        .{ .file_path = "lib/zap/manifest.zap", .source = "pub struct Zap.Manifest {}" },
        .{ .file_path = "lib/simd.zap", .source = "pub struct Simd {}" },
    };
    const reachable_source_files = [_][]const u8{
        "build.zap",
        "lib/zap/manifest.zap",
    };
    const runtime_dependencies = [_]zap.ctfe.CtDependency{
        .{ .env_var = .{ .name = "ZAP_ENV", .value_hash = 123, .present = true } },
    };

    const dependencies = try manifestEvalDependencies(
        alloc,
        &reachable_source_files,
        &source_units,
        &runtime_dependencies,
    );
    defer deinitManifestEvalDependencies(alloc, dependencies);

    try std.testing.expectEqual(@as(usize, 3), dependencies.len);
    try std.testing.expectEqualStrings("build.zap", dependencies[0].file.path);
    try std.testing.expectEqualStrings("lib/zap/manifest.zap", dependencies[1].file.path);
    try std.testing.expectEqualStrings("ZAP_ENV", dependencies[2].env_var.name);
    for (dependencies) |dependency| {
        if (dependency == .file) {
            try std.testing.expect(!std.mem.eql(u8, dependency.file.path, "lib/simd.zap"));
        }
    }
}

test "manifestEvalDependencies deep-clones runtime dependencies" {
    const alloc = testing.allocator;

    var runtime_name = try alloc.dupe(u8, "ZAP_ENV");
    defer alloc.free(runtime_name);
    const runtime_dependencies = [_]zap.ctfe.CtDependency{
        .{ .env_var = .{ .name = runtime_name, .value_hash = 123, .present = true } },
    };

    const dependencies = try manifestEvalDependencies(
        alloc,
        &.{},
        &.{},
        &runtime_dependencies,
    );
    defer deinitManifestEvalDependencies(alloc, dependencies);

    try testing.expectEqual(@as(usize, 1), dependencies.len);
    try testing.expectEqualStrings("ZAP_ENV", dependencies[0].env_var.name);
    runtime_name[0] = 'X';
    try testing.expectEqualStrings("ZAP_ENV", dependencies[0].env_var.name);
    try testing.expect(@intFromPtr(dependencies[0].env_var.name.ptr) != @intFromPtr(runtime_name.ptr));
}

fn exerciseManifestEvalDependenciesRuntimeCloneAllocationFailures(alloc: std.mem.Allocator) !void {
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = "manifest" },
    };
    const reachable_source_files = [_][]const u8{"build.zap"};
    const reflected_source_paths = [_][]const u8{ "lib/config.zap", "lib/runtime.zap" };
    const runtime_dependencies = [_]zap.ctfe.CtDependency{
        .{ .env_var = .{ .name = "ZAP_ENV", .value_hash = 123, .present = true } },
        .{ .reflected_source = .{ .paths = &reflected_source_paths, .graph_hash = 456 } },
    };

    const dependencies = try manifestEvalDependencies(
        alloc,
        &reachable_source_files,
        &source_units,
        &runtime_dependencies,
    );
    defer deinitManifestEvalDependencies(alloc, dependencies);

    try testing.expectEqual(@as(usize, 3), dependencies.len);
}

test "P4J2: manifestEvalDependencies frees cloned runtime dependencies on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseManifestEvalDependenciesRuntimeCloneAllocationFailures,
        .{},
    );
}

fn exerciseAppendManifestFileDependencyAllocationFailures(alloc: std.mem.Allocator) !void {
    var dependencies: std.ArrayListUnmanaged(zap.ctfe.CtDependency) = .empty;
    defer deinitManifestEvalDependencyList(alloc, &dependencies);

    try appendManifestFileDependency(alloc, &dependencies, "build.zap", "pub struct Build {}");

    try testing.expectEqual(@as(usize, 1), dependencies.items.len);
    try testing.expect(dependencies.items[0] == .file);
    try testing.expectEqualStrings("build.zap", dependencies.items[0].file.path);
}

test "P4J2: appendManifestFileDependency frees path duplicate when dependency append fails" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseAppendManifestFileDependencyAllocationFailures,
        .{},
    );
}

fn p4j2OwnedManifestConfigValue() zap.ctfe.ConstValue {
    return .{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "paths", .value = .{ .list = &.{
                .{ .string = "lib" },
            } } },
        },
    } };
}

fn makeP4J2OwnedManifestEval(alloc: std.mem.Allocator) !ManifestEval {
    const config = try constValueToBuildConfig(alloc, p4j2OwnedManifestConfigValue());
    var config_transferred = false;
    errdefer if (!config_transferred) freeConstValueBuildConfig(alloc, config);

    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "build.zap", .source = "manifest" },
    };
    const reachable_source_files = [_][]const u8{"build.zap"};
    const runtime_dependencies = [_]zap.ctfe.CtDependency{
        .{ .env_var = .{ .name = "ZAP_ENV", .value_hash = 123, .present = true } },
    };
    const dependencies = try manifestEvalDependencies(
        alloc,
        &reachable_source_files,
        &source_units,
        &runtime_dependencies,
    );
    var dependencies_transferred = false;
    errdefer if (!dependencies_transferred) deinitManifestEvalDependencies(alloc, dependencies);

    config_transferred = true;
    dependencies_transferred = true;
    return .{
        .config = config,
        .dependencies = dependencies,
        .result_hash = 0x1234,
    };
}

fn exerciseManifestEvalDeinitAllocationFailures(alloc: std.mem.Allocator) !void {
    var manifest_eval = try makeP4J2OwnedManifestEval(alloc);
    manifest_eval.deinit(alloc);
}

test "P4J2: ManifestEval.deinit frees owned config and dependencies" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseManifestEvalDeinitAllocationFailures,
        .{},
    );
}

fn exerciseManifestEvalConfigTransferAllocationFailures(alloc: std.mem.Allocator) !void {
    var manifest_eval = try makeP4J2OwnedManifestEval(alloc);
    const config = manifest_eval.takeConfig();
    defer freeConstValueBuildConfig(alloc, config);
    manifest_eval.deinit(alloc);
}

test "P4J2: ManifestEval.deinit preserves transferred config ownership" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseManifestEvalConfigTransferAllocationFailures,
        .{},
    );
}

/// Read all .zap files from a directory and its subdirectories recursively,
/// adding them as source units.
fn readLibSourceUnits(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
            defer alloc.free(subdir_path);
            try readLibSourceUnits(alloc, subdir_path, source_units);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        errdefer alloc.free(file_path);
        const source = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024));
        errdefer alloc.free(source);
        try source_units.append(alloc, .{ .file_path = file_path, .source = source });
    }
}

fn readLibSourceUnitsUnique(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
            defer alloc.free(subdir_path);
            try readLibSourceUnitsUnique(alloc, subdir_path, source_units);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
        const file_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const source = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024));
        try appendUniqueSourceUnit(alloc, source_units, .{ .file_path = file_path, .source = source });
    }
}

fn deinitSourceUnitList(
    alloc: std.mem.Allocator,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
) void {
    for (source_units.items) |source_unit| {
        alloc.free(source_unit.file_path);
        alloc.free(source_unit.source);
    }
    source_units.deinit(alloc);
}

fn deinitManifestSourceUnitList(
    alloc: std.mem.Allocator,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
    owned_stdlib_source_unit_count: usize,
) void {
    std.debug.assert(owned_stdlib_source_unit_count <= source_units.items.len);
    for (source_units.items[0..owned_stdlib_source_unit_count]) |source_unit| {
        alloc.free(source_unit.file_path);
        alloc.free(source_unit.source);
    }
    source_units.deinit(alloc);
}

fn exerciseManifestSourceUnitListCleanupAllocationFailures(alloc: std.mem.Allocator) !void {
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    var owned_stdlib_source_unit_count: usize = 0;
    defer deinitManifestSourceUnitList(alloc, &source_units, owned_stdlib_source_unit_count);

    const stdlib_path = try alloc.dupe(u8, "lib/kernel.zap");
    var stdlib_path_transferred = false;
    errdefer if (!stdlib_path_transferred) alloc.free(stdlib_path);
    const stdlib_source = try alloc.dupe(u8, "pub struct Kernel {}");
    var stdlib_source_transferred = false;
    errdefer if (!stdlib_source_transferred) alloc.free(stdlib_source);
    try source_units.append(alloc, .{
        .file_path = stdlib_path,
        .source = stdlib_source,
    });
    stdlib_path_transferred = true;
    stdlib_source_transferred = true;
    owned_stdlib_source_unit_count = source_units.items.len;

    try source_units.append(alloc, .{
        .file_path = "build.zap",
        .source = "pub struct App.Builder {}",
    });

    try testing.expectEqual(@as(usize, 2), source_units.items.len);
}

test "P4J2: manifest source-unit cleanup frees owned stdlib units only" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseManifestSourceUnitListCleanupAllocationFailures,
        .{},
    );
}

fn exerciseReadLibSourceUnitsAllocationFailures(
    alloc: std.mem.Allocator,
    root_path: []const u8,
) !void {
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    defer deinitSourceUnitList(alloc, &source_units);

    try readLibSourceUnits(alloc, root_path, &source_units);
    try std.testing.expectEqual(@as(usize, 2), source_units.items.len);
}

test "P4J2: readLibSourceUnits frees recursive paths and unappended source units on allocation failure" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.Options.debug_io, "stdlib/nested");
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "stdlib/kernel.zap",
        .data = "pub struct Kernel {}",
    });
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "stdlib/nested/list.zap",
        .data = "pub struct List {}",
    });

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "stdlib", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseReadLibSourceUnitsAllocationFailures,
        .{root_path},
    );
}

test "readStdlibSourceUnits propagates missing required directory" {
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    try std.testing.expectError(
        error.FileNotFound,
        readStdlibSourceUnits(std.testing.allocator, "missing-required-zap-stdlib-root", &source_units),
    );
}

test "readStdlibSourceUnits propagates allocator failure during discovery" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "kernel.zap",
        .data = "pub struct Kernel {}",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", arena.allocator());

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    try std.testing.expectError(
        error.OutOfMemory,
        readStdlibSourceUnits(failing_allocator.allocator(), root_path, &source_units),
    );
}

test "P4J2: canonicalSourcePath propagates canonicalization failures" {
    try std.testing.expectError(
        error.FileNotFound,
        canonicalSourcePath(std.testing.allocator, "missing/p4j2/canonical/source.zap"),
    );
}

test "P4J2: appendUniqueSourceUnit propagates canonicalization failures" {
    var source_units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty;
    try std.testing.expectError(
        error.FileNotFound,
        appendUniqueSourceUnit(std.testing.allocator, &source_units, .{
            .file_path = "missing/p4j2/source-unit.zap",
            .source = "",
        }),
    );
}

fn appendUniqueSourceUnit(
    alloc: std.mem.Allocator,
    source_units: *std.ArrayListUnmanaged(compiler.SourceUnit),
    source_unit: compiler.SourceUnit,
) std.Io.Dir.RealPathFileAllocError!void {
    const source_key = try canonicalSourcePath(alloc, source_unit.file_path);
    defer alloc.free(source_key);
    for (source_units.items) |existing| {
        const existing_key = try canonicalSourcePath(alloc, existing.file_path);
        defer alloc.free(existing_key);
        if (std.mem.eql(u8, existing_key, source_key)) return;
    }
    try source_units.append(alloc, source_unit);
}

fn canonicalSourcePath(alloc: std.mem.Allocator, file_path: []const u8) std.Io.Dir.RealPathFileAllocError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, file_path, alloc);
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
            var config_transferred = false;
            errdefer if (!config_transferred) freeConstValueBuildConfig(alloc, config);
            var paths_list: std.ArrayListUnmanaged([]const u8) = .empty;
            var paths_list_transferred = false;
            errdefer if (!paths_list_transferred) deinitOwnedStringList(alloc, &paths_list);
            var deps_list: std.ArrayListUnmanaged(BuildConfig.Dep) = .empty;
            var deps_list_transferred = false;
            errdefer if (!deps_list_transferred) deinitBuildConfigDepList(alloc, &deps_list);

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
                                    .string => |s| {
                                        const path = try alloc.dupe(u8, s);
                                        var path_transferred = false;
                                        errdefer if (!path_transferred) alloc.free(path);
                                        try paths_list.append(alloc, path);
                                        path_transferred = true;
                                    },
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
                                const dep = try constValueToDep(alloc, item);
                                var dep_transferred = false;
                                errdefer if (!dep_transferred) freeBuildConfigDep(alloc, dep);
                                try deps_list.append(alloc, dep);
                                dep_transferred = true;
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
                            var groups_list_transferred = false;
                            errdefer if (!groups_list_transferred) deinitDocGroupList(alloc, &groups_list);
                            for (items) |item| {
                                if (try constValueToDocGroup(alloc, item)) |group| {
                                    var group_transferred = false;
                                    errdefer if (!group_transferred) freeDocGroup(alloc, group);
                                    try groups_list.append(alloc, group);
                                    group_transferred = true;
                                }
                            }
                            config.doc_groups = try groups_list.toOwnedSlice(alloc);
                            groups_list_transferred = true;
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, field.name, "runtime_concurrency")) {
                    switch (field.value) {
                        .bool_val => |gate_enabled| {
                            config.runtime_concurrency = gate_enabled;
                            config.runtime_concurrency_explicit = true;
                        },
                        // `nil`/absent — leave for the opt-out default
                        // (`resolveConcurrencyGate`, which needs the target).
                        else => {},
                    }
                } else if (std.mem.eql(u8, field.name, "runtime_tracing")) {
                    config.runtime_tracing = switch (field.value) {
                        .bool_val => |trace_enabled| trace_enabled,
                        else => false,
                    };
                } else if (std.mem.eql(u8, field.name, "pipeline")) {
                    config.pipeline = try constValueToPipeline(alloc, field.value);
                }
            }

            const paths = try paths_list.toOwnedSlice(alloc);
            paths_list_transferred = true;
            config.paths = paths;
            const deps = try deps_list.toOwnedSlice(alloc);
            deps_list_transferred = true;
            config.deps = deps;
            config_transferred = true;
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

    var collect_source_units: AdapterSourceUnitCollection = .{};
    defer collect_source_units.deinit(alloc);
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

    var ctx = try collectMemoryManagerAdapterFrontend(alloc, collect_source_units.units.items, collect_options);

    const source_path = try resolveMemoryManagerBackendFromSourceGraph(
        alloc,
        &ctx.collector.graph,
        ctx.interner,
        selected.type_name,
    );
    return buildMemoryAdapterEval(alloc, selected.type_name, source_path);
}

fn collectMemoryManagerAdapterFrontend(
    alloc: std.mem.Allocator,
    source_units: []const compiler.SourceUnit,
    options: compiler.CompileOptions,
) error{ OutOfMemory, CompileFailed }!compiler.CompilationContext {
    return compiler.collectAllFromUnits(alloc, source_units, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompileFailed,
    };
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
    defer alloc.free(explicit_source_files);
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
    errdefer file_paths.deinit(alloc);
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

const AdapterSourceUnitCollection = struct {
    units: std.ArrayListUnmanaged(compiler.SourceUnit) = .empty,
    owned_sources: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *AdapterSourceUnitCollection, alloc: std.mem.Allocator) void {
        for (self.owned_sources.items) |source| {
            alloc.free(source);
        }
        self.owned_sources.deinit(alloc);
        self.units.deinit(alloc);
        self.* = .{};
    }

    fn appendBorrowedUnique(
        self: *AdapterSourceUnitCollection,
        alloc: std.mem.Allocator,
        source_unit: compiler.SourceUnit,
    ) std.Io.Dir.RealPathFileAllocError!void {
        try appendUniqueSourceUnit(alloc, &self.units, source_unit);
    }

    fn appendOwnedUnique(
        self: *AdapterSourceUnitCollection,
        alloc: std.mem.Allocator,
        source_unit: compiler.SourceUnit,
    ) std.Io.Dir.RealPathFileAllocError!void {
        const previous_len = self.units.items.len;
        var source_tracked = false;
        errdefer {
            if (!source_tracked) {
                alloc.free(source_unit.source);
                if (self.units.items.len > previous_len) {
                    self.units.items.len = previous_len;
                }
            }
        }

        try appendUniqueSourceUnit(alloc, &self.units, source_unit);
        if (self.units.items.len == previous_len) {
            alloc.free(source_unit.source);
            source_tracked = true;
            return;
        }

        try self.owned_sources.append(alloc, source_unit.source);
        source_tracked = true;
    }
};

fn appendDiscoveredSourceUnits(
    alloc: std.mem.Allocator,
    out: *AdapterSourceUnitCollection,
    file_paths: []const []const u8,
    provided_units: []const compiler.SourceUnit,
    graph: *const zap.discovery.FileGraph,
) error{ OutOfMemory, ReadError }!void {
    for (file_paths) |file_path| {
        const provided = findProvidedSourceUnit(alloc, provided_units, file_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadError,
        };
        if (provided) |unit| {
            out.appendBorrowedUnique(alloc, unit) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ReadError,
            };
            continue;
        }

        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, alloc, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadError,
        };
        out.appendOwnedUnique(alloc, .{
            .file_path = file_path,
            .source = source,
            .primary_struct_name = graph.file_to_struct.get(file_path),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadError,
        };
    }
}

fn findProvidedSourceUnit(
    alloc: std.mem.Allocator,
    provided_units: []const compiler.SourceUnit,
    file_path: []const u8,
) std.Io.Dir.RealPathFileAllocError!?compiler.SourceUnit {
    if (provided_units.len == 0) return null;

    const target_key = try canonicalSourcePath(alloc, file_path);
    defer alloc.free(target_key);

    for (provided_units) |unit| {
        const unit_key = try canonicalSourcePath(alloc, unit.file_path);
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
    errdefer alloc.free(source_path);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(manager_type_name);
    hasher.update(source_path);

    const owned_type_name = try alloc.dupe(u8, manager_type_name);
    return .{
        .manager = .{
            .type_name = owned_type_name,
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
    var steps_transferred = false;
    errdefer if (!steps_transferred) deinitBuildConfigStepList(alloc, &steps);
    for (step_values) |step_value| {
        const step = try constValueToPipelineStep(alloc, step_value);
        var step_transferred = false;
        errdefer if (!step_transferred) freeBuildConfigStep(alloc, step);
        try steps.append(alloc, step);
        step_transferred = true;
    }
    if (steps.items.len == 0) return error.InvalidManifestPipeline;
    const owned_steps = try steps.toOwnedSlice(alloc);
    steps_transferred = true;
    return BuildConfig.Pipeline{ .steps = owned_steps };
}

fn constValueToPipelineStep(
    alloc: std.mem.Allocator,
    val: zap.ctfe.ConstValue,
) !BuildConfig.Step {
    if (val != .struct_val) return error.InvalidManifestPipeline;

    var parsed_step: ?BuildConfig.Step = null;
    errdefer if (parsed_step) |step| freeBuildConfigStep(alloc, step);
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
                    .string => |arg| {
                        const owned_arg = try alloc.dupe(u8, arg);
                        var owned_arg_transferred = false;
                        errdefer if (!owned_arg_transferred) alloc.free(owned_arg);
                        try args.append(alloc, owned_arg);
                        owned_arg_transferred = true;
                    },
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

fn freeDocGroup(alloc: std.mem.Allocator, group: BuildConfig.DocGroup) void {
    alloc.free(group.name);
    for (group.pages) |page| alloc.free(page);
    alloc.free(group.pages);
}

fn deinitDocGroupList(
    alloc: std.mem.Allocator,
    groups: *std.ArrayListUnmanaged(BuildConfig.DocGroup),
) void {
    for (groups.items) |group| freeDocGroup(alloc, group);
    groups.deinit(alloc);
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
            var name_transferred = false;
            errdefer if (!name_transferred) alloc.free(name);
            const pages = switch (fields[1]) {
                .list => |items| blk: {
                    var page_list: std.ArrayListUnmanaged([]const u8) = .empty;
                    var page_list_transferred = false;
                    errdefer if (!page_list_transferred) deinitOwnedStringList(alloc, &page_list);
                    for (items) |item| {
                        switch (item) {
                            .string => |s| {
                                const page = try alloc.dupe(u8, s);
                                var page_transferred = false;
                                errdefer if (!page_transferred) alloc.free(page);
                                try page_list.append(alloc, page);
                                page_transferred = true;
                            },
                            else => {},
                        }
                    }
                    const owned_pages = try page_list.toOwnedSlice(alloc);
                    page_list_transferred = true;
                    break :blk owned_pages;
                },
                else => return null,
            };
            name_transferred = true;
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
    errdefer {
        if (name) |owned_name| alloc.free(owned_name);
        if (path) |owned_path| alloc.free(owned_path);
        if (git_url) |owned_url| alloc.free(owned_url);
        if (git_tag) |owned_tag| alloc.free(owned_tag);
        if (git_branch) |owned_branch| alloc.free(owned_branch);
        if (git_rev) |owned_rev| alloc.free(owned_rev);
    }

    switch (val) {
        .struct_val => |sv| {
            for (sv.fields) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    const owned_name = try constStringField(alloc, field.value);
                    if (name) |previous| alloc.free(previous);
                    name = owned_name;
                } else if (std.mem.eql(u8, field.name, "path")) {
                    const owned_path = try constOptionalStringField(alloc, field.value);
                    if (path) |previous| alloc.free(previous);
                    path = owned_path;
                } else if (std.mem.eql(u8, field.name, "git_url")) {
                    const owned_url = try constOptionalStringField(alloc, field.value);
                    if (git_url) |previous| alloc.free(previous);
                    git_url = owned_url;
                } else if (std.mem.eql(u8, field.name, "git_tag")) {
                    const owned_tag = try constOptionalStringField(alloc, field.value);
                    if (git_tag) |previous| alloc.free(previous);
                    git_tag = owned_tag;
                } else if (std.mem.eql(u8, field.name, "git_branch")) {
                    const owned_branch = try constOptionalStringField(alloc, field.value);
                    if (git_branch) |previous| alloc.free(previous);
                    git_branch = owned_branch;
                } else if (std.mem.eql(u8, field.name, "git_rev")) {
                    const owned_rev = try constOptionalStringField(alloc, field.value);
                    if (git_rev) |previous| alloc.free(previous);
                    git_rev = owned_rev;
                }
            }
        },
        .map => |entries| {
            for (entries) |entry| {
                const key = constKeyName(entry.key) orelse continue;
                if (std.mem.eql(u8, key, "name")) {
                    const owned_name = try constStringField(alloc, entry.value);
                    if (name) |previous| alloc.free(previous);
                    name = owned_name;
                } else if (std.mem.eql(u8, key, "path")) {
                    const owned_path = try constOptionalStringField(alloc, entry.value);
                    if (path) |previous| alloc.free(previous);
                    path = owned_path;
                } else if (std.mem.eql(u8, key, "git_url")) {
                    const owned_url = try constOptionalStringField(alloc, entry.value);
                    if (git_url) |previous| alloc.free(previous);
                    git_url = owned_url;
                } else if (std.mem.eql(u8, key, "git_tag")) {
                    const owned_tag = try constOptionalStringField(alloc, entry.value);
                    if (git_tag) |previous| alloc.free(previous);
                    git_tag = owned_tag;
                } else if (std.mem.eql(u8, key, "git_branch")) {
                    const owned_branch = try constOptionalStringField(alloc, entry.value);
                    if (git_branch) |previous| alloc.free(previous);
                    git_branch = owned_branch;
                } else if (std.mem.eql(u8, key, "git_rev")) {
                    const owned_rev = try constOptionalStringField(alloc, entry.value);
                    if (git_rev) |previous| alloc.free(previous);
                    git_rev = owned_rev;
                }
            }
        },
        .tuple => |elems| {
            // Tuple format: {:name, {:path, "path"}} or {:name, {:git, "url"}}
            // Also supports extended git: {:name, {:git, "url", tag: "v1"}}
            if (elems.len >= 2) {
                // First element: dep name (atom)
                switch (elems[0]) {
                    .atom => |a| {
                        const owned_name = try alloc.dupe(u8, a);
                        if (name) |previous| alloc.free(previous);
                        name = owned_name;
                    },
                    .string => |s| {
                        const owned_name = try alloc.dupe(u8, s);
                        if (name) |previous| alloc.free(previous);
                        name = owned_name;
                    },
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
                                    if (path) |previous| alloc.free(previous);
                                    path = sv;
                                } else if (std.mem.eql(u8, source_type, "git")) {
                                    if (git_url) |previous| alloc.free(previous);
                                    git_url = sv;
                                    // Optional extra fields: tag, branch, rev
                                    if (source_elems.len >= 3) {
                                        switch (source_elems[2]) {
                                            .string => |s| {
                                                const owned_tag = try alloc.dupe(u8, s);
                                                if (git_tag) |previous| alloc.free(previous);
                                                git_tag = owned_tag;
                                            },
                                            else => {},
                                        }
                                    }
                                } else {
                                    alloc.free(sv);
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
        if (git_url) |unused_url| alloc.free(unused_url);
        if (git_tag) |unused_tag| alloc.free(unused_tag);
        if (git_branch) |unused_branch| alloc.free(unused_branch);
        if (git_rev) |unused_rev| alloc.free(unused_rev);
        name = null;
        path = null;
        git_url = null;
        git_tag = null;
        git_branch = null;
        git_rev = null;
        return .{ .name = dep_name, .source = .{ .path = dep_path } };
    }
    if (git_url) |url| {
        const tag = git_tag;
        const branch = git_branch;
        const rev = git_rev;
        name = null;
        git_url = null;
        git_tag = null;
        git_branch = null;
        git_rev = null;
        return .{ .name = dep_name, .source = .{ .git = .{
            .url = url,
            .tag = tag,
            .branch = branch,
            .rev = rev,
        } } };
    }
    return error.ManifestNotFound;
}

fn putOwnedBuildOpt(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged([]const u8),
    owned_key: []const u8,
    owned_value: []const u8,
) !void {
    const entry = try map.getOrPut(alloc, owned_key);
    if (entry.found_existing) {
        alloc.free(owned_key);
        alloc.free(entry.value_ptr.*);
    }
    entry.value_ptr.* = owned_value;
}

fn putBuildOptFromBorrowedKey(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged([]const u8),
    key: []const u8,
    value: zap.ctfe.ConstValue,
) !void {
    const owned_value = try constStringField(alloc, value);
    var value_transferred = false;
    errdefer if (!value_transferred) alloc.free(owned_value);

    const owned_key = try alloc.dupe(u8, key);
    var key_transferred = false;
    errdefer if (!key_transferred) alloc.free(owned_key);

    try putOwnedBuildOpt(alloc, map, owned_key, owned_value);
    key_transferred = true;
    value_transferred = true;
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
                try putBuildOptFromBorrowedKey(alloc, map, key, entry.value);
            }
        },
        .list => |items| {
            for (items) |item| {
                switch (item) {
                    .tuple => |elems| {
                        if (elems.len != 2) continue;
                        const key = constKeyName(elems[0]) orelse continue;
                        try putBuildOptFromBorrowedKey(alloc, map, key, elems[1]);
                    },
                    .struct_val => |sv| {
                        var key: ?[]const u8 = null;
                        var value: ?[]const u8 = null;
                        defer {
                            if (key) |owned_key| alloc.free(owned_key);
                            if (value) |owned_value| alloc.free(owned_value);
                        }
                        for (sv.fields) |field| {
                            if (std.mem.eql(u8, field.name, "key")) {
                                const owned_key = try constStringField(alloc, field.value);
                                if (key) |previous| alloc.free(previous);
                                key = owned_key;
                            }
                            if (std.mem.eql(u8, field.name, "value")) {
                                const owned_value = try constStringField(alloc, field.value);
                                if (value) |previous| alloc.free(previous);
                                value = owned_value;
                            }
                        }
                        if (key != null and value != null) {
                            try putOwnedBuildOpt(alloc, map, key.?, value.?);
                            key = null;
                            value = null;
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

fn exerciseLoadBuildOptsAllocationFailures(alloc: std.mem.Allocator) !void {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer freeBuildConfigBuildOpts(alloc, &map);

    const map_val = zap.ctfe.ConstValue{ .map = &.{
        .{
            .key = .{ .atom = "from_map" },
            .value = .{ .string = "enabled" },
        },
    } };
    try loadBuildOpts(alloc, &map, map_val);

    const list_val = zap.ctfe.ConstValue{ .list = &.{
        .{ .tuple = &.{ .{ .atom = "from_tuple" }, .{ .string = "yes" } } },
        .{ .struct_val = .{
            .type_name = "Zap.Build.Option",
            .fields = &.{
                .{ .name = "key", .value = .{ .string = "from_struct" } },
                .{ .name = "value", .value = .{ .string = "ok" } },
            },
        } },
        .{ .struct_val = .{
            .type_name = "Zap.Build.Option",
            .fields = &.{
                .{ .name = "key", .value = .{ .string = "partial_struct" } },
            },
        } },
    } };
    try loadBuildOpts(alloc, &map, list_val);

    try testing.expectEqual(@as(u32, 3), map.count());
    try testing.expectEqualStrings("enabled", map.get("from_map").?);
    try testing.expectEqualStrings("yes", map.get("from_tuple").?);
    try testing.expectEqualStrings("ok", map.get("from_struct").?);
    try testing.expect(map.get("partial_struct") == null);
}

test "P4J2: loadBuildOpts rolls back owned key value pairs on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseLoadBuildOptsAllocationFailures,
        .{},
    );
}

test "P4J2: loadBuildOpts frees replaced values for duplicate keys" {
    const alloc = testing.allocator;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer freeBuildConfigBuildOpts(alloc, &map);

    const val = zap.ctfe.ConstValue{ .list = &.{
        .{ .tuple = &.{ .{ .atom = "optimize" }, .{ .string = "debug" } } },
        .{ .tuple = &.{ .{ .atom = "optimize" }, .{ .string = "release_fast" } } },
    } };

    try loadBuildOpts(alloc, &map, val);

    try testing.expectEqual(@as(u32, 1), map.count());
    try testing.expectEqualStrings("release_fast", map.get("optimize").?);
}

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

test "P4J2: constValueToBuildConfig frees path duplicate when paths append fails" {
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "paths", .value = .{ .list = &.{
                .{ .string = "src/**/*.zap" },
            } } },
        },
    } };

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(
        error.OutOfMemory,
        constValueToBuildConfig(failing_allocator.allocator(), val),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

fn exerciseConstValueToBuildConfigDependencyAllocationFailures(alloc: std.mem.Allocator) !void {
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap_Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "app" } },
            .{ .name = "version", .value = .{ .string = "0.1.0" } },
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
                .{ .tuple = &.{ .{ .atom = "feature_x" }, .{ .string = "true" } } },
            } } },
            .{ .name = "source_url", .value = .{ .string = "https://example.com/app" } },
        },
    } };

    const config = try constValueToBuildConfig(alloc, val);
    defer freeConstValueBuildConfig(alloc, config);

    try testing.expectEqual(@as(usize, 2), config.deps.len);
    try testing.expect(config.deps[0].source == .path);
    try testing.expectEqualStrings("../local_dep", config.deps[0].source.path);
    try testing.expect(config.deps[1].source == .git);
    try testing.expectEqualStrings("v1.2.3", config.deps[1].source.git.tag.?);
    try testing.expectEqualStrings("true", config.build_opts.get("feature_x").?);
    try testing.expectEqualStrings("https://example.com/app", config.source_url.?);
}

test "P4J2: constValueToBuildConfig frees dependency records on append and later failures" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseConstValueToBuildConfigDependencyAllocationFailures,
        .{},
    );
}

fn exerciseConstValueToPipelineRunAllocationFailures(alloc: std.mem.Allocator) !void {
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Build.Run",
        .fields = &.{
            .{ .name = "args", .value = .{ .list = &.{
                .{ .string = "--only" },
                .{ .string = "math" },
            } } },
            .{ .name = "forward_args", .value = .{ .bool_val = false } },
        },
    } };

    const run = try constValueToPipelineRun(alloc, val);
    defer {
        for (run.args) |arg| alloc.free(arg);
        alloc.free(run.args);
    }

    try testing.expectEqual(@as(usize, 2), run.args.len);
    try testing.expectEqualStrings("--only", run.args[0]);
    try testing.expect(!run.forward_args);
}

test "P4J2: constValueToPipelineRun frees duplicated arg when args append fails" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseConstValueToPipelineRunAllocationFailures,
        .{},
    );
}

fn exerciseConstValueToPipelineAllocationFailures(alloc: std.mem.Allocator) !void {
    const val = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Build.Pipeline",
        .fields = &.{
            .{ .name = "steps", .value = .{ .list = &.{
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
                            },
                        } } },
                    },
                } },
                .{ .struct_val = .{
                    .type_name = "Zap.Build.Step",
                    .fields = &.{
                        .{ .name = "compile", .value = .{ .struct_val = .{
                            .type_name = "Zap.Build.Compile",
                            .fields = &.{},
                        } } },
                    },
                } },
            } } },
        },
    } };

    const maybe_pipeline = try constValueToPipeline(alloc, val);
    const pipeline = maybe_pipeline orelse return error.ExpectedPipeline;
    defer freeBuildConfigPipeline(alloc, pipeline);

    try testing.expectEqual(@as(usize, 2), pipeline.steps.len);
    try testing.expect(pipeline.steps[0] == .run);
    try testing.expectEqualStrings("--only", pipeline.steps[0].run.args[0]);
    try testing.expect(pipeline.steps[1] == .compile);
}

test "P4J2: constValueToPipeline frees run step args on step append and slice failures" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseConstValueToPipelineAllocationFailures,
        .{},
    );
}

fn exerciseConstValueToDocGroupAllocationFailures(alloc: std.mem.Allocator) !void {
    const val = zap.ctfe.ConstValue{ .tuple = &.{
        .{ .string = "Guides" },
        .{ .list = &.{
            .{ .string = "docs/intro.md" },
            .{ .string = "docs/install.md" },
        } },
    } };

    const maybe_group = try constValueToDocGroup(alloc, val);
    const group = maybe_group orelse return error.ExpectedDocGroup;
    defer freeDocGroup(alloc, group);

    try testing.expectEqualStrings("Guides", group.name);
    try testing.expectEqual(@as(usize, 2), group.pages.len);
    try testing.expectEqualStrings("docs/intro.md", group.pages[0]);
}

test "P4J2: constValueToDocGroup frees duplicated page when page append fails" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseConstValueToDocGroupAllocationFailures,
        .{},
    );
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

    var interp = try zap.ctfe.Interpreter.init(alloc, &result.ir_program);
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

    var interp = try zap.ctfe.Interpreter.init(alloc, &result.ir_program);
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

    var interp = try zap.ctfe.Interpreter.init(alloc, &ctfe_result.ir_program);
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

test "ctfe manifest evaluates minimal valid manifest with real stdlib" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub struct Zap.Builder {
        \\  pub fn manifest(_env :: Zap.Env) -> Zap.Manifest {
        \\    %Zap.Manifest{
        \\      name: "manifest_daemon_valid",
        \\      version: "0.1.0",
        \\      kind: :bin,
        \\      root: &Main.main/1,
        \\      paths: ["lib/**/*.zap"],
        \\      optimize: :debug
        \\    }
        \\  }
        \\}
    ;

    var captured_stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer captured_stderr.deinit(alloc);
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured_stderr,
        .allocator = alloc,
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    const build_opts: std.StringHashMapUnmanaged([]const u8) = .empty;
    var manifest_eval = ctfeManifestDetailedWithProgress(
        alloc,
        source,
        "default",
        null,
        build_opts,
        "lib",
        null,
    ) catch |err| {
        std.debug.print(
            "manifest CTFE failed with {s}\n--- captured stderr ---\n{s}\n--- end captured stderr ---\n",
            .{ @errorName(err), captured_stderr.items },
        );
        return err;
    };
    defer manifest_eval.deinit(alloc);

    try testing.expectEqualStrings("manifest_daemon_valid", manifest_eval.config.name);
    try testing.expectEqualStrings("0.1.0", manifest_eval.config.version);
    try testing.expectEqual(BuildConfig.Kind.bin, manifest_eval.config.kind);
    try testing.expectEqualStrings("Main.main/1", manifest_eval.config.root.?);
    try testing.expectEqual(BuildConfig.Optimize.debug, manifest_eval.config.optimize);
    try testing.expectEqual(@as(usize, 1), manifest_eval.config.paths.len);
    try testing.expectEqualStrings("lib/**/*.zap", manifest_eval.config.paths[0]);
    try testing.expect(manifest_eval.config.memory_manager != null);
    try testing.expectEqualStrings("Memory.ARC", manifest_eval.config.memory_manager.?.type_name);
}

test "constValueToBuildConfig parses the runtime_tracing gate (P6-J6)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tracing_on = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "trace_probe" } },
            .{ .name = "version", .value = .{ .string = "0.0.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "runtime_concurrency", .value = .{ .bool_val = true } },
            .{ .name = "runtime_tracing", .value = .{ .bool_val = true } },
        },
    } };
    const tracing_on_config = try constValueToBuildConfig(alloc, tracing_on);
    try testing.expect(tracing_on_config.runtime_tracing);

    const tracing_absent = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "trace_probe" } },
            .{ .name = "version", .value = .{ .string = "0.0.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
        },
    } };
    const tracing_absent_config = try constValueToBuildConfig(alloc, tracing_absent);
    try testing.expect(!tracing_absent_config.runtime_tracing);
}

test "constValueToBuildConfig parses the runtime_concurrency gate (P2-J1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const gate_on = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "gate_probe" } },
            .{ .name = "version", .value = .{ .string = "0.0.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "runtime_concurrency", .value = .{ .bool_val = true } },
        },
    } };
    const gate_on_config = try constValueToBuildConfig(alloc, gate_on);
    try testing.expect(gate_on_config.runtime_concurrency);
    // Explicit `true` in the manifest marks the gate resolved — `resolveConcurrencyGate`
    // must leave it untouched (an explicit request, not the opt-out default).
    try testing.expect(gate_on_config.runtime_concurrency_explicit);

    const gate_off = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "gate_probe" } },
            .{ .name = "version", .value = .{ .string = "0.0.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
            .{ .name = "runtime_concurrency", .value = .{ .bool_val = false } },
        },
    } };
    const gate_off_config = try constValueToBuildConfig(alloc, gate_off);
    // Explicit `false` opts OUT — resolved, so the target-based default never applies.
    try testing.expect(!gate_off_config.runtime_concurrency);
    try testing.expect(gate_off_config.runtime_concurrency_explicit);

    const gate_absent = zap.ctfe.ConstValue{ .struct_val = .{
        .type_name = "Zap.Manifest",
        .fields = &.{
            .{ .name = "name", .value = .{ .string = "gate_probe" } },
            .{ .name = "version", .value = .{ .string = "0.0.0" } },
            .{ .name = "kind", .value = .{ .atom = "bin" } },
        },
    } };
    const gate_absent_config = try constValueToBuildConfig(alloc, gate_absent);
    // Absent field ⇒ left UNRESOLVED (explicit == false) so `resolveConcurrencyGate`
    // computes the opt-out default from the target. The pre-resolution value is still
    // `false`; resolution is what flips it ON for capable targets.
    try testing.expect(!gate_absent_config.runtime_concurrency);
    try testing.expect(!gate_absent_config.runtime_concurrency_explicit);
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

    var interp = try zap.ctfe.Interpreter.init(alloc, &result.ir_program);
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

    var interp = try zap.ctfe.Interpreter.init(alloc, &result.ir_program);
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

test "memory adapter source collection preserves OutOfMemory" {
    const source =
        \\pub protocol Memory.Manager {
        \\}
    ;
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/memory/manager.zap", .source = source },
    };

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        collectMemoryManagerAdapterFrontend(
            failing_allocator.allocator(),
            &source_units,
            .{ .show_progress = false },
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: memory adapter eval frees owned source path when type-name duplication fails" {
    const source_path = try testing.allocator.dupe(u8, "lib/memory/arc.zap");

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        buildMemoryAdapterEval(
            failing_allocator.allocator(),
            "Memory.ARC",
            source_path,
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: discoverMemoryAdapterGraph frees explicit source-file slice on later failure" {
    const source_units = &[_]compiler.SourceUnit{
        .{
            .file_path = "missing/p4j2/memory/adapter.zap",
            .source =
            \\pub struct ThirdParty.ProjectArena {
            \\}
            ,
        },
    };

    try testing.expectError(
        error.ReadError,
        discoverMemoryAdapterGraph(
            testing.allocator,
            "ThirdParty.ProjectArena",
            &.{},
            source_units,
        ),
    );
}

fn countExplicitSourceFilesDeclaringStructAllocations(
    source_units: []const compiler.SourceUnit,
    struct_name: []const u8,
) !usize {
    var counting_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = counting_allocator.allocator();

    const file_paths = try explicitSourceFilesDeclaringStruct(alloc, source_units, struct_name);
    alloc.free(file_paths);

    return counting_allocator.alloc_index;
}

test "P4J2: explicitSourceFilesDeclaringStruct frees partial list on allocation failure" {
    const source_units = &[_]compiler.SourceUnit{
        .{
            .file_path = "first_adapter.zap",
            .source =
            \\pub struct ThirdParty.ProjectArena {
            \\}
            ,
        },
        .{
            .file_path = "second_adapter.zap",
            .source =
            \\pub struct ThirdParty.ProjectArena {
            \\}
            ,
        },
    };

    const allocation_count = try countExplicitSourceFilesDeclaringStructAllocations(
        source_units,
        "ThirdParty.ProjectArena",
    );
    try testing.expect(allocation_count > 1);

    for (0..allocation_count) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing_allocator.allocator();

        const file_paths = explicitSourceFilesDeclaringStruct(
            alloc,
            source_units,
            "ThirdParty.ProjectArena",
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try testing.expect(failing_allocator.has_induced_failure);
                continue;
            },
        };

        try testing.expect(!failing_allocator.has_induced_failure);
        alloc.free(file_paths);
    }
}

test "memory adapter source collection maps diagnosed frontend failure to CompileFailed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var captured_stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer captured_stderr.deinit(alloc);
    const previous_capture = zap.diagnostics.installStderrCapture(.{
        .list = &captured_stderr,
        .allocator = alloc,
    });
    defer _ = zap.diagnostics.installStderrCapture(previous_capture);

    const source =
        \\pub struct Broken {
        \\  pub fn bad() -> i64 {
        \\    1
    ;
    const source_units = [_]compiler.SourceUnit{
        .{ .file_path = "lib/broken.zap", .source = source },
    };

    try testing.expectError(
        error.CompileFailed,
        collectMemoryManagerAdapterFrontend(
            alloc,
            &source_units,
            .{ .show_progress = false },
        ),
    );
    try testing.expect(captured_stderr.items.len > 0);
}

test "appendDiscoveredSourceUnits preserves read OutOfMemory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "manager.zap",
        .data = "pub struct Project.Manager {}",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const manager_path = try std.fs.path.join(alloc, &.{ tmp_path, "manager.zap" });

    var graph = zap.discovery.FileGraph.init(testing.allocator);
    defer graph.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var collected: AdapterSourceUnitCollection = .{};
    defer collected.deinit(failing_allocator.allocator());

    try testing.expectError(
        error.OutOfMemory,
        appendDiscoveredSourceUnits(
            failing_allocator.allocator(),
            &collected,
            &.{manager_path},
            &.{},
            &graph,
        ),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "P4J2: adapter source-unit collection frees owned read sources after later allocation failure" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "manager.zap",
        .data = "pub struct Project.Manager {}",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path_alloc = arena.allocator();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", path_alloc);
    const manager_path = try std.fs.path.join(path_alloc, &.{ tmp_path, "manager.zap" });

    var graph = zap.discovery.FileGraph.init(testing.allocator);
    defer graph.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var collected: AdapterSourceUnitCollection = .{};
    defer collected.deinit(alloc);

    try appendDiscoveredSourceUnits(
        alloc,
        &collected,
        &.{manager_path},
        &.{},
        &graph,
    );
    try testing.expectEqual(@as(usize, 1), collected.units.items.len);
    try testing.expectEqual(@as(usize, 1), collected.owned_sources.items.len);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    const later_allocation = alloc.dupe(u8, "later adapter frontend allocation") catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(failing_allocator.has_induced_failure);
        return;
    };
    defer alloc.free(later_allocation);
    return error.TestExpectedError;
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
const REAL_ORC_BACKEND_SOURCE = @embedFile("memory/orc/manager.zig");
const REAL_ARENA_BACKEND_SOURCE = @embedFile("memory/arena/manager.zig");
const REAL_LEAK_BACKEND_SOURCE = @embedFile("memory/leak/manager.zig");
const REAL_TRACKING_BACKEND_SOURCE = @embedFile("memory/tracking/manager.zig");
const REAL_NO_OP_BACKEND_SOURCE = @embedFile("memory/no_op/manager.zig");
const REAL_GC_BACKEND_SOURCE = @embedFile("memory/gc/manager.zig");

const ReclamationModel = zap.memory_elision.ReclamationModel;
const SharingStrategy = zap.memory_elision.SharingStrategy;

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
    /// The exact `declared_caps` value the real backend declares. Parsed
    /// from the backend source so the assertion stays tied to the real
    /// production source the build driver compiles, not a restated copy.
    expected_caps: u64,
    /// Axis A — the reclamation model `expected_caps` decodes to.
    expected_model: ReclamationModel,
    /// Axis B — the sharing strategy `expected_caps` decodes to (only
    /// codegen-meaningful when `expected_model == .individual_no_refcount`).
    expected_sharing: SharingStrategy,
};

const stdlib_manager_matrix = [_]StdlibManagerCase{
    .{
        .type_name = "Memory.ARC",
        .adapter_path = "lib/memory/arc.zap",
        .backend_source = REAL_ARC_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_REFCOUNTED, // 0x1
        .expected_model = .refcounted,
        .expected_sharing = .clone_on_share,
    },
    .{
        // ORC declares REFCOUNTED byte-identically to ARC (0x1) — the
        // shares-the-specialization hypothesis: same caps ⇒ same reclamation
        // model ⇒ same codegen specialization. The cycle collector is a
        // separate CYCL capability descriptor, invisible to `declared_caps`.
        .type_name = "Memory.ORC",
        .adapter_path = "lib/memory/orc.zap",
        .backend_source = REAL_ORC_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_REFCOUNTED, // 0x1
        .expected_model = .refcounted,
        .expected_sharing = .clone_on_share,
    },
    .{
        .type_name = "Memory.Arena",
        .adapter_path = "lib/memory/arena.zap",
        .backend_source = REAL_ARENA_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_BULK_OR_NEVER, // 0x0
        .expected_model = .bulk_or_never,
        .expected_sharing = .clone_on_share,
    },
    .{
        .type_name = "Memory.Leak",
        .adapter_path = "lib/memory/leak.zap",
        .backend_source = REAL_LEAK_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_BULK_OR_NEVER, // 0x0
        .expected_model = .bulk_or_never,
        .expected_sharing = .clone_on_share,
    },
    .{
        .type_name = "Memory.Tracking",
        .adapter_path = "lib/memory/tracking.zap",
        .backend_source = REAL_TRACKING_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_INDIVIDUAL_NO_REFCOUNT, // 0x2
        .expected_model = .individual_no_refcount,
        .expected_sharing = .clone_on_share,
    },
    .{
        .type_name = "Memory.NoOp",
        .adapter_path = "lib/memory/no_op.zap",
        .backend_source = REAL_NO_OP_BACKEND_SOURCE,
        .expected_caps = zap.memory_abi.CAPS_BULK_OR_NEVER, // 0x0
        .expected_model = .bulk_or_never,
        .expected_sharing = .clone_on_share,
    },
    .{
        .type_name = "Memory.GC",
        .adapter_path = "lib/memory/gc.zap",
        .backend_source = REAL_GC_BACKEND_SOURCE,
        // TRACED — the conservative tracing-GC reclamation model (Axis A = 0b10).
        .expected_caps = zap.memory_abi.RECLAMATION_TRACED << zap.memory_abi.RECLAMATION_MODEL_SHIFT, // 0x4
        .expected_model = .traced,
        .expected_sharing = .clone_on_share,
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

/// Parse the `declared_caps` value a real backend `.zig` source declares in
/// its `.zapmem` `ZapMemoryManagerMetaV1`/`ZapMemoryManagerCoreV1`.
///
/// Each backend assigns `.declared_caps = <CONST>` where `<CONST>` is a local
/// `const NAME: u64 = 0x...;` (ARC uses `CAP_REFCOUNT_V1_BIT`; the other four
/// use `CAP_DECLARED_CAPS`, because the production-manager rule forbids
/// importing the shared abi module). This reads the named constant's hex
/// literal directly from the real source so the axis assertions stay tied to
/// the source the build driver compiles, not a restated copy. Both the meta
/// and core declarations reference the same constant, so a single parse covers
/// the (separately ABI-validated) agreement between them.
fn realBackendDeclaredCaps(backend_source: []const u8) !u64 {
    // Find which constant the `.declared_caps` field is assigned to.
    const field_needle = ".declared_caps = ";
    const field_at = std.mem.indexOf(u8, backend_source, field_needle) orelse
        return error.DeclaredCapsFieldNotFound;
    const after_field = backend_source[field_at + field_needle.len ..];
    // The identifier runs until a non-identifier byte (',', whitespace, ...).
    var name_end: usize = 0;
    while (name_end < after_field.len) : (name_end += 1) {
        const c = after_field[name_end];
        const is_ident = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!is_ident) break;
    }
    const const_name = after_field[0..name_end];
    if (const_name.len == 0) return error.DeclaredCapsConstNameEmpty;

    // Locate `const <const_name>: u64 = <literal>;` and parse the literal.
    var decl_buf: [128]u8 = undefined;
    const decl_needle = std.fmt.bufPrint(&decl_buf, "const {s}: u64 = ", .{const_name}) catch
        return error.DeclaredCapsConstNameTooLong;
    const decl_at = std.mem.indexOf(u8, backend_source, decl_needle) orelse
        return error.DeclaredCapsConstDeclNotFound;
    const after_decl = backend_source[decl_at + decl_needle.len ..];
    const semi = std.mem.indexOfScalar(u8, after_decl, ';') orelse
        return error.DeclaredCapsConstUnterminated;
    var literal = after_decl[0..semi];
    literal = std.mem.trim(u8, literal, " ");
    return parseZigU64Literal(literal);
}

/// Parse a Zig integer literal as it appears in backend source: hex
/// (`0x...`), decimal, with optional `_` digit separators. The backend
/// capability constants are written as `0x0000_0000_0000_000N`.
fn parseZigU64Literal(literal: []const u8) !u64 {
    var digits_buf: [64]u8 = undefined;
    var len: usize = 0;
    for (literal) |c| {
        if (c == '_') continue;
        if (len >= digits_buf.len) return error.LiteralTooLong;
        digits_buf[len] = c;
        len += 1;
    }
    const cleaned = digits_buf[0..len];
    if (cleaned.len > 2 and (std.mem.startsWith(u8, cleaned, "0x") or std.mem.startsWith(u8, cleaned, "0X"))) {
        return std.fmt.parseInt(u64, cleaned[2..], 16);
    }
    return std.fmt.parseInt(u64, cleaned, 10);
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
        // compile for this manager declares the expected `declared_caps`.
        const parsed_caps = try realBackendDeclaredCaps(case.backend_source);
        try testing.expectEqual(case.expected_caps, parsed_caps);

        // Selection -> backend -> caps -> axes: the declared caps decode to
        // the manager's expected reclamation model (Axis A) and sharing
        // strategy (Axis B), via the single-source-of-truth elision queries.
        try testing.expectEqual(
            case.expected_model,
            zap.memory_elision.reclamationModel(parsed_caps),
        );
        try testing.expectEqual(
            case.expected_sharing,
            zap.memory_elision.sharingStrategy(parsed_caps),
        );

        // `shouldEmitRefcountOps` is true iff REFCOUNTED. The refcounted stdlib
        // managers are Memory.ARC and Memory.ORC: ORC (P3-J6) shares ARC's
        // REFCOUNTED model and codegen specialization byte-for-byte — its cycle
        // collector is a separate CYCL capability descriptor, invisible to the
        // Axis-A model — so it emits the identical retain/release gate as ARC.
        const is_refcounted_stdlib_manager = std.mem.eql(u8, case.type_name, "Memory.ARC") or
            std.mem.eql(u8, case.type_name, "Memory.ORC");
        try testing.expectEqual(
            is_refcounted_stdlib_manager,
            zap.memory_elision.shouldEmitRefcountOps(parsed_caps),
        );
        try testing.expectEqual(
            case.expected_model == .refcounted,
            zap.memory_elision.shouldEmitRefcountOps(parsed_caps),
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
    // The default manager (ARC) declares the REFCOUNTED caps (0x1) and
    // resolves to the refcounted reclamation model.
    const arc_caps = try realBackendDeclaredCaps(REAL_ARC_BACKEND_SOURCE);
    try testing.expectEqual(zap.memory_abi.CAPS_REFCOUNTED, arc_caps);
    try testing.expectEqual(ReclamationModel.refcounted, zap.memory_elision.reclamationModel(arc_caps));
    try testing.expect(zap.memory_elision.shouldEmitRefcountOps(arc_caps));
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
