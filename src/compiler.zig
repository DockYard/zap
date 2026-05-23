//! Zap Frontend Compiler Pipeline
//!
//! Reusable compilation pipeline: source → parse → collect → macro → desugar →
//! type check → HIR → IR. Used by both the builder phase (compiling build.zap)
//! and the target build phase (compiling project source).

const std = @import("std");
const zap = @import("root.zig");
const ir = zap.ir;
const ast = zap.ast;
// zig_lib_archive is only available in the main binary, not the library.
// extractEmbeddedZigLib is called from main.zig which has access to it.

const runtime_source = @embedFile("runtime.zig");
const lexer = @import("lexer.zig");
const progress_mod = @import("progress.zig");
const frontend_policy = @import("frontend_policy.zig");

/// Per-stage timing diagnostic. Gated by `ZAP_PROFILE`: production builds
/// stay quiet, but `ZAP_PROFILE=1 zap test` (or any compile-driving
/// command) emits `[stage NAME] ms=N` lines so a regression hunt can
/// pinpoint which compile stage owns a slowdown without recompiling
/// the toolchain. Tracks the inflection points the task-#15 PART 2
/// investigation identified — `compileStagedStructHir` (per-struct
/// HIR-stage type-check vs HIR-build split) and the per-wave Phase
/// boundaries (HIR collect, monomorphize, IR build, analysis+contify).
const ZapTimer = struct {
    last_ns: i128,

    fn nowNs() i128 {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    }

    pub fn start() ZapTimer {
        return .{ .last_ns = nowNs() };
    }

    pub fn lapMs(self: *ZapTimer) u64 {
        const now = nowNs();
        const ms = @as(u64, @intCast(@divTrunc(now - self.last_ns, 1_000_000)));
        self.last_ns = now;
        return ms;
    }

    pub fn readMs(self: *const ZapTimer) u64 {
        return @as(u64, @intCast(@divTrunc(nowNs() - self.last_ns, 1_000_000)));
    }

    pub fn reset(self: *ZapTimer) void {
        self.last_ns = nowNs();
    }
};

/// True when `ZAP_PROFILE` is set in the process environment. Cached on
/// first call so the env scan runs once per process. Use as a guard
/// around `std.debug.print` calls in stage-timing diagnostics.
fn profilingEnabled() bool {
    const Cache = struct {
        var inited: bool = false;
        var enabled: bool = false;
    };
    if (Cache.inited) return Cache.enabled;
    Cache.enabled = std.c.getenv("ZAP_PROFILE") != null;
    Cache.inited = true;
    return Cache.enabled;
}

/// True when verbose incremental-cache tracing is enabled. This is separate
/// from `ZAP_PROFILE`: profiling answers "how long?", while this trace answers
/// "why was this node rebuilt?" The alternate spelling keeps older local
/// scripts usable while standardizing new docs on `ZAP_INCREMENTAL_TRACE`.
var incremental_trace_enabled_override: ?bool = null;

pub fn setIncrementalTraceEnabledOverride(enabled: ?bool) void {
    incremental_trace_enabled_override = enabled;
}

fn incrementalTraceEnabled() bool {
    const Cache = struct {
        var inited: bool = false;
        var enabled: bool = false;
    };
    if (incremental_trace_enabled_override) |enabled| return enabled;
    if (Cache.inited) return Cache.enabled;
    Cache.enabled = std.c.getenv("ZAP_INCREMENTAL_TRACE") != null or
        std.c.getenv("ZAP_TRACE_INCREMENTAL") != null;
    Cache.inited = true;
    return Cache.enabled;
}

fn incrementalTrace(comptime format: []const u8, args: anytype) void {
    if (!incrementalTraceEnabled()) return;
    std.debug.print("\n[incremental trace] " ++ format ++ "\n", args);
}

fn tracePackageKey(key: zap.incremental_graph.PackageKey) void {
    std.debug.print("package={s} root={s}", .{ key.name, key.root_identity });
    if (key.version) |version| std.debug.print(" version={s}", .{version});
}

fn traceDeclarationOwnerKey(key: zap.incremental_graph.DeclarationOwnerKey) void {
    std.debug.print("owner_kind={s} ", .{@tagName(key.kind)});
    tracePackageKey(key.package);
    std.debug.print(" owner={s}", .{key.qualified_name});
}

fn traceIncrementalNodeKeyFields(key: zap.incremental_graph.NodeKey) void {
    switch (key) {
        .source_file => |value| {
            tracePackageKey(value.package);
            std.debug.print(" path={s}", .{value.path});
        },
        .package_surface => |value| tracePackageKey(value),
        .struct_surface => |value| {
            tracePackageKey(value.package);
            std.debug.print(" struct={s}", .{value.qualified_name});
        },
        .macro_provider => |value| {
            traceDeclarationOwnerKey(value.owner);
            std.debug.print(" macro={s}/{d}", .{ value.local_name, value.arity });
        },
        .function_signature, .function_body => |value| {
            traceDeclarationOwnerKey(value.owner);
            std.debug.print(
                " function={s}/{d} clause={d} declaration_kind={s}",
                .{ value.local_name, value.arity, value.clause_index, @tagName(value.declaration_kind) },
            );
        },
        .type_layout => |value| {
            tracePackageKey(value.package);
            std.debug.print(" type={s}", .{value.qualified_name});
        },
        .protocol => |value| {
            tracePackageKey(value.package);
            std.debug.print(" protocol={s}", .{value.qualified_name});
        },
        .impl => |value| {
            tracePackageKey(value.package);
            std.debug.print(
                " module={s} protocol={s} target={s}",
                .{ value.module_path, value.protocol_qualified_name, value.target_type_identity },
            );
        },
        .ctfe_file => |value| {
            tracePackageKey(value.package);
            std.debug.print(" path={s}", .{value.path});
        },
        .ctfe_env => |value| {
            tracePackageKey(value.package);
            std.debug.print(" env={s}", .{value.name});
        },
        .ctfe_glob => |value| {
            tracePackageKey(value.package);
            std.debug.print(" pattern={s} recursive={}", .{ value.pattern, value.recursive });
        },
        .ctfe_reflection => |value| {
            tracePackageKey(value.package);
            std.debug.print(" query={s}", .{value.query_identity});
        },
        .backend_artifact => |value| {
            tracePackageKey(value.package);
            std.debug.print(" target={s} artifact={s}", .{ value.target_identity, value.artifact_identity });
        },
        .backend_module => |value| {
            tracePackageKey(value.package);
            std.debug.print(" module={s}", .{value.module_identity});
        },
    }
}

fn traceIncrementalGraphNode(
    comptime label: []const u8,
    graph: *const zap.incremental_graph.Graph,
    node_id: zap.incremental_graph.NodeId,
) void {
    if (!incrementalTraceEnabled()) return;
    const node_key = graph.nodeKey(node_id) orelse {
        std.debug.print(
            "\n[incremental trace] {s} id={d} kind=unknown reason=missing-node-record\n",
            .{ label, @intFromEnum(node_id) },
        );
        return;
    };
    std.debug.print(
        "\n[incremental trace] {s} id={d} kind={s} ",
        .{ label, @intFromEnum(node_id), @tagName(node_key.kind()) },
    );
    traceIncrementalNodeKeyFields(node_key.*);
    std.debug.print("\n", .{});
}

fn traceIncrementalGraphStep(
    comptime label: []const u8,
    graph: *const zap.incremental_graph.Graph,
    step: zap.incremental_graph.AffectedStep,
) void {
    if (!incrementalTraceEnabled()) return;
    const depender_key = graph.nodeKey(step.depender) orelse {
        incrementalTrace(
            "{s} reason={s} depender_id={d} dependee_id={d} error=missing-depender",
            .{ label, @tagName(step.reason), @intFromEnum(step.depender), @intFromEnum(step.dependee) },
        );
        return;
    };
    const dependee_key = graph.nodeKey(step.dependee) orelse {
        incrementalTrace(
            "{s} reason={s} depender_id={d} dependee_id={d} error=missing-dependee",
            .{ label, @tagName(step.reason), @intFromEnum(step.depender), @intFromEnum(step.dependee) },
        );
        return;
    };

    std.debug.print(
        "\n[incremental trace] {s} reason={s} depender_id={d} depender_kind={s} ",
        .{ label, @tagName(step.reason), @intFromEnum(step.depender), @tagName(depender_key.kind()) },
    );
    traceIncrementalNodeKeyFields(depender_key.*);
    std.debug.print(
        " dependee_id={d} dependee_kind={s} ",
        .{ @intFromEnum(step.dependee), @tagName(dependee_key.kind()) },
    );
    traceIncrementalNodeKeyFields(dependee_key.*);
    std.debug.print("\n", .{});
}

pub const CompileResult = struct {
    ir_program: ir.Program,
    analysis_context: ?zap.escape_lattice.AnalysisContext = null,
    /// Per-function ARC ownership tables computed during IR lowering
    /// (Phase 4 of the k-nucleotide RSS gap implementation plan). The
    /// table is consumed by the ZIR backend so per-function lowering
    /// can populate `arc_returned_locals` from each function's
    /// `return_source_locals` set without re-running the analysis.
    /// Empty when the IR program contains no ARC-managed locals.
    arc_ownership: ?zap.arc_liveness.ProgramArcOwnership = null,
    /// Function ids whose current emitted ZIR should be considered dirty by
    /// the persistent Zig backend. The frontend still uses its broader
    /// invalidation set to keep Zap-level macro/type effects correct; this
    /// narrower caller closure tells the backend which modules need Zig Sema
    /// invalidation for a source edit.
    incremental_backend_affected_function_ids: []const ir.FunctionId = &.{},
    /// True when the incremental frontend could not prove final IR layout
    /// stability. The caller must refresh every emitted backend module rather
    /// than attempting a selected update.
    incremental_backend_force_full: bool = false,
};

pub const CompileError = error{
    ParseFailed,
    CollectFailed,
    MacroExpansionFailed,
    DesugarFailed,
    TypeCheckFailed,
    HirFailed,
    IrFailed,
    OutOfMemory,
    ReadError,
    IncrementalGraphDigestCollision,
    UnknownIncrementalGraphNode,
};

pub const FrontendVerifierMode = frontend_policy.FrontendVerifierMode;
pub const FrontendPassPolicy = frontend_policy.FrontendPassPolicy;
pub const FrontendOptimizeMode = frontend_policy.FrontendOptimizeMode;

pub const CompileOptions = struct {
    /// Show progress output to stderr.
    show_progress: bool = true,
    /// Shared CLI progress reporter. When present, compiler phases update the
    /// caller-owned line instead of printing their own standalone header.
    progress: ?*progress_mod.Reporter = null,
    /// Optional namespace for progress labels, e.g. "Manifest" or "Frontend".
    progress_context: []const u8 = "",
    /// lib mode — skip main function emission in ZIR.
    lib_mode: bool = false,
    /// Selected frontend optimization policy. Debug skips optimization-only
    /// frontend passes; release modes preserve the full pass set.
    frontend_optimize_mode: FrontendOptimizeMode = .debug,
    /// Struct names in dependency order for CTFE evaluation.
    /// When set, computed attributes are evaluated per-struct in this order.
    struct_order: ?[]const []const u8 = null,
    /// Indices into struct_order marking where each dependency level ends.
    /// Structs within the same level have no dependencies on each other
    /// and can be compiled in parallel. Populated by import-driven discovery.
    level_boundaries: ?[]const u32 = null,
    /// Directory for persistent CTFE cache. When set, computed attribute
    /// results are cached to disk and reused across builds.
    cache_dir: ?[]const u8 = null,
    /// Target name used when hashing CTFE cache keys.
    ctfe_target: ?[]const u8 = null,
    /// Optimize mode used when hashing CTFE cache keys.
    ctfe_optimize: ?[]const u8 = null,
    /// Io instance for parallel compilation. When set with level_boundaries,
    /// structs within the same dependency level are compiled concurrently
    /// using Io.Group.
    io: ?std.Io = null,
    /// Memory Manager ABI v1.0 capability bitmask declared by the
    /// active manager (`docs/memory-manager-abi.md` section 7). Read
    /// by `arc_materialize.materializeAnalysisArcOps` so Phase 6
    /// codegen elision can skip retain/release/reset/reuse-alloc IR
    /// materialization under managers that do not declare
    /// `REFCOUNT_V1`. Defaults to 0 (no caps); the build pipeline
    /// (`src/main.zig:compileProjectFrontend`) wires the real value
    /// from the resolved manager's `.zapmem` core vtable.
    declared_caps: u64 = 0,
    /// Build-manifest CTFE may construct first-class Type/Function values
    /// that name declarations in target/dependency sources not loaded during
    /// the initial build.zap-only pass. Project compilation leaves this false.
    allow_external_static_references: bool = false,
};

fn ctfeCompileOptionsHash(options: CompileOptions) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const base_hash = zap.ctfe.hashCompileOptions(options.ctfe_target orelse "", options.ctfe_optimize orelse "");
    const frontend_policy_tag = options.frontend_optimize_mode.cacheTag();
    hasher.update(std.mem.asBytes(&base_hash));
    hasher.update(std.mem.asBytes(&frontend_policy_tag));
    return hasher.final();
}

fn progressHeader(options: CompileOptions) void {
    if (!options.show_progress) return;
    if (options.progress) |progress| {
        progress.begin();
    } else {
        std.debug.print("Compiling\n", .{});
    }
}

fn progressStage(options: CompileOptions, comptime format: []const u8, args: anytype) void {
    if (!options.show_progress) return;
    if (options.progress) |progress| {
        progress.stagePrefixed(options.progress_context, format, args);
    } else {
        std.debug.print("\r\x1b[K  ", .{});
        if (options.progress_context.len > 0) {
            std.debug.print("{s}: ", .{options.progress_context});
        }
        std.debug.print(format, args);
    }
}

fn progressClear(options: CompileOptions) void {
    if (!options.show_progress) return;
    if (options.progress) |progress| {
        progress.clearLine();
    } else {
        std.debug.print("\r\x1b[K", .{});
    }
}

/// Compile Zap source text through the full frontend pipeline:
/// parse → collect → macro → desugar → type check → HIR → IR.
///
/// `source` is raw Zap source.
/// `file_path` is used for diagnostic display only.
/// Diagnostics are emitted to stderr on failure.
// ============================================================
// Per-File Compilation Architecture
//
// Three-pass pipeline:
//   Pass 1 (collectAll): Parse all files, collect declarations into a
//     shared CompilationContext.
//   Pass 2 (compileForCtfe / compileStructByStruct): Run the
//     post-collect pipeline. The phase methods on `Pipeline` handle
//     the shared front-end (substitute → macro → desugar →
//     re-collect → type check → HIR → mono → IR), and each entry
//     point composes the phases it needs and adds its own divergent
//     steps (build-time CTFE re-checks types after analysis; per-
//     struct compilation runs whole-program monomorphization once
//     across all structs).
//   Pass 3 (analysis + contify): Last phase of pass 2 — escape /
//     alias analysis, contification rewrite, and (for compileForCtfe)
//     a borrow re-check.
// ============================================================

/// Shared compilation state from Pass 1. Holds the scope graph, type store,
/// and interner that all files compile against.
pub const CompilationContext = struct {
    alloc: std.mem.Allocator,

    // ---- Parallel views into the same compilation. Each lives at a
    // different granularity (whole-program AST / per-struct AST /
    // per-file metadata / per-file source / per-struct scope), and
    // they're populated at different points during `collectAll`.
    // Always call the corresponding `findX` helper instead of
    // iterating the slice directly so the lookup convention has one
    // home.

    /// Whole-program merged AST — every `pub struct` from every source
    /// file lives in `.structs`, and every top-level `impl` lives in
    /// `.top_items`. Source of truth for macro expansion, scope
    /// collection, and CTFE; downstream phases mostly read from the
    /// per-struct split below.
    merged_program: ast.Program,

    /// Per-struct AST programs split out of `merged_program` after
    /// macro expansion / desugaring. Keyed by `name` (the dotted
    /// struct path). The per-struct pipeline reads from here so it
    /// does not need to re-walk the merged tree at every stage.
    struct_programs: []const StructProgram,

    /// Per-file compilation state: source path, owning struct, the
    /// raw file source, and (when produced) the per-file IR program.
    /// `units.len == source_units.len`; one unit per file.
    units: []CompilationUnit,

    /// Original per-file source units used to drive parsing and to
    /// resolve span → file mappings in diagnostics.
    source_units: []const SourceUnit,

    /// String interner shared across all parsed source units.
    interner: *ast.StringInterner,

    /// Scope graph populated by the collector. `collector.graph.structs`
    /// is the per-struct scope view (one entry per struct containing
    /// its `ScopeId`, declared functions, and attributes); the graph
    /// also holds bindings, function families, types, protocols, and
    /// impls. The scope graph and `struct_programs` always stay in
    /// sync — same structs, different views.
    collector: zap.Collector,

    /// Diagnostic engine — collects errors and warnings emitted across
    /// every phase before they're rendered to the user.
    diag_engine: zap.DiagnosticEngine,
};

pub const StructProgram = struct {
    name: []const u8,
    program: ast.Program,
};

/// Per-file compilation state.
pub const CompilationUnit = struct {
    file_path: []const u8,
    struct_name: []const u8,
    source: []const u8,
    /// Index of this file's struct in the merged program's structs array
    struct_index: ?u32 = null,
    /// Per-file IR program, populated by compileFile
    ir_program: ?ir.Program = null,
    /// Which dep this file belongs to (null for project files)
    dep: ?[]const u8 = null,
};

/// Result of compiling a single struct to HIR (before monomorphization).
/// Used by whole-program monomorphization to collect all struct HIRs,
/// then monomorphize across struct boundaries.
pub const StructHirResult = struct {
    mod_name: []const u8,
    hir_program: zap.hir.Program,
    next_group_id: u32,
};

pub const SourceUnit = struct {
    file_path: []const u8,
    source: []const u8,
    primary_struct_name: ?[]const u8 = null,
    /// Opt-in single-file script carve-out for THIS unit. Default
    /// `false` so every existing source unit (manifest path, stdlib,
    /// deps) parses byte-identically. When `true`, the unit is parsed
    /// with the parser's `script_mode` enabled, so a literal top-level
    /// `fn`/`pub fn` is hoisted into the reserved synthetic wrapper
    /// struct instead of being rejected. Only the single synthetic
    /// script unit produced by the `zap run <script.zap>` path ever
    /// sets this.
    script_mode: bool = false,
};

pub const FrontendDependencyGraph = struct {
    file_to_structs: *const std.StringHashMap([]const []const u8),
    file_imported_by: *const std.StringHashMap([]const []const u8),
    file_compile_after_globs: *const std.StringHashMap([]const []const u8),
    file_compile_after_files: *const std.StringHashMap([]const []const u8),
};

pub const FrontendIncrementalState = struct {
    allocator: std.mem.Allocator,
    interner: ast.StringInterner,
    parsed_files: std.StringHashMap(*CachedParsedFile),
    expanded_structs: std.StringHashMap(*CachedExpandedStruct),
    expanded_top_level: ?*CachedExpandedTopLevel = null,
    final_arena: ?std.heap.ArenaAllocator = null,
    final_program: ?ir.Program = null,
    dependency_graph: zap.incremental_graph.Graph,
    inventory_fingerprints_arena: std.heap.ArenaAllocator,
    compile_after_inventory_fingerprints: std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
    policy_cache_tag: ?u64 = null,
    initialized: bool = false,

    const CachedParsedFile = struct {
        arena: std.heap.ArenaAllocator,
        file_path: []const u8,
        source_hash: u64,
        script_mode: bool,
        primary_struct_name: ?[]const u8,
        program: ast.Program,
        declaration_fingerprints: ?zap.incremental_graph.DeclarationFingerprintSet = null,
        reflection_fingerprints: ?zap.incremental_graph.DeclarationFingerprintSet = null,

        fn destroy(self: *CachedParsedFile, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    const CachedExpandedStruct = struct {
        arena: std.heap.ArenaAllocator,
        name: []const u8,
        declares_macro_provider: bool,
        program: ast.Program,

        fn destroy(self: *CachedExpandedStruct, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    const CachedExpandedTopLevel = struct {
        arena: std.heap.ArenaAllocator,
        signature: u64,
        program: ast.Program,

        fn destroy(self: *CachedExpandedTopLevel, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator) FrontendIncrementalState {
        return .{
            .allocator = allocator,
            .interner = ast.StringInterner.init(allocator),
            .parsed_files = std.StringHashMap(*CachedParsedFile).init(allocator),
            .expanded_structs = std.StringHashMap(*CachedExpandedStruct).init(allocator),
            .dependency_graph = zap.incremental_graph.Graph.init(allocator),
            .inventory_fingerprints_arena = std.heap.ArenaAllocator.init(allocator),
            .compile_after_inventory_fingerprints = std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet).init(allocator),
        };
    }

    pub fn deinit(self: *FrontendIncrementalState) void {
        var parsed_iter = self.parsed_files.iterator();
        while (parsed_iter.next()) |entry| entry.value_ptr.*.destroy(self.allocator);
        self.parsed_files.deinit();

        var expanded_iter = self.expanded_structs.iterator();
        while (expanded_iter.next()) |entry| entry.value_ptr.*.destroy(self.allocator);
        self.expanded_structs.deinit();
        if (self.expanded_top_level) |artifact| artifact.destroy(self.allocator);
        self.expanded_top_level = null;

        if (self.final_arena) |*arena| arena.deinit();
        self.final_arena = null;
        self.final_program = null;

        self.dependency_graph.deinit();
        self.compile_after_inventory_fingerprints.deinit();
        self.inventory_fingerprints_arena.deinit();
        self.interner.deinit();
    }

    fn clearCachedFrontendState(self: *FrontendIncrementalState) void {
        var parsed_iter = self.parsed_files.iterator();
        while (parsed_iter.next()) |entry| entry.value_ptr.*.destroy(self.allocator);
        self.parsed_files.clearRetainingCapacity();

        var expanded_iter = self.expanded_structs.iterator();
        while (expanded_iter.next()) |entry| entry.value_ptr.*.destroy(self.allocator);
        self.expanded_structs.clearRetainingCapacity();

        if (self.expanded_top_level) |artifact| artifact.destroy(self.allocator);
        self.expanded_top_level = null;

        if (self.final_arena) |*arena| arena.deinit();
        self.final_arena = null;
        self.final_program = null;

        self.dependency_graph.deinit();
        self.dependency_graph = zap.incremental_graph.Graph.init(self.allocator);
        self.compile_after_inventory_fingerprints.clearRetainingCapacity();
        self.inventory_fingerprints_arena.deinit();
        self.inventory_fingerprints_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.interner.deinit();
        self.interner = ast.StringInterner.init(self.allocator);
        self.initialized = false;
    }

    fn ensurePolicyCacheTag(self: *FrontendIncrementalState, policy_cache_tag: u64) void {
        if (self.policy_cache_tag) |current_tag| {
            if (current_tag == policy_cache_tag) return;
            self.clearCachedFrontendState();
        }
        self.policy_cache_tag = policy_cache_tag;
    }

    pub fn prepare(
        self: *FrontendIncrementalState,
        alloc: std.mem.Allocator,
        source_units: []const SourceUnit,
        graph: FrontendDependencyGraph,
        options: CompileOptions,
    ) CompileError!FrontendIncrementalPrepared {
        self.ensurePolicyCacheTag(options.frontend_optimize_mode.cacheTag());

        var diag_engine = zap.DiagnosticEngine.init(alloc);
        diag_engine.use_color = zap.diagnostics.detectColor();
        setDiagnosticSources(&diag_engine, source_units);
        diag_engine.setLineOffset(0);

        progressHeader(options);
        progressStage(options, "[1/11] Parse", .{});

        var changed_files: std.ArrayListUnmanaged([]const u8) = .empty;
        var new_parsed_files: std.ArrayListUnmanaged(*CachedParsedFile) = .empty;
        errdefer destroyCachedParsedFiles(self.allocator, new_parsed_files.items);

        const parsed_programs = try alloc.alloc(ast.Program, source_units.len);
        const parsed_fingerprint_sets = try alloc.alloc(?zap.incremental_graph.DeclarationFingerprintSet, source_units.len);
        const reflection_fingerprint_sets = try alloc.alloc(?zap.incremental_graph.DeclarationFingerprintSet, source_units.len);
        var changed_declaration_fingerprints: std.ArrayListUnmanaged(FrontendChangedFileFingerprints) = .empty;
        for (source_units, 0..) |unit, source_index| {
            const current_hash = hashSourceBytes(unit.source);
            const cached = self.parsed_files.get(unit.file_path);
            if (cached) |entry| {
                if (entry.source_hash == current_hash and
                    entry.script_mode == unit.script_mode and
                    optionalStringEql(entry.primary_struct_name, unit.primary_struct_name))
                {
                    parsed_programs[source_index] = entry.program;
                    parsed_fingerprint_sets[source_index] = entry.declaration_fingerprints;
                    reflection_fingerprint_sets[source_index] = entry.reflection_fingerprints;
                    continue;
                }
            }

            try appendUniqueFilePath(alloc, &changed_files, unit.file_path);
            const parsed = try self.parseSourceUnit(unit, source_units, source_index, current_hash, alloc, &diag_engine);

            // Phase 1.4 warn-only advisory lints (`raise "string"` on a
            // `pub` API surface; bare `{:ok, _}`/`{:error, _}` patterns).
            // Run only on newly-parsed user units — skip the stdlib (its
            // own legacy idioms are not the lint's concern) and skip cached
            // units (already linted on their first parse).
            if (!isStdlibUnitPath(unit.file_path)) {
                zap.lints.runPhase14Lints(&parsed.program, &self.interner, &diag_engine) catch {};
            }

            try new_parsed_files.append(alloc, parsed);
            parsed_programs[source_index] = parsed.program;
            parsed_fingerprint_sets[source_index] = parsed.declaration_fingerprints;
            reflection_fingerprint_sets[source_index] = parsed.reflection_fingerprints;
            try changed_declaration_fingerprints.append(alloc, .{
                .file_path = unit.file_path,
                .previous = if (cached) |entry| entry.declaration_fingerprints else null,
                .current = parsed.declaration_fingerprints,
            });
            try changed_declaration_fingerprints.append(alloc, .{
                .file_path = unit.file_path,
                .previous = if (cached) |entry| entry.reflection_fingerprints else null,
                .current = parsed.reflection_fingerprints,
            });
        }

        if (diag_engine.hasErrors()) {
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, source_units, diag_engine.use_color);
            return error.ParseFailed;
        }

        // Surface warn-only diagnostics accumulated during parsing — most
        // notably the Phase 1.4 advisory lints (`raise "string"` on a `pub`
        // API surface; bare `{:ok, _}`/`{:error, _}` tuple patterns). These
        // never abort the build; without an explicit flush here they would
        // be silently dropped (the parse loop only emits on the error path).
        if (diag_engine.warningCount() > 0) {
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, source_units, diag_engine.use_color);
        }

        var new_dependency_graph = try buildFrontendIncrementalGraph(self.allocator, source_units, graph);
        errdefer new_dependency_graph.deinit();
        try augmentFrontendGraphWithDeclarationFingerprints(&new_dependency_graph, parsed_fingerprint_sets);
        try augmentFrontendGraphWithDeclarationFingerprints(&new_dependency_graph, reflection_fingerprint_sets);

        var new_inventory_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer new_inventory_arena.deinit();
        var new_compile_after_inventory_fingerprints = std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet).init(self.allocator);
        errdefer new_compile_after_inventory_fingerprints.deinit();
        try buildCompileAfterInventoryFingerprints(
            new_inventory_arena.allocator(),
            graph,
            &new_compile_after_inventory_fingerprints,
        );
        try appendCompileAfterInventoryFingerprintChanges(
            alloc,
            graph,
            &self.compile_after_inventory_fingerprints,
            &new_compile_after_inventory_fingerprints,
            &changed_files,
            &changed_declaration_fingerprints,
        );
        try augmentFrontendGraphWithInventoryFingerprints(&new_dependency_graph, &new_compile_after_inventory_fingerprints);

        var invalidated_structs = std.StringHashMap(void).init(alloc);
        var changed_declaration_structs = std.StringHashMap(void).init(alloc);
        var changed_graph_roots: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
        try self.computeInvalidatedStructs(
            alloc,
            source_units,
            graph,
            &new_dependency_graph,
            changed_files.items,
            changed_declaration_fingerprints.items,
            &invalidated_structs,
            &changed_declaration_structs,
            &changed_graph_roots,
        );
        const invalidated_struct_names = try invalidatedStructNamesInSourceOrder(
            alloc,
            source_units,
            graph,
            &invalidated_structs,
        );
        const changed_struct_names = try structNamesForFilesInSourceOrder(
            alloc,
            source_units,
            graph,
            changed_files.items,
        );
        incrementalTrace(
            "frontend-invalidated changed_structs={d} invalidated_structs={d}",
            .{ changed_struct_names.len, invalidated_struct_names.len },
        );
        for (changed_struct_names) |struct_name| {
            incrementalTrace("changed-struct struct={s}", .{struct_name});
        }
        for (invalidated_struct_names) |struct_name| {
            incrementalTrace("invalidated-struct-order struct={s}", .{struct_name});
        }

        var new_expanded_structs: std.ArrayListUnmanaged(*CachedExpandedStruct) = .empty;
        errdefer destroyCachedExpandedStructs(self.allocator, new_expanded_structs.items);
        var new_expanded_top_level: ?*CachedExpandedTopLevel = null;
        errdefer if (new_expanded_top_level) |artifact| artifact.destroy(self.allocator);

        var expansion_cache = ExpansionCacheWork{
            .state = self,
            .invalidated_structs = &invalidated_structs,
            .changed_declaration_structs = &changed_declaration_structs,
            .new_expanded_structs = &new_expanded_structs,
            .new_expanded_top_level = &new_expanded_top_level,
        };

        var ctx = try collectAllFromParsedPrograms(
            alloc,
            source_units,
            parsed_programs,
            &self.interner,
            options,
            diag_engine,
            &expansion_cache,
        );

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (options.struct_order) |graph_order| {
            for (graph_order) |struct_name| {
                names.append(alloc, struct_name) catch {};
            }
            // The precomputed `struct_order` is the discovery-time
            // topological ordering of the SOURCE structs. Structs that
            // only exist after desugaring — notably the `pub struct Foo`
            // produced by every `pub error Foo` rewrite (e.g.
            // `AssertionError`, `RuntimeError`) — are absent from it
            // because discovery ran before `applyErrorDeclDesugar`. They
            // ARE present in `ctx.struct_programs` (built from the fully
            // desugared programs and registered in the re-collected
            // scope graph). Compiling only `struct_order` would silently
            // drop these structs from the merged IR: their `pub impl
            // Error` method functions (`AssertionError.message__1`, …)
            // would never be lowered, so the protocol vtable instance
            // `ErrorVTable_for_AssertionError` — which IS emitted — would
            // reference methods that do not exist, tripping the ZIR
            // backend's "struct 'AssertionError' has no member named
            // 'message__1'" (#186). Append every collected struct program
            // missing from the precomputed order so the compilation set
            // is the union of the discovery order and the actually
            // collected structs. The per-struct loops downstream dedup by
            // name, so appending an already-present name is harmless.
            for (ctx.struct_programs) |mp| {
                var already_ordered = false;
                for (names.items) |existing| {
                    if (std.mem.eql(u8, existing, mp.name)) {
                        already_ordered = true;
                        break;
                    }
                }
                if (!already_ordered) names.append(alloc, mp.name) catch {};
            }
        } else {
            for (ctx.struct_programs) |mp| {
                names.append(alloc, mp.name) catch {};
            }
        }

        const result = try compileStructByStructIncrementalFinal(
            alloc,
            &ctx,
            names.items,
            options,
            self.final_program,
            &invalidated_structs,
            &changed_declaration_structs,
            changed_graph_roots.items,
            changed_struct_names,
            &new_dependency_graph,
        );

        var final_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer final_arena.deinit();
        const final_program = ir.cloneProgram(final_arena.allocator(), result.ir_program) catch return error.OutOfMemory;

        return .{
            .state = self,
            .result = result,
            .invalidated_struct_names = invalidated_struct_names,
            .changed_struct_names = changed_struct_names,
            .changed_graph_roots = try changed_graph_roots.toOwnedSlice(alloc),
            .new_parsed_files = try new_parsed_files.toOwnedSlice(alloc),
            .new_expanded_structs = try new_expanded_structs.toOwnedSlice(alloc),
            .new_expanded_top_level = new_expanded_top_level,
            .clear_expanded_top_level = !expansion_cache.has_unassigned_top_level_items,
            .new_final_arena = final_arena,
            .new_final_program = final_program,
            .new_dependency_graph = new_dependency_graph,
            .new_inventory_arena = new_inventory_arena,
            .new_compile_after_inventory_fingerprints = new_compile_after_inventory_fingerprints,
        };
    }

    pub fn dependencyGraphNodeCount(self: *const FrontendIncrementalState) usize {
        return self.dependency_graph.nodeCount();
    }

    pub fn dependencyGraphSourceFileNode(self: *const FrontendIncrementalState, file_path: []const u8) !?zap.incremental_graph.NodeId {
        return self.dependency_graph.getNode(frontendSourceFileNodeKey(file_path));
    }

    pub fn dependencyGraphStructSurfaceNode(self: *const FrontendIncrementalState, struct_name: []const u8) !?zap.incremental_graph.NodeId {
        return self.dependency_graph.getNode(frontendStructSurfaceNodeKey(struct_name));
    }

    pub fn dependencyGraphAffectedFromSourceFile(self: *const FrontendIncrementalState, allocator: std.mem.Allocator, file_path: []const u8) ![]zap.incremental_graph.NodeId {
        const source_id = (try self.dependencyGraphSourceFileNode(file_path)) orelse return error.UnknownIncrementalGraphNode;
        return self.dependency_graph.affectedFrom(allocator, &.{source_id});
    }

    fn parseSourceUnit(
        self: *FrontendIncrementalState,
        unit: SourceUnit,
        source_units: []const SourceUnit,
        source_index: usize,
        source_hash: u64,
        alloc: std.mem.Allocator,
        diag_engine: *zap.DiagnosticEngine,
    ) CompileError!*CachedParsedFile {
        const artifact = self.allocator.create(CachedParsedFile) catch return error.OutOfMemory;
        artifact.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .file_path = &.{},
            .source_hash = source_hash,
            .script_mode = unit.script_mode,
            .primary_struct_name = null,
            .program = .{ .structs = &.{}, .top_items = &.{} },
            .declaration_fingerprints = null,
            .reflection_fingerprints = null,
        };
        errdefer artifact.destroy(self.allocator);

        const artifact_alloc = artifact.arena.allocator();
        artifact.file_path = artifact_alloc.dupe(u8, unit.file_path) catch return error.OutOfMemory;
        artifact.primary_struct_name = if (unit.primary_struct_name) |name|
            artifact_alloc.dupe(u8, name) catch return error.OutOfMemory
        else
            null;

        var parser = zap.Parser.initWithSharedInternerScriptMode(
            artifact_alloc,
            unit.source,
            &self.interner,
            @intCast(source_index),
            unit.script_mode,
        );
        defer parser.deinit();

        artifact.program = parser.parseProgram() catch {
            emitParseErrorsFromUnits(alloc, parser.errors.items, source_units, diag_engine.use_color);
            return error.ParseFailed;
        };

        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }

        artifact.declaration_fingerprints = computeFrontendDeclarationFingerprints(
            artifact_alloc,
            artifact.program,
            unit.source,
            @intCast(source_index),
            &self.interner,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedDeclarationFingerprint => null,
        };
        artifact.reflection_fingerprints = computeFrontendReflectionFingerprints(
            artifact_alloc,
            artifact.program,
            unit.source,
            @intCast(source_index),
            unit.file_path,
            &self.interner,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedDeclarationFingerprint => null,
        };

        return artifact;
    }

    fn computeInvalidatedStructs(
        self: *FrontendIncrementalState,
        alloc: std.mem.Allocator,
        source_units: []const SourceUnit,
        graph: FrontendDependencyGraph,
        dependency_graph: *const zap.incremental_graph.Graph,
        changed_files: []const []const u8,
        changed_declaration_fingerprints: []const FrontendChangedFileFingerprints,
        invalidated_structs: *std.StringHashMap(void),
        changed_declaration_structs: *std.StringHashMap(void),
        changed_graph_roots: *std.ArrayListUnmanaged(zap.incremental_graph.NodeId),
    ) CompileError!void {
        incrementalTrace(
            "frontend-prepare initialized={} changed_files={d} graph_nodes={d} graph_edges={d}",
            .{ self.initialized, changed_files.len, dependency_graph.nodeCount(), dependency_graph.edgeCount() },
        );
        for (changed_files) |file_path| {
            incrementalTrace("changed-file path={s}", .{file_path});
        }

        if (!self.initialized) {
            incrementalTrace("struct-invalidation scope=all reason=initial-build", .{});
            try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
            return;
        }

        if (changed_files.len == 0) {
            incrementalTrace("struct-invalidation scope=none reason=no-source-changes", .{});
            return;
        }

        for (changed_files) |file_path| {
            if (wholeFrontendInvalidationReason(file_path, graph, true)) |reason| {
                incrementalTrace(
                    "struct-invalidation scope=all reason={s} file={s}",
                    .{ @tagName(reason), file_path },
                );
                try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
                return;
            }
        }

        if (try transitiveDependentWholeFrontendInvalidation(alloc, graph, changed_files)) |hit| {
            incrementalTrace(
                "struct-invalidation scope=all reason=transitive-dependent-{s} file={s}",
                .{ @tagName(hit.reason), hit.file_path },
            );
            try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
            return;
        }

        if (allChangedFilesHaveFingerprintBatch(changed_files, changed_declaration_fingerprints)) {
            var precise_roots: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
            defer precise_roots.deinit(alloc);
            var precise_rebuild_structs = std.StringHashMap(void).init(alloc);
            defer precise_rebuild_structs.deinit();
            var precise_struct_surfaces = std.StringHashMap(void).init(alloc);
            defer precise_struct_surfaces.deinit();
            var fallback_source_files: std.ArrayListUnmanaged([]const u8) = .empty;
            defer fallback_source_files.deinit(alloc);

            for (changed_declaration_fingerprints) |file_fingerprints| {
                var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
                    alloc,
                    dependency_graph,
                    file_fingerprints.previous,
                    file_fingerprints.current,
                );
                defer selection.deinit(alloc);

                if (selection.fallback_reason) |reason| {
                    incrementalTrace(
                        "declaration-invalidation fallback reason={s} file={s}",
                        .{ @tagName(reason), file_fingerprints.file_path },
                    );
                    try appendUniqueFilePath(alloc, &fallback_source_files, file_fingerprints.file_path);
                    continue;
                }

                for (selection.roots) |root_id| {
                    try appendUniqueNodeId(alloc, &precise_roots, root_id);
                    const root_key = dependency_graph.nodeKey(root_id) orelse {
                        incrementalTrace(
                            "declaration-invalidation fallback reason=missing-root-node id={d}",
                            .{@intFromEnum(root_id)},
                        );
                        try appendUniqueFilePath(alloc, &fallback_source_files, file_fingerprints.file_path);
                        break;
                    };
                    try addChangedDeclarationStructForNode(alloc, root_key.*, &precise_rebuild_structs);
                    if (root_key.kind() == .struct_surface) {
                        try precise_struct_surfaces.put(root_key.struct_surface.qualified_name, {});
                    }
                    traceIncrementalGraphNode("changed-declaration-root", dependency_graph, root_id);
                }
            }

            if (precise_roots.items.len > 0 or fallback_source_files.items.len > 0) {
                try copyStringSet(&precise_rebuild_structs, changed_declaration_structs);
                var surface_iter = precise_struct_surfaces.iterator();
                while (surface_iter.next()) |entry| {
                    try invalidated_structs.put(entry.key_ptr.*, {});
                    incrementalTrace(
                        "invalidated-struct source=changed-root struct={s}",
                        .{entry.key_ptr.*},
                    );
                }

                if (precise_roots.items.len > 0) {
                    const affected_nodes = try dependency_graph.affectedFrom(alloc, precise_roots.items);
                    defer alloc.free(affected_nodes);
                    if (incrementalTraceEnabled()) {
                        const affected_steps = try dependency_graph.affectedTraceFrom(alloc, precise_roots.items);
                        defer alloc.free(affected_steps);
                        for (affected_steps) |step| {
                            traceIncrementalGraphStep("affected-edge", dependency_graph, step);
                        }
                    }
                    incrementalTrace(
                        "graph-reachability declaration_roots={d} affected_nodes={d}",
                        .{ precise_roots.items.len, affected_nodes.len },
                    );

                    for (affected_nodes) |node_id| {
                        traceIncrementalGraphNode("affected-node", dependency_graph, node_id);
                        const node_key = dependency_graph.nodeKey(node_id) orelse {
                            incrementalTrace(
                                "struct-invalidation scope=all reason=missing-affected-node id={d}",
                                .{@intFromEnum(node_id)},
                            );
                            try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
                            return;
                        };
                        switch (node_key.*) {
                            .struct_surface => |struct_key| {
                                try invalidated_structs.put(struct_key.qualified_name, {});
                                incrementalTrace(
                                    "invalidated-struct source=graph struct={s}",
                                    .{struct_key.qualified_name},
                                );
                            },
                            else => {},
                        }
                    }
                }

                if (fallback_source_files.items.len > 0) {
                    try addSourceGraphInvalidations(
                        alloc,
                        source_units,
                        graph,
                        dependency_graph,
                        fallback_source_files.items,
                        invalidated_structs,
                    );
                }

                for (precise_roots.items) |root_id| {
                    try changed_graph_roots.append(alloc, root_id);
                }
                return;
            }
        } else {
            incrementalTrace(
                "declaration-invalidation fallback reason=missing-changed-fingerprint-batch changed_files={d} fingerprints={d}",
                .{ changed_files.len, changed_declaration_fingerprints.len },
            );
        }

        var changed_source_ids: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
        defer changed_source_ids.deinit(alloc);
        for (changed_files) |file_path| {
            const source_id = (try dependency_graph.getNode(frontendSourceFileNodeKey(file_path))) orelse {
                incrementalTrace(
                    "struct-invalidation scope=all reason=missing-source-node file={s}",
                    .{file_path},
                );
                try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
                return;
            };
            try changed_source_ids.append(alloc, source_id);
            traceIncrementalGraphNode("changed-source-node", dependency_graph, source_id);
        }

        const affected_nodes = try dependency_graph.affectedFrom(alloc, changed_source_ids.items);
        defer alloc.free(affected_nodes);
        if (incrementalTraceEnabled()) {
            const affected_steps = try dependency_graph.affectedTraceFrom(alloc, changed_source_ids.items);
            defer alloc.free(affected_steps);
            for (affected_steps) |step| {
                traceIncrementalGraphStep("affected-edge", dependency_graph, step);
            }
        }
        incrementalTrace(
            "graph-reachability source_nodes={d} affected_nodes={d}",
            .{ changed_source_ids.items.len, affected_nodes.len },
        );

        for (affected_nodes) |node_id| {
            traceIncrementalGraphNode("affected-node", dependency_graph, node_id);
            const node_key = dependency_graph.nodeKey(node_id) orelse {
                incrementalTrace(
                    "struct-invalidation scope=all reason=missing-affected-node id={d}",
                    .{@intFromEnum(node_id)},
                );
                try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
                return;
            };
            switch (node_key.*) {
                .struct_surface => |struct_key| {
                    try invalidated_structs.put(struct_key.qualified_name, {});
                    incrementalTrace(
                        "invalidated-struct source=graph struct={s}",
                        .{struct_key.qualified_name},
                    );
                },
                else => {},
            }
        }
    }
};

pub const FrontendIncrementalPrepared = struct {
    state: *FrontendIncrementalState,
    result: CompileResult,
    invalidated_struct_names: []const []const u8,
    changed_struct_names: []const []const u8,
    changed_graph_roots: []const zap.incremental_graph.NodeId,
    new_parsed_files: []const *FrontendIncrementalState.CachedParsedFile,
    new_expanded_structs: []const *FrontendIncrementalState.CachedExpandedStruct,
    new_expanded_top_level: ?*FrontendIncrementalState.CachedExpandedTopLevel,
    clear_expanded_top_level: bool,
    new_final_arena: std.heap.ArenaAllocator,
    new_final_program: ir.Program,
    new_dependency_graph: zap.incremental_graph.Graph,
    new_inventory_arena: std.heap.ArenaAllocator,
    new_compile_after_inventory_fingerprints: std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
    committed: bool = false,

    pub fn commit(self: *FrontendIncrementalPrepared) !void {
        try self.state.parsed_files.ensureUnusedCapacity(@intCast(self.new_parsed_files.len));
        try self.state.expanded_structs.ensureUnusedCapacity(@intCast(self.new_expanded_structs.len));

        for (self.new_parsed_files) |parsed| {
            if (self.state.parsed_files.fetchRemove(parsed.file_path)) |old| {
                old.value.destroy(self.state.allocator);
            }
            try self.state.parsed_files.put(parsed.file_path, parsed);
        }

        for (self.new_expanded_structs) |expanded| {
            if (self.state.expanded_structs.fetchRemove(expanded.name)) |old| {
                old.value.destroy(self.state.allocator);
            }
            try self.state.expanded_structs.put(expanded.name, expanded);
        }

        if (self.new_expanded_top_level) |expanded_top_level| {
            if (self.state.expanded_top_level) |old| old.destroy(self.state.allocator);
            self.state.expanded_top_level = expanded_top_level;
        } else if (self.clear_expanded_top_level) {
            if (self.state.expanded_top_level) |old| old.destroy(self.state.allocator);
            self.state.expanded_top_level = null;
        }

        if (self.state.final_arena) |*arena| arena.deinit();
        self.state.final_arena = self.new_final_arena;
        self.state.final_program = self.new_final_program;

        self.state.dependency_graph.deinit();
        self.state.dependency_graph = self.new_dependency_graph;
        self.state.compile_after_inventory_fingerprints.deinit();
        self.state.inventory_fingerprints_arena.deinit();
        self.state.inventory_fingerprints_arena = self.new_inventory_arena;
        self.state.compile_after_inventory_fingerprints = self.new_compile_after_inventory_fingerprints;
        self.state.initialized = true;
        self.committed = true;
    }

    pub fn deinit(self: *FrontendIncrementalPrepared) void {
        if (self.committed) return;
        destroyCachedParsedFiles(self.state.allocator, self.new_parsed_files);
        destroyCachedExpandedStructs(self.state.allocator, self.new_expanded_structs);
        if (self.new_expanded_top_level) |expanded_top_level| expanded_top_level.destroy(self.state.allocator);
        self.new_final_arena.deinit();
        self.new_dependency_graph.deinit();
        self.new_compile_after_inventory_fingerprints.deinit();
        self.new_inventory_arena.deinit();
    }
};

const FrontendChangedFileFingerprints = struct {
    file_path: []const u8,
    previous: ?zap.incremental_graph.DeclarationFingerprintSet,
    current: ?zap.incremental_graph.DeclarationFingerprintSet,
};

const ExpansionCacheWork = struct {
    state: *FrontendIncrementalState,
    invalidated_structs: *const std.StringHashMap(void),
    changed_declaration_structs: *const std.StringHashMap(void),
    new_expanded_structs: *std.ArrayListUnmanaged(*FrontendIncrementalState.CachedExpandedStruct),
    new_expanded_top_level: *?*FrontendIncrementalState.CachedExpandedTopLevel,
    has_unassigned_top_level_items: bool = false,
};

const StagedExpansionResult = struct {
    program: ast.Program,
    cache_hit: bool,
};

fn destroyCachedParsedFiles(
    allocator: std.mem.Allocator,
    parsed_files: []const *FrontendIncrementalState.CachedParsedFile,
) void {
    for (parsed_files) |parsed| parsed.destroy(allocator);
}

fn destroyCachedExpandedStructs(
    allocator: std.mem.Allocator,
    expanded_structs: []const *FrontendIncrementalState.CachedExpandedStruct,
) void {
    for (expanded_structs) |expanded| expanded.destroy(allocator);
}

fn hashSourceBytes(source: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(source);
    return hasher.final();
}

const FrontendFingerprintBuildError = std.mem.Allocator.Error || error{
    UnsupportedDeclarationFingerprint,
};

fn computeFrontendDeclarationFingerprints(
    alloc: std.mem.Allocator,
    program: ast.Program,
    source: []const u8,
    source_id: u32,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.DeclarationFingerprintSet {
    var records: std.ArrayListUnmanaged(zap.incremental_graph.DeclarationFingerprint) = .empty;
    errdefer records.deinit(alloc);

    for (program.structs) |*struct_decl| {
        const struct_name = try structNameToOwnedString(alloc, struct_decl.name, interner);
        const struct_key = zap.incremental_graph.NodeKey{ .struct_surface = .{
            .package = frontendPackageKey(),
            .qualified_name = struct_name,
        } };
        try records.append(alloc, .{
            .key = struct_key,
            .kind = .struct_surface,
            .digest = try fingerprintStructSurface(struct_decl, source, source_id, interner),
        });

        const owner = zap.incremental_graph.DeclarationOwnerKey{
            .package = frontendPackageKey(),
            .kind = .@"struct",
            .qualified_name = struct_name,
        };
        try appendStructFunctionDeclarationFingerprints(alloc, &records, struct_decl, owner, source, source_id, interner);
    }

    var top_function_groups: FunctionFingerprintGroups = .{};
    defer top_function_groups.deinit(alloc);

    for (program.top_items) |item| {
        switch (item) {
            .function => |function_decl| try top_function_groups.append(
                alloc,
                function_decl,
                frontendPackageOwnerKey(),
                .free,
                source,
                source_id,
                interner,
            ),
            .priv_function => |function_decl| try top_function_groups.append(
                alloc,
                function_decl,
                frontendPackageOwnerKey(),
                .free,
                source,
                source_id,
                interner,
            ),
            .impl_decl => |impl_decl| try appendImplFunctionDeclarationFingerprints(
                alloc,
                &records,
                impl_decl,
                source,
                source_id,
                interner,
            ),
            .priv_impl_decl => |impl_decl| try appendImplFunctionDeclarationFingerprints(
                alloc,
                &records,
                impl_decl,
                source,
                source_id,
                interner,
            ),
            else => {},
        }
    }
    try top_function_groups.appendRecords(alloc, &records);

    return .{
        .root_glue = null,
        .records = try records.toOwnedSlice(alloc),
    };
}

fn computeFrontendReflectionFingerprints(
    alloc: std.mem.Allocator,
    program: ast.Program,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.DeclarationFingerprintSet {
    var records: std.ArrayListUnmanaged(zap.incremental_graph.DeclarationFingerprint) = .empty;
    errdefer records.deinit(alloc);

    for (program.structs) |*struct_decl| {
        const struct_name = try structNameToOwnedString(alloc, struct_decl.name, interner);
        try records.append(alloc, .{
            .key = frontendStructReflectionNodeKey(struct_name),
            .kind = .ctfe_reflection,
            .digest = try fingerprintReflectedMetadata(alloc, program, struct_decl, source, source_id, file_path, interner),
        });
    }

    return .{
        .root_glue = null,
        .records = try records.toOwnedSlice(alloc),
    };
}

fn appendStructFunctionDeclarationFingerprints(
    alloc: std.mem.Allocator,
    records: *std.ArrayListUnmanaged(zap.incremental_graph.DeclarationFingerprint),
    struct_decl: *const ast.StructDecl,
    owner: zap.incremental_graph.DeclarationOwnerKey,
    source: []const u8,
    source_id: u32,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    var groups: FunctionFingerprintGroups = .{};
    defer groups.deinit(alloc);

    for (struct_decl.items) |item| {
        switch (item) {
            .function => |function_decl| try groups.append(
                alloc,
                function_decl,
                owner,
                .struct_method,
                source,
                source_id,
                interner,
            ),
            .priv_function => |function_decl| try groups.append(
                alloc,
                function_decl,
                owner,
                .struct_method,
                source,
                source_id,
                interner,
            ),
            else => {},
        }
    }

    try groups.appendRecords(alloc, records);
}

fn appendImplFunctionDeclarationFingerprints(
    alloc: std.mem.Allocator,
    records: *std.ArrayListUnmanaged(zap.incremental_graph.DeclarationFingerprint),
    impl_decl: *const ast.ImplDecl,
    source: []const u8,
    source_id: u32,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    const target_name = try structNameToOwnedString(alloc, impl_decl.target_type, interner);
    const owner = zap.incremental_graph.DeclarationOwnerKey{
        .package = frontendPackageKey(),
        .kind = .@"struct",
        .qualified_name = target_name,
    };

    var groups: FunctionFingerprintGroups = .{};
    defer groups.deinit(alloc);

    for (impl_decl.functions) |function_decl| {
        try groups.append(
            alloc,
            function_decl,
            owner,
            .struct_method,
            source,
            source_id,
            interner,
        );
    }

    try groups.appendRecords(alloc, records);
}

const FunctionFingerprintGroup = struct {
    key: zap.incremental_graph.FunctionKey,
    signature_hasher: zap.incremental_graph.StableHasher,
    body_hasher: zap.incremental_graph.StableHasher,
    declaration_count: u64 = 0,
    clause_count: u64 = 0,

    fn init(key: zap.incremental_graph.FunctionKey) FunctionFingerprintGroup {
        var signature_hasher = zap.incremental_graph.StableHasher.init(.function_signature_fingerprint);
        appendFunctionFingerprintGroupKey(&signature_hasher, key);
        var body_hasher = zap.incremental_graph.StableHasher.init(.function_body_fingerprint);
        appendFunctionFingerprintGroupKey(&body_hasher, key);
        return .{
            .key = key,
            .signature_hasher = signature_hasher,
            .body_hasher = body_hasher,
        };
    }

    fn appendDeclaration(
        self: *FunctionFingerprintGroup,
        function_decl: *const ast.FunctionDecl,
        source: []const u8,
        source_id: u32,
        interner: *const ast.StringInterner,
    ) FrontendFingerprintBuildError!void {
        self.declaration_count += 1;
        self.signature_hasher.appendEnum(function_decl.visibility);
        self.signature_hasher.appendBytes(interner.get(function_decl.name));
        try appendOptionalExprSpan(&self.signature_hasher, function_decl.name_expr, source, source_id);
        self.signature_hasher.appendInt(u64, function_decl.clauses.len);

        self.body_hasher.appendInt(u64, function_decl.clauses.len);
        for (function_decl.clauses) |clause| {
            self.clause_count += 1;
            self.signature_hasher.appendInt(u64, clause.params.len);
            for (clause.params) |param| {
                self.signature_hasher.appendEnum(param.ownership);
                self.signature_hasher.appendBool(param.ownership_explicit);
                try appendPatternSpan(&self.signature_hasher, param.pattern, source, source_id);
                try appendOptionalTypeExprSpan(&self.signature_hasher, param.type_annotation, source, source_id);
                try appendOptionalExprSpan(&self.signature_hasher, param.default, source, source_id);
            }
            try appendOptionalTypeExprSpan(&self.signature_hasher, clause.return_type, source, source_id);

            try appendOptionalExprSpan(&self.body_hasher, clause.refinement, source, source_id);
            if (clause.body) |statements| {
                self.body_hasher.appendBool(true);
                self.body_hasher.appendInt(u64, statements.len);
                for (statements) |statement| {
                    self.body_hasher.appendEnum(std.meta.activeTag(statement));
                    try appendSourceSpan(&self.body_hasher, stmtSourceSpan(statement), source, source_id);
                }
            } else {
                self.body_hasher.appendBool(false);
            }
        }
    }

    fn signatureDigest(self: *FunctionFingerprintGroup) zap.incremental_graph.StableDigest {
        self.signature_hasher.appendInt(u64, self.declaration_count);
        self.signature_hasher.appendInt(u64, self.clause_count);
        return self.signature_hasher.final();
    }

    fn bodyDigest(self: *FunctionFingerprintGroup) zap.incremental_graph.StableDigest {
        self.body_hasher.appendInt(u64, self.declaration_count);
        self.body_hasher.appendInt(u64, self.clause_count);
        return self.body_hasher.final();
    }
};

const FunctionFingerprintGroups = struct {
    items: std.ArrayListUnmanaged(FunctionFingerprintGroup) = .empty,

    fn deinit(self: *FunctionFingerprintGroups, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }

    fn append(
        self: *FunctionFingerprintGroups,
        alloc: std.mem.Allocator,
        function_decl: *const ast.FunctionDecl,
        owner: zap.incremental_graph.DeclarationOwnerKey,
        declaration_kind: zap.incremental_graph.FunctionDeclarationKind,
        source: []const u8,
        source_id: u32,
        interner: *const ast.StringInterner,
    ) FrontendFingerprintBuildError!void {
        const function_key = try frontendAstFunctionKey(alloc, function_decl, owner, declaration_kind, interner);
        const group = try self.getOrAppend(alloc, function_key);
        try group.appendDeclaration(function_decl, source, source_id, interner);
    }

    fn appendRecords(
        self: *FunctionFingerprintGroups,
        alloc: std.mem.Allocator,
        records: *std.ArrayListUnmanaged(zap.incremental_graph.DeclarationFingerprint),
    ) !void {
        for (self.items.items) |*group| {
            try records.append(alloc, .{
                .key = .{ .function_signature = group.key },
                .kind = .function_signature,
                .digest = group.signatureDigest(),
            });
            try records.append(alloc, .{
                .key = .{ .function_body = group.key },
                .kind = .function_body,
                .digest = group.bodyDigest(),
            });
        }
    }

    fn getOrAppend(
        self: *FunctionFingerprintGroups,
        alloc: std.mem.Allocator,
        function_key: zap.incremental_graph.FunctionKey,
    ) !*FunctionFingerprintGroup {
        for (self.items.items) |*group| {
            if (zap.incremental_graph.FunctionKey.eql(group.key, function_key)) return group;
        }
        try self.items.append(alloc, FunctionFingerprintGroup.init(function_key));
        return &self.items.items[self.items.items.len - 1];
    }
};

fn appendFunctionFingerprintGroupKey(
    hasher: *zap.incremental_graph.StableHasher,
    key: zap.incremental_graph.FunctionKey,
) void {
    key.appendStableHash(hasher);
}

fn frontendPackageOwnerKey() zap.incremental_graph.DeclarationOwnerKey {
    return .{
        .package = frontendPackageKey(),
        .kind = .package,
        .qualified_name = "",
    };
}

fn frontendAstFunctionKey(
    alloc: std.mem.Allocator,
    function_decl: *const ast.FunctionDecl,
    owner: zap.incremental_graph.DeclarationOwnerKey,
    declaration_kind: zap.incremental_graph.FunctionDeclarationKind,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.FunctionKey {
    const arity = try functionDeclArity(function_decl);
    const raw_name = interner.get(function_decl.name);
    const mangled_name = try ir.mangleSymbolForZig(alloc, raw_name);
    const local_name = try std.fmt.allocPrint(alloc, "{s}__{d}", .{ mangled_name, arity });
    return .{
        .owner = owner,
        .declaration_kind = declaration_kind,
        .local_name = local_name,
        .arity = arity,
        .clause_index = 0,
        .specialization = null,
    };
}

fn functionDeclArity(function_decl: *const ast.FunctionDecl) error{UnsupportedDeclarationFingerprint}!u16 {
    if (function_decl.clauses.len == 0) return 0;
    return std.math.cast(u16, function_decl.clauses[0].params.len) orelse error.UnsupportedDeclarationFingerprint;
}

fn fingerprintStructSurface(
    struct_decl: *const ast.StructDecl,
    source: []const u8,
    source_id: u32,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.StableDigest {
    var hasher = zap.incremental_graph.StableHasher.init(.struct_surface_fingerprint);
    hasher.appendBool(struct_decl.is_private);
    appendStructName(&hasher, struct_decl.name, interner);
    hasher.appendBool(struct_decl.parent != null);
    if (struct_decl.parent) |parent| hasher.appendBytes(interner.get(parent));

    hasher.appendInt(u64, struct_decl.fields.len);
    for (struct_decl.fields) |field| {
        hasher.appendBytes(interner.get(field.name));
        try appendTypeExprSpan(&hasher, field.type_expr, source, source_id);
        try appendOptionalExprSpan(&hasher, field.default, source, source_id);
    }

    hasher.appendInt(u64, struct_decl.items.len);
    for (struct_decl.items) |item| {
        hasher.appendEnum(std.meta.activeTag(item));
        switch (item) {
            .function, .priv_function => |function_decl| try appendFunctionSurface(&hasher, function_decl, interner),
            else => try appendSourceSpan(&hasher, structItemSourceSpan(item), source, source_id),
        }
    }

    return hasher.final();
}

fn fingerprintFunctionSignature(
    function_decl: *const ast.FunctionDecl,
    source: []const u8,
    source_id: u32,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.StableDigest {
    var hasher = zap.incremental_graph.StableHasher.init(.function_signature_fingerprint);
    hasher.appendEnum(function_decl.visibility);
    hasher.appendBytes(interner.get(function_decl.name));
    try appendOptionalExprSpan(&hasher, function_decl.name_expr, source, source_id);
    hasher.appendInt(u64, function_decl.clauses.len);
    for (function_decl.clauses) |clause| {
        hasher.appendInt(u64, clause.params.len);
        for (clause.params) |param| {
            hasher.appendEnum(param.ownership);
            hasher.appendBool(param.ownership_explicit);
            try appendPatternSpan(&hasher, param.pattern, source, source_id);
            try appendOptionalTypeExprSpan(&hasher, param.type_annotation, source, source_id);
            try appendOptionalExprSpan(&hasher, param.default, source, source_id);
        }
        try appendOptionalTypeExprSpan(&hasher, clause.return_type, source, source_id);
    }
    return hasher.final();
}

fn fingerprintFunctionBody(
    function_decl: *const ast.FunctionDecl,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!zap.incremental_graph.StableDigest {
    var hasher = zap.incremental_graph.StableHasher.init(.function_body_fingerprint);
    hasher.appendInt(u64, function_decl.clauses.len);
    for (function_decl.clauses) |clause| {
        try appendOptionalExprSpan(&hasher, clause.refinement, source, source_id);
        if (clause.body) |statements| {
            hasher.appendBool(true);
            hasher.appendInt(u64, statements.len);
            for (statements) |statement| {
                hasher.appendEnum(std.meta.activeTag(statement));
                try appendSourceSpan(&hasher, stmtSourceSpan(statement), source, source_id);
            }
        } else {
            hasher.appendBool(false);
        }
    }
    return hasher.final();
}

fn fingerprintReflectedMetadata(
    alloc: std.mem.Allocator,
    program: ast.Program,
    struct_decl: *const ast.StructDecl,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!zap.incremental_graph.StableDigest {
    var hasher = zap.incremental_graph.StableHasher.init(.ctfe_reflection_fingerprint);
    hasher.appendBytes("struct_surface");
    hasher.appendDigest(try fingerprintStructSurface(struct_decl, source, source_id, interner));
    try appendReflectedStructInfo(alloc, &hasher, program.top_items, struct_decl, source, source_id, file_path, interner);
    try appendReflectedStructFunctions(alloc, &hasher, struct_decl, source, source_id, file_path, interner);
    try appendReflectedStructMacros(alloc, &hasher, struct_decl, source, source_id, file_path, interner);
    try appendReflectedNestedUnions(alloc, &hasher, struct_decl, file_path, interner);
    try appendReflectedFileInventory(alloc, &hasher, program, file_path, interner);
    return hasher.final();
}

fn appendReflectedStructInfo(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    top_items: []const ast.TopItem,
    struct_decl: *const ast.StructDecl,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("struct_info");
    appendStructName(hasher, struct_decl.name, interner);
    hasher.appendBytes(file_path);
    hasher.appendBool(struct_decl.is_private);
    _ = source;
    _ = source_id;
    try appendDocAttributeText(alloc, hasher, topLevelStructDocAttribute(top_items, struct_decl, interner), interner);
    try appendDocAttributeText(alloc, hasher, trailingStructDocAttribute(struct_decl, interner), interner);
}

fn appendReflectedStructFunctions(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    struct_decl: *const ast.StructDecl,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("struct_functions");
    hasher.appendInt(u64, reflectedPublicFunctionCount(struct_decl));

    var pending_doc: ?*const ast.AttributeDecl = null;
    for (struct_decl.items) |item| {
        switch (item) {
            .attribute => |attribute| updatePendingDocAttribute(&pending_doc, attribute, interner),
            .function => |function_decl| {
                try appendReflectedCallable(alloc, hasher, "function", function_decl, pending_doc, source, source_id, file_path, interner);
                pending_doc = null;
            },
            .priv_function => {
                pending_doc = null;
            },
            .macro, .priv_macro => {
                pending_doc = null;
            },
            else => {},
        }
    }
}

fn appendReflectedStructMacros(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    struct_decl: *const ast.StructDecl,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("struct_macros");
    hasher.appendInt(u64, reflectedPublicMacroCount(struct_decl, interner));

    var pending_doc: ?*const ast.AttributeDecl = null;
    for (struct_decl.items) |item| {
        switch (item) {
            .attribute => |attribute| updatePendingDocAttribute(&pending_doc, attribute, interner),
            .macro => |macro_decl| {
                const macro_name = interner.get(macro_decl.name);
                if (!std.mem.startsWith(u8, macro_name, "__")) {
                    try appendReflectedCallable(alloc, hasher, "macro", macro_decl, pending_doc, source, source_id, file_path, interner);
                }
                pending_doc = null;
            },
            .priv_macro => {
                pending_doc = null;
            },
            .function, .priv_function => {
                pending_doc = null;
            },
            else => {},
        }
    }
}

fn appendReflectedCallable(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    kind: []const u8,
    function_decl: *const ast.FunctionDecl,
    doc_attribute: ?*const ast.AttributeDecl,
    source: []const u8,
    source_id: u32,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes(kind);
    hasher.appendBytes(interner.get(function_decl.name));
    hasher.appendInt(u16, try functionDeclArity(function_decl));
    hasher.appendEnum(function_decl.visibility);
    try appendDocAttributeText(alloc, hasher, doc_attribute, interner);
    hasher.appendBytes(file_path);
    try appendSourceSpanLineNumber(hasher, function_decl.meta.span, source, source_id);
    const signature_digest = try fingerprintFunctionSignature(function_decl, source, source_id, interner);
    hasher.appendDigest(signature_digest);
}

fn appendReflectedNestedUnions(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    struct_decl: *const ast.StructDecl,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("nested_unions");
    hasher.appendInt(u64, reflectedNestedUnionCount(struct_decl));
    for (struct_decl.items) |item| {
        switch (item) {
            .union_decl => |union_decl| try appendReflectedUnion(alloc, hasher, union_decl, null, file_path, interner),
            else => {},
        }
    }
}

fn appendReflectedFileInventory(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    program: ast.Program,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("source_graph_inventory");
    hasher.appendBytes(file_path);
    hasher.appendInt(u64, reflectedTopItemCount(program.top_items));

    var pending_doc: ?*const ast.AttributeDecl = null;
    for (program.top_items) |item| {
        switch (item) {
            .attribute => |attribute| updatePendingDocAttribute(&pending_doc, attribute, interner),
            .struct_decl, .priv_struct_decl => |decl| {
                hasher.appendBytes("source_graph_struct");
                appendStructName(hasher, decl.name, interner);
                hasher.appendBool(decl.is_private);
                pending_doc = null;
            },
            .protocol, .priv_protocol => |decl| {
                try appendReflectedProtocol(alloc, hasher, decl, pending_doc, file_path, interner);
                pending_doc = null;
            },
            .union_decl => |decl| {
                try appendReflectedUnion(alloc, hasher, decl, pending_doc, file_path, interner);
                pending_doc = null;
            },
            .impl_decl, .priv_impl_decl => |decl| {
                try appendReflectedImpl(alloc, hasher, decl, file_path, interner);
                pending_doc = null;
            },
            .function, .priv_function, .macro, .priv_macro, .type_decl, .opaque_decl => {
                pending_doc = null;
            },
            .error_decl, .priv_error_decl => {
                // `pub error` desugars to `pub struct + pub impl Error` in
                // `src/desugar.zig` before any reflective traversal of the
                // top-level item list. Seeing one here is a wiring bug.
                @panic("incremental fingerprint saw an ErrorDecl that should have been desugared");
            },
        }
    }
}

fn appendReflectedProtocol(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    protocol_decl: *const ast.ProtocolDecl,
    doc_attribute: ?*const ast.AttributeDecl,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("protocol");
    appendStructName(hasher, protocol_decl.name, interner);
    hasher.appendBytes(file_path);
    hasher.appendBool(protocol_decl.is_private);
    try appendDocAttributeText(alloc, hasher, doc_attribute, interner);
    hasher.appendInt(u64, protocol_decl.type_params.len);
    for (protocol_decl.type_params) |type_param| hasher.appendBytes(interner.get(type_param));
    hasher.appendInt(u64, protocol_decl.functions.len);
    for (protocol_decl.functions) |function_sig| {
        hasher.appendBytes(interner.get(function_sig.name));
        hasher.appendBytes(zap.signature.buildProtocolFunctionSignature(alloc, function_sig, interner));
    }
}

fn appendReflectedUnion(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    union_decl: *const ast.UnionDecl,
    doc_attribute: ?*const ast.AttributeDecl,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("union");
    hasher.appendBytes(interner.get(union_decl.name));
    hasher.appendBytes(file_path);
    hasher.appendBool(union_decl.is_private);
    try appendDocAttributeText(alloc, hasher, doc_attribute, interner);
    hasher.appendInt(u64, union_decl.variants.len);
    for (union_decl.variants) |variant| {
        hasher.appendBytes(interner.get(variant.name));
        hasher.appendBytes(zap.signature.buildUnionVariantSignature(alloc, variant, interner));
    }
}

fn appendReflectedImpl(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    impl_decl: *const ast.ImplDecl,
    file_path: []const u8,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    hasher.appendBytes("impl");
    appendStructName(hasher, impl_decl.protocol_name, interner);
    appendStructName(hasher, impl_decl.target_type, interner);
    hasher.appendBytes(file_path);
    hasher.appendBool(impl_decl.is_private);
    hasher.appendInt(u64, impl_decl.type_params.len);
    for (impl_decl.type_params) |type_param| hasher.appendBytes(interner.get(type_param));
    hasher.appendInt(u64, impl_decl.protocol_type_args.len);
    for (impl_decl.protocol_type_args) |type_arg| {
        var buffer = zap.signature.Buffer.init(alloc);
        zap.signature.appendTypeExpr(&buffer, type_arg, interner);
        hasher.appendBytes(buffer.toSlice());
    }
}

fn reflectedPublicFunctionCount(struct_decl: *const ast.StructDecl) u64 {
    var count: u64 = 0;
    for (struct_decl.items) |item| {
        switch (item) {
            .function => count += 1,
            else => {},
        }
    }
    return count;
}

fn reflectedPublicMacroCount(struct_decl: *const ast.StructDecl, interner: *const ast.StringInterner) u64 {
    var count: u64 = 0;
    for (struct_decl.items) |item| {
        switch (item) {
            .macro => |macro_decl| {
                if (!std.mem.startsWith(u8, interner.get(macro_decl.name), "__")) count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn reflectedNestedUnionCount(struct_decl: *const ast.StructDecl) u64 {
    var count: u64 = 0;
    for (struct_decl.items) |item| {
        switch (item) {
            .union_decl => count += 1,
            else => {},
        }
    }
    return count;
}

fn reflectedTopItemCount(top_items: []const ast.TopItem) u64 {
    var count: u64 = 0;
    for (top_items) |item| {
        switch (item) {
            .struct_decl,
            .priv_struct_decl,
            .protocol,
            .priv_protocol,
            .union_decl,
            .impl_decl,
            .priv_impl_decl,
            => count += 1,
            else => {},
        }
    }
    return count;
}

fn updatePendingDocAttribute(
    pending_doc: *?*const ast.AttributeDecl,
    attribute: *const ast.AttributeDecl,
    interner: *const ast.StringInterner,
) void {
    if (pending_doc.* != null) return;
    if (std.mem.eql(u8, interner.get(attribute.name), "doc")) {
        pending_doc.* = attribute;
    }
}

fn topLevelStructDocAttribute(
    top_items: []const ast.TopItem,
    struct_decl: *const ast.StructDecl,
    interner: *const ast.StringInterner,
) ?*const ast.AttributeDecl {
    var pending_doc: ?*const ast.AttributeDecl = null;
    for (top_items) |item| {
        switch (item) {
            .attribute => |attribute| updatePendingDocAttribute(&pending_doc, attribute, interner),
            .struct_decl, .priv_struct_decl => |decl| {
                if (sameStructDeclIdentity(decl, struct_decl)) return pending_doc;
                pending_doc = null;
            },
            .protocol,
            .priv_protocol,
            .union_decl,
            .impl_decl,
            .priv_impl_decl,
            .function,
            .priv_function,
            .macro,
            .priv_macro,
            .type_decl,
            .opaque_decl,
            => pending_doc = null,
            .error_decl, .priv_error_decl => {
                // Desugar runs before this scan; an ErrorDecl here is a wiring bug.
                @panic("topLevelStructDocAttribute saw an ErrorDecl that should have been desugared");
            },
        }
    }
    return null;
}

fn trailingStructDocAttribute(
    struct_decl: *const ast.StructDecl,
    interner: *const ast.StringInterner,
) ?*const ast.AttributeDecl {
    var pending_doc: ?*const ast.AttributeDecl = null;
    var saw_pending_after_callable = false;
    for (struct_decl.items) |item| {
        switch (item) {
            .attribute => |attribute| {
                updatePendingDocAttribute(&pending_doc, attribute, interner);
                saw_pending_after_callable = true;
            },
            .function, .priv_function, .macro, .priv_macro => {
                pending_doc = null;
                saw_pending_after_callable = false;
            },
            else => {},
        }
    }
    return if (saw_pending_after_callable) pending_doc else null;
}

fn sameStructDeclIdentity(left: *const ast.StructDecl, right: *const ast.StructDecl) bool {
    return structNameIdsEqual(left.name, right.name) and
        left.meta.span.start == right.meta.span.start and
        left.meta.span.end == right.meta.span.end and
        left.meta.span.source_id == right.meta.span.source_id;
}

fn structNameIdsEqual(left: ast.StructName, right: ast.StructName) bool {
    if (left.parts.len != right.parts.len) return false;
    for (left.parts, right.parts) |left_part, right_part| {
        if (left_part != right_part) return false;
    }
    return true;
}

fn appendDocAttributeText(
    alloc: std.mem.Allocator,
    hasher: *zap.incremental_graph.StableHasher,
    attribute: ?*const ast.AttributeDecl,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError!void {
    const doc_text = try docAttributeText(alloc, attribute, interner);
    hasher.appendBytes(doc_text);
}

fn docAttributeText(
    alloc: std.mem.Allocator,
    attribute: ?*const ast.AttributeDecl,
    interner: *const ast.StringInterner,
) FrontendFingerprintBuildError![]const u8 {
    const attr = attribute orelse return "";
    const expr = attr.value orelse return "";
    if (expr.* != .string_literal) return "";
    return try stripHeredocCommonIndentForFingerprint(alloc, interner.get(expr.string_literal.value));
}

fn stripHeredocCommonIndentForFingerprint(
    alloc: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitSequence(u8, text, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var indent: usize = 0;
        for (line) |char| {
            if (char == ' ') {
                indent += 1;
            } else if (char == '\t') {
                indent += 4;
            } else break;
        }
        if (indent < min_indent) min_indent = indent;
    }

    if (min_indent == 0 or min_indent == std.math.maxInt(usize)) {
        return try alloc.dupe(u8, text);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitSequence(u8, text, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var to_strip = min_indent;
        var start: usize = 0;
        while (start < line.len and to_strip > 0) {
            if (line[start] == ' ') {
                to_strip -= 1;
                start += 1;
            } else if (line[start] == '\t') {
                if (to_strip >= 4) {
                    to_strip -= 4;
                } else {
                    to_strip = 0;
                }
                start += 1;
            } else break;
        }
        try out.appendSlice(alloc, line[start..]);
    }
    return try out.toOwnedSlice(alloc);
}

fn appendSourceSpanLineNumber(
    hasher: *zap.incremental_graph.StableHasher,
    span: ast.SourceSpan,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    if (span.source_id == null or span.source_id.? != source_id) return error.UnsupportedDeclarationFingerprint;
    if (span.start > source.len) return error.UnsupportedDeclarationFingerprint;
    hasher.appendInt(u32, lineNumberFromSourceOffset(source, span.start));
}

fn lineNumberFromSourceOffset(source: []const u8, offset: u32) u32 {
    if (offset > source.len) return 0;
    var line: u32 = 1;
    var index: usize = 0;
    while (index < offset) : (index += 1) {
        if (source[index] == '\n') line += 1;
    }
    return line;
}

fn buildCompileAfterInventoryFingerprints(
    alloc: std.mem.Allocator,
    graph: FrontendDependencyGraph,
    out: *std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
) CompileError!void {
    var iter = graph.file_compile_after_globs.iterator();
    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const owned_file_path = try alloc.dupe(u8, file_path);
        const records = try alloc.alloc(zap.incremental_graph.DeclarationFingerprint, 1);
        records[0] = .{
            .key = frontendCompileAfterGlobNodeKey(owned_file_path),
            .kind = .ctfe_glob,
            .digest = try fingerprintCompileAfterInventory(
                graph,
                file_path,
                entry.value_ptr.*,
                graph.file_compile_after_files.get(file_path) orelse &.{},
            ),
        };
        try out.put(owned_file_path, .{
            .root_glue = null,
            .records = records,
        });
    }
}

fn fingerprintCompileAfterInventory(
    graph: FrontendDependencyGraph,
    file_path: []const u8,
    patterns: []const []const u8,
    matched_files: []const []const u8,
) CompileError!zap.incremental_graph.StableDigest {
    var hasher = zap.incremental_graph.StableHasher.init(.ctfe_glob_fingerprint);
    hasher.appendBytes(file_path);
    hasher.appendInt(u64, patterns.len);
    for (patterns) |pattern| hasher.appendBytes(pattern);

    hasher.appendInt(u64, matched_files.len);
    for (matched_files) |matched_file| {
        hasher.appendBytes(matched_file);
        const structs = graph.file_to_structs.get(matched_file) orelse &.{};
        hasher.appendInt(u64, structs.len);
        for (structs) |struct_name| hasher.appendBytes(struct_name);
    }
    return hasher.final();
}

fn appendCompileAfterInventoryFingerprintChanges(
    alloc: std.mem.Allocator,
    graph: FrontendDependencyGraph,
    previous: *const std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
    current: *const std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
    changed_files: *std.ArrayListUnmanaged([]const u8),
    changed_declaration_fingerprints: *std.ArrayListUnmanaged(FrontendChangedFileFingerprints),
) CompileError!void {
    _ = graph;
    var current_iter = current.iterator();
    while (current_iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const previous_set = previous.get(file_path);
        if (previous_set) |some_previous| {
            if (declarationFingerprintSetsEqual(some_previous, entry.value_ptr.*)) continue;
        }
        try appendUniqueFilePath(alloc, changed_files, file_path);
        try changed_declaration_fingerprints.append(alloc, .{
            .file_path = file_path,
            .previous = previous_set,
            .current = entry.value_ptr.*,
        });
    }

    var previous_iter = previous.iterator();
    while (previous_iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        if (current.contains(file_path)) continue;
        try appendUniqueFilePath(alloc, changed_files, file_path);
        try changed_declaration_fingerprints.append(alloc, .{
            .file_path = file_path,
            .previous = entry.value_ptr.*,
            .current = null,
        });
    }
}

fn augmentFrontendGraphWithInventoryFingerprints(
    dependency_graph: *zap.incremental_graph.Graph,
    inventory_fingerprints: *const std.StringHashMap(zap.incremental_graph.DeclarationFingerprintSet),
) CompileError!void {
    var iter = inventory_fingerprints.iterator();
    while (iter.next()) |entry| {
        const sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{entry.value_ptr.*};
        try augmentFrontendGraphWithDeclarationFingerprints(dependency_graph, &sets);
    }
}

fn declarationFingerprintSetsEqual(
    left: zap.incremental_graph.DeclarationFingerprintSet,
    right: zap.incremental_graph.DeclarationFingerprintSet,
) bool {
    if (!optionalDigestEqual(left.root_glue, right.root_glue)) return false;
    if (left.records.len != right.records.len) return false;
    for (left.records, right.records) |left_record, right_record| {
        if (left_record.kind != right_record.kind) return false;
        if (!zap.incremental_graph.NodeKey.eql(left_record.key, right_record.key)) return false;
        if (!std.mem.eql(u8, left_record.digest[0..], right_record.digest[0..])) return false;
    }
    return true;
}

fn optionalDigestEqual(
    left: ?zap.incremental_graph.StableDigest,
    right: ?zap.incremental_graph.StableDigest,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?[0..], right.?[0..]);
}

fn appendFunctionSurface(
    hasher: *zap.incremental_graph.StableHasher,
    function_decl: *const ast.FunctionDecl,
    interner: *const ast.StringInterner,
) error{UnsupportedDeclarationFingerprint}!void {
    hasher.appendEnum(function_decl.visibility);
    hasher.appendBytes(interner.get(function_decl.name));
    const arity = try functionDeclArity(function_decl);
    hasher.appendInt(u16, arity);
    hasher.appendInt(u64, function_decl.clauses.len);
}

fn appendStructName(
    hasher: *zap.incremental_graph.StableHasher,
    name: ast.StructName,
    interner: *const ast.StringInterner,
) void {
    hasher.appendInt(u64, name.parts.len);
    for (name.parts) |part| hasher.appendBytes(interner.get(part));
}

fn appendPatternSpan(
    hasher: *zap.incremental_graph.StableHasher,
    pattern: *const ast.Pattern,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    try appendSourceSpan(hasher, pattern.getMeta().span, source, source_id);
}

fn appendTypeExprSpan(
    hasher: *zap.incremental_graph.StableHasher,
    type_expr: *const ast.TypeExpr,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    try appendSourceSpan(hasher, type_expr.getMeta().span, source, source_id);
}

fn appendOptionalTypeExprSpan(
    hasher: *zap.incremental_graph.StableHasher,
    type_expr: ?*const ast.TypeExpr,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    if (type_expr) |some| {
        hasher.appendBool(true);
        try appendTypeExprSpan(hasher, some, source, source_id);
    } else {
        hasher.appendBool(false);
    }
}

fn appendOptionalExprSpan(
    hasher: *zap.incremental_graph.StableHasher,
    expr: ?*const ast.Expr,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    if (expr) |some| {
        hasher.appendBool(true);
        try appendSourceSpan(hasher, some.getMeta().span, source, source_id);
    } else {
        hasher.appendBool(false);
    }
}

fn appendSourceSpan(
    hasher: *zap.incremental_graph.StableHasher,
    span: ast.SourceSpan,
    source: []const u8,
    source_id: u32,
) FrontendFingerprintBuildError!void {
    if (span.source_id == null or span.source_id.? != source_id) return error.UnsupportedDeclarationFingerprint;
    if (span.start > span.end) return error.UnsupportedDeclarationFingerprint;
    const start: usize = @intCast(span.start);
    const end: usize = @intCast(span.end);
    if (end > source.len) return error.UnsupportedDeclarationFingerprint;
    hasher.appendBytes(source[start..end]);
}

fn structItemSourceSpan(item: ast.StructItem) ast.SourceSpan {
    return switch (item) {
        .type_decl => |decl| decl.meta.span,
        .opaque_decl => |decl| decl.meta.span,
        .struct_decl => |decl| decl.meta.span,
        .union_decl => |decl| decl.meta.span,
        .function => |decl| decl.meta.span,
        .priv_function => |decl| decl.meta.span,
        .macro => |decl| decl.meta.span,
        .priv_macro => |decl| decl.meta.span,
        .alias_decl => |decl| decl.meta.span,
        .import_decl => |decl| decl.meta.span,
        .use_decl => |decl| decl.meta.span,
        .attribute => |decl| decl.meta.span,
        .struct_level_expr => |expr| expr.getMeta().span,
    };
}

fn stmtSourceSpan(statement: ast.Stmt) ast.SourceSpan {
    return switch (statement) {
        .expr => |expr| expr.getMeta().span,
        .assignment => |assignment| assignment.meta.span,
        .function_decl => |decl| decl.meta.span,
        .macro_decl => |decl| decl.meta.span,
        .import_decl => |decl| decl.meta.span,
        .attribute => |decl| decl.meta.span,
        .defer_stmt => |decl| decl.meta.span,
    };
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

/// True when `file_path` names a Zap standard-library source unit (the
/// `lib/...` tree). Used to scope the Phase 1.4 advisory lints to user
/// code — the stdlib's own legacy idioms (`raise("...")`, `{:ok, _}`
/// tuples) are intentionally exempt.
fn isStdlibUnitPath(file_path: []const u8) bool {
    return std.mem.startsWith(u8, file_path, "lib/") or
        std.mem.indexOf(u8, file_path, "/lib/") != null;
}

const WholeFrontendInvalidationReason = enum {
    missing_file_struct_mapping,
    empty_file_struct_mapping,
    kernel_struct,
};

const WholeFrontendInvalidationHit = struct {
    file_path: []const u8,
    reason: WholeFrontendInvalidationReason,
};

fn wholeFrontendInvalidationReason(
    file_path: []const u8,
    graph: FrontendDependencyGraph,
    file_is_direct_change: bool,
) ?WholeFrontendInvalidationReason {
    _ = file_is_direct_change;
    const structs = graph.file_to_structs.get(file_path) orelse return .missing_file_struct_mapping;
    if (structs.len == 0) return .empty_file_struct_mapping;
    for (structs) |struct_name| {
        if (std.mem.eql(u8, struct_name, zap.discovery.kernel_struct_name)) return .kernel_struct;
    }
    return null;
}

fn mustInvalidateWholeFrontend(file_path: []const u8, graph: FrontendDependencyGraph, file_is_direct_change: bool) bool {
    return wholeFrontendInvalidationReason(file_path, graph, file_is_direct_change) != null;
}

fn transitiveDependentWholeFrontendInvalidation(
    alloc: std.mem.Allocator,
    graph: FrontendDependencyGraph,
    changed_files: []const []const u8,
) CompileError!?WholeFrontendInvalidationHit {
    var seen_files = std.StringHashMap(void).init(alloc);
    defer seen_files.deinit();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(alloc);

    for (changed_files) |file_path| {
        const seen_entry = try seen_files.getOrPut(file_path);
        if (!seen_entry.found_existing) try queue.append(alloc, file_path);
    }

    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const current_file = queue.items[cursor];
        const dependents = graph.file_imported_by.get(current_file) orelse continue;
        for (dependents) |dependent_file| {
            const seen_entry = try seen_files.getOrPut(dependent_file);
            if (seen_entry.found_existing) continue;
            if (wholeFrontendInvalidationReason(dependent_file, graph, false)) |reason| {
                return .{ .file_path = dependent_file, .reason = reason };
            }
            try queue.append(alloc, dependent_file);
        }
    }

    return null;
}

fn allChangedFilesHaveFingerprintBatch(
    changed_files: []const []const u8,
    changed_declaration_fingerprints: []const FrontendChangedFileFingerprints,
) bool {
    for (changed_files) |file_path| {
        var found = false;
        for (changed_declaration_fingerprints) |file_fingerprints| {
            if (std.mem.eql(u8, file_fingerprints.file_path, file_path)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn addSourceGraphInvalidations(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    graph: FrontendDependencyGraph,
    dependency_graph: *const zap.incremental_graph.Graph,
    changed_files: []const []const u8,
    invalidated_structs: *std.StringHashMap(void),
) CompileError!void {
    var changed_source_ids: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
    defer changed_source_ids.deinit(alloc);
    for (changed_files) |file_path| {
        const source_id = (try dependency_graph.getNode(frontendSourceFileNodeKey(file_path))) orelse {
            incrementalTrace(
                "struct-invalidation scope=all reason=missing-source-node file={s}",
                .{file_path},
            );
            try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
            return;
        };
        try changed_source_ids.append(alloc, source_id);
        traceIncrementalGraphNode("changed-source-node", dependency_graph, source_id);
    }

    const affected_nodes = try dependency_graph.affectedFrom(alloc, changed_source_ids.items);
    defer alloc.free(affected_nodes);
    if (incrementalTraceEnabled()) {
        const affected_steps = try dependency_graph.affectedTraceFrom(alloc, changed_source_ids.items);
        defer alloc.free(affected_steps);
        for (affected_steps) |step| {
            traceIncrementalGraphStep("affected-edge", dependency_graph, step);
        }
    }
    incrementalTrace(
        "graph-reachability source_nodes={d} affected_nodes={d}",
        .{ changed_source_ids.items.len, affected_nodes.len },
    );

    for (affected_nodes) |node_id| {
        traceIncrementalGraphNode("affected-node", dependency_graph, node_id);
        const node_key = dependency_graph.nodeKey(node_id) orelse {
            incrementalTrace(
                "struct-invalidation scope=all reason=missing-affected-node id={d}",
                .{@intFromEnum(node_id)},
            );
            try addAllSourceStructs(alloc, source_units, graph, invalidated_structs);
            return;
        };
        switch (node_key.*) {
            .struct_surface => |struct_key| {
                try invalidated_structs.put(struct_key.qualified_name, {});
                incrementalTrace(
                    "invalidated-struct source=graph struct={s}",
                    .{struct_key.qualified_name},
                );
            },
            else => {},
        }
    }
}

fn addAllSourceStructs(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    graph: FrontendDependencyGraph,
    invalidated_structs: *std.StringHashMap(void),
) CompileError!void {
    for (source_units) |unit| {
        if (graph.file_to_structs.get(unit.file_path)) |structs| {
            for (structs) |struct_name| {
                try invalidated_structs.put(struct_name, {});
            }
        }
    }
    _ = alloc;
}

fn appendUniqueNodeId(
    alloc: std.mem.Allocator,
    node_ids: *std.ArrayListUnmanaged(zap.incremental_graph.NodeId),
    node_id: zap.incremental_graph.NodeId,
) CompileError!void {
    for (node_ids.items) |existing| {
        if (existing == node_id) return;
    }
    try node_ids.append(alloc, node_id);
}

fn appendUniqueFilePath(
    alloc: std.mem.Allocator,
    file_paths: *std.ArrayListUnmanaged([]const u8),
    file_path: []const u8,
) CompileError!void {
    for (file_paths.items) |existing| {
        if (std.mem.eql(u8, existing, file_path)) return;
    }
    try file_paths.append(alloc, file_path);
}

fn copyStringSet(source: *const std.StringHashMap(void), dest: *std.StringHashMap(void)) CompileError!void {
    var iter = source.iterator();
    while (iter.next()) |entry| {
        try dest.put(entry.key_ptr.*, {});
    }
}

fn addChangedDeclarationStructForNode(
    alloc: std.mem.Allocator,
    node_key: zap.incremental_graph.NodeKey,
    changed_declaration_structs: *std.StringHashMap(void),
) CompileError!void {
    _ = alloc;
    switch (node_key) {
        .struct_surface => |struct_key| try changed_declaration_structs.put(struct_key.qualified_name, {}),
        .function_signature, .function_body => |function_key| {
            if (function_key.owner.kind == .@"struct") {
                try changed_declaration_structs.put(function_key.owner.qualified_name, {});
            } else if (function_key.owner.kind == .package) {
                try changed_declaration_structs.put("", {});
            }
        },
        .package_surface => try changed_declaration_structs.put("", {}),
        else => {},
    }
}

fn frontendPackageKey() zap.incremental_graph.PackageKey {
    return .{
        .kind = .project_root,
        .name = "frontend",
        .root_identity = "zap-frontend-incremental-v1",
        .version = null,
    };
}

fn frontendSourceFileNodeKey(file_path: []const u8) zap.incremental_graph.NodeKey {
    return .{ .source_file = .{
        .package = frontendPackageKey(),
        .path = file_path,
    } };
}

fn frontendPackageSurfaceNodeKey() zap.incremental_graph.NodeKey {
    return .{ .package_surface = frontendPackageKey() };
}

fn frontendStructSurfaceNodeKey(struct_name: []const u8) zap.incremental_graph.NodeKey {
    return .{ .struct_surface = .{
        .package = frontendPackageKey(),
        .qualified_name = struct_name,
    } };
}

fn frontendCompileAfterGlobNodeKey(file_path: []const u8) zap.incremental_graph.NodeKey {
    return .{ .ctfe_glob = .{
        .package = frontendPackageKey(),
        .pattern = file_path,
        .recursive = false,
    } };
}

fn frontendStructReflectionNodeKey(struct_name: []const u8) zap.incremental_graph.NodeKey {
    return .{ .ctfe_reflection = .{
        .package = frontendPackageKey(),
        .query_identity = struct_name,
    } };
}

fn frontendFunctionOwnerKey(function: ir.Function) zap.incremental_graph.DeclarationOwnerKey {
    if (function.struct_name) |struct_name| {
        return .{
            .package = frontendPackageKey(),
            .kind = .@"struct",
            .qualified_name = struct_name,
        };
    }

    return .{
        .package = frontendPackageKey(),
        .kind = .package,
        .qualified_name = "",
    };
}

fn frontendFunctionKey(function: ir.Function) CompileError!zap.incremental_graph.FunctionKey {
    return .{
        .owner = frontendFunctionOwnerKey(function),
        .declaration_kind = if (function.struct_name != null) .struct_method else .free,
        .local_name = if (function.local_name.len > 0) function.local_name else function.name,
        .arity = std.math.cast(u16, function.arity) orelse return error.IrFailed,
        .clause_index = function.source_clause_index orelse 0,
        .specialization = null,
    };
}

fn frontendFunctionBodyNodeKey(function: ir.Function) CompileError!zap.incremental_graph.NodeKey {
    return .{ .function_body = try frontendFunctionKey(function) };
}

fn frontendFunctionSignatureNodeKey(function: ir.Function) CompileError!zap.incremental_graph.NodeKey {
    return .{ .function_signature = try frontendFunctionKey(function) };
}

fn buildFrontendIncrementalGraph(
    allocator: std.mem.Allocator,
    source_units: []const SourceUnit,
    frontend_graph: FrontendDependencyGraph,
) CompileError!zap.incremental_graph.Graph {
    var dependency_graph = zap.incremental_graph.Graph.init(allocator);
    errdefer dependency_graph.deinit();

    _ = try dependency_graph.getOrPutNode(frontendPackageSurfaceNodeKey());

    for (source_units) |unit| {
        const source_id = try dependency_graph.getOrPutNode(frontendSourceFileNodeKey(unit.file_path));
        const structs = frontend_graph.file_to_structs.get(unit.file_path) orelse continue;
        for (structs) |struct_name| {
            const struct_id = try dependency_graph.getOrPutNode(frontendStructSurfaceNodeKey(struct_name));
            try dependency_graph.addEdge(struct_id, source_id, .surface);
        }
    }

    var imported_iter = frontend_graph.file_imported_by.iterator();
    while (imported_iter.next()) |entry| {
        const imported_structs = frontend_graph.file_to_structs.get(entry.key_ptr.*) orelse continue;
        for (entry.value_ptr.*) |dependent_file| {
            const dependent_structs = frontend_graph.file_to_structs.get(dependent_file) orelse continue;
            for (dependent_structs) |dependent_struct_name| {
                const dependent_struct_id = try dependency_graph.getOrPutNode(frontendStructSurfaceNodeKey(dependent_struct_name));
                for (imported_structs) |imported_struct_name| {
                    const imported_struct_id = try dependency_graph.getOrPutNode(frontendStructSurfaceNodeKey(imported_struct_name));
                    try dependency_graph.addEdge(dependent_struct_id, imported_struct_id, .import);
                }
            }
        }
    }

    var compile_after_iter = frontend_graph.file_compile_after_globs.iterator();
    while (compile_after_iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const glob_id = try dependency_graph.getOrPutNode(frontendCompileAfterGlobNodeKey(file_path));
        const structs = frontend_graph.file_to_structs.get(file_path) orelse continue;
        for (structs) |struct_name| {
            const struct_id = try dependency_graph.getOrPutNode(frontendStructSurfaceNodeKey(struct_name));
            try dependency_graph.addEdge(struct_id, glob_id, .ctfe_glob);
        }
        const matched_files = frontend_graph.file_compile_after_files.get(file_path) orelse continue;
        for (matched_files) |matched_file| {
            const matched_structs = frontend_graph.file_to_structs.get(matched_file) orelse continue;
            for (matched_structs) |matched_struct_name| {
                const reflection_id = try dependency_graph.getOrPutNode(frontendStructReflectionNodeKey(matched_struct_name));
                try dependency_graph.addEdge(glob_id, reflection_id, .ctfe_reflection);
            }
        }
    }

    return dependency_graph;
}

fn augmentFrontendGraphWithDeclarationFingerprints(
    dependency_graph: *zap.incremental_graph.Graph,
    fingerprint_sets: []const ?zap.incremental_graph.DeclarationFingerprintSet,
) CompileError!void {
    for (fingerprint_sets) |maybe_set| {
        const fingerprint_set = maybe_set orelse continue;
        for (fingerprint_set.records) |record| {
            const node_id = try dependency_graph.getOrPutNode(record.key);
            switch (record.key) {
                .function_body => |function_key| {
                    const signature_id = try dependency_graph.getOrPutNode(.{ .function_signature = function_key });
                    try dependency_graph.addEdge(node_id, signature_id, .surface);
                    const owner_surface_id = try dependency_graph.getOrPutNode(frontendOwnerSurfaceNodeKey(function_key.owner));
                    try dependency_graph.addEdge(node_id, owner_surface_id, .surface);
                },
                .function_signature => |function_key| {
                    const owner_surface_id = try dependency_graph.getOrPutNode(frontendOwnerSurfaceNodeKey(function_key.owner));
                    try dependency_graph.addEdge(node_id, owner_surface_id, .surface);
                },
                else => {},
            }
        }
    }
}

fn frontendOwnerSurfaceNodeKey(owner: zap.incremental_graph.DeclarationOwnerKey) zap.incremental_graph.NodeKey {
    if (owner.kind == .@"struct") {
        return .{ .struct_surface = .{
            .package = owner.package,
            .qualified_name = owner.qualified_name,
        } };
    }
    return .{ .package_surface = owner.package };
}

fn augmentFrontendGraphWithFunctions(
    alloc: std.mem.Allocator,
    dependency_graph: *zap.incremental_graph.Graph,
    program: ir.Program,
) CompileError!void {
    for (program.functions) |function| {
        const body_id = try dependency_graph.getOrPutNode(try frontendFunctionBodyNodeKey(function));
        const signature_id = try dependency_graph.getOrPutNode(try frontendFunctionSignatureNodeKey(function));
        try dependency_graph.addEdge(body_id, signature_id, .surface);

        if (function.struct_name) |struct_name| {
            const struct_id = try dependency_graph.getOrPutNode(frontendStructSurfaceNodeKey(struct_name));
            try dependency_graph.addEdge(body_id, struct_id, .surface);
            try dependency_graph.addEdge(signature_id, struct_id, .surface);
        } else {
            const package_id = try dependency_graph.getOrPutNode(frontendPackageSurfaceNodeKey());
            try dependency_graph.addEdge(body_id, package_id, .surface);
            try dependency_graph.addEdge(signature_id, package_id, .surface);
        }
    }

    var callers_by_callee = std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)).init(alloc);
    defer {
        var lists = callers_by_callee.valueIterator();
        while (lists.next()) |list| list.deinit(alloc);
        callers_by_callee.deinit();
    }

    for (program.functions) |function| {
        for (function.body) |block| {
            try addCallEdgesFromInstructions(alloc, program, function.id, block.instructions, &callers_by_callee);
        }
    }

    var callee_iter = callers_by_callee.iterator();
    while (callee_iter.next()) |entry| {
        const callee = functionById(program, entry.key_ptr.*) orelse continue;
        const callee_signature_id = try dependency_graph.getOrPutNode(try frontendFunctionSignatureNodeKey(callee.*));
        for (entry.value_ptr.items) |caller_id| {
            const caller = functionById(program, caller_id) orelse continue;
            const caller_body_id = try dependency_graph.getOrPutNode(try frontendFunctionBodyNodeKey(caller.*));
            // Normal calls depend on the callee signature. Callee-body semantic summaries
            // must be represented by a separate .analysis_summary edge.
            try dependency_graph.addEdge(caller_body_id, callee_signature_id, .call_edge);
        }
    }
}

fn augmentFrontendGraphWithAnalysisSummaryEdges(
    alloc: std.mem.Allocator,
    dependency_graph: *zap.incremental_graph.Graph,
    program: ir.Program,
    policy: FrontendPassPolicy,
) CompileError!void {
    var callers_by_callee = std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)).init(alloc);
    defer {
        var lists = callers_by_callee.valueIterator();
        while (lists.next()) |list| list.deinit(alloc);
        callers_by_callee.deinit();
    }

    for (program.functions) |function| {
        for (function.body) |block| {
            try addAnalysisSummaryEdgesFromInstructions(
                alloc,
                program,
                function.id,
                block.instructions,
                policy,
                &callers_by_callee,
            );
        }
    }

    var callee_iter = callers_by_callee.iterator();
    while (callee_iter.next()) |entry| {
        const callee = functionById(program, entry.key_ptr.*) orelse continue;
        if (!calleeBodyMayAffectCallerFinalIr(callee.*, policy)) continue;

        const callee_body_id = try dependency_graph.getOrPutNode(try frontendFunctionBodyNodeKey(callee.*));
        for (entry.value_ptr.items) |caller_id| {
            const caller = functionById(program, caller_id) orelse continue;
            const caller_body_id = try dependency_graph.getOrPutNode(try frontendFunctionBodyNodeKey(caller.*));
            // These edges are deliberately separate from `.call_edge`: normal
            // calls depend on signatures, while body-derived analysis summaries
            // only flow to callers for passes whose summaries can change caller IR.
            try dependency_graph.addEdge(caller_body_id, callee_body_id, .analysis_summary);
        }
    }
}

fn addAnalysisSummaryEdgesFromInstructions(
    alloc: std.mem.Allocator,
    program: ir.Program,
    caller_id: ir.FunctionId,
    instructions: []const ir.Instruction,
    policy: FrontendPassPolicy,
    callers_by_callee: *std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) CompileError!void {
    for (instructions) |instruction| {
        switch (instruction) {
            .call_direct => |call| try addReverseCallEdgeTarget(alloc, program, caller_id, call.function, callers_by_callee),
            .call_named => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
            },
            .tail_call => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
            },
            .try_call_named => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, call.handler_instrs, policy, callers_by_callee);
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, call.success_instrs, policy, callers_by_callee);
            },
            .make_closure => |closure| {
                if (policy.run_contification) {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, closure.function, callers_by_callee);
                }
            },
            .if_expr => |value| {
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.then_instrs, policy, callers_by_callee);
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.else_instrs, policy, callers_by_callee);
            },
            .guard_block => |value| try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.body, policy, callers_by_callee),
            .case_block => |value| {
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.pre_instrs, policy, callers_by_callee);
                for (value.arms) |arm| {
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, arm.cond_instrs, policy, callers_by_callee);
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, arm.body_instrs, policy, callers_by_callee);
                }
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, policy, callers_by_callee);
            },
            .switch_literal => |value| {
                for (value.cases) |case| {
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, policy, callers_by_callee);
                }
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, policy, callers_by_callee);
            },
            .switch_return => |value| {
                for (value.cases) |case| {
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, policy, callers_by_callee);
                }
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, policy, callers_by_callee);
            },
            .union_switch => |value| {
                for (value.cases) |case| {
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, policy, callers_by_callee);
                }
            },
            .union_switch_return => |value| {
                for (value.cases) |case| {
                    try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, policy, callers_by_callee);
                }
            },
            .optional_dispatch => |value| {
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.nil_instrs, policy, callers_by_callee);
                try addAnalysisSummaryEdgesFromInstructions(alloc, program, caller_id, value.struct_instrs, policy, callers_by_callee);
            },
            else => {},
        }
    }
}

fn calleeBodyMayAffectCallerFinalIr(function: ir.Function, policy: FrontendPassPolicy) bool {
    // ARC parameter-convention inference is semantic in every mode: a callee
    // body can prove a borrowed parameter is actually consumed, and the caller
    // final IR then rewrites the matching share/release pair into a move.
    if (functionHasBorrowedParamConvention(function)) return true;

    // Release policies enable optimization summaries whose callee-body facts
    // are materialized into caller IR: escape/Perceus ARC records,
    // contification, and unchecked uniqueness rewrites. Until each summary has
    // a narrower digest node, model the dependency explicitly at body level.
    return policyUsesCalleeBodySummariesInCallerFinalIr(policy);
}

fn functionHasBorrowedParamConvention(function: ir.Function) bool {
    for (function.param_conventions) |convention| {
        if (convention == .borrowed) return true;
    }
    return false;
}

fn policyUsesCalleeBodySummariesInCallerFinalIr(policy: FrontendPassPolicy) bool {
    return policy.run_region_solver or
        policy.run_lambda_specialization or
        policy.run_perceus_reuse or
        policy.run_arc_optimizer or
        policy.run_contification or
        policy.rewrite_unchecked_uniqueness;
}

fn invalidatedStructNamesInSourceOrder(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    graph: FrontendDependencyGraph,
    invalidated_structs: *const std.StringHashMap(void),
) CompileError![]const []const u8 {
    var ordered: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered.deinit(alloc);
    var emitted = std.StringHashMap(void).init(alloc);
    defer emitted.deinit();

    for (source_units) |unit| {
        const structs = graph.file_to_structs.get(unit.file_path) orelse continue;
        for (structs) |struct_name| {
            if (!invalidated_structs.contains(struct_name) or emitted.contains(struct_name)) continue;
            try emitted.put(struct_name, {});
            try ordered.append(alloc, struct_name);
        }
    }

    var iter = invalidated_structs.iterator();
    while (iter.next()) |entry| {
        if (emitted.contains(entry.key_ptr.*)) continue;
        try emitted.put(entry.key_ptr.*, {});
        try ordered.append(alloc, entry.key_ptr.*);
    }

    return ordered.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn structNamesForFilesInSourceOrder(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    graph: FrontendDependencyGraph,
    file_paths: []const []const u8,
) CompileError![]const []const u8 {
    var changed_files = std.StringHashMap(void).init(alloc);
    defer changed_files.deinit();
    for (file_paths) |file_path| {
        try changed_files.put(file_path, {});
    }

    var ordered: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer ordered.deinit(alloc);
    var emitted = std.StringHashMap(void).init(alloc);
    defer emitted.deinit();

    for (source_units) |unit| {
        if (!changed_files.contains(unit.file_path)) continue;
        const structs = graph.file_to_structs.get(unit.file_path) orelse continue;
        for (structs) |struct_name| {
            if (emitted.contains(struct_name)) continue;
            try emitted.put(struct_name, {});
            try ordered.append(alloc, struct_name);
        }
    }

    return ordered.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn registerSourceUnits(graph: *zap.scope.ScopeGraph, source_units: []const SourceUnit) !void {
    for (source_units, 0..) |unit, source_index| {
        try graph.registerSourceFileWithContent(@intCast(source_index), unit.file_path, unit.source);
    }
}

/// A memory-mapped file that provides zero-copy read access to source contents.
/// Uses Zig 0.16's std.Io.File.MemoryMap for cross-platform memory mapping.
pub const MappedFile = struct {
    memory_map: ?std.Io.File.MemoryMap,
    file: ?std.Io.File,

    pub fn deinit(self: *MappedFile, io: std.Io) void {
        if (self.memory_map) |*mm| mm.destroy(io);
        if (self.file) |f| f.close(io);
    }

    /// Return the mapped bytes as a plain slice for use in SourceUnit.source.
    pub fn bytes(self: MappedFile) []const u8 {
        if (self.memory_map) |mm| return mm.memory;
        return &.{};
    }
};

/// Memory-map a source file for read-only access using Zig 0.16's
/// std.Io.File.MemoryMap. Empty files return a null memory map.
pub fn mmapSourceFile(io: std.Io, file_path: []const u8, fallback_allocator: std.mem.Allocator) !MappedFile {
    _ = fallback_allocator;
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    errdefer file.close(io);

    const file_stat = try file.stat(io);
    const file_size = file_stat.size;

    if (file_size == 0) {
        file.close(io);
        return MappedFile{ .memory_map = null, .file = null };
    }

    const mm = try file.createMemoryMap(io, .{
        .len = file_size,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    });
    errdefer mm.destroy(io);

    return MappedFile{ .memory_map = mm, .file = file };
}

/// Pass 1: Parse all source files and collect declarations into a shared context.
///
/// Takes a merged source string (all files concatenated) and a file path for
/// diagnostics. Returns a CompilationContext with the shared scope graph and
/// type store populated.
///
/// This is equivalent to the parse + collect phases of compileFrontend.
pub fn collectAll(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: CompileOptions,
) CompileError!CompilationContext {
    const source_units = [_]SourceUnit{.{ .file_path = file_path, .source = source }};
    return collectAllFromUnits(alloc, &source_units, options);
}

pub fn collectAllFromUnits(
    alloc: std.mem.Allocator,
    source_units: []const SourceUnit,
    options: CompileOptions,
) CompileError!CompilationContext {
    // progress writer: use debug.print in 0.16
    var step: u32 = 0;
    const total_steps: u32 = 11;

    progressHeader(options);

    var diag_engine = zap.DiagnosticEngine.init(alloc);
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Parse each source unit with its own local interner, then merge
    // interners and remap AST StringIds. This architecture supports
    // parallel parsing (each parser is independent).
    step += 1;
    progressStage(options, "[{d}/{d}] Parse", .{ step, total_steps });

    const all_source_units = source_units;

    setDiagnosticSources(&diag_engine, all_source_units);
    diag_engine.setLineOffset(0);

    var global_interner = ast.StringInterner.init(alloc);
    const parsed_programs = try alloc.alloc(ast.Program, all_source_units.len);
    const local_interners = try alloc.alloc(ast.StringInterner, all_source_units.len);
    // Parse all files. When Io is available and there are multiple files,
    // parse in parallel using Io.Group — each parser gets its own local
    // StringInterner so there is zero contention.
    if (options.io != null and all_source_units.len > 1) {
        const io_val = options.io.?;
        const parse_results = try alloc.alloc(ParseTaskResult, all_source_units.len);
        defer alloc.free(parse_results);

        var group: std.Io.Group = .init;
        for (all_source_units, 0..) |unit, i| {
            local_interners[i] = ast.StringInterner.init(alloc);
            parse_results[i] = .{};
            group.async(io_val, parseFileTask, .{ alloc, unit.source, &local_interners[i], @as(u32, @intCast(i)), unit.script_mode, &parsed_programs[i], &parse_results[i] });
        }
        group.await(io_val) catch {};

        // Check for parse failures and collect errors
        var any_failed = false;
        for (parse_results, 0..) |result, i| {
            if (result.failed) {
                if (result.errors.len > 0) {
                    emitParseErrorsFromUnits(alloc, result.errors, all_source_units, diag_engine.use_color);
                }
                any_failed = true;
            } else {
                for (result.errors) |parse_err| {
                    diag_engine.reportDiagnostic(.{
                        .severity = .@"error",
                        .message = parse_err.message,
                        .span = parse_err.span,
                        .label = parse_err.label,
                        .help = parse_err.help,
                    }) catch {};
                }
            }
            _ = i;
        }
        if (any_failed) {
            progressClear(options);
            return error.ParseFailed;
        }
    } else {
        // Sequential fallback: single file or no Io available
        for (all_source_units, 0..) |unit, i| {
            local_interners[i] = ast.StringInterner.init(alloc);
            var parser = zap.Parser.initWithSharedInternerScriptMode(alloc, unit.source, &local_interners[i], @intCast(i), unit.script_mode);
            defer parser.deinit();

            parsed_programs[i] = parser.parseProgram() catch {
                emitParseErrorsFromUnits(alloc, parser.errors.items, all_source_units, diag_engine.use_color);
                progressClear(options);
                return error.ParseFailed;
            };

            for (parser.errors.items) |parse_err| {
                diag_engine.reportDiagnostic(.{
                    .severity = .@"error",
                    .message = parse_err.message,
                    .span = parse_err.span,
                    .label = parse_err.label,
                    .help = parse_err.help,
                }) catch {};
            }
        }
    }

    // Merge local interners into the global interner and remap ASTs.
    for (0..all_source_units.len) |i| {
        const remap = buildInternerRemap(alloc, &local_interners[i], &global_interner) catch
            return error.OutOfMemory;
        remapProgram(alloc, &parsed_programs[i], remap) catch
            return error.OutOfMemory;
    }
    const interner = try alloc.create(ast.StringInterner);
    interner.* = global_interner;

    // Phase 1.4 warn-only advisory lints (`raise "string"` on a `pub` API
    // surface; bare `{:ok, _}`/`{:error, _}` tuple patterns). Runs on the
    // parsed-and-remapped per-unit ASTs (StringIds are now global, so the
    // shared `interner` resolves atom text) BEFORE desugar rewrites
    // `raise_expr`/tuple patterns away. User units only — the stdlib's own
    // legacy idioms are exempt.
    for (parsed_programs, 0..) |*parsed_program, i| {
        if (isStdlibUnitPath(all_source_units[i].file_path)) continue;
        zap.lints.runPhase14Lints(parsed_program, interner, &diag_engine) catch {};
    }

    // Phase 3.b — mandatory-`raises` lint mode (opt-in via ZAP_LINT_RAISES),
    // scoped to the stdlib (`lib/*`). Warn-only: it flags `pub fn`s whose
    // body can `raise`/propagate but omit a `raises` row, so the stdlib's
    // participation in the nominal abortive effect is auditable. Off by
    // default to keep ordinary builds quiet; `ZAP_LINT_RAISES=1 zap build`
    // confirms `lib/*` is consistent under mandatory annotation.
    if (std.c.getenv("ZAP_LINT_RAISES") != null) {
        for (parsed_programs, 0..) |*parsed_program, i| {
            if (!isStdlibUnitPath(all_source_units[i].file_path)) continue;
            zap.lints.runMandatoryRaisesLint(parsed_program, interner, &diag_engine) catch {};
        }
    }

    // Phase 1.5 — error-code collision check. `@code Zxxxx` values are
    // stable public API and must be globally unique across every unit
    // (stdlib + user). This runs over ALL parsed programs (stdlib units
    // included, so a user code colliding with a reserved stdlib code is
    // caught) and emits a hard `.error` diagnostic per collision. Unlike
    // the warn-only lints above this aborts the build via the
    // `hasErrors` gate below.
    _ = zap.error_codes.checkCodeCollisions(alloc, parsed_programs, interner, &diag_engine) catch {};

    if (diag_engine.hasErrors()) {
        progressClear(options);
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    if (diag_engine.warningCount() > 0) {
        progressClear(options);
        emitDiagnostics(&diag_engine, alloc);
    }

    var program = try mergePrograms(alloc, parsed_programs);

    // Rewrite every `pub error Foo { ... }` / `error Foo { ... }` into
    // a `pub struct Foo + pub impl Error for Foo` pair before any
    // collect or HIR pass sees the program. The desugar lives in
    // `src/desugar.zig` and runs end-to-end here so the rest of the
    // pipeline (collector → macro engine → full desugar → typecheck →
    // HIR → IR → ZIR) never has to know about the `ErrorDecl` form.
    // This is the only `pub error`-aware pre-collect step in the
    // compiler — everything downstream treats the generated struct
    // and impl as ordinary declarations.
    try applyErrorDeclDesugar(alloc, interner, &program);

    // Collect declarations from the merged program first (needed for
    // macro expansion to resolve Kernel macros etc.)
    step += 1;
    progressStage(options, "[{d}/{d}] Collect", .{ step, total_steps });

    // Intern the auto-imported Kernel struct's name once — needed for
    // auto-import injection. The literal name lives in
    // `discovery.kernel_struct_name`.
    const kernel_name_id = try interner.intern(zap.discovery.kernel_struct_name);
    var collector = zap.Collector.init(alloc, interner, kernel_name_id);
    try registerSourceUnits(&collector.graph, all_source_units);
    {
        const pre_struct_programs = try buildStructPrograms(alloc, &program, interner);

        // Collect Kernel FIRST so its scope exists when other structs'
        // auto-import resolves. This mirrors Elixir's bootstrap ordering.
        for (pre_struct_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) {
                collector.collectProgramSurface(&entry.program) catch {};
                break;
            }
        }
        for (pre_struct_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) continue;
            collector.collectProgramSurface(&entry.program) catch {
                for (collector.errors.items) |collect_err| {
                    diag_engine.err(collect_err.message, collect_err.span) catch {};
                }
                progressClear(options);
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return error.CollectFailed;
            };
        }

        if (program.top_items.len > 0) {
            const top_only = ast.Program{ .structs = &.{}, .top_items = program.top_items };
            collector.collectProgramSurface(&top_only) catch {
                for (collector.errors.items) |collect_err| {
                    diag_engine.err(collect_err.message, collect_err.span) catch {};
                }
                progressClear(options);
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return error.CollectFailed;
            };
        }
        // Validate protocol conformance and register impl functions in target structs
        collector.validateImplConformance() catch {};
        collector.registerImplFunctionsInTargetScopes() catch {};
        if (collector.errors.items.len > 0) {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        }

        const pre_slices = try alloc.alloc(ast.Program, pre_struct_programs.len);
        for (pre_struct_programs, 0..) |entry, i| pre_slices[i] = entry.program;
        collector.finalizeCollectedPrograms(pre_slices) catch {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        progressClear(options);
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.CollectFailed;
    }

    // Static capability inference: walk every macro/function body, identify
    // direct uses of impure intrinsics, and propagate to the fixed point so
    // each `MacroFamily.required_caps` reflects what the body actually does.
    // Replaces the historical `@requires` annotation; macro authors no
    // longer write capability sets by hand.
    zap.capability_inference.inferAndApply(alloc, &collector.graph, interner) catch {};

    // Run macro expansion and desugaring. When the discovery graph supplies a
    // struct order, expand one struct at a time and compile each completed
    // dependency level to IR so later macros can call already compiled Zap
    // functions through CTFE. Without a graph order, keep the legacy merged
    // expansion path.
    step += 1;
    progressStage(options, "[{d}/{d}] Macro expand", .{ step, total_steps });

    const desugared_program = if (options.struct_order) |struct_order|
        stagedMacroExpandAndDesugar(
            alloc,
            &program,
            struct_order,
            interner,
            &collector,
            &diag_engine,
            options,
        ) catch |err| {
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return err;
        }
    else
        legacyMacroExpandAndDesugar(
            alloc,
            &program,
            interner,
            &collector,
            &diag_engine,
            options.frontend_optimize_mode,
        ) catch |err| {
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return err;
        };

    step += 1;
    progressStage(options, "[{d}/{d}] Desugar", .{ step, total_steps });

    // NOW split into per-struct programs from the expanded/desugared AST.
    // All if_expr nodes are gone, all pipes desugared, all macros expanded.
    const struct_programs = try buildStructPrograms(alloc, &desugared_program, interner);

    // Rebuild the scope graph from the desugared AST. The original collector
    // was built from pre-expansion AST, so its function declaration pointers
    // are stale. The HIR builder compares AST node pointers to determine
    // which functions belong to the current struct, so the scope graph must
    // reference the same AST nodes as the desugared struct programs.
    step += 1;
    progressStage(options, "[{d}/{d}] Re-collect", .{ step, total_steps });

    var final_collector = zap.Collector.init(alloc, interner, kernel_name_id);
    try registerSourceUnits(&final_collector.graph, all_source_units);
    // Collect Kernel first in the second pass too
    for (struct_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) {
            final_collector.collectProgramSurface(&entry.program) catch {};
            break;
        }
    }
    for (struct_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) continue;
        final_collector.collectProgramSurface(&entry.program) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }
    if (desugared_program.top_items.len > 0) {
        const top_only = ast.Program{ .structs = &.{}, .top_items = desugared_program.top_items };
        final_collector.collectProgramSurface(&top_only) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }
    // Re-register impl functions in their target struct scopes. The first
    // collector did this on its own graph, but the final_collector built a
    // fresh graph and per-struct HIR/type-check reads from THIS graph. Without
    // re-registration, impl functions like `Integer.+` are invisible.
    final_collector.validateImplConformance() catch {};
    final_collector.registerImplFunctionsInTargetScopes() catch {};
    {
        const slices = try alloc.alloc(ast.Program, struct_programs.len);
        for (struct_programs, 0..) |entry, i| slices[i] = entry.program;
        final_collector.finalizeCollectedPrograms(slices) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }

    // Re-run capability inference on the post-expansion graph so any
    // downstream consumer (HIR, runtime CTFE) reads the same inferred
    // capability sets the macro engine used.
    zap.capability_inference.inferAndApply(alloc, &final_collector.graph, interner) catch {};

    const units = try buildCompilationUnits(alloc, struct_programs, all_source_units);

    return .{
        .alloc = alloc,
        .merged_program = desugared_program,
        .struct_programs = struct_programs,
        .units = units,
        .source_units = all_source_units,
        .interner = interner,
        .collector = final_collector,
        .diag_engine = diag_engine,
    };
}

fn collectAllFromParsedPrograms(
    alloc: std.mem.Allocator,
    all_source_units: []const SourceUnit,
    parsed_programs: []const ast.Program,
    interner: *ast.StringInterner,
    options: CompileOptions,
    diag_engine_value: zap.DiagnosticEngine,
    expansion_cache: ?*ExpansionCacheWork,
) CompileError!CompilationContext {
    var diag_engine = diag_engine_value;
    var step: u32 = 1;
    const total_steps: u32 = 11;

    if (diag_engine.hasErrors()) {
        progressClear(options);
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    var program = try mergePrograms(alloc, parsed_programs);

    // Rewrite every `pub error Foo { ... }` / `error Foo { ... }` into a
    // `pub struct Foo + pub impl Error for Foo` pair before any collect,
    // macro, or staged-desugar pass sees the program. This mirrors the
    // identical pre-collect step in `collectAllFromUnits` (the whole-program
    // path). Without it, the incremental-daemon path leaves the `ErrorDecl`
    // form intact through `mergePrograms`; the desugared struct then only
    // surfaces via the per-program desugar fallback, which appends it to
    // `top_items` rather than `program.structs`. `buildStructPrograms` only
    // promotes `program.structs` entries into struct programs, so the
    // generated error structs (e.g. `AssertionError`) would be dropped from
    // the re-collected scope graph — leaving `%AssertionError{}` literals in
    // stdlib code (such as `Kernel.contract_violation`) typed UNKNOWN, which
    // suppresses the protocol-box auto-boxing and trips Sema's
    // `expected zap_runtime.ProtocolBox, found Kernel.contract_violation__3__struct`
    // in the whole-stdlib `zap test` build (#186). Running the desugar here
    // makes the daemon path treat `pub error` exactly like the whole-program
    // path so the rest of the pipeline never sees a raw `ErrorDecl`.
    try applyErrorDeclDesugar(alloc, interner, &program);

    step += 1;
    progressStage(options, "[{d}/{d}] Collect", .{ step, total_steps });

    const kernel_name_id = try interner.intern(zap.discovery.kernel_struct_name);
    var collector = zap.Collector.init(alloc, interner, kernel_name_id);
    try registerSourceUnits(&collector.graph, all_source_units);
    {
        const pre_struct_programs = try buildStructPrograms(alloc, &program, interner);

        for (pre_struct_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) {
                collector.collectProgramSurface(&entry.program) catch {};
                break;
            }
        }
        for (pre_struct_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) continue;
            collector.collectProgramSurface(&entry.program) catch {
                for (collector.errors.items) |collect_err| {
                    diag_engine.err(collect_err.message, collect_err.span) catch {};
                }
                progressClear(options);
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return error.CollectFailed;
            };
        }

        if (program.top_items.len > 0) {
            const top_only = ast.Program{ .structs = &.{}, .top_items = program.top_items };
            collector.collectProgramSurface(&top_only) catch {
                for (collector.errors.items) |collect_err| {
                    diag_engine.err(collect_err.message, collect_err.span) catch {};
                }
                progressClear(options);
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return error.CollectFailed;
            };
        }
        collector.validateImplConformance() catch {};
        collector.registerImplFunctionsInTargetScopes() catch {};
        if (collector.errors.items.len > 0) {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        }

        const pre_slices = try alloc.alloc(ast.Program, pre_struct_programs.len);
        for (pre_struct_programs, 0..) |entry, i| pre_slices[i] = entry.program;
        collector.finalizeCollectedPrograms(pre_slices) catch {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        progressClear(options);
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.CollectFailed;
    }

    zap.capability_inference.inferAndApply(alloc, &collector.graph, interner) catch {};

    step += 1;
    progressStage(options, "[{d}/{d}] Macro expand", .{ step, total_steps });

    const desugared_program = if (options.struct_order) |struct_order| blk: {
        if (expansion_cache) |cache| {
            break :blk stagedMacroExpandAndDesugarCached(
                alloc,
                &program,
                struct_order,
                interner,
                &collector,
                &diag_engine,
                options,
                cache,
            ) catch |err| {
                progressClear(options);
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return err;
            };
        }
        break :blk stagedMacroExpandAndDesugar(
            alloc,
            &program,
            struct_order,
            interner,
            &collector,
            &diag_engine,
            options,
        ) catch |err| {
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return err;
        };
    } else legacyMacroExpandAndDesugar(
        alloc,
        &program,
        interner,
        &collector,
        &diag_engine,
        options.frontend_optimize_mode,
    ) catch |err| {
        progressClear(options);
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return err;
    };

    step += 1;
    progressStage(options, "[{d}/{d}] Desugar", .{ step, total_steps });

    const struct_programs = try buildStructPrograms(alloc, &desugared_program, interner);

    step += 1;
    progressStage(options, "[{d}/{d}] Re-collect", .{ step, total_steps });

    var final_collector = zap.Collector.init(alloc, interner, kernel_name_id);
    try registerSourceUnits(&final_collector.graph, all_source_units);
    for (struct_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) {
            final_collector.collectProgramSurface(&entry.program) catch {};
            break;
        }
    }
    for (struct_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_struct_name)) continue;
        final_collector.collectProgramSurface(&entry.program) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            progressClear(options);
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }
    if (desugared_program.top_items.len > 0) {
        const top_only = ast.Program{ .structs = &.{}, .top_items = desugared_program.top_items };
        final_collector.collectProgramSurface(&top_only) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }
    final_collector.validateImplConformance() catch {};
    final_collector.registerImplFunctionsInTargetScopes() catch {};
    {
        const slices = try alloc.alloc(ast.Program, struct_programs.len);
        for (struct_programs, 0..) |entry, i| slices[i] = entry.program;
        final_collector.finalizeCollectedPrograms(slices) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }

    zap.capability_inference.inferAndApply(alloc, &final_collector.graph, interner) catch {};

    const units = try buildCompilationUnits(alloc, struct_programs, all_source_units);

    return .{
        .alloc = alloc,
        .merged_program = desugared_program,
        .struct_programs = struct_programs,
        .units = units,
        .source_units = all_source_units,
        .interner = interner,
        .collector = final_collector,
        .diag_engine = diag_engine,
    };
}

/// Compile the build.zap manifest through the full pipeline.
/// This is ONLY used by the builder for CTFE manifest evaluation —
/// NOT for project compilation. Project compilation uses compileStructByStruct.
pub fn compileForCtfe(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    options: CompileOptions,
) CompileError!CompileResult {
    // Already past parse + collect, which were performed by
    // `collectAllFromUnits`. The remaining nine progress steps run
    // here against the merged program; the total is kept at 11 to
    // match the user-visible counter from the previous phase.
    var pipeline = Pipeline.init(alloc, ctx, options, 2, 11);

    const substituted = try pipeline.runSubstitute(&ctx.merged_program);
    const expanded = try pipeline.runMacroExpand(&substituted);
    // Functions introduced by macro expansion need scopes before
    // desugar can rewrite their bodies — register them now, then
    // again after desugar in case desugaring synthesised more
    // helpers (`__for_N`, etc.).
    pipeline.runReCollectFunctions(&expanded);
    const desugared = try pipeline.runDesugar(&expanded);
    pipeline.runReCollectFunctions(&desugared);

    var type_checker = try pipeline.runTypeCheck(&desugared, null, true);
    defer type_checker.deinit();

    const hir_result = try pipeline.runHirBuild(&desugared, type_checker.store, 0);
    var mono_next = hir_result.next_group_id;
    const mono_program = try pipeline.runMonomorphize(&hir_result.program, type_checker.store, &mono_next);
    const ir_lowering_result = try pipeline.runIrLowering(&mono_program, type_checker.store);
    var ir_program = ir_lowering_result.program;

    pipeline.runCtfeAttributes(&ir_program, options.struct_order);

    var analysis_result = try pipeline.runAnalysisAndOptimization(&ir_program);

    // Materialize the analysis-context records into first-class
    // `.retain { kind }` / `.release { kind }` IR instructions so
    // the whole-program codegen path consumes the same canonical
    // IR shape as `compileStructByStruct`'s merged path.
    try materializeAnalysisArcOps(alloc, &ir_program, &analysis_result.context, type_checker.store, options.declared_caps, options);

    // Second type-check pass — borrow / move diagnostics live behind
    // the analysis context, so they only fire on this re-check.
    // Replays `checkProgram` + `checkUnusedBindings` against the same
    // desugared AST, now wired up to the analysis context.
    type_checker.setAnalysisContext(&analysis_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
    type_checker.allow_external_static_references = options.allow_external_static_references;
    type_checker.checkProgram(&desugared) catch {};
    type_checker.checkUnusedBindings() catch {};

    for (analysis_result.diagnostics.items) |analysis_diag| {
        ctx.diag_engine.reportDiagnostic(analysis_diag) catch {};
    }
    pipeline.routeTypeCheckerErrors(&type_checker);
    if (ctx.diag_engine.hasErrors()) return pipeline.failWithExisting(error.TypeCheckFailed);

    if (ctx.diag_engine.warningCount() > 0) {
        pipeline.clearProgress();
        emitContextDiagnostics(ctx, alloc);
    }

    pipeline.clearProgress();

    return .{
        .ir_program = ir_program,
        .analysis_context = analysis_result.context,
        .arc_ownership = ir_lowering_result.arc_ownership,
    };
}

// ============================================================
// Pipeline — phase orchestration for the post-collect compiler
//
// `Pipeline` holds the shared state every phase needs (allocator,
// CompilationContext, options, progress counter) and exposes one
// method per phase. Each entry point — `compileForCtfe` for the
// build-time manifest pass, `compileStructByStruct` for project
// compilation — composes the phases it needs in the order it needs
// them, including divergent steps. The intentional differences
// (compileForCtfe re-checks types after escape analysis to catch
// borrow diagnostics; the per-struct path skips
// `checkUnusedBindings` because the shared scope graph would
// produce false positives across structs) live at the call site,
// not inside the phase methods.
// ============================================================

const HirBuildResult = struct {
    program: zap.hir.Program,
    next_group_id: u32,
};

const Pipeline = struct {
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    options: CompileOptions,
    step: u32,
    total_steps: u32,
    progress_enabled: bool,
    /// Diagnostic count when this pipeline was constructed. `hasNewErrors`
    /// reports only errors added during this pipeline's lifetime, so
    /// per-struct pipelines don't trip on residual errors from earlier
    /// structs sharing the same DiagnosticEngine.
    error_baseline: usize,
    /// When true, `failWith`/`failWithExisting` accumulate errors into the
    /// engine but do not flush them to stderr. Used by the per-struct
    /// loop in `compileStructByStruct`, which renders all collected
    /// diagnostics once at the end so each error appears exactly once.
    defer_render: bool,

    fn init(
        alloc: std.mem.Allocator,
        ctx: *CompilationContext,
        options: CompileOptions,
        starting_step: u32,
        total_steps: u32,
    ) Pipeline {
        return .{
            .alloc = alloc,
            .ctx = ctx,
            .options = options,
            .step = starting_step,
            .total_steps = total_steps,
            .progress_enabled = options.show_progress and total_steps > 0,
            .error_baseline = ctx.diag_engine.errorCount(),
            .defer_render = false,
        };
    }

    /// Errors added since this pipeline was constructed. The shared
    /// DiagnosticEngine accumulates across structs, so a raw
    /// `hasErrors()` check would treat any prior struct's failures as
    /// our own.
    fn hasNewErrors(self: *const Pipeline) bool {
        return self.ctx.diag_engine.errorCount() > self.error_baseline;
    }

    fn progress(self: *Pipeline, name: []const u8) void {
        self.step += 1;
        if (self.progress_enabled) {
            progressStage(self.options, "[{d}/{d}] {s}", .{ self.step, self.total_steps, name });
        }
    }

    fn clearProgress(self: *const Pipeline) void {
        if (self.options.show_progress and (self.progress_enabled or self.options.progress != null)) {
            progressClear(self.options);
        }
    }

    /// Generic-message failure: the underlying call returned an error
    /// without populating any structured diagnostics, so log a "Error
    /// during X" line and bubble the supplied compile error.
    fn failWith(self: *Pipeline, message: []const u8, err: CompileError) CompileError {
        self.ctx.diag_engine.err(message, .{ .start = 0, .end = 0 }) catch {};
        self.clearProgress();
        if (!self.defer_render) emitContextDiagnostics(self.ctx, self.alloc);
        return err;
    }

    /// Structured-error failure: the phase already routed its own
    /// errors into the diagnostic engine; flush them and bubble.
    fn failWithExisting(self: *Pipeline, err: CompileError) CompileError {
        self.clearProgress();
        if (!self.defer_render) emitContextDiagnostics(self.ctx, self.alloc);
        return err;
    }

    fn runSubstitute(self: *Pipeline, program: *const ast.Program) CompileError!ast.Program {
        self.progress("Substitute attributes");
        var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
        const substituted = zap.attr_substitute.substituteAttributes(
            self.alloc,
            program,
            &self.ctx.collector.graph,
            self.ctx.interner,
            &subst_errors,
        ) catch return self.failWith("Error during attribute substitution", error.DesugarFailed);
        for (subst_errors.items) |subst_err| {
            self.ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
        }
        if (self.hasNewErrors()) return self.failWithExisting(error.DesugarFailed);
        return substituted;
    }

    fn runMacroExpand(self: *Pipeline, program: *const ast.Program) CompileError!ast.Program {
        self.progress("Expand macros");
        var macro_engine = zap.MacroEngine.init(self.alloc, self.ctx.interner, &self.ctx.collector.graph);
        macro_engine.setOptimizeMode(self.options.frontend_optimize_mode);
        defer macro_engine.deinit();
        const expanded = macro_engine.expandProgram(program) catch {
            for (macro_engine.errors.items) |macro_err| {
                self.ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
            }
            return self.failWithExisting(error.MacroExpansionFailed);
        };
        for (macro_engine.errors.items) |macro_err| {
            self.ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (self.hasNewErrors()) return self.failWithExisting(error.MacroExpansionFailed);
        return expanded;
    }

    fn runDesugar(self: *Pipeline, program: *const ast.Program) CompileError!ast.Program {
        self.progress("Desugar");
        var desugarer = zap.Desugarer.init(self.alloc, self.ctx.interner, &self.ctx.collector.graph);
        return desugarer.desugarProgram(program) catch
            self.failWith("Error during desugaring", error.DesugarFailed);
    }

    /// Walk `program` and register every function declaration that
    /// the scope graph hasn't already recorded under its parent
    /// struct. Used after macro expansion or desugaring introduces
    /// helpers (e.g., `__for_N` from for-comprehensions) that need a
    /// scope before HIR lowering can resolve their callsites — the
    /// HIR builder compares AST node pointers to determine which
    /// functions belong to the current struct, so the scope graph
    /// entries must reference these new AST nodes.
    fn runReCollectFunctions(self: *Pipeline, program: *const ast.Program) void {
        for (program.structs) |*mod| {
            const mod_scope = self.ctx.collector.graph.findStructScope(mod.name) orelse continue;
            for (mod.items) |item| {
                switch (item) {
                    .function, .priv_function => |func| {
                        const arity: u8 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                        const key = zap.scope.FamilyKey{ .name = func.name, .arity = arity };
                        const scope_data = self.ctx.collector.graph.getScope(mod_scope);
                        if (scope_data.function_families.get(key) == null) {
                            self.ctx.collector.collectFunction(func, mod_scope) catch {};
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Run the type checker against a desugared program. The TypeStore
    /// is either shared across structs (`shared_store != null`, used
    /// by the whole-program monomorphization path so call-site
    /// inferred signatures travel between structs) or owned by the
    /// returned checker. The caller must `deinit` the returned
    /// TypeChecker — the function returns it so the caller can keep
    /// it alive across later phases (e.g., compileForCtfe re-runs
    /// `checkProgram` after escape analysis).
    fn runTypeCheck(
        self: *Pipeline,
        desugared: *const ast.Program,
        shared_store: ?*zap.types.TypeStore,
        check_unused: bool,
    ) CompileError!zap.types.TypeChecker {
        self.progress("Type check");
        var type_checker = if (shared_store) |store| blk: {
            // Per-struct typecheck reuses the shared store; clear
            // call-site-specific inferred signatures from the previous
            // struct so they don't leak between structs.
            store.inferred_signatures.clearRetainingCapacity();
            break :blk zap.types.TypeChecker.initWithSharedStore(self.alloc, store, self.ctx.interner, &self.ctx.collector.graph);
        } else zap.types.TypeChecker.init(self.alloc, self.ctx.interner, &self.ctx.collector.graph);
        errdefer type_checker.deinit();
        type_checker.allow_external_static_references = self.options.allow_external_static_references;

        type_checker.checkProgram(desugared) catch {};
        if (check_unused) type_checker.checkUnusedBindings() catch {};
        self.routeTypeCheckerErrors(&type_checker);
        if (self.hasNewErrors()) return self.failWithExisting(error.TypeCheckFailed);
        return type_checker;
    }

    /// Forward errors collected by `type_checker` into the context's
    /// diagnostic engine. Type-checker errors are always hard errors —
    /// strict types is a hard language requirement, not an opt-in.
    /// Pulled out as a helper because compileForCtfe also needs to
    /// drain the checker after a second-pass `checkProgram` once
    /// escape analysis has populated borrow diagnostics.
    fn routeTypeCheckerErrors(self: *Pipeline, type_checker: *const zap.types.TypeChecker) void {
        for (type_checker.errors.items) |type_err| {
            self.ctx.diag_engine.reportDiagnostic(.{
                .severity = type_err.severity orelse .@"error",
                .message = type_err.message,
                .span = type_err.span,
                .label = type_err.label,
                .help = type_err.help,
                .secondary_spans = type_err.secondary_spans,
            }) catch {};
        }
    }

    /// Build HIR from a desugared program. `group_id_offset` lets the
    /// whole-program pipeline assign globally-unique function group
    /// IDs across structs; pass 0 for a single-struct run.
    fn runHirBuild(
        self: *Pipeline,
        desugared: *const ast.Program,
        type_store: *zap.types.TypeStore,
        group_id_offset: u32,
    ) CompileError!HirBuildResult {
        self.progress("HIR");
        var hir_builder = zap.hir.HirBuilder.init(self.alloc, self.ctx.interner, &self.ctx.collector.graph, type_store);
        hir_builder.next_group_id = group_id_offset;
        hir_builder.allow_external_static_references = self.options.allow_external_static_references;
        const hir_program = hir_builder.buildProgram(desugared) catch {
            for (hir_builder.errors.items) |hir_err| {
                self.ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
            }
            return self.failWithExisting(error.HirFailed);
        };
        for (hir_builder.errors.items) |hir_err| {
            self.ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        if (self.hasNewErrors()) return self.failWithExisting(error.HirFailed);
        return .{ .program = hir_program, .next_group_id = hir_builder.next_group_id };
    }

    fn runMonomorphize(
        self: *Pipeline,
        hir_program: *const zap.hir.Program,
        type_store: *zap.types.TypeStore,
        next_group_id: *u32,
    ) CompileError!zap.hir.Program {
        const result = zap.monomorphize.monomorphize(self.alloc, hir_program, type_store, next_group_id, self.ctx.interner) catch
            return self.failWith("Error during monomorphization", error.HirFailed);
        return result.program;
    }

    /// Result of an IR-lowering phase: the lowered IR program plus the
    /// ARC-ownership side table that Phase 4 of the k-nucleotide RSS
    /// gap implementation plan computes during the same phase.
    pub const IrLoweringResult = struct {
        program: ir.Program,
        arc_ownership: zap.arc_liveness.ProgramArcOwnership,
    };

    fn runIrLowering(
        self: *Pipeline,
        hir_program: *const zap.hir.Program,
        type_store: *zap.types.TypeStore,
    ) CompileError!IrLoweringResult {
        self.progress("IR");
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, self.ctx.interner);
        ir_builder.type_store = type_store;
        ir_builder.scope_graph = &self.ctx.collector.graph;
        defer ir_builder.deinit();
        var program = ir_builder.buildProgram(hir_program) catch
            return self.failWith("Error during IR lowering", error.IrFailed);
        // Phase 4 of the ARC ownership initiative: compute the
        // last-use ownership pass and write back consume modes onto
        // every share_value instruction whose ID is a consume site.
        // The returned table is threaded downstream so the ZIR
        // backend can consult `return_source_locals` per function.
        var ownership = zap.arc_liveness.runProgramArcOwnership(self.alloc, &program, type_store) catch
            return self.failWith("Error during ARC ownership analysis", error.IrFailed);
        // Phase E.9 of the Phase 6 redux plan: per-callee parameter
        // convention inference. Promotes `.borrowed` to `.owned` for
        // function parameters whose every call site (recursive AND
        // non-recursive) consumes the source local. The promotion is
        // a prerequisite for emitting `move_value` at non-tail call
        // sites in `arc_ownership` (Step 2) and is enforced by V7 in
        // `arc_verifier` (Step 4).
        zap.arc_param_convention.inferConventions(self.alloc, &program, &ownership, type_store) catch
            return self.failWith("Error during ARC parameter convention inference", error.IrFailed);
        // Phase A of the Phase 6 redux plan: run the new ownership
        // classification + verifier passes between `arc_liveness` and
        // `arc_drop_insertion`. Both passes are stubs at this phase
        // (no IR mutation, no rejected programs); they exist so the
        // wiring is in place when subsequent phases populate them.
        runArcOwnershipAndVerify(self.alloc, &program, &ownership, type_store, self.options) catch
            return self.failWith("Error during ARC ownership classification or verification", error.IrFailed);
        // Phase E.9: `runArcOwnershipAndVerify` rewrote share/release
        // pairs into move/(no-release) for owned-convention call
        // sites, which mutates the per-stream liveness shape that
        // `arc_drop_insertion` consumes. Recompute the ownership
        // analysis on the post-rewrite IR so `live_before_ret`,
        // `last_use_map`, and `owned_at_ret` reflect the actual
        // shape drop insertion sees. Without the recompute the drop
        // pass would emit destroys for sources that are now moved
        // through a call (double-free).
        ownership.deinit();
        ownership = zap.arc_liveness.runProgramArcOwnership(self.alloc, &program, type_store) catch
            return self.failWith("Error during ARC ownership analysis (recompute)", error.IrFailed);
        // Phase 6 of the ARC ownership initiative: insert scope-exit
        // `release` IR instructions before every ret-equivalent
        // terminator, using the per-terminator live-before-ret sets
        // recorded by the ownership analyzer. The existing
        // `isReleaseSuppressed` filter in `ZirDriver` (consulting
        // `arc_returned_locals` and `arc_share_skipped`) handles
        // elision automatically at ZIR
        // emission time.
        //
        // This whole-program path retains drop-insertion in place
        // because it processes the entire program in one pass — there
        // is no later "merged" stage where the inference must re-run.
        // The per-struct path (`runIrLoweringWithTryIdSeed`) defers
        // drop-insertion to `compileStructByStruct`'s Phase 5b so the
        // post-merge uniqueness inference sees a clean `last_use_map` (see
        // the note in `runIrLoweringWithTryIdSeed`).
        runArcDropInsertion(self.alloc, &program, &ownership, type_store, self.options) catch
            return self.failWith("Error during ARC drop insertion", error.IrFailed);
        return .{ .program = program, .arc_ownership = ownership };
    }

    /// Per-struct IR build variant that threads a globally-unique
    /// `__try` ID counter across struct boundaries. Without this,
    /// each per-struct IR build would derive `next_try_id` from the
    /// per-struct max group ID and a `__try` variant produced for
    /// struct A's multi-clause function could share the ID of struct
    /// B's regular HIR group, causing call_direct dispatches to
    /// resolve to the wrong function.
    fn runIrLoweringWithTryIdSeed(
        self: *Pipeline,
        hir_program: *const zap.hir.Program,
        type_store: *zap.types.TypeStore,
        next_try_id: *u32,
        known_name_program: ?*const zap.hir.Program,
    ) CompileError!IrLoweringResult {
        self.progress("IR");
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, self.ctx.interner);
        ir_builder.type_store = type_store;
        ir_builder.scope_graph = &self.ctx.collector.graph;
        ir_builder.next_try_id = next_try_id.*;
        ir_builder.known_name_program = known_name_program;
        defer ir_builder.deinit();
        var program = ir_builder.buildProgram(hir_program) catch
            return self.failWith("Error during IR lowering", error.IrFailed);
        next_try_id.* = ir_builder.next_try_id;
        var ownership = zap.arc_liveness.runProgramArcOwnership(self.alloc, &program, type_store) catch
            return self.failWith("Error during ARC ownership analysis", error.IrFailed);
        // Phase E.9: same per-callee inference as `runIrLowering`.
        // Both pipelines must run the inference before
        // `arc_ownership` so the classifier sees the refined
        // conventions when deciding whether to emit `move_value` at
        // non-tail call sites.
        //
        // NOTE: this per-struct inference necessarily MISSES cross-struct
        // call sites — its `name_to_id` table only contains the
        // current struct's functions, so a call from
        // a flat-list fill loop to `List.set` (defined in a
        // different struct) cannot resolve back to a callee FunctionId
        // and the call site is never recorded against `List.set`'s
        // promotion candidates. The conservative outcome is that
        // wrappers whose only callers live in OTHER structs stay
        // `.borrowed`, and the rc-1 fast path never fires for them.
        //
        // The post-merge re-run in `compileStructByStruct` (Phase 5b)
        // closes that gap by running the same inference against the
        // merged program where every cross-struct call site is
        // visible.
        zap.arc_param_convention.inferConventions(self.alloc, &program, &ownership, type_store) catch
            return self.failWith("Error during ARC parameter convention inference", error.IrFailed);
        // NOTE: `runArcOwnershipAndVerify` (which runs
        // `rewriteOwnedConsumeBuiltinSites`, `classifyAndNormalize`, and
        // `rewriteOwnedConsumeSites`) is intentionally SKIPPED here.
        // These passes rewrite `local_get` instructions into
        // `borrow_value`/`copy_value`/`move_value` based on the CURRENT
        // (per-struct) `param_conventions`. The per-struct convention
        // pass cannot see cross-struct callers, so it leaves slots
        // `.borrowed` that the merged convention pass (run later in
        // `compileStructByStruct`'s Phase 5b) will promote to `.owned`.
        //
        // If classification ran here, the `borrow_value` shapes emitted
        // under the stale per-struct conventions would still be baked
        // into the IR when the merged convention pass runs. The merged
        // classifier is NOT bidirectional — it only re-classifies
        // `local_get`, never pre-emitted `borrow_value`. Callees whose
        // conventions are promoted by the merged pass would then receive
        // args via `borrow_value → share_value`, and the merged
        // `rewriteOwnedConsumeSites` would turn the share into a
        // `move_value` whose source (the borrow) does not own +1. The
        // soundness verifier rejects this in the merged uniqueness
        // pre-flight, blocking promotion entirely.
        //
        // Deferring classification to the merged stage ensures the
        // classifier sees the FINAL conventions across the whole
        // program, so its borrow/copy/move decisions are correct.
        //
        // Drop-insertion is also skipped here (same reason as previously
        // documented): explicit releases pollute `last_use_map` so the
        // merged convention pass's last-use checks would refuse
        // promotions that depend on the release-free shape.
        //
        // Both `runArcOwnershipAndVerify` and `runArcDropInsertion` run
        // exactly once in `compileStructByStruct`'s Phase 5b, AFTER the
        // merged convention inference, so the rewrites and releases
        // land on top of the final convention assignment.
        return .{ .program = program, .arc_ownership = ownership };
    }

    /// CTFE attribute evaluation across the whole IR program. When a
    /// `struct_order` is supplied each struct's attributes are
    /// evaluated in dependency order so each struct can read its
    /// dependencies' resolved values; otherwise the legacy
    /// whole-program evaluator runs. CTFE errors are emitted through
    /// the CTFE struct's own path, so the return is best-effort.
    fn runCtfeAttributes(
        self: *Pipeline,
        ir_program: *ir.Program,
        struct_order: ?[]const []const u8,
    ) void {
        const cache_dir = self.options.cache_dir;
        const opts_hash = ctfeCompileOptionsHash(self.options);
        if (struct_order) |order| {
            _ = zap.ctfe.evaluateStructAttributesInOrder(
                self.alloc,
                ir_program,
                &self.ctx.collector.graph,
                self.ctx.interner,
                order,
                cache_dir,
                opts_hash,
            ) catch {};
        } else {
            _ = zap.ctfe.evaluateComputedAttributes(
                self.alloc,
                ir_program,
                &self.ctx.collector.graph,
                self.ctx.interner,
                cache_dir,
                opts_hash,
            ) catch {};
        }
    }

    /// Per-struct CTFE used when each struct's IR is built in
    /// isolation. Surfaces any errors directly through the CTFE
    /// emit path.
    fn runCtfeAttributesForStruct(
        self: *Pipeline,
        mod_name: []const u8,
        mod_ir: *ir.Program,
    ) void {
        const ctfe_result = zap.ctfe.evaluateComputedAttributesForStruct(
            self.alloc,
            mod_ir,
            &self.ctx.collector.graph,
            self.ctx.interner,
            mod_name,
            self.options.cache_dir,
            ctfeCompileOptionsHash(self.options),
        ) catch null;
        if (ctfe_result) |cr| {
            if (cr.errors.len > 0) zap.ctfe.emitCtfeErrors(self.alloc, cr.errors);
        }
    }

    fn runAnalysisPipelineOnly(
        self: *Pipeline,
        ir_program: *ir.Program,
    ) CompileError!zap.analysis_pipeline.PipelineResult {
        self.progress("Escape analysis");
        const policy = self.options.frontend_optimize_mode.passPolicy();
        return zap.analysis_pipeline.runAnalysisPipelineWithPolicy(self.alloc, ir_program, policy) catch
            return self.failWith("Error during escape analysis", error.IrFailed);
    }

    fn runContificationRewrite(
        self: *Pipeline,
        ir_program: *ir.Program,
        pipeline_result: *zap.analysis_pipeline.PipelineResult,
    ) CompileError!void {
        // Optional contification rewrite: an optimization-only IR rewrite fed
        // by analysis metadata. Debug policy skips it; release policies keep
        // it enabled.
        zap.contification_rewrite.rewriteContifiedContinuations(self.alloc, ir_program, &pipeline_result.context) catch |err| switch (err) {
            error.UnsupportedContifiedRewrite => {},
            else => return error.IrFailed,
        };
    }

    fn runAnalysisAndOptimization(
        self: *Pipeline,
        ir_program: *ir.Program,
    ) CompileError!zap.analysis_pipeline.PipelineResult {
        const policy = self.options.frontend_optimize_mode.passPolicy();
        var pipeline_result = try self.runAnalysisPipelineOnly(ir_program);
        errdefer pipeline_result.deinit();
        if (policy.run_contification) {
            try self.runContificationRewrite(ir_program, &pipeline_result);
        }
        return pipeline_result;
    }
};

/// Compile a single struct's AST through attribute substitution → type
/// check → HIR build. Used by `compileStructByStruct`'s phase-1 loop
/// to gather every struct's HIR before whole-program monomorphization.
fn compileSingleStructHir(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    mod_program: *const ast.Program,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
    options: CompileOptions,
) CompileError!StructHirResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    const desugared = try pipeline.runSubstitute(mod_program);

    // checkUnusedBindings is intentionally skipped — the type checker
    // shares the scope graph across structs but only visits the
    // current struct's bindings, so checking all bindings here would
    // emit false "unused" warnings for bindings declared elsewhere.
    var type_checker = try pipeline.runTypeCheck(&desugared, shared_store, false);
    defer type_checker.deinit();

    const hir_result = try pipeline.runHirBuild(&desugared, shared_store, group_id_offset);
    return .{
        .mod_name = mod_name,
        .hir_program = hir_result.program,
        .next_group_id = hir_result.next_group_id,
    };
}

/// Lower a monomorphized HIR program to IR, then evaluate computed
/// attributes for the struct so downstream structs can read the
/// resolved values. Per-struct half of the IR-lowering loop in
/// `compileStructByStruct`. Returns both the lowered IR and the
/// per-function ARC ownership table the IR-lowering phase produced
/// (Phase 4 of the k-nucleotide RSS gap implementation plan); the
/// caller merges the per-struct ownership tables into a program-wide
/// table that downstream phases consume.
fn compileHirToIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    hir_program: *const zap.hir.Program,
    type_store: *zap.types.TypeStore,
    options: CompileOptions,
    next_try_id: *u32,
    known_name_program: ?*const zap.hir.Program,
) CompileError!Pipeline.IrLoweringResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    var mod_ir_result = try pipeline.runIrLoweringWithTryIdSeed(hir_program, type_store, next_try_id, known_name_program);
    pipeline.runCtfeAttributesForStruct(mod_name, &mod_ir_result.program);
    return mod_ir_result;
}

fn legacyMacroExpandAndDesugar(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
) CompileError!ast.Program {
    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
    macro_engine.setOptimizeMode(optimize_mode);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        return error.MacroExpansionFailed;
    };
    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.hasErrors()) return error.MacroExpansionFailed;

    var desugarer = zap.Desugarer.init(alloc, interner, &collector.graph);
    return desugarer.desugarProgram(&expanded_program) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        return error.DesugarFailed;
    };
}

fn stagedMacroExpandAndDesugar(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    struct_order: []const []const u8,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    options: CompileOptions,
) CompileError!ast.Program {
    const original_structs = buildStructPrograms(alloc, program, interner) catch return error.OutOfMemory;
    var expanded_structs: std.ArrayListUnmanaged(StructProgram) = .empty;
    var seen_structs = std.StringHashMap(void).init(alloc);

    var cumulative_ir = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };
    var compiled_executor = @import("macro.zig").CompiledMacroExecutor.init(alloc, &cumulative_ir);
    defer compiled_executor.deinit();

    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, interner);

    var hir_results: std.ArrayListUnmanaged(StructHirResult) = .empty;
    var group_id_offset: u32 = 0;

    var staged_timer = ZapTimer.start();
    for (struct_order, 0..) |struct_name, struct_index| {
        const original = lookupStructProgramInSlice(original_structs, struct_name) orelse continue;
        progressStage(options, "[macro {d}/{d}] {s}", .{ struct_index + 1, struct_order.len, struct_name });
        staged_timer.reset();
        const desugared = try expandAndDesugarStagedStruct(
            alloc,
            original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
            options.frontend_optimize_mode,
        );
        const expand_ms = staged_timer.lapMs();
        try expanded_structs.append(alloc, .{ .name = original.name, .program = desugared });
        try seen_structs.put(original.name, {});

        const hir_result = try compileStagedStructHir(
            alloc,
            &desugared,
            original.name,
            interner,
            collector,
            diag_engine,
            shared_store,
            group_id_offset,
            options.allow_external_static_references,
        );
        const hir_ms = staged_timer.lapMs();
        group_id_offset = hir_result.next_group_id;
        try hir_results.append(alloc, hir_result);

        cumulative_ir = try rebuildStagedIr(
            alloc,
            hir_results.items,
            interner,
            collector,
            shared_store,
            group_id_offset,
        );
        const rebuild_ms = staged_timer.lapMs();
        if (profilingEnabled() and (expand_ms + hir_ms + rebuild_ms) >= 100) {
            std.debug.print("\n[staged struct={s} expand+desugar_ms={d} stagedHIR_ms={d} rebuildIR_ms={d}]\n", .{ struct_name, expand_ms, hir_ms, rebuild_ms });
        }
    }

    for (original_structs, 0..) |original, original_index| {
        if (seen_structs.contains(original.name)) continue;
        progressStage(options, "[macro extra {d}/{d}] {s}", .{ original_index + 1, original_structs.len, original.name });
        const desugared = try expandAndDesugarStagedStruct(
            alloc,
            &original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
            options.frontend_optimize_mode,
        );
        try expanded_structs.append(alloc, .{ .name = original.name, .program = desugared });
    }

    const top_level_items = try collectUnassignedTopLevelItems(alloc, program);
    const top_level_program: ?ast.Program = if (top_level_items.len > 0) blk: {
        const expanded = try expandAndDesugarTopLevelProgram(
            alloc,
            top_level_items,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
            options.frontend_optimize_mode,
        );
        break :blk expanded;
    } else null;

    const extra_top_level_count: usize = if (top_level_program != null) 1 else 0;
    const slices = try alloc.alloc(ast.Program, expanded_structs.items.len + extra_top_level_count);
    for (expanded_structs.items, 0..) |entry, index| {
        slices[index] = entry.program;
    }
    if (top_level_program) |top_program| {
        slices[expanded_structs.items.len] = top_program;
    }
    return mergePrograms(alloc, slices) catch return error.OutOfMemory;
}

fn stagedMacroExpandAndDesugarCached(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    struct_order: []const []const u8,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    options: CompileOptions,
    cache: *ExpansionCacheWork,
) CompileError!ast.Program {
    const original_structs = buildStructPrograms(alloc, program, interner) catch return error.OutOfMemory;
    var ordered_structs: std.ArrayListUnmanaged(*const StructProgram) = .empty;
    var ordered_seen_structs = std.StringHashMap(void).init(alloc);
    for (struct_order) |struct_name| {
        const original = lookupStructProgramInSlice(original_structs, struct_name) orelse continue;
        try ordered_structs.append(alloc, original);
        try ordered_seen_structs.put(original.name, {});
    }
    for (original_structs) |*original| {
        if (ordered_seen_structs.contains(original.name)) continue;
        try ordered_structs.append(alloc, original);
    }

    const top_level_items = try collectUnassignedTopLevelItems(alloc, program);
    cache.has_unassigned_top_level_items = top_level_items.len > 0;
    const top_level_signature = topLevelItemsSignature(&collector.graph, top_level_items);
    const top_level_expansion_required = topLevelExpansionRequired(
        top_level_items,
        top_level_signature,
        cache,
        original_structs,
    );
    const expansion_required = try alloc.alloc(bool, ordered_structs.items.len);
    for (ordered_structs.items, 0..) |original, index| {
        expansion_required[index] = cache.invalidated_structs.contains(original.name) or
            cache.changed_declaration_structs.contains(original.name) or
            cache.state.expanded_structs.get(original.name) == null;
    }
    const later_expansion_required = try alloc.alloc(bool, ordered_structs.items.len);
    var later_required = top_level_expansion_required;
    var reverse_index = ordered_structs.items.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        later_expansion_required[reverse_index] = later_required;
        later_required = later_required or expansion_required[reverse_index];
    }

    var expanded_structs: std.ArrayListUnmanaged(StructProgram) = .empty;

    var cumulative_ir = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };
    var compiled_executor = @import("macro.zig").CompiledMacroExecutor.init(alloc, &cumulative_ir);
    defer compiled_executor.deinit();

    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, interner);

    var hir_results: std.ArrayListUnmanaged(StructHirResult) = .empty;
    var group_id_offset: u32 = 0;
    var staged_ir_dirty = false;

    var staged_timer = ZapTimer.start();
    for (ordered_structs.items, 0..) |original, struct_index| {
        progressStage(options, "[macro {d}/{d}] {s}", .{ struct_index + 1, ordered_structs.items.len, original.name });
        staged_timer.reset();

        var rebuild_ms: u64 = 0;
        if (expansion_required[struct_index] and staged_ir_dirty) {
            cumulative_ir = try rebuildStagedIr(
                alloc,
                hir_results.items,
                interner,
                collector,
                shared_store,
                group_id_offset,
            );
            rebuild_ms = staged_timer.lapMs();
            staged_ir_dirty = false;
        }

        const expanded = try cachedOrExpandStagedStruct(
            alloc,
            original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
            options.frontend_optimize_mode,
            cache,
        );
        const desugared = expanded.program;
        const expand_ms = staged_timer.lapMs();
        try expanded_structs.append(alloc, .{ .name = original.name, .program = desugared });

        if (!later_expansion_required[struct_index]) {
            if (profilingEnabled() and expand_ms >= 100) {
                std.debug.print("\n[staged struct={s} expand+desugar_ms={d} stagedHIR_ms=0 rebuildIR_ms=0]\n", .{ original.name, expand_ms });
            }
            continue;
        }

        const hir_result = try compileStagedStructHir(
            alloc,
            &desugared,
            original.name,
            interner,
            collector,
            diag_engine,
            shared_store,
            group_id_offset,
            options.allow_external_static_references,
        );
        const hir_ms = staged_timer.lapMs();
        group_id_offset = hir_result.next_group_id;
        try hir_results.append(alloc, hir_result);
        staged_ir_dirty = true;
        if (profilingEnabled() and (expand_ms + hir_ms + rebuild_ms) >= 100) {
            std.debug.print("\n[staged struct={s} expand+desugar_ms={d} stagedHIR_ms={d} rebuildIR_ms={d}]\n", .{ original.name, expand_ms, hir_ms, rebuild_ms });
        }
    }

    if (top_level_expansion_required and staged_ir_dirty) {
        cumulative_ir = try rebuildStagedIr(
            alloc,
            hir_results.items,
            interner,
            collector,
            shared_store,
            group_id_offset,
        );
        staged_ir_dirty = false;
    }

    const top_level_program = try cachedOrExpandTopLevelProgram(
        alloc,
        top_level_items,
        top_level_signature,
        top_level_expansion_required,
        interner,
        collector,
        diag_engine,
        &compiled_executor,
        options.frontend_optimize_mode,
        cache,
    );

    const extra_top_level_count: usize = if (top_level_program != null) 1 else 0;
    const slices = try alloc.alloc(ast.Program, expanded_structs.items.len + extra_top_level_count);
    for (expanded_structs.items, 0..) |entry, index| {
        slices[index] = entry.program;
    }
    if (top_level_program) |top_program| {
        slices[expanded_structs.items.len] = top_program;
    }
    return mergePrograms(alloc, slices) catch return error.OutOfMemory;
}

fn topLevelExpansionRequired(
    top_level_items: []const ast.TopItem,
    top_level_signature: ?u64,
    cache: *ExpansionCacheWork,
    original_structs: []const StructProgram,
) bool {
    if (top_level_items.len == 0) return false;
    if (cache.changed_declaration_structs.contains("")) return true;
    const signature = top_level_signature orelse return true;
    if (invalidatedStructsMayAffectTopLevelMacros(original_structs, cache)) return true;
    const cached = cache.state.expanded_top_level orelse return true;
    return cached.signature != signature;
}

fn invalidatedStructsMayAffectTopLevelMacros(
    original_structs: []const StructProgram,
    cache: *ExpansionCacheWork,
) bool {
    if (structSetMayAffectTopLevelMacros(original_structs, cache, cache.invalidated_structs)) return true;
    return structSetMayAffectTopLevelMacros(original_structs, cache, cache.changed_declaration_structs);
}

fn structSetMayAffectTopLevelMacros(
    original_structs: []const StructProgram,
    cache: *ExpansionCacheWork,
    struct_names: *const std.StringHashMap(void),
) bool {
    var iter = struct_names.keyIterator();
    while (iter.next()) |struct_name| {
        if (lookupStructProgramInSlice(original_structs, struct_name.*)) |current| {
            if (structProgramDeclaresMacro(current.program)) return true;
        }
        if (cache.state.expanded_structs.get(struct_name.*)) |previous| {
            if (previous.declares_macro_provider) return true;
        }
    }
    return false;
}

fn structProgramDeclaresMacro(program: ast.Program) bool {
    for (program.structs) |struct_decl| {
        for (struct_decl.items) |item| {
            switch (item) {
                .macro, .priv_macro => return true,
                else => {},
            }
        }
    }
    for (program.top_items) |item| {
        switch (item) {
            .macro, .priv_macro => return true,
            else => {},
        }
    }
    return false;
}

fn topLevelItemsSignature(
    graph: *const zap.scope.ScopeGraph,
    top_level_items: []const ast.TopItem,
) ?u64 {
    if (top_level_items.len == 0) return null;

    var hasher = std.hash.Wyhash.init(0);
    var item_count: u64 = @intCast(top_level_items.len);
    hasher.update(std.mem.asBytes(&item_count));

    for (top_level_items) |item| {
        const tag_value: u32 = @intFromEnum(std.meta.activeTag(item));
        hasher.update(std.mem.asBytes(&tag_value));

        const span = topItemSourceSpan(item);
        const source_id = span.source_id orelse return null;
        const source = graph.sourceContentById(source_id);
        if (source.len == 0) return null;
        if (span.start >= span.end) return null;
        if (span.end > source.len) return null;

        var start: u32 = span.start;
        var end: u32 = span.end;
        hasher.update(std.mem.asBytes(&source_id));
        hasher.update(std.mem.asBytes(&start));
        hasher.update(std.mem.asBytes(&end));
        hasher.update(source[start..end]);
    }

    return hasher.final();
}

fn topItemSourceSpan(item: ast.TopItem) ast.SourceSpan {
    return switch (item) {
        .struct_decl => |decl| decl.meta.span,
        .priv_struct_decl => |decl| decl.meta.span,
        .protocol => |decl| decl.meta.span,
        .priv_protocol => |decl| decl.meta.span,
        .impl_decl => |decl| decl.meta.span,
        .priv_impl_decl => |decl| decl.meta.span,
        .type_decl => |decl| decl.meta.span,
        .opaque_decl => |decl| decl.meta.span,
        .union_decl => |decl| decl.meta.span,
        .function => |decl| decl.meta.span,
        .priv_function => |decl| decl.meta.span,
        .macro => |decl| decl.meta.span,
        .priv_macro => |decl| decl.meta.span,
        .attribute => |decl| decl.meta.span,
        .error_decl => |decl| decl.meta.span,
        .priv_error_decl => |decl| decl.meta.span,
    };
}

fn cachedOrExpandTopLevelProgram(
    alloc: std.mem.Allocator,
    top_level_items: []const ast.TopItem,
    top_level_signature: ?u64,
    expansion_required: bool,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
    cache: *ExpansionCacheWork,
) CompileError!?ast.Program {
    if (top_level_items.len == 0) return null;

    if (!expansion_required) {
        if (cache.state.expanded_top_level) |entry| {
            try updateImplDeclsInProgram(collector, &entry.program);
            return entry.program;
        }
    }

    const signature = top_level_signature orelse {
        const expanded = try expandAndDesugarTopLevelProgram(
            alloc,
            top_level_items,
            interner,
            collector,
            diag_engine,
            compiled_executor,
            optimize_mode,
        );
        try updateImplDeclsInProgram(collector, &expanded);
        return expanded;
    };

    const artifact = cache.state.allocator.create(FrontendIncrementalState.CachedExpandedTopLevel) catch
        return error.OutOfMemory;
    artifact.* = .{
        .arena = std.heap.ArenaAllocator.init(cache.state.allocator),
        .signature = signature,
        .program = .{ .structs = &.{}, .top_items = &.{} },
    };
    errdefer artifact.destroy(cache.state.allocator);

    const artifact_alloc = artifact.arena.allocator();
    const expanded_program = try expandAndDesugarTopLevelProgram(
        artifact_alloc,
        top_level_items,
        interner,
        collector,
        diag_engine,
        compiled_executor,
        optimize_mode,
    );
    artifact.program = try cloneAstProgramOwned(artifact_alloc, expanded_program, interner);
    try updateImplDeclsInProgram(collector, &artifact.program);
    cache.new_expanded_top_level.* = artifact;
    return artifact.program;
}

fn cachedOrExpandStagedStruct(
    alloc: std.mem.Allocator,
    original: *const StructProgram,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
    cache: *ExpansionCacheWork,
) CompileError!StagedExpansionResult {
    const cached = cache.state.expanded_structs.get(original.name);
    if (!cache.invalidated_structs.contains(original.name) and
        !cache.changed_declaration_structs.contains(original.name))
    {
        if (cached) |entry| {
            try reCollectFunctionsInProgram(collector, &entry.program);
            try updateImplDeclsInProgram(collector, &entry.program);
            return .{ .program = entry.program, .cache_hit = true };
        }
    }

    const artifact = cache.state.allocator.create(FrontendIncrementalState.CachedExpandedStruct) catch
        return error.OutOfMemory;
    artifact.* = .{
        .arena = std.heap.ArenaAllocator.init(cache.state.allocator),
        .name = &.{},
        .declares_macro_provider = structProgramDeclaresMacro(original.program),
        .program = .{ .structs = &.{}, .top_items = &.{} },
    };
    errdefer artifact.destroy(cache.state.allocator);

    const artifact_alloc = artifact.arena.allocator();
    artifact.name = artifact_alloc.dupe(u8, original.name) catch return error.OutOfMemory;
    const expanded_program = try expandAndDesugarStagedStruct(
        artifact_alloc,
        original,
        interner,
        collector,
        diag_engine,
        compiled_executor,
        optimize_mode,
    );
    artifact.program = try cloneAstProgramOwned(artifact_alloc, expanded_program, interner);
    try reCollectFunctionsInProgram(collector, &artifact.program);
    try updateImplDeclsInProgram(collector, &artifact.program);
    try cache.new_expanded_structs.append(alloc, artifact);
    return .{ .program = artifact.program, .cache_hit = false };
}

fn collectUnassignedTopLevelItems(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
) ![]const ast.TopItem {
    var items: std.ArrayListUnmanaged(ast.TopItem) = .empty;
    for (program.top_items) |item| {
        if (topItemIsAssignedToStruct(item, program.structs)) continue;
        try items.append(alloc, item);
    }
    return try items.toOwnedSlice(alloc);
}

fn topItemIsAssignedToStruct(item: ast.TopItem, structs: []const ast.StructDecl) bool {
    const target_type = switch (item) {
        .impl_decl => |impl| impl.target_type,
        .priv_impl_decl => |impl| impl.target_type,
        else => return false,
    };
    for (structs) |structure| {
        if (structNamesEqual(structure.name, target_type)) return true;
    }
    return false;
}

fn expandAndDesugarTopLevelProgram(
    alloc: std.mem.Allocator,
    top_items: []const ast.TopItem,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
) CompileError!ast.Program {
    const top_program = ast.Program{ .structs = &.{}, .top_items = top_items };
    const error_baseline = diag_engine.errorCount();

    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
    defer macro_engine.deinit();
    macro_engine.setCompiledExecutor(compiled_executor);
    macro_engine.setOptimizeMode(optimize_mode);
    const expanded = macro_engine.expandProgram(&top_program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        return error.MacroExpansionFailed;
    };
    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.errorCount() > error_baseline) return error.MacroExpansionFailed;

    var desugarer = zap.Desugarer.init(alloc, interner, &collector.graph);
    return desugarer.desugarProgram(&expanded) catch {
        diag_engine.err("Error during top-level desugaring", .{ .start = 0, .end = 0 }) catch {};
        return error.DesugarFailed;
    };
}

fn expandAndDesugarStagedStruct(
    alloc: std.mem.Allocator,
    struct_program: *const StructProgram,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
) CompileError!ast.Program {
    const error_baseline = diag_engine.errorCount();

    // Substitute @attr references with their values before macro
    // expansion. This mirrors `compileForCtfe`'s pipeline (substitute
    // → macro expand → desugar) so attribute values reach later
    // passes regardless of which compilation path runs.
    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const substituted = zap.attr_substitute.substituteAttributes(
        alloc,
        &struct_program.program,
        &collector.graph,
        interner,
        &subst_errors,
    ) catch {
        diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (diag_engine.errorCount() > error_baseline) return error.DesugarFailed;

    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
    defer macro_engine.deinit();
    macro_engine.setCompiledExecutor(compiled_executor);
    macro_engine.setOptimizeMode(optimize_mode);
    const expanded = macro_engine.expandProgram(&substituted) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        return error.MacroExpansionFailed;
    };
    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.errorCount() > error_baseline) return error.MacroExpansionFailed;

    try reCollectFunctionsInProgram(collector, &expanded);
    try updateImplDeclsInProgram(collector, &expanded);

    var desugarer = zap.Desugarer.init(alloc, interner, &collector.graph);
    const desugared = desugarer.desugarProgram(&expanded) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        return error.DesugarFailed;
    };
    try reCollectFunctionsInProgram(collector, &desugared);
    try updateImplDeclsInProgram(collector, &desugared);
    try expandGraphImplsForProgram(alloc, &desugared, interner, collector, diag_engine, compiled_executor, optimize_mode);
    return desugared;
}

fn expandGraphImplsForProgram(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
    optimize_mode: frontend_policy.FrontendOptimizeMode,
) CompileError!void {
    for (collector.graph.impls.items) |*entry| {
        var target_in_program = false;
        for (program.structs) |struct_decl| {
            if (structNamesEqual(struct_decl.name, entry.target_type)) {
                target_in_program = true;
                break;
            }
        }
        if (!target_in_program) continue;

        const top_item: ast.TopItem = if (entry.is_private)
            .{ .priv_impl_decl = entry.decl }
        else
            .{ .impl_decl = entry.decl };
        const top_items = alloc.alloc(ast.TopItem, 1) catch return error.OutOfMemory;
        top_items[0] = top_item;
        const impl_program = ast.Program{ .structs = &.{}, .top_items = top_items };

        var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
        defer macro_engine.deinit();
        macro_engine.setCompiledExecutor(compiled_executor);
        macro_engine.setOptimizeMode(optimize_mode);
        const expanded = macro_engine.expandProgram(&impl_program) catch {
            for (macro_engine.errors.items) |macro_err| {
                diag_engine.err(macro_err.message, macro_err.span) catch {};
            }
            return error.MacroExpansionFailed;
        };
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }

        var desugarer = zap.Desugarer.init(alloc, interner, &collector.graph);
        const desugared_impl_program = desugarer.desugarProgram(&expanded) catch {
            diag_engine.err("Error during impl desugaring", .{ .start = 0, .end = 0 }) catch {};
            return error.DesugarFailed;
        };
        if (desugared_impl_program.top_items.len > 0) {
            const desugared_impl = switch (desugared_impl_program.top_items[0]) {
                .impl_decl => |decl| decl,
                .priv_impl_decl => |decl| decl,
                else => entry.decl,
            };
            entry.protocol_name = desugared_impl.protocol_name;
            entry.target_type = desugared_impl.target_type;
            entry.decl = desugared_impl;
        }
    }
}

fn compileStagedStructHir(
    alloc: std.mem.Allocator,
    desugared: *const ast.Program,
    struct_name: []const u8,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
    allow_external_static_references: bool,
) CompileError!StructHirResult {
    const error_baseline = diag_engine.errorCount();
    if (findUndesugaredMacroForm(desugared) orelse findUndesugaredMacroFormInGraphImpls(&collector.graph, desugared)) |form| {
        diag_engine.err(
            std.fmt.allocPrint(
                alloc,
                "staged macro expansion left raw `{s}` before HIR in `{s}`",
                .{ form.name, struct_name },
            ) catch "staged macro expansion left raw macro form before HIR",
            form.span,
        ) catch {};
        return error.MacroExpansionFailed;
    }
    shared_store.inferred_signatures.clearRetainingCapacity();

    var sub_timer = ZapTimer.start();
    var type_checker = zap.types.TypeChecker.initWithSharedStore(alloc, shared_store, interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.allow_external_static_references = allow_external_static_references;
    type_checker.checkProgram(desugared) catch {};
    const tc_ms = sub_timer.lapMs();
    for (type_checker.errors.items) |type_err| {
        diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse .@"error",
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (diag_engine.errorCount() > error_baseline) return error.TypeCheckFailed;

    var hir_builder = zap.hir.HirBuilder.init(alloc, interner, &collector.graph, shared_store);
    hir_builder.next_group_id = group_id_offset;
    hir_builder.allow_external_static_references = allow_external_static_references;
    sub_timer.reset();
    const hir_program = hir_builder.buildProgram(desugared) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        return error.HirFailed;
    };
    for (hir_builder.errors.items) |hir_err| {
        diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    const hb_ms = sub_timer.lapMs();
    if (profilingEnabled() and (tc_ms + hb_ms) >= 100) {
        std.debug.print("\n[hir-stage struct={s} type_check_ms={d} hir_build_ms={d}]\n", .{ struct_name, tc_ms, hb_ms });
    }
    if (diag_engine.errorCount() > error_baseline) return error.HirFailed;

    return .{
        .mod_name = struct_name,
        .hir_program = hir_program,
        .next_group_id = hir_builder.next_group_id,
    };
}

const UndesugaredMacroForm = struct {
    name: []const u8,
    span: ast.SourceSpan,
};

fn findUndesugaredMacroForm(program: *const ast.Program) ?UndesugaredMacroForm {
    for (program.structs) |struct_decl| {
        for (struct_decl.items) |item| {
            if (findUndesugaredMacroFormInStructItem(item)) |form| return form;
        }
    }
    for (program.top_items) |item| {
        if (findUndesugaredMacroFormInTopItem(item)) |form| return form;
    }
    return null;
}

fn findUndesugaredMacroFormInGraphImpls(graph: *const zap.scope.ScopeGraph, program: *const ast.Program) ?UndesugaredMacroForm {
    for (graph.impls.items) |impl_entry| {
        var target_in_program = false;
        for (program.structs) |struct_decl| {
            if (structNamesEqual(struct_decl.name, impl_entry.target_type)) {
                target_in_program = true;
                break;
            }
        }
        if (!target_in_program) continue;
        if (findUndesugaredMacroFormInImpl(impl_entry.decl)) |form| return form;
    }
    return null;
}

fn findUndesugaredMacroFormInTopItem(item: ast.TopItem) ?UndesugaredMacroForm {
    return switch (item) {
        .function, .priv_function => |function| findUndesugaredMacroFormInFunction(function),
        .impl_decl => |impl| findUndesugaredMacroFormInImpl(impl),
        .priv_impl_decl => |impl| findUndesugaredMacroFormInImpl(impl),
        else => null,
    };
}

fn findUndesugaredMacroFormInStructItem(item: ast.StructItem) ?UndesugaredMacroForm {
    return switch (item) {
        .function, .priv_function => |function| findUndesugaredMacroFormInFunction(function),
        .struct_level_expr => |expr| findUndesugaredMacroFormInExpr(expr),
        else => null,
    };
}

fn findUndesugaredMacroFormInImpl(impl: *const ast.ImplDecl) ?UndesugaredMacroForm {
    for (impl.functions) |function| {
        if (findUndesugaredMacroFormInFunction(function)) |form| return form;
    }
    return null;
}

fn findUndesugaredMacroFormInFunction(function: *const ast.FunctionDecl) ?UndesugaredMacroForm {
    for (function.clauses) |clause| {
        if (clause.body) |body| {
            for (body) |stmt| {
                if (findUndesugaredMacroFormInStmt(stmt)) |form| return form;
            }
        }
    }
    return null;
}

fn findUndesugaredMacroFormInStmt(stmt: ast.Stmt) ?UndesugaredMacroForm {
    return switch (stmt) {
        .expr => |expr| findUndesugaredMacroFormInExpr(expr),
        .assignment => |assignment| findUndesugaredMacroFormInExpr(assignment.value),
        .function_decl => |function| findUndesugaredMacroFormInFunction(function),
        else => null,
    };
}

fn findUndesugaredMacroFormInExpr(expr: *const ast.Expr) ?UndesugaredMacroForm {
    return switch (expr.*) {
        .if_expr => |if_expr| .{ .name = "if", .span = if_expr.meta.span },
        .cond_expr => |cond_expr| .{ .name = "cond", .span = cond_expr.meta.span },
        .pipe => |pipe| .{ .name = "|>", .span = pipe.meta.span },
        .binary_op => |binary| findUndesugaredMacroFormInExpr(binary.lhs) orelse findUndesugaredMacroFormInExpr(binary.rhs),
        .unary_op => |unary| findUndesugaredMacroFormInExpr(unary.operand),
        .call => |call| blk: {
            if (findUndesugaredMacroFormInExpr(call.callee)) |form| break :blk form;
            for (call.args) |arg| {
                if (findUndesugaredMacroFormInExpr(arg)) |form| break :blk form;
            }
            break :blk null;
        },
        .field_access => |field| findUndesugaredMacroFormInExpr(field.object),
        .case_expr => |case_expr| blk: {
            if (findUndesugaredMacroFormInExpr(case_expr.scrutinee)) |form| break :blk form;
            for (case_expr.clauses) |clause| {
                if (clause.guard) |guard| {
                    if (findUndesugaredMacroFormInExpr(guard)) |form| break :blk form;
                }
                for (clause.body) |stmt| {
                    if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
                }
            }
            break :blk null;
        },
        .tuple => |tuple| blk: {
            for (tuple.elements) |element| {
                if (findUndesugaredMacroFormInExpr(element)) |form| break :blk form;
            }
            break :blk null;
        },
        .list => |list| blk: {
            for (list.elements) |element| {
                if (findUndesugaredMacroFormInExpr(element)) |form| break :blk form;
            }
            break :blk null;
        },
        .map => |map| blk: {
            for (map.fields) |field| {
                if (findUndesugaredMacroFormInExpr(field.key)) |form| break :blk form;
                if (findUndesugaredMacroFormInExpr(field.value)) |form| break :blk form;
            }
            break :blk null;
        },
        .struct_expr => |struct_expr| blk: {
            for (struct_expr.fields) |field| {
                if (findUndesugaredMacroFormInExpr(field.value)) |form| break :blk form;
            }
            break :blk null;
        },
        .block => |block| blk: {
            for (block.stmts) |stmt| {
                if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
            }
            break :blk null;
        },
        .panic_expr => |panic_expr| findUndesugaredMacroFormInExpr(panic_expr.message),
        .raise_expr => |raise_expr| findUndesugaredMacroFormInExpr(raise_expr.value),
        .unwrap => |unwrap| findUndesugaredMacroFormInExpr(unwrap.expr),
        .type_annotated => |type_annotated| findUndesugaredMacroFormInExpr(type_annotated.expr),
        .anonymous_function => |anonymous| findUndesugaredMacroFormInFunction(anonymous.decl),
        .list_cons_expr => |list_cons| findUndesugaredMacroFormInExpr(list_cons.head) orelse findUndesugaredMacroFormInExpr(list_cons.tail),
        .error_pipe => |error_pipe| findUndesugaredMacroFormInErrorPipeChain(error_pipe.chain) orelse findUndesugaredMacroFormInErrorHandler(error_pipe.handler),
        .try_rescue => |try_rescue| blk: {
            for (try_rescue.body) |stmt| {
                if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
            }
            for (try_rescue.rescue_clauses) |clause| {
                if (clause.guard) |guard| {
                    if (findUndesugaredMacroFormInExpr(guard)) |form| break :blk form;
                }
                for (clause.body) |stmt| {
                    if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
                }
            }
            if (try_rescue.after_block) |cleanup| {
                for (cleanup) |stmt| {
                    if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn findUndesugaredMacroFormInErrorPipeChain(expr: *const ast.Expr) ?UndesugaredMacroForm {
    return switch (expr.*) {
        .pipe => |pipe| findUndesugaredMacroFormInErrorPipeChain(pipe.lhs) orelse findUndesugaredMacroFormInErrorPipeChain(pipe.rhs),
        else => findUndesugaredMacroFormInExpr(expr),
    };
}

fn findUndesugaredMacroFormInErrorHandler(handler: ast.ErrorHandler) ?UndesugaredMacroForm {
    return switch (handler) {
        .function => |function| findUndesugaredMacroFormInExpr(function),
        .block => |clauses| blk: {
            for (clauses) |clause| {
                if (clause.guard) |guard| {
                    if (findUndesugaredMacroFormInExpr(guard)) |form| break :blk form;
                }
                for (clause.body) |stmt| {
                    if (findUndesugaredMacroFormInStmt(stmt)) |form| break :blk form;
                }
            }
            break :blk null;
        },
    };
}

fn rebuildStagedIr(
    alloc: std.mem.Allocator,
    hir_results: []const StructHirResult,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
) CompileError!ir.Program {
    var all_hir_structs: std.ArrayListUnmanaged(zap.hir.Struct) = .empty;
    var all_hir_top_fns: std.ArrayListUnmanaged(zap.hir.FunctionGroup) = .empty;
    var all_hir_protocols: std.ArrayListUnmanaged(zap.hir.ProtocolInfo) = .empty;
    var all_hir_impls: std.ArrayListUnmanaged(zap.hir.ImplInfo) = .empty;
    for (hir_results) |*result| {
        for (result.hir_program.structs) |mod| {
            all_hir_structs.append(alloc, mod) catch return error.OutOfMemory;
        }
        for (result.hir_program.top_functions) |top_function| {
            all_hir_top_fns.append(alloc, top_function) catch return error.OutOfMemory;
        }
        for (result.hir_program.protocols) |protocol| {
            all_hir_protocols.append(alloc, protocol) catch return error.OutOfMemory;
        }
        for (result.hir_program.impls) |impl_info| {
            all_hir_impls.append(alloc, impl_info) catch return error.OutOfMemory;
        }
    }

    var combined_hir = zap.hir.Program{
        .structs = all_hir_structs.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .top_functions = all_hir_top_fns.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .protocols = all_hir_protocols.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .impls = all_hir_impls.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };

    var mono_next = group_id_offset;
    const mono_result = zap.monomorphize.monomorphize(alloc, &combined_hir, shared_store, &mono_next, interner) catch
        return error.HirFailed;
    combined_hir = mono_result.program;

    var ir_builder = zap.ir.IrBuilder.init(alloc, interner);
    ir_builder.type_store = shared_store;
    ir_builder.scope_graph = &collector.graph;
    defer ir_builder.deinit();
    const program = ir_builder.buildProgram(&combined_hir) catch return error.IrFailed;
    zap.arc_liveness.runProgramArcLiveness(alloc, &program, shared_store) catch return error.IrFailed;
    return program;
}

fn lookupStructProgramInSlice(struct_programs: []const StructProgram, struct_name: []const u8) ?*const StructProgram {
    for (struct_programs) |*entry| {
        if (std.mem.eql(u8, entry.name, struct_name)) return entry;
    }
    return null;
}

fn reCollectFunctionsInProgram(collector: *zap.Collector, program: *const ast.Program) CompileError!void {
    collector.refreshStructFunctionDeclarations(program) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CollectFailed,
    };
}

fn updateImplDeclsInProgram(collector: *zap.Collector, program: *const ast.Program) CompileError!void {
    for (program.top_items) |item| {
        const impl = switch (item) {
            .impl_decl => |decl| decl,
            .priv_impl_decl => |decl| decl,
            else => continue,
        };
        for (collector.graph.impls.items) |*entry| {
            if (!structNamesEqual(entry.protocol_name, impl.protocol_name)) continue;
            if (!structNamesEqual(entry.target_type, impl.target_type)) continue;
            collector.refreshImplDeclaration(entry, impl) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CollectFailed,
            };
        }
    }
    collector.registerImplFunctionsInTargetScopes() catch return error.OutOfMemory;
}

fn structNamesEqual(left: ast.StructName, right: ast.StructName) bool {
    if (left.parts.len != right.parts.len) return false;
    for (left.parts, right.parts) |left_part, right_part| {
        if (left_part != right_part) return false;
    }
    return true;
}

/// True per-struct compilation: process each struct independently through
/// macro → desugar → typecheck → HIR → IR, in dependency order.
///
/// After each struct's IR is built, runs CTFE on its computed attributes
/// and registers the results for downstream structs to reference.
///
/// This is the architecture described in ir-interpreter-plan.md Phase 5:
/// "split macro expansion, desugaring, typechecking, HIR, and IR lowering
/// into real per-struct units."
///
/// Requires that collectAll has already populated the shared scope graph
/// with all structs' declarations. Each struct compiles against the full
/// scope graph (for cross-struct type resolution) but only processes its
/// own AST through the pipeline.
const PreFinalIrResult = struct {
    shared_store: *zap.types.TypeStore,
    program: ir.Program,
    arc_ownership: zap.arc_liveness.ProgramArcOwnership,
};

fn compileStructsToPreFinalIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    struct_order: []const []const u8,
    options: CompileOptions,
) CompileError!PreFinalIrResult {
    var phase_timer = ZapTimer.start();
    var per_struct_timer = ZapTimer.start();
    var hir_results: std.ArrayListUnmanaged(StructHirResult) = .empty;
    var group_id_offset: u32 = 0;

    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, ctx.interner);

    var lowered_structs = std.StringHashMap(void).init(alloc);
    defer lowered_structs.deinit();
    for (struct_order, 0..) |mod_name, mod_idx| {
        if (lowered_structs.contains(mod_name)) continue;
        progressStage(options, "[hir {d}/{d}] {s}", .{ mod_idx + 1, struct_order.len, mod_name });
        const mod_program = lookupStructProgram(ctx, mod_name) orelse continue;
        per_struct_timer.reset();
        const hir_result = compileSingleStructHir(alloc, ctx, mod_name, mod_program, shared_store, group_id_offset, options) catch continue;
        const hir_elapsed_ms = per_struct_timer.readMs();
        if (profilingEnabled() and hir_elapsed_ms >= 100) {
            std.debug.print("\n[stage HIR struct={s}] ms={d}\n", .{ mod_name, hir_elapsed_ms });
        }
        group_id_offset = hir_result.next_group_id;
        hir_results.append(alloc, hir_result) catch return error.OutOfMemory;
        lowered_structs.put(mod_name, {}) catch return error.OutOfMemory;
    }
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase1-AllHIR] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    progressStage(options, "HIR: merge", .{});
    var all_hir_structs: std.ArrayListUnmanaged(zap.hir.Struct) = .empty;
    var all_hir_top_fns: std.ArrayListUnmanaged(zap.hir.FunctionGroup) = .empty;
    var all_hir_protocols: std.ArrayListUnmanaged(zap.hir.ProtocolInfo) = .empty;
    var all_hir_impls: std.ArrayListUnmanaged(zap.hir.ImplInfo) = .empty;
    for (hir_results.items) |*result| {
        for (result.hir_program.structs) |mod| {
            all_hir_structs.append(alloc, mod) catch return error.OutOfMemory;
        }
        for (result.hir_program.top_functions) |top_function| {
            all_hir_top_fns.append(alloc, top_function) catch return error.OutOfMemory;
        }
        for (result.hir_program.protocols) |protocol| {
            all_hir_protocols.append(alloc, protocol) catch return error.OutOfMemory;
        }
        for (result.hir_program.impls) |impl_info| {
            all_hir_impls.append(alloc, impl_info) catch return error.OutOfMemory;
        }
    }

    var combined_hir = zap.hir.Program{
        .structs = all_hir_structs.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .top_functions = all_hir_top_fns.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .protocols = all_hir_protocols.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .impls = all_hir_impls.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase2-MergeHIR] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    progressStage(options, "Monomorphize", .{});
    var mono_next = group_id_offset;
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    combined_hir = try pipeline.runMonomorphize(&combined_hir, shared_store, &mono_next);
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase3-Monomorphize] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    var all_functions: std.ArrayListUnmanaged(ir.Function) = .empty;
    var all_type_defs: std.ArrayListUnmanaged(ir.TypeDef) = .empty;
    var entry_id: ?ir.FunctionId = null;
    var next_try_id: u32 = mono_next;
    var combined_arc_ownership = zap.arc_liveness.ProgramArcOwnership.init(alloc);
    errdefer combined_arc_ownership.deinit();

    for (combined_hir.structs, 0..) |mod, mod_index| {
        const mod_name_str = if (mod.name.parts.len > 0) ctx.interner.get(mod.name.parts[mod.name.parts.len - 1]) else "unknown";
        progressStage(options, "[ir {d}/{d}] {s}", .{ mod_index + 1, combined_hir.structs.len, mod_name_str });
        const single_mod_hir = zap.hir.Program{
            .structs = try alloc.dupe(zap.hir.Struct, &.{mod}),
            .top_functions = &.{},
        };
        per_struct_timer.reset();
        const mod_lower = compileHirToIr(alloc, ctx, mod_name_str, &single_mod_hir, shared_store, options, &next_try_id, &combined_hir) catch {
            continue;
        };
        const mod_ir = mod_lower.program;
        try mergeArcOwnership(alloc, &combined_arc_ownership, mod_lower.arc_ownership);
        const ir_elapsed_ms = per_struct_timer.readMs();
        if (profilingEnabled() and ir_elapsed_ms >= 100) {
            std.debug.print("\n[stage IR struct={s}] ms={d}\n", .{ mod_name_str, ir_elapsed_ms });
        }
        for (mod_ir.functions) |function| {
            all_functions.append(alloc, function) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |entry| entry_id = entry;
        for (mod_ir.type_defs) |type_def| {
            all_type_defs.append(alloc, type_def) catch return error.OutOfMemory;
        }
    }

    if (combined_hir.top_functions.len > 0) {
        progressStage(options, "IR: top-level functions", .{});
        const top_hir = zap.hir.Program{
            .structs = &.{},
            .top_functions = combined_hir.top_functions,
            .impls = combined_hir.impls,
        };
        const mod_lower = compileHirToIr(alloc, ctx, "top", &top_hir, shared_store, options, &next_try_id, &combined_hir) catch return error.IrFailed;
        const mod_ir = mod_lower.program;
        try mergeArcOwnership(alloc, &combined_arc_ownership, mod_lower.arc_ownership);
        for (mod_ir.functions) |function| {
            all_functions.append(alloc, function) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |entry| entry_id = entry;
        for (mod_ir.type_defs) |type_def| {
            all_type_defs.append(alloc, type_def) catch return error.OutOfMemory;
        }
    }

    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase4-AllIR] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    return .{
        .shared_store = shared_store,
        .program = .{
            .functions = all_functions.items,
            .type_defs = all_type_defs.items,
            .entry = entry_id,
        },
        .arc_ownership = combined_arc_ownership,
    };
}

fn finishMergedIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    options: CompileOptions,
    shared_store: *zap.types.TypeStore,
    pre_final_program: ir.Program,
    pre_final_arc_ownership: zap.arc_liveness.ProgramArcOwnership,
) CompileError!CompileResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    var phase_timer = ZapTimer.start();

    progressStage(options, "Analysis: escape and contification", .{});
    var merged_ir = pre_final_program;
    var analysis_result = try pipeline.runAnalysisAndOptimization(&merged_ir);
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase5-AnalysisAndContify] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    var combined_arc_ownership = pre_final_arc_ownership;
    {
        progressStage(options, "ARC: ownership and drops", .{});
        progressStage(options, "ARC: computing merged ownership", .{});
        var merged_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, &merged_ir, shared_store) catch
            return error.IrFailed;
        progressStage(options, "ARC: inferring parameter conventions", .{});
        zap.arc_param_convention.inferConventions(alloc, &merged_ir, &merged_ownership, shared_store) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        runArcOwnershipAndVerify(alloc, &merged_ir, &merged_ownership, shared_store, options) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        progressStage(options, "ARC: recomputing post-rewrite ownership", .{});
        merged_ownership.deinit();
        merged_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, &merged_ir, shared_store) catch
            return error.IrFailed;
        runArcDropInsertion(alloc, &merged_ir, &merged_ownership, shared_store, options) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        materializeAnalysisArcOps(alloc, &merged_ir, &analysis_result.context, shared_store, options.declared_caps, options) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        combined_arc_ownership.deinit();
        combined_arc_ownership = merged_ownership;
        if (profilingEnabled()) {
            std.debug.print("\n[stage Phase5b-MergedArcRedux] ms={d}\n", .{phase_timer.lapMs()});
        } else {
            _ = phase_timer.lapMs();
        }
    }

    if (ctx.diag_engine.hasErrors()) {
        pipeline.clearProgress();
        emitContextDiagnostics(ctx, alloc);
    }

    return .{
        .ir_program = merged_ir,
        .analysis_context = analysis_result.context,
        .arc_ownership = combined_arc_ownership,
    };
}

pub fn compileStructByStruct(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    struct_order: []const []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    const pre_final = try compileStructsToPreFinalIr(alloc, ctx, struct_order, options);
    return finishMergedIr(alloc, ctx, options, pre_final.shared_store, pre_final.program, pre_final.arc_ownership);
}

fn compileStructByStructIncrementalFinal(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    struct_order: []const []const u8,
    options: CompileOptions,
    cached_final_program: ?ir.Program,
    invalidated_structs: *const std.StringHashMap(void),
    changed_declaration_structs: *const std.StringHashMap(void),
    changed_graph_roots: []const zap.incremental_graph.NodeId,
    changed_struct_names: []const []const u8,
    dependency_graph: *zap.incremental_graph.Graph,
) CompileError!CompileResult {
    var pre_final = try compileStructsToPreFinalIr(alloc, ctx, struct_order, options);
    try augmentFrontendGraphWithFunctions(alloc, dependency_graph, pre_final.program);
    try augmentFrontendGraphWithAnalysisSummaryEdges(
        alloc,
        dependency_graph,
        pre_final.program,
        options.frontend_optimize_mode.passPolicy(),
    );
    const cached_program = cached_final_program orelse {
        incrementalTrace("function-selection skipped reason=no-cached-final-program", .{});
        return finishMergedIr(alloc, ctx, options, pre_final.shared_store, pre_final.program, pre_final.arc_ownership);
    };

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(alloc);
    defer affected_functions.deinit();
    const graph_selection = try selectAffectedFunctionsFromGraph(
        alloc,
        dependency_graph,
        pre_final.program,
        invalidated_structs,
        changed_graph_roots,
        &affected_functions,
    );
    if (!graph_selection.usedGraph()) {
        incrementalTrace("function-selection fallback reason={s}", .{@tagName(graph_selection)});
        try seedAffectedFunctionsFromStructs(alloc, pre_final.program, invalidated_structs, &affected_functions);
        try seedAffectedFunctionsFromStructs(alloc, pre_final.program, changed_declaration_structs, &affected_functions);
        try expandAffectedFunctionsToCallers(alloc, pre_final.program, &affected_functions);
    }
    incrementalTrace(
        "function-selection mode={s} invalidated_structs={d} changed_declaration_structs={d} changed_roots={d} affected_functions={d}",
        .{
            if (graph_selection.usedGraph()) "graph" else "fallback",
            invalidated_structs.count(),
            changed_declaration_structs.count(),
            changed_graph_roots.len,
            affected_functions.count(),
        },
    );
    if (profilingEnabled()) {
        std.debug.print(
            "\n[incremental frontend] changed_structs={d} affected_function_selection={s} affected_functions={d}\n",
            .{
                changed_struct_names.len,
                if (graph_selection.usedGraph()) "graph" else "fallback",
                affected_functions.count(),
            },
        );
    }
    if (affected_functions.count() == 0) {
        pre_final.arc_ownership.deinit();
        return .{
            .ir_program = cached_program,
            .analysis_context = null,
            .arc_ownership = null,
            .incremental_backend_affected_function_ids = &.{},
        };
    }

    const backend_affected_function_ids = try affectedFunctionIdsInProgramOrder(
        alloc,
        pre_final.program,
        &affected_functions,
    );
    traceAffectedFunctionIds(pre_final.program, backend_affected_function_ids);
    if (profilingEnabled()) {
        std.debug.print(
            "[incremental frontend] backend_affected_functions={d} total_functions={d}\n",
            .{ backend_affected_function_ids.len, pre_final.program.functions.len },
        );
    }
    if (affected_functions.count() == pre_final.program.functions.len) {
        incrementalTrace(
            "frontend-final scope=all reason=all-functions-affected affected_functions={d} total_functions={d}",
            .{ affected_functions.count(), pre_final.program.functions.len },
        );
        var result = try finishMergedIr(alloc, ctx, options, pre_final.shared_store, pre_final.program, pre_final.arc_ownership);
        result.incremental_backend_force_full = true;
        return result;
    }

    if (!finalFunctionLayoutStable(pre_final.program, cached_program) or
        !unaffectedFunctionIdentitiesStable(pre_final.program, cached_program, &affected_functions))
    {
        incrementalTrace("frontend-final scope=all reason=function-layout-or-identity-change", .{});
        var result = try finishMergedIr(alloc, ctx, options, pre_final.shared_store, pre_final.program, pre_final.arc_ownership);
        result.incremental_backend_force_full = true;
        return result;
    }
    if (!typeDefinitionsStable(pre_final.program.type_defs, cached_program.type_defs)) {
        incrementalTrace("frontend-final scope=all reason=type-definitions-changed", .{});
        var result = try finishMergedIr(alloc, ctx, options, pre_final.shared_store, pre_final.program, pre_final.arc_ownership);
        result.incremental_backend_force_full = true;
        return result;
    }

    const component_program = try buildAffectedPreFinalProgram(alloc, pre_final.program, &affected_functions);
    const component_pre_ownership = zap.arc_liveness.ProgramArcOwnership.init(alloc);
    const component_result = try finishMergedIr(
        alloc,
        ctx,
        options,
        pre_final.shared_store,
        component_program,
        component_pre_ownership,
    );
    pre_final.arc_ownership.deinit();

    const merged_program = try mergeCachedAndAffectedFinalProgram(
        alloc,
        pre_final.program,
        cached_program,
        component_result.ir_program,
        &affected_functions,
    );

    return .{
        .ir_program = merged_program,
        .analysis_context = component_result.analysis_context,
        .arc_ownership = component_result.arc_ownership,
        .incremental_backend_affected_function_ids = backend_affected_function_ids,
    };
}

fn finalFunctionLayoutStable(current: ir.Program, cached: ir.Program) bool {
    if (current.functions.len != cached.functions.len) return false;
    for (current.functions, cached.functions) |current_function, cached_function| {
        if (current_function.id != cached_function.id) return false;
    }
    return true;
}

fn unaffectedFunctionIdentitiesStable(
    current: ir.Program,
    cached: ir.Program,
    affected_functions: *const std.AutoHashMap(ir.FunctionId, void),
) bool {
    if (current.functions.len != cached.functions.len) return false;
    for (current.functions, cached.functions) |current_function, cached_function| {
        if (affected_functions.contains(current_function.id)) continue;
        if (current_function.id != cached_function.id) return false;
        if (!std.mem.eql(u8, current_function.name, cached_function.name)) return false;
        if (!optionalStringEql(current_function.struct_name, cached_function.struct_name)) return false;
        if (!std.mem.eql(u8, current_function.local_name, cached_function.local_name)) return false;
        if (current_function.arity != cached_function.arity) return false;
    }
    return true;
}

fn typeDefinitionsStable(current: []const ir.TypeDef, cached: []const ir.TypeDef) bool {
    if (current.len != cached.len) return false;
    for (current, cached) |current_type, cached_type| {
        if (!typeDefinitionEqual(current_type, cached_type)) return false;
    }
    return true;
}

fn typeDefinitionEqual(left: ir.TypeDef, right: ir.TypeDef) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .struct_def => |left_struct| blk: {
            const right_struct = right.kind.struct_def;
            if (left_struct.fields.len != right_struct.fields.len) break :blk false;
            for (left_struct.fields, right_struct.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name)) break :blk false;
                if (!zigTypeEqual(left_field.type_expr, right_field.type_expr)) break :blk false;
                if (left_field.storage != right_field.storage) break :blk false;
            }
            break :blk true;
        },
        .enum_def => |left_enum| blk: {
            const right_enum = right.kind.enum_def;
            if (left_enum.variants.len != right_enum.variants.len) break :blk false;
            for (left_enum.variants, right_enum.variants) |left_variant, right_variant| {
                if (!std.mem.eql(u8, left_variant, right_variant)) break :blk false;
            }
            break :blk true;
        },
        .union_def => |left_union| blk: {
            const right_union = right.kind.union_def;
            if (left_union.variants.len != right_union.variants.len) break :blk false;
            for (left_union.variants, right_union.variants) |left_variant, right_variant| {
                if (!std.mem.eql(u8, left_variant.name, right_variant.name)) break :blk false;
                if (!optionalStringEql(left_variant.type_name, right_variant.type_name)) break :blk false;
            }
            break :blk true;
        },
        .protocol_vtable_def => |left_vt| blk: {
            // Per-protocol vtable types compare equal when their
            // protocol name and method-slot shape are identical.
            // Stable across rebuilds is essential for the cache
            // sidecar — if the per-impl vtable constants depend on
            // a vtable type that was recomputed with a different
            // method order, every dependent impl rebuilds.
            const right_vt = right.kind.protocol_vtable_def;
            if (!std.mem.eql(u8, left_vt.protocol_name, right_vt.protocol_name)) break :blk false;
            if (left_vt.methods.len != right_vt.methods.len) break :blk false;
            for (left_vt.methods, right_vt.methods) |left_method, right_method| {
                if (!std.mem.eql(u8, left_method.name, right_method.name)) break :blk false;
                if (left_method.arity != right_method.arity) break :blk false;
                if (left_method.extra_param_types.len != right_method.extra_param_types.len) break :blk false;
                for (left_method.extra_param_types, right_method.extra_param_types) |left_param, right_param| {
                    if (!zigTypeEqual(left_param, right_param)) break :blk false;
                }
                if (!zigTypeEqual(left_method.return_type, right_method.return_type)) break :blk false;
            }
            break :blk true;
        },
        .protocol_vtable_instance_def => |left_inst| blk: {
            // Per-impl vtable instance constants compare equal when
            // their protocol/target pair and method-slot pointers
            // are identical. A change to either side (e.g. a new
            // method on the protocol, a renamed monomorphized impl
            // method) must invalidate the cache for this entry so
            // the synthetic source file is rebuilt with the right
            // names.
            const right_inst = right.kind.protocol_vtable_instance_def;
            if (!std.mem.eql(u8, left_inst.protocol_name, right_inst.protocol_name)) break :blk false;
            if (!std.mem.eql(u8, left_inst.target_type_name, right_inst.target_type_name)) break :blk false;
            if (left_inst.methods.len != right_inst.methods.len) break :blk false;
            for (left_inst.methods, right_inst.methods) |left_method, right_method| {
                if (!std.mem.eql(u8, left_method.method_name, right_method.method_name)) break :blk false;
                if (!std.mem.eql(u8, left_method.impl_function_name, right_method.impl_function_name)) break :blk false;
                if (left_method.arity != right_method.arity) break :blk false;
                if (left_method.extra_param_types.len != right_method.extra_param_types.len) break :blk false;
                for (left_method.extra_param_types, right_method.extra_param_types) |left_param, right_param| {
                    if (!zigTypeEqual(left_param, right_param)) break :blk false;
                }
                if (!zigTypeEqual(left_method.return_type, right_method.return_type)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn zigTypeEqual(left: ir.ZigType, right: ir.ZigType) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .tuple => |left_items| blk: {
            const right_items = right.tuple;
            if (left_items.len != right_items.len) break :blk false;
            for (left_items, right_items) |left_item, right_item| {
                if (!zigTypeEqual(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .list => |left_item| zigTypeEqual(left_item.*, right.list.*),
        .map => |left_map| zigTypeEqual(left_map.key.*, right.map.key.*) and zigTypeEqual(left_map.value.*, right.map.value.*),
        .struct_ref => |left_name| std.mem.eql(u8, left_name, right.struct_ref),
        .function => |left_fn| blk: {
            const right_fn = right.function;
            if (left_fn.params.len != right_fn.params.len) break :blk false;
            for (left_fn.params, right_fn.params) |left_param, right_param| {
                if (!zigTypeEqual(left_param, right_param)) break :blk false;
            }
            break :blk zigTypeEqual(left_fn.return_type.*, right_fn.return_type.*);
        },
        .tagged_union => |left_name| std.mem.eql(u8, left_name, right.tagged_union),
        .optional => |left_item| zigTypeEqual(left_item.*, right.optional.*),
        .ptr => |left_item| zigTypeEqual(left_item.*, right.ptr.*),
        else => true,
    };
}

fn seedAffectedFunctionsFromStructs(
    alloc: std.mem.Allocator,
    program: ir.Program,
    invalidated_structs: *const std.StringHashMap(void),
    affected_functions: *std.AutoHashMap(ir.FunctionId, void),
) CompileError!void {
    _ = alloc;
    for (program.functions) |function| {
        const struct_name = function.struct_name orelse {
            if (invalidated_structs.contains("")) try affected_functions.put(function.id, {});
            continue;
        };
        if (structSetContainsIncrementalName(invalidated_structs, struct_name)) {
            try affected_functions.put(function.id, {});
        }
    }
}

fn selectAffectedFunctionsFromGraph(
    alloc: std.mem.Allocator,
    dependency_graph: *const zap.incremental_graph.Graph,
    program: ir.Program,
    invalidated_structs: *const std.StringHashMap(void),
    changed_graph_roots: []const zap.incremental_graph.NodeId,
    affected_functions: *std.AutoHashMap(ir.FunctionId, void),
) CompileError!GraphFunctionSelection {
    var body_node_to_function = std.AutoHashMap(zap.incremental_graph.NodeId, ir.FunctionId).init(alloc);
    defer body_node_to_function.deinit();

    for (program.functions) |function| {
        const body_id = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(function))) orelse {
            incrementalTrace(
                "function-selection missing-node kind=function_body function={s}",
                .{function.name},
            );
            return .missing_function_body_node;
        };
        try body_node_to_function.put(body_id, function.id);
    }

    var invalidated_root_nodes: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
    defer invalidated_root_nodes.deinit(alloc);

    if (changed_graph_roots.len > 0) {
        for (changed_graph_roots) |root_id| {
            if (dependency_graph.nodeKey(root_id) == null) {
                incrementalTrace(
                    "function-selection missing-node kind=changed-root id={d}",
                    .{@intFromEnum(root_id)},
                );
                return .missing_changed_root_node;
            }
            try invalidated_root_nodes.append(alloc, root_id);
            traceIncrementalGraphNode("invalidated-changed-root-node", dependency_graph, root_id);
        }
    } else {
        var invalidated_iter = invalidated_structs.iterator();
        while (invalidated_iter.next()) |entry| {
            const surface_id = if (entry.key_ptr.*.len == 0)
                (try dependency_graph.getNode(frontendPackageSurfaceNodeKey())) orelse {
                    incrementalTrace("function-selection missing-node kind=package_surface", .{});
                    return .missing_invalidated_surface_node;
                }
            else
                (try dependency_graph.getNode(frontendStructSurfaceNodeKey(entry.key_ptr.*))) orelse {
                    incrementalTrace(
                        "function-selection missing-node kind=struct_surface struct={s}",
                        .{entry.key_ptr.*},
                    );
                    return .missing_invalidated_surface_node;
                };
            try invalidated_root_nodes.append(alloc, surface_id);
            traceIncrementalGraphNode("invalidated-surface-node", dependency_graph, surface_id);
        }
    }

    const affected_nodes = try dependency_graph.affectedFrom(alloc, invalidated_root_nodes.items);
    defer alloc.free(affected_nodes);
    if (incrementalTraceEnabled()) {
        const affected_steps = try dependency_graph.affectedTraceFrom(alloc, invalidated_root_nodes.items);
        defer alloc.free(affected_steps);
        for (affected_steps) |step| {
            traceIncrementalGraphStep("function-affected-edge", dependency_graph, step);
        }
    }
    incrementalTrace(
        "function-graph-reachability root_nodes={d} affected_nodes={d}",
        .{ invalidated_root_nodes.items.len, affected_nodes.len },
    );

    var selected_functions = std.AutoHashMap(ir.FunctionId, void).init(alloc);
    defer selected_functions.deinit();

    for (invalidated_root_nodes.items) |node_id| {
        const node_key = dependency_graph.nodeKey(node_id) orelse {
            incrementalTrace(
                "function-selection missing-node kind=root id={d}",
                .{@intFromEnum(node_id)},
            );
            return .missing_changed_root_node;
        };
        switch (node_key.*) {
            .function_body => {
                const function_id = body_node_to_function.get(node_id) orelse {
                    incrementalTrace(
                        "function-selection unmapped-function-body-node id={d}",
                        .{@intFromEnum(node_id)},
                    );
                    return .unmapped_function_body_node;
                };
                try selected_functions.put(function_id, {});
            },
            else => {},
        }
    }

    for (affected_nodes) |node_id| {
        traceIncrementalGraphNode("function-affected-node", dependency_graph, node_id);
        const node_key = dependency_graph.nodeKey(node_id) orelse {
            incrementalTrace(
                "function-selection missing-node kind=affected id={d}",
                .{@intFromEnum(node_id)},
            );
            return .missing_affected_node;
        };
        switch (node_key.*) {
            .function_body => {
                const function_id = body_node_to_function.get(node_id) orelse {
                    incrementalTrace(
                        "function-selection unmapped-function-body-node id={d}",
                        .{@intFromEnum(node_id)},
                    );
                    return .unmapped_function_body_node;
                };
                try selected_functions.put(function_id, {});
            },
            else => {},
        }
    }

    var selected_iter = selected_functions.keyIterator();
    while (selected_iter.next()) |function_id| {
        try affected_functions.put(function_id.*, {});
    }
    return .graph;
}

fn incrementalStructNameByte(byte: u8) u8 {
    return if (byte == '.') '_' else byte;
}

fn incrementalStructNamesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (incrementalStructNameByte(left_byte) != incrementalStructNameByte(right_byte)) return false;
    }
    return true;
}

fn structSetContainsIncrementalName(struct_names: *const std.StringHashMap(void), struct_name: []const u8) bool {
    if (struct_names.contains(struct_name)) return true;
    var iter = struct_names.iterator();
    while (iter.next()) |entry| {
        if (incrementalStructNamesEqual(entry.key_ptr.*, struct_name)) return true;
    }
    return false;
}

fn seedAffectedFunctionsFromStructNames(
    alloc: std.mem.Allocator,
    program: ir.Program,
    struct_names: []const []const u8,
    affected_functions: *std.AutoHashMap(ir.FunctionId, void),
) CompileError!void {
    var changed_structs = std.StringHashMap(void).init(alloc);
    defer changed_structs.deinit();
    for (struct_names) |struct_name| {
        try changed_structs.put(struct_name, {});
    }
    try seedAffectedFunctionsFromStructs(alloc, program, &changed_structs, affected_functions);
}

fn affectedFunctionIdsInProgramOrder(
    alloc: std.mem.Allocator,
    program: ir.Program,
    affected_functions: *const std.AutoHashMap(ir.FunctionId, void),
) CompileError![]const ir.FunctionId {
    var ordered: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
    errdefer ordered.deinit(alloc);
    for (program.functions) |function| {
        if (affected_functions.contains(function.id)) {
            try ordered.append(alloc, function.id);
        }
    }
    return ordered.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn functionById(program: ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*function| {
        if (function.id == function_id) return function;
    }
    return null;
}

const GraphFunctionSelection = enum {
    graph,
    missing_changed_root_node,
    missing_function_body_node,
    missing_invalidated_surface_node,
    missing_affected_node,
    unmapped_function_body_node,

    fn usedGraph(self: GraphFunctionSelection) bool {
        return self == .graph;
    }
};

fn traceAffectedFunctionIds(program: ir.Program, function_ids: []const ir.FunctionId) void {
    if (!incrementalTraceEnabled()) return;
    for (function_ids) |function_id| {
        const function = functionById(program, function_id) orelse {
            incrementalTrace("affected-function id={d} name=<missing>", .{function_id});
            continue;
        };
        incrementalTrace(
            "affected-function id={d} name={s} struct={s}",
            .{ function.id, function.name, function.struct_name orelse "<top-level>" },
        );
    }
}

fn functionIdByName(program: ir.Program, name: []const u8) ?ir.FunctionId {
    for (program.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function.id;
    }
    return null;
}

fn addReverseCallEdgeTarget(
    alloc: std.mem.Allocator,
    program: ir.Program,
    caller_id: ir.FunctionId,
    target_id: ir.FunctionId,
    callers_by_callee: *std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) CompileError!void {
    if (functionById(program, target_id) == null) return;
    const gop = try callers_by_callee.getOrPut(target_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(alloc, caller_id);
}

fn addReverseDispatchCallEdges(
    alloc: std.mem.Allocator,
    program: ir.Program,
    caller_id: ir.FunctionId,
    group_id: ir.FunctionId,
    callers_by_callee: *std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) CompileError!void {
    try addReverseCallEdgeTarget(alloc, program, caller_id, group_id, callers_by_callee);

    for (program.functions) |function| {
        if (function.source_group_id == group_id) {
            try addReverseCallEdgeTarget(alloc, program, caller_id, function.id, callers_by_callee);
        }
    }
}

fn addCallEdgesFromInstructions(
    alloc: std.mem.Allocator,
    program: ir.Program,
    caller_id: ir.FunctionId,
    instructions: []const ir.Instruction,
    callers_by_callee: *std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) CompileError!void {
    for (instructions) |instruction| {
        switch (instruction) {
            .call_direct => |call| try addReverseCallEdgeTarget(alloc, program, caller_id, call.function, callers_by_callee),
            .call_dispatch => |call| try addReverseDispatchCallEdges(alloc, program, caller_id, call.group_id, callers_by_callee),
            .make_closure => |closure| try addReverseCallEdgeTarget(alloc, program, caller_id, closure.function, callers_by_callee),
            .call_named => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
            },
            .tail_call => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
            },
            .try_call_named => |call| {
                if (functionIdByName(program, call.name)) |target_id| {
                    try addReverseCallEdgeTarget(alloc, program, caller_id, target_id, callers_by_callee);
                }
                try addCallEdgesFromInstructions(alloc, program, caller_id, call.handler_instrs, callers_by_callee);
                try addCallEdgesFromInstructions(alloc, program, caller_id, call.success_instrs, callers_by_callee);
            },
            .if_expr => |value| {
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.then_instrs, callers_by_callee);
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.else_instrs, callers_by_callee);
            },
            .guard_block => |value| try addCallEdgesFromInstructions(alloc, program, caller_id, value.body, callers_by_callee),
            .case_block => |value| {
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.pre_instrs, callers_by_callee);
                for (value.arms) |arm| {
                    try addCallEdgesFromInstructions(alloc, program, caller_id, arm.cond_instrs, callers_by_callee);
                    try addCallEdgesFromInstructions(alloc, program, caller_id, arm.body_instrs, callers_by_callee);
                }
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, callers_by_callee);
            },
            .switch_literal => |value| {
                for (value.cases) |case| {
                    try addCallEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, callers_by_callee);
                }
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, callers_by_callee);
            },
            .switch_return => |value| {
                for (value.cases) |case| {
                    try addCallEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, callers_by_callee);
                }
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.default_instrs, callers_by_callee);
            },
            .union_switch => |value| {
                for (value.cases) |case| {
                    try addCallEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, callers_by_callee);
                }
            },
            .union_switch_return => |value| {
                for (value.cases) |case| {
                    try addCallEdgesFromInstructions(alloc, program, caller_id, case.body_instrs, callers_by_callee);
                }
            },
            .optional_dispatch => |value| {
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.nil_instrs, callers_by_callee);
                try addCallEdgesFromInstructions(alloc, program, caller_id, value.struct_instrs, callers_by_callee);
            },
            else => {},
        }
    }
}

fn expandAffectedFunctionsToCallers(
    alloc: std.mem.Allocator,
    program: ir.Program,
    affected_functions: *std.AutoHashMap(ir.FunctionId, void),
) CompileError!void {
    var callers_by_callee = std.AutoHashMap(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)).init(alloc);
    defer {
        var lists = callers_by_callee.valueIterator();
        while (lists.next()) |list| list.deinit(alloc);
        callers_by_callee.deinit();
    }

    for (program.functions) |function| {
        for (function.body) |block| {
            try addCallEdgesFromInstructions(alloc, program, function.id, block.instructions, &callers_by_callee);
        }
    }

    var queue: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
    defer queue.deinit(alloc);
    var affected_iter = affected_functions.keyIterator();
    while (affected_iter.next()) |function_id| try queue.append(alloc, function_id.*);

    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const function_id = queue.items[cursor];
        const callers = callers_by_callee.get(function_id) orelse continue;
        for (callers.items) |caller_id| {
            if (affected_functions.contains(caller_id)) continue;
            try affected_functions.put(caller_id, {});
            try queue.append(alloc, caller_id);
        }
    }
}

fn buildAffectedPreFinalProgram(
    alloc: std.mem.Allocator,
    program: ir.Program,
    affected_functions: *const std.AutoHashMap(ir.FunctionId, void),
) CompileError!ir.Program {
    var functions: std.ArrayListUnmanaged(ir.Function) = .empty;
    for (program.functions) |function| {
        if (affected_functions.contains(function.id)) {
            try functions.append(alloc, function);
        }
    }
    const entry = if (program.entry) |entry_id|
        if (affected_functions.contains(entry_id)) entry_id else null
    else
        null;
    return .{
        .functions = try functions.toOwnedSlice(alloc),
        .type_defs = program.type_defs,
        .entry = entry,
    };
}

fn mergeCachedAndAffectedFinalProgram(
    alloc: std.mem.Allocator,
    current_pre_final: ir.Program,
    cached_final: ir.Program,
    affected_final: ir.Program,
    affected_functions: *const std.AutoHashMap(ir.FunctionId, void),
) CompileError!ir.Program {
    const functions = try alloc.alloc(ir.Function, current_pre_final.functions.len);
    for (current_pre_final.functions, 0..) |current_function, index| {
        if (affected_functions.contains(current_function.id)) {
            functions[index] = (functionById(affected_final, current_function.id) orelse return error.IrFailed).*;
        } else {
            functions[index] = (functionById(cached_final, current_function.id) orelse return error.IrFailed).*;
        }
    }
    return .{
        .functions = functions,
        .type_defs = current_pre_final.type_defs,
        .entry = current_pre_final.entry,
    };
}

test "incremental caller expansion follows dispatch group changes" {
    const dispatch_instructions = [_]ir.Instruction{
        .{ .call_dispatch = .{
            .dest = 0,
            .group_id = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &dispatch_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__uses_dispatch__0",
            .struct_name = "Caller",
            .local_name = "uses_dispatch__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();
    try affected_functions.put(1, {});

    try expandAffectedFunctionsToCallers(std.testing.allocator, program, &affected_functions);

    try std.testing.expect(affected_functions.contains(0));
}

test "incremental caller expansion follows dispatch source clause changes" {
    const dispatch_instructions = [_]ir.Instruction{
        .{ .call_dispatch = .{
            .dest = 0,
            .group_id = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &dispatch_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__uses_dispatch__0",
            .struct_name = "Caller",
            .local_name = "uses_dispatch__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__negate__1_clause_0",
            .source_group_id = 1,
            .source_clause_index = 0,
            .struct_name = "Bool",
            .local_name = "negate__1_clause_0",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();
    try affected_functions.put(2, {});

    try expandAffectedFunctionsToCallers(std.testing.allocator, program, &affected_functions);

    try std.testing.expect(affected_functions.contains(0));
}

test "incremental frontend function graph follows dispatch source clause call signatures" {
    const dispatch_instructions = [_]ir.Instruction{
        .{ .call_dispatch = .{
            .dest = 0,
            .group_id = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &dispatch_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__uses_dispatch__0",
            .struct_name = "Caller",
            .local_name = "uses_dispatch__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__negate__1_clause_0",
            .source_group_id = 1,
            .source_clause_index = 0,
            .struct_name = "Bool",
            .local_name = "negate__1_clause_0",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    const caller_id = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(functions[0]))).?;
    const clause_signature_id = (try dependency_graph.getNode(try frontendFunctionSignatureNodeKey(functions[2]))).?;
    const affected = try dependency_graph.affectedFrom(std.testing.allocator, &.{clause_signature_id});
    defer std.testing.allocator.free(affected);

    try std.testing.expect(nodeIdSliceContains(affected, caller_id));

    const clause_body_id = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(functions[2]))).?;
    const body_affected = try dependency_graph.affectedFrom(std.testing.allocator, &.{clause_body_id});
    defer std.testing.allocator.free(body_affected);

    try std.testing.expect(!nodeIdSliceContains(body_affected, caller_id));
}

test "incremental graph affected function selection includes direct caller closure" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 0,
            .function = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Beta__value__0",
            .struct_name = "Beta",
            .local_name = "value__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Alpha__value__0",
            .struct_name = "Alpha",
            .local_name = "value__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();
    try invalidated_structs.put("Alpha", {});

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expect(affected_functions.contains(1));
}

test "incremental graph affected function selection keeps body-only roots function-scoped" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 0,
            .function = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__check__0",
            .struct_name = "Caller",
            .local_name = "check__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__to_string__1",
            .struct_name = "Bool",
            .local_name = "to_string__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .string,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();

    const body_root = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(functions[1]))).?;
    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{body_root},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(1));
    try std.testing.expect(!affected_functions.contains(0));
    try std.testing.expect(!affected_functions.contains(2));
    try std.testing.expectEqual(@as(u32, 1), affected_functions.count());
}

test "incremental graph affected function selection reaches callers from signature roots" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 0,
            .function = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__check__0",
            .struct_name = "Caller",
            .local_name = "check__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__to_string__1",
            .struct_name = "Bool",
            .local_name = "to_string__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .string,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();

    const signature_root = (try dependency_graph.getNode(try frontendFunctionSignatureNodeKey(functions[1]))).?;
    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{signature_root},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expect(affected_functions.contains(1));
    try std.testing.expect(!affected_functions.contains(2));
    try std.testing.expectEqual(@as(u32, 2), affected_functions.count());
}

test "incremental graph analysis summary edges select callers for callee body-derived ARC conventions" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 1,
            .function = 1,
            .args = &[_]ir.LocalId{0},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const callee_params = [_]ir.Param{.{
        .name = "value",
        .type_expr = .string,
    }};
    const callee_param_conventions = [_]ir.ParamConvention{.borrowed};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__check__1",
            .struct_name = "Caller",
            .local_name = "check__1",
            .scope_id = 0,
            .arity = 1,
            .params = &callee_params,
            .return_type = .string,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
            .param_conventions = &callee_param_conventions,
        },
        .{
            .id = 1,
            .name = "Value__normalize__1",
            .struct_name = "Value",
            .local_name = "normalize__1",
            .scope_id = 0,
            .arity = 1,
            .params = &callee_params,
            .return_type = .string,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
            .param_conventions = &callee_param_conventions,
        },
        .{
            .id = 2,
            .name = "Value__unrelated__0",
            .struct_name = "Value",
            .local_name = "unrelated__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .string,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);
    try augmentFrontendGraphWithAnalysisSummaryEdges(
        std.testing.allocator,
        &dependency_graph,
        program,
        FrontendOptimizeMode.debug.passPolicy(),
    );

    const callee_body_id = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(functions[1]))).?;
    const caller_body_id = (try dependency_graph.getNode(try frontendFunctionBodyNodeKey(functions[0]))).?;
    const affected_trace = try dependency_graph.affectedTraceFrom(std.testing.allocator, &.{callee_body_id});
    defer std.testing.allocator.free(affected_trace);
    try std.testing.expectEqual(@as(usize, 1), affected_trace.len);
    try std.testing.expectEqual(caller_body_id, affected_trace[0].depender);
    try std.testing.expectEqual(callee_body_id, affected_trace[0].dependee);
    try std.testing.expectEqual(zap.incremental_graph.DependencyReason.analysis_summary, affected_trace[0].reason);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();
    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();
    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{callee_body_id},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expect(affected_functions.contains(1));
    try std.testing.expect(!affected_functions.contains(2));
    try std.testing.expectEqual(@as(u32, 2), affected_functions.count());
}

test "incremental graph affected function selection reaches owned functions from struct surface roots" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 0,
            .function = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__check__0",
            .struct_name = "Caller",
            .local_name = "check__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__to_string__1",
            .struct_name = "Bool",
            .local_name = "to_string__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .string,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();

    const struct_root = (try dependency_graph.getNode(frontendStructSurfaceNodeKey("Bool"))).?;
    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{struct_root},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expect(affected_functions.contains(1));
    try std.testing.expect(affected_functions.contains(2));
    try std.testing.expectEqual(@as(u32, 3), affected_functions.count());
}

test "incremental graph affected function selection includes dispatch source-clause callers" {
    const dispatch_instructions = [_]ir.Instruction{
        .{ .call_dispatch = .{
            .dest = 0,
            .group_id = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &dispatch_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__uses_dispatch__0",
            .struct_name = "Caller",
            .local_name = "uses_dispatch__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 2,
            .name = "Bool__negate__1_clause_0",
            .source_group_id = 1,
            .source_clause_index = 0,
            .struct_name = "Bool",
            .local_name = "negate__1_clause_0",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();
    try invalidated_structs.put("Bool", {});

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expect(affected_functions.contains(1));
    try std.testing.expect(affected_functions.contains(2));
}

test "incremental graph affected function selection handles top-level invalidation" {
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "main__0",
            .struct_name = null,
            .local_name = "main__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    try augmentFrontendGraphWithFunctions(std.testing.allocator, &dependency_graph, program);

    var invalidated_structs = std.StringHashMap(void).init(std.testing.allocator);
    defer invalidated_structs.deinit();
    try invalidated_structs.put("", {});

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();

    try std.testing.expectEqual(GraphFunctionSelection.graph, try selectAffectedFunctionsFromGraph(
        std.testing.allocator,
        &dependency_graph,
        program,
        &invalidated_structs,
        &.{},
        &affected_functions,
    ));
    try std.testing.expect(affected_functions.contains(0));
    try std.testing.expectEqual(@as(u32, 1), affected_functions.count());
}

test "incremental backend affected ids use changed structs and caller closure" {
    const call_instructions = [_]ir.Instruction{
        .{ .call_direct = .{
            .dest = 0,
            .function = 1,
            .args = &.{},
            .arg_modes = &.{},
        } },
    };
    const caller_blocks = [_]ir.Block{.{
        .label = 0,
        .instructions = &call_instructions,
    }};
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Caller__check__0",
            .struct_name = "Caller",
            .local_name = "check__0",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .bool_type,
            .body = &caller_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "Bool__negate__1",
            .struct_name = "Bool",
            .local_name = "negate__1",
            .scope_id = 0,
            .arity = 1,
            .params = &.{},
            .return_type = .bool_type,
            .body = &.{},
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = null };

    var affected_functions = std.AutoHashMap(ir.FunctionId, void).init(std.testing.allocator);
    defer affected_functions.deinit();
    try seedAffectedFunctionsFromStructNames(std.testing.allocator, program, &[_][]const u8{"Bool"}, &affected_functions);
    try expandAffectedFunctionsToCallers(std.testing.allocator, program, &affected_functions);
    const affected_ids = try affectedFunctionIdsInProgramOrder(std.testing.allocator, program, &affected_functions);
    defer std.testing.allocator.free(affected_ids);

    try std.testing.expectEqual(@as(usize, 2), affected_ids.len);
    try std.testing.expectEqual(@as(ir.FunctionId, 0), affected_ids[0]);
    try std.testing.expectEqual(@as(ir.FunctionId, 1), affected_ids[1]);
}

test "incremental frontend invalidates dispatch callers when callee clauses change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const bool_structs = [_][]const u8{"Bool"};
    const caller_structs = [_][]const u8{"Caller"};
    try file_to_structs.put("lib/bool.zap", &bool_structs);
    try file_to_structs.put("lib/caller.zap", &caller_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const bool_dependents = [_][]const u8{"lib/caller.zap"};
    try file_imported_by.put("lib/bool.zap", &bool_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Bool", "Caller" };

    const bool_correct_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { false }\n" ++
        "  pub fn negate(false) -> Bool { true }\n" ++
        "}\n";
    const bool_broken_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { true }\n" ++
        "  pub fn negate(false) -> Bool { false }\n" ++
        "}\n";
    const caller_source =
        "pub struct Caller {\n" ++
        "  pub fn check() -> Bool { Bool.negate(false) }\n" ++
        "}\n";

    var correct_units = [_]SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = bool_correct_source, .primary_struct_name = "Bool" },
        .{ .file_path = "lib/caller.zap", .source = caller_source, .primary_struct_name = "Caller" },
    };
    var initial = try state.prepare(alloc, &correct_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try expectCtfeBool(alloc, initial.result.ir_program, "Caller__check__0", true);
    try initial.commit();
    initial.deinit();

    var broken_units = [_]SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = bool_broken_source, .primary_struct_name = "Bool" },
        .{ .file_path = "lib/caller.zap", .source = caller_source, .primary_struct_name = "Caller" },
    };
    var broken = try state.prepare(alloc, &broken_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try expectCtfeBool(alloc, broken.result.ir_program, "Caller__check__0", false);
    try broken.commit();
    broken.deinit();

    var restored = try state.prepare(alloc, &correct_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try expectCtfeBool(alloc, restored.result.ir_program, "Caller__check__0", true);
    try restored.commit();
    restored.deinit();
}

test "incremental frontend propagates changed callee behavior through indirect callers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const bool_structs = [_][]const u8{"Bool"};
    const middle_structs = [_][]const u8{"Middle"};
    const top_structs = [_][]const u8{"Top"};
    try file_to_structs.put("lib/bool.zap", &bool_structs);
    try file_to_structs.put("lib/middle.zap", &middle_structs);
    try file_to_structs.put("lib/top.zap", &top_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const bool_dependents = [_][]const u8{"lib/middle.zap"};
    const middle_dependents = [_][]const u8{"lib/top.zap"};
    try file_imported_by.put("lib/bool.zap", &bool_dependents);
    try file_imported_by.put("lib/middle.zap", &middle_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Bool", "Middle", "Top" };

    const bool_correct_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { false }\n" ++
        "  pub fn negate(false) -> Bool { true }\n" ++
        "}\n";
    const bool_broken_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { true }\n" ++
        "  pub fn negate(false) -> Bool { false }\n" ++
        "}\n";
    const middle_source =
        "pub struct Middle {\n" ++
        "  pub fn check() -> Bool { Bool.negate(false) }\n" ++
        "}\n";
    const top_source =
        "pub struct Top {\n" ++
        "  pub fn check() -> Bool { Middle.check() }\n" ++
        "}\n";

    var correct_units = [_]SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = bool_correct_source, .primary_struct_name = "Bool" },
        .{ .file_path = "lib/middle.zap", .source = middle_source, .primary_struct_name = "Middle" },
        .{ .file_path = "lib/top.zap", .source = top_source, .primary_struct_name = "Top" },
    };
    var initial = try state.prepare(alloc, &correct_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try expectCtfeBool(alloc, initial.result.ir_program, "Top__check__0", true);
    try initial.commit();
    initial.deinit();

    var broken_units = [_]SourceUnit{
        .{ .file_path = "lib/bool.zap", .source = bool_broken_source, .primary_struct_name = "Bool" },
        .{ .file_path = "lib/middle.zap", .source = middle_source, .primary_struct_name = "Middle" },
        .{ .file_path = "lib/top.zap", .source = top_source, .primary_struct_name = "Top" },
    };
    var broken = try state.prepare(alloc, &broken_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try expectCtfeBool(alloc, broken.result.ir_program, "Top__check__0", false);
    try broken.commit();
    broken.deinit();
}

test "incremental frontend commit stores durable source and struct graph nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };

    const alpha_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    var units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
    };

    var prepared = try state.prepare(alloc, &units, graph, .{ .show_progress = false });
    try prepared.commit();
    prepared.deinit();

    try std.testing.expect(state.dependencyGraphNodeCount() >= 2);
    try std.testing.expect((try state.dependencyGraphSourceFileNode("lib/alpha.zap")) != null);
    try std.testing.expect((try state.dependencyGraphStructSurfaceNode("Alpha")) != null);
}

test "incremental frontend graph represents import dependents without changing invalidation behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const beta_structs = [_][]const u8{"Beta"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/beta.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Alpha", "Beta" };

    const alpha_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const beta_source =
        "pub struct Beta {\n" ++
        "  pub fn value() -> i64 { Alpha.value() }\n" ++
        "}\n";
    var units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = beta_source, .primary_struct_name = "Beta" },
    };

    var prepared = try state.prepare(alloc, &units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try prepared.commit();
    prepared.deinit();

    const alpha_id = (try state.dependencyGraphStructSurfaceNode("Alpha")).?;
    const beta_id = (try state.dependencyGraphStructSurfaceNode("Beta")).?;
    const affected = try state.dependencyGraphAffectedFromSourceFile(std.testing.allocator, "lib/alpha.zap");
    defer std.testing.allocator.free(affected);

    try std.testing.expect(nodeIdSliceContains(affected, alpha_id));
    try std.testing.expect(nodeIdSliceContains(affected, beta_id));
}

test "incremental frontend graph-backed invalidation follows transitive import struct surfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();
    state.initialized = true;

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const middle_structs = [_][]const u8{"Middle"};
    const top_structs = [_][]const u8{"Top"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/middle.zap", &middle_structs);
    try file_to_structs.put("lib/top.zap", &top_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/middle.zap"};
    const middle_dependents = [_][]const u8{"lib/top.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);
    try file_imported_by.put("lib/middle.zap", &middle_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const frontend_graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const source_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = "", .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/middle.zap", .source = "", .primary_struct_name = "Middle" },
        .{ .file_path = "lib/top.zap", .source = "", .primary_struct_name = "Top" },
    };

    var dependency_graph = try buildFrontendIncrementalGraph(std.testing.allocator, &source_units, frontend_graph);
    defer dependency_graph.deinit();

    var invalidated_structs = std.StringHashMap(void).init(alloc);
    var changed_declaration_structs = std.StringHashMap(void).init(alloc);
    var changed_graph_roots: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
    const changed_files = [_][]const u8{"lib/alpha.zap"};
    try state.computeInvalidatedStructs(
        alloc,
        &source_units,
        frontend_graph,
        &dependency_graph,
        &changed_files,
        &.{},
        &invalidated_structs,
        &changed_declaration_structs,
        &changed_graph_roots,
    );

    try std.testing.expect(invalidated_structs.contains("Alpha"));
    try std.testing.expect(invalidated_structs.contains("Middle"));
    try std.testing.expect(invalidated_structs.contains("Top"));
    try std.testing.expectEqual(@as(u32, 3), invalidated_structs.count());
}

test "incremental frontend dependent guardrails force full invalidation before graph narrowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();
    state.initialized = true;

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const beta_structs = [_][]const u8{"Beta"};
    const empty_structs = [_][]const u8{};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);
    try file_to_structs.put("lib/empty.zap", &empty_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/empty.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const frontend_graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const source_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = "", .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = "", .primary_struct_name = "Beta" },
        .{ .file_path = "lib/empty.zap", .source = "" },
    };

    var dependency_graph = try buildFrontendIncrementalGraph(std.testing.allocator, &source_units, frontend_graph);
    defer dependency_graph.deinit();

    var invalidated_structs = std.StringHashMap(void).init(alloc);
    var changed_declaration_structs = std.StringHashMap(void).init(alloc);
    var changed_graph_roots: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
    const changed_files = [_][]const u8{"lib/alpha.zap"};
    try state.computeInvalidatedStructs(
        alloc,
        &source_units,
        frontend_graph,
        &dependency_graph,
        &changed_files,
        &.{},
        &invalidated_structs,
        &changed_declaration_structs,
        &changed_graph_roots,
    );

    try std.testing.expect(invalidated_structs.contains("Alpha"));
    try std.testing.expect(invalidated_structs.contains("Beta"));
    try std.testing.expectEqual(@as(u32, 2), invalidated_structs.count());
}

test "incremental frontend transitive dependent guardrails force full invalidation before graph narrowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();
    state.initialized = true;

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const middle_structs = [_][]const u8{"Middle"};
    const beta_structs = [_][]const u8{"Beta"};
    const empty_structs = [_][]const u8{};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/middle.zap", &middle_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);
    try file_to_structs.put("lib/empty.zap", &empty_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/middle.zap"};
    const middle_dependents = [_][]const u8{"lib/empty.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);
    try file_imported_by.put("lib/middle.zap", &middle_dependents);

    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const frontend_graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const source_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = "", .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/middle.zap", .source = "", .primary_struct_name = "Middle" },
        .{ .file_path = "lib/beta.zap", .source = "", .primary_struct_name = "Beta" },
        .{ .file_path = "lib/empty.zap", .source = "" },
    };

    var dependency_graph = try buildFrontendIncrementalGraph(std.testing.allocator, &source_units, frontend_graph);
    defer dependency_graph.deinit();

    var invalidated_structs = std.StringHashMap(void).init(alloc);
    var changed_declaration_structs = std.StringHashMap(void).init(alloc);
    var changed_graph_roots: std.ArrayListUnmanaged(zap.incremental_graph.NodeId) = .empty;
    const changed_files = [_][]const u8{"lib/alpha.zap"};
    try state.computeInvalidatedStructs(
        alloc,
        &source_units,
        frontend_graph,
        &dependency_graph,
        &changed_files,
        &.{},
        &invalidated_structs,
        &changed_declaration_structs,
        &changed_graph_roots,
    );

    try std.testing.expect(invalidated_structs.contains("Alpha"));
    try std.testing.expect(invalidated_structs.contains("Middle"));
    try std.testing.expect(invalidated_structs.contains("Beta"));
    try std.testing.expectEqual(@as(u32, 3), invalidated_structs.count());
}

test "incremental frontend graph represents compile-after inventory without import invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const provider_structs = [_][]const u8{"Provider"};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/provider.zap", &provider_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns = [_][]const u8{"test/**/*_test.zap"};
    const runner_matches = [_][]const u8{"lib/provider.zap"};
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches);

    const frontend_graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const provider_source =
        "pub struct Provider {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";
    const source_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_source, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };

    var dependency_graph = try buildFrontendIncrementalGraph(std.testing.allocator, &source_units, frontend_graph);
    defer dependency_graph.deinit();

    const glob_id = (try dependency_graph.getNode(frontendCompileAfterGlobNodeKey("test/test_runner.zap"))).?;
    const runner_id = (try dependency_graph.getNode(frontendStructSurfaceNodeKey("TestRunner"))).?;
    const provider_source_id = (try dependency_graph.getNode(frontendSourceFileNodeKey("lib/provider.zap"))).?;
    const provider_reflection_id = (try dependency_graph.getNode(frontendStructReflectionNodeKey("Provider"))).?;

    const affected = try dependency_graph.affectedFrom(std.testing.allocator, &.{glob_id});
    defer std.testing.allocator.free(affected);
    try std.testing.expect(nodeIdSliceContains(affected, runner_id));

    const source_affected = try dependency_graph.affectedFrom(std.testing.allocator, &.{provider_source_id});
    defer std.testing.allocator.free(source_affected);
    try std.testing.expect(!nodeIdSliceContains(source_affected, runner_id));

    const reflection_affected = try dependency_graph.affectedFrom(std.testing.allocator, &.{provider_reflection_id});
    defer std.testing.allocator.free(reflection_affected);
    try std.testing.expect(nodeIdSliceContains(reflection_affected, runner_id));
}

test "incremental frontend compile-after ignores provider body-only changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const provider_structs = [_][]const u8{"Provider"};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/provider.zap", &provider_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns = [_][]const u8{"test/**/*_test.zap"};
    const runner_matches = [_][]const u8{"lib/provider.zap"};
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches);

    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Provider", "TestRunner" };
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 2 }\n" ++
        "}\n";
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v1, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try initial.commit();
    initial.deinit();

    var changed_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v2, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var changed = try state.prepare(alloc, &changed_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    defer changed.deinit();

    try std.testing.expect(!stringSliceContains(changed.invalidated_struct_names, "TestRunner"));
    try std.testing.expectEqual(@as(usize, 1), changed.changed_graph_roots.len);
    const root_key = changed.new_dependency_graph.nodeKey(changed.changed_graph_roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.function_body, root_key.kind());
    try std.testing.expect(!nodeIdSliceContainsKind(&changed.new_dependency_graph, changed.changed_graph_roots, .ctfe_reflection));
}

test "incremental frontend compile-after follows reflected public interface changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const provider_structs = [_][]const u8{"Provider"};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/provider.zap", &provider_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns = [_][]const u8{"test/**/*_test.zap"};
    const runner_matches = [_][]const u8{"lib/provider.zap"};
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches);

    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Provider", "TestRunner" };
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> f64 { 1.0 }\n" ++
        "}\n";
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v1, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try initial.commit();
    initial.deinit();

    var changed_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v2, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var changed = try state.prepare(alloc, &changed_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    defer changed.deinit();

    try std.testing.expect(stringSliceContains(changed.invalidated_struct_names, "TestRunner"));
    try std.testing.expect(nodeIdSliceContainsKind(&changed.new_dependency_graph, changed.changed_graph_roots, .ctfe_reflection));
}

test "incremental frontend compile-after follows reflected public function doc changes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  @doc = \"\"\"\n" ++
        "    First reflected doc.\n" ++
        "    \"\"\"\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  @doc = \"\"\"\n" ++
        "    Updated reflected doc.\n" ++
        "    \"\"\"\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend compile-after follows reflected public macro presence changes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n\n" ++
        "  pub macro reflected_macro() -> Expr {\n" ++
        "    quote { 1 }\n" ++
        "  }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend compile-after follows reflected public macro signature changes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n\n" ++
        "  pub macro reflected_macro() -> Expr {\n" ++
        "    quote { 1 }\n" ++
        "  }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n\n" ++
        "  pub macro reflected_macro(value :: Expr) -> Expr {\n" ++
        "    quote { unquote(value) }\n" ++
        "  }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend compile-after follows reflected public macro doc changes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n\n" ++
        "  @doc = \"\"\"\n" ++
        "    First macro doc.\n" ++
        "    \"\"\"\n\n" ++
        "  pub macro reflected_macro() -> Expr {\n" ++
        "    quote { 1 }\n" ++
        "  }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n\n" ++
        "  @doc = \"\"\"\n" ++
        "    Updated macro doc.\n" ++
        "    \"\"\"\n\n" ++
        "  pub macro reflected_macro() -> Expr {\n" ++
        "    quote { 1 }\n" ++
        "  }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend compile-after follows reflected struct doc changes" {
    const provider_v1 =
        "@doc = \"\"\"\n" ++
        "  First struct doc.\n" ++
        "  \"\"\"\n\n" ++
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "@doc = \"\"\"\n" ++
        "  Updated struct doc.\n" ++
        "  \"\"\"\n\n" ++
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend compile-after follows reflected struct privacy changes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectCompileAfterRunnerInvalidation(provider_v1, provider_v2, true, true);
}

test "incremental frontend reflection fingerprints include struct-level expression surface" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  emit_case(\"alpha\")\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  emit_case(\"beta\")\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectReflectionRootForMetadataChange(provider_v1, provider_v2);
}

test "incremental frontend reflection fingerprints include use declarations" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  use MacroSurface, pattern: \"alpha\"\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  use MacroSurface, pattern: \"beta\"\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectReflectionRootForMetadataChange(provider_v1, provider_v2);
}

test "incremental frontend reflection fingerprints include non-doc struct attributes" {
    const provider_v1 =
        "pub struct Provider {\n" ++
        "  @generated_count :: i64 = 1\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const provider_v2 =
        "pub struct Provider {\n" ++
        "  @generated_count :: i64 = 2\n\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectReflectionRootForMetadataChange(provider_v1, provider_v2);
}

test "incremental frontend reflection fingerprints include source file metadata" {
    const provider_source =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";

    try expectReflectionRootForMetadataChangeWithPaths(
        "lib/provider.zap",
        provider_source,
        "lib/renamed_provider.zap",
        provider_source,
    );
}

test "incremental frontend reflection fingerprints represent protocol union and impl inventory" {
    const base_source =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n\n" ++
        "pub protocol Reflectable {\n" ++
        "  fn render(value :: Provider) -> String\n" ++
        "}\n\n" ++
        "pub union ProviderMode {\n" ++
        "  Fast,\n" ++
        "  Slow\n" ++
        "}\n\n" ++
        "pub impl Reflectable for Provider {\n" ++
        "  pub fn render(value :: Provider) -> String { \"provider\" }\n" ++
        "}\n";
    const protocol_changed =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n\n" ++
        "pub protocol Reflectable {\n" ++
        "  fn render(value :: Provider) -> i64\n" ++
        "}\n\n" ++
        "pub union ProviderMode {\n" ++
        "  Fast,\n" ++
        "  Slow\n" ++
        "}\n\n" ++
        "pub impl Reflectable for Provider {\n" ++
        "  pub fn render(value :: Provider) -> String { \"provider\" }\n" ++
        "}\n";
    const union_changed =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n\n" ++
        "pub protocol Reflectable {\n" ++
        "  fn render(value :: Provider) -> String\n" ++
        "}\n\n" ++
        "pub union ProviderMode {\n" ++
        "  Fast,\n" ++
        "  Slow,\n" ++
        "  Tagged :: i64\n" ++
        "}\n\n" ++
        "pub impl Reflectable for Provider {\n" ++
        "  pub fn render(value :: Provider) -> String { \"provider\" }\n" ++
        "}\n";
    const impl_changed =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n\n" ++
        "pub protocol Reflectable {\n" ++
        "  fn render(value :: Provider) -> String\n" ++
        "}\n\n" ++
        "pub union ProviderMode {\n" ++
        "  Fast,\n" ++
        "  Slow\n" ++
        "}\n\n" ++
        "impl Reflectable for Provider {\n" ++
        "  pub fn render(value :: Provider) -> String { \"provider\" }\n" ++
        "}\n";

    try expectReflectionRootForMetadataChange(base_source, protocol_changed);
    try expectReflectionRootForMetadataChange(base_source, union_changed);
    try expectReflectionRootForMetadataChange(base_source, impl_changed);
}

test "incremental frontend compile-after falls back for protocol-only reflected inventory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const protocol_structs = [_][]const u8{};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/reflectable.zap", &protocol_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns = [_][]const u8{"lib/*.zap"};
    const runner_matches = [_][]const u8{"lib/reflectable.zap"};
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches);

    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{"TestRunner"};
    const protocol_v1 =
        "pub protocol Reflectable {\n" ++
        "  fn render(value) -> String\n" ++
        "}\n";
    const protocol_v2 =
        "pub protocol Reflectable {\n" ++
        "  fn render(value) -> i64\n" ++
        "}\n";
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/reflectable.zap", .source = protocol_v1 },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try initial.commit();
    initial.deinit();

    var changed_units = [_]SourceUnit{
        .{ .file_path = "lib/reflectable.zap", .source = protocol_v2 },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var changed = try state.prepare(alloc, &changed_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    defer changed.deinit();

    try std.testing.expect(stringSliceContains(changed.invalidated_struct_names, "TestRunner"));
    try std.testing.expectEqual(@as(usize, 0), changed.changed_graph_roots.len);
}

test "incremental frontend compile-after follows glob inventory changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const provider_structs = [_][]const u8{"Provider"};
    const extra_structs = [_][]const u8{"Extra"};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/provider.zap", &provider_structs);
    try file_to_structs.put("lib/extra.zap", &extra_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns_v1 = [_][]const u8{"test/**/*_test.zap"};
    const runner_patterns_v2 = [_][]const u8{ "test/**/*_test.zap", "lib/*.zap" };
    const runner_matches_v1 = [_][]const u8{"lib/provider.zap"};
    const runner_matches_v2 = [_][]const u8{ "lib/provider.zap", "lib/extra.zap" };
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns_v1);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches_v1);

    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order_v1 = [_][]const u8{ "Provider", "TestRunner" };
    const struct_order_v2 = [_][]const u8{ "Provider", "Extra", "TestRunner" };
    const provider_source =
        "pub struct Provider {\n" ++
        "  pub fn reflected() -> i64 { 1 }\n" ++
        "}\n";
    const extra_source =
        "pub struct Extra {\n" ++
        "  pub fn reflected() -> i64 { 2 }\n" ++
        "}\n";
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_source, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order_v1,
    });
    try initial.commit();
    initial.deinit();

    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns_v2);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches_v2);

    var changed_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_source, .primary_struct_name = "Provider" },
        .{ .file_path = "lib/extra.zap", .source = extra_source, .primary_struct_name = "Extra" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var changed = try state.prepare(alloc, &changed_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order_v2,
    });
    defer changed.deinit();

    try std.testing.expect(stringSliceContains(changed.invalidated_struct_names, "TestRunner"));
    try std.testing.expect(nodeIdSliceContainsKind(&changed.new_dependency_graph, changed.changed_graph_roots, .ctfe_glob));
}

test "incremental frontend commit stores function body nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const beta_structs = [_][]const u8{"Beta"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/beta.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Alpha", "Beta" };

    const alpha_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const beta_source =
        "pub struct Beta {\n" ++
        "  pub fn value() -> i64 { Alpha.value() }\n" ++
        "}\n";
    var units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = beta_source, .primary_struct_name = "Beta" },
    };

    var prepared = try state.prepare(alloc, &units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    const alpha_function = testFunctionByStructLocal(prepared.result.ir_program, "Alpha", "value__0").?;
    const beta_function = testFunctionByStructLocal(prepared.result.ir_program, "Beta", "value__0").?;
    try prepared.commit();
    prepared.deinit();

    try std.testing.expect((try state.dependency_graph.getNode(try frontendFunctionBodyNodeKey(alpha_function.*))) != null);
    try std.testing.expect((try state.dependency_graph.getNode(try frontendFunctionBodyNodeKey(beta_function.*))) != null);
}

test "incremental frontend function call edge reaches caller body from callee signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const beta_structs = [_][]const u8{"Beta"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_dependents = [_][]const u8{"lib/beta.zap"};
    try file_imported_by.put("lib/alpha.zap", &alpha_dependents);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Alpha", "Beta" };

    const alpha_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const beta_source =
        "pub struct Beta {\n" ++
        "  pub fn value() -> i64 { Alpha.value() }\n" ++
        "}\n";
    var units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = beta_source, .primary_struct_name = "Beta" },
    };

    var prepared = try state.prepare(alloc, &units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    const alpha_function = testFunctionByStructLocal(prepared.result.ir_program, "Alpha", "value__0").?;
    const beta_function = testFunctionByStructLocal(prepared.result.ir_program, "Beta", "value__0").?;
    try prepared.commit();
    prepared.deinit();

    const callee_signature_id = (try state.dependency_graph.getNode(try frontendFunctionSignatureNodeKey(alpha_function.*))).?;
    const caller_body_id = (try state.dependency_graph.getNode(try frontendFunctionBodyNodeKey(beta_function.*))).?;
    const affected = try state.dependency_graph.affectedFrom(std.testing.allocator, &.{callee_signature_id});
    defer std.testing.allocator.free(affected);

    try std.testing.expect(nodeIdSliceContains(affected, caller_body_id));

    const callee_body_id = (try state.dependency_graph.getNode(try frontendFunctionBodyNodeKey(alpha_function.*))).?;
    const body_affected = try state.dependency_graph.affectedFrom(std.testing.allocator, &.{callee_body_id});
    defer std.testing.allocator.free(body_affected);

    try std.testing.expect(!nodeIdSliceContains(body_affected, caller_body_id));
}

test "incremental frontend declaration fingerprints root body-only edits at function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const previous_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const current_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 2 }\n" ++
        "}\n";

    const previous = try testDeclarationFingerprintsFromSource(alloc, previous_source);
    const current = try testDeclarationFingerprintsFromSource(alloc, current_source);

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    const current_sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{current};
    try augmentFrontendGraphWithDeclarationFingerprints(&dependency_graph, &current_sets);

    var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
        std.testing.allocator,
        &dependency_graph,
        previous,
        current,
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
    const root_key = dependency_graph.nodeKey(selection.roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.function_body, root_key.kind());
}

test "incremental frontend declaration fingerprints group multi-clause body edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const previous_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { false }\n" ++
        "  pub fn negate(false) -> Bool { true }\n" ++
        "}\n";
    const current_source =
        "pub struct Bool {\n" ++
        "  pub fn negate(true) -> Bool { false }\n" ++
        "  pub fn negate(false) -> Bool { false }\n" ++
        "}\n";

    const previous = try testDeclarationFingerprintsFromSource(alloc, previous_source);
    const current = try testDeclarationFingerprintsFromSource(alloc, current_source);

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    const current_sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{current};
    try augmentFrontendGraphWithDeclarationFingerprints(&dependency_graph, &current_sets);

    var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
        std.testing.allocator,
        &dependency_graph,
        previous,
        current,
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
    const root_key = dependency_graph.nodeKey(selection.roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.function_body, root_key.kind());
    try std.testing.expectEqualStrings("negate__1", root_key.function_body.local_name);
    try std.testing.expectEqual(@as(u32, 0), root_key.function_body.clause_index);
}

test "incremental frontend declaration fingerprints root signature edits at function signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const previous_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const current_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> f64 { 1 }\n" ++
        "}\n";

    const previous = try testDeclarationFingerprintsFromSource(alloc, previous_source);
    const current = try testDeclarationFingerprintsFromSource(alloc, current_source);

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    const current_sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{current};
    try augmentFrontendGraphWithDeclarationFingerprints(&dependency_graph, &current_sets);

    var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
        std.testing.allocator,
        &dependency_graph,
        previous,
        current,
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
    const root_key = dependency_graph.nodeKey(selection.roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.function_signature, root_key.kind());

    const affected = try dependency_graph.affectedFrom(std.testing.allocator, selection.roots);
    defer std.testing.allocator.free(affected);
    try std.testing.expect(nodeIdSliceContainsKind(&dependency_graph, affected, .function_body));
}

test "incremental frontend declaration fingerprints root struct member edits at struct surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const previous_source =
        "pub struct Alpha {\n" ++
        "  value :: i64\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const current_source =
        "pub struct Alpha {\n" ++
        "  value :: f64\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";

    const previous = try testDeclarationFingerprintsFromSource(alloc, previous_source);
    const current = try testDeclarationFingerprintsFromSource(alloc, current_source);

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    const current_sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{current};
    try augmentFrontendGraphWithDeclarationFingerprints(&dependency_graph, &current_sets);

    var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
        std.testing.allocator,
        &dependency_graph,
        previous,
        current,
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
    const root_key = dependency_graph.nodeKey(selection.roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.struct_surface, root_key.kind());
}

test "incremental frontend uncommitted and failed prepares do not replace state graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const alpha_structs = [_][]const u8{"Alpha"};
    const beta_structs = [_][]const u8{"Beta"};
    try file_to_structs.put("lib/alpha.zap", &alpha_structs);
    try file_to_structs.put("lib/beta.zap", &beta_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Alpha", "Beta" };

    const alpha_source =
        "pub struct Alpha {\n" ++
        "  pub fn value() -> i64 { 1 }\n" ++
        "}\n";
    const beta_source =
        "pub struct Beta {\n" ++
        "  pub fn value() -> i64 { 2 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{ .show_progress = false });
    try initial.commit();
    initial.deinit();

    const committed_node_count = state.dependencyGraphNodeCount();
    try std.testing.expect((try state.dependencyGraphStructSurfaceNode("Alpha")) != null);
    try std.testing.expect((try state.dependencyGraphStructSurfaceNode("Beta")) == null);

    var expanded_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = beta_source, .primary_struct_name = "Beta" },
    };
    var uncommitted = try state.prepare(alloc, &expanded_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    uncommitted.deinit();

    try std.testing.expectEqual(committed_node_count, state.dependencyGraphNodeCount());
    try std.testing.expect((try state.dependencyGraphStructSurfaceNode("Beta")) == null);

    const bad_beta_source = "pub struct Beta {\n  pub fn broken( -> i64 { 2 }\n}\n";
    var bad_units = [_]SourceUnit{
        .{ .file_path = "lib/alpha.zap", .source = alpha_source, .primary_struct_name = "Alpha" },
        .{ .file_path = "lib/beta.zap", .source = bad_beta_source, .primary_struct_name = "Beta" },
    };
    try std.testing.expectError(error.ParseFailed, state.prepare(alloc, &bad_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    }));

    try std.testing.expectEqual(committed_node_count, state.dependencyGraphNodeCount());
    try std.testing.expect((try state.dependencyGraphStructSurfaceNode("Beta")) == null);
}

fn nodeIdSliceContains(haystack: []const zap.incremental_graph.NodeId, needle: zap.incremental_graph.NodeId) bool {
    for (haystack) |candidate| {
        if (candidate == needle) return true;
    }
    return false;
}

fn stringSliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
}

fn nodeIdSliceContainsKind(
    graph: *const zap.incremental_graph.Graph,
    haystack: []const zap.incremental_graph.NodeId,
    kind: zap.incremental_graph.NodeKind,
) bool {
    for (haystack) |candidate| {
        const candidate_kind = graph.nodeKind(candidate) orelse continue;
        if (candidate_kind == kind) return true;
    }
    return false;
}

fn testDeclarationFingerprintsFromSource(
    alloc: std.mem.Allocator,
    source: []const u8,
) !zap.incremental_graph.DeclarationFingerprintSet {
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var parser = zap.Parser.initWithSharedInterner(alloc, source, &interner, 0);
    defer parser.deinit();
    const program = try parser.parseProgram();
    return try computeFrontendDeclarationFingerprints(alloc, program, source, 0, &interner);
}

fn testReflectionFingerprintsFromSource(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
) !zap.incremental_graph.DeclarationFingerprintSet {
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var parser = zap.Parser.initWithSharedInterner(alloc, source, &interner, 0);
    defer parser.deinit();
    const program = try parser.parseProgram();
    return try computeFrontendReflectionFingerprints(alloc, program, source, 0, file_path, &interner);
}

fn expectReflectionRootForMetadataChange(
    previous_source: []const u8,
    current_source: []const u8,
) !void {
    try expectReflectionRootForMetadataChangeWithPaths(
        "lib/provider.zap",
        previous_source,
        "lib/provider.zap",
        current_source,
    );
}

fn expectReflectionRootForMetadataChangeWithPaths(
    previous_file_path: []const u8,
    previous_source: []const u8,
    current_file_path: []const u8,
    current_source: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const previous = try testReflectionFingerprintsFromSource(alloc, previous_file_path, previous_source);
    const current = try testReflectionFingerprintsFromSource(alloc, current_file_path, current_source);

    var dependency_graph = zap.incremental_graph.Graph.init(std.testing.allocator);
    defer dependency_graph.deinit();
    const current_sets = [_]?zap.incremental_graph.DeclarationFingerprintSet{current};
    try augmentFrontendGraphWithDeclarationFingerprints(&dependency_graph, &current_sets);

    var selection = try zap.incremental_graph.selectChangedDeclarationRoots(
        std.testing.allocator,
        &dependency_graph,
        previous,
        current,
    );
    defer selection.deinit(std.testing.allocator);

    try std.testing.expect(selection.isPrecise());
    try std.testing.expectEqual(@as(usize, 1), selection.roots.len);
    const root_key = dependency_graph.nodeKey(selection.roots[0]).?;
    try std.testing.expectEqual(zap.incremental_graph.NodeKind.ctfe_reflection, root_key.kind());
}

fn expectCompileAfterRunnerInvalidation(
    provider_v1: []const u8,
    provider_v2: []const u8,
    expected_runner_invalidated: bool,
    expected_reflection_root: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = FrontendIncrementalState.init(std.testing.allocator);
    defer state.deinit();

    var file_to_structs = std.StringHashMap([]const []const u8).init(alloc);
    const provider_structs = [_][]const u8{"Provider"};
    const runner_structs = [_][]const u8{"TestRunner"};
    try file_to_structs.put("lib/provider.zap", &provider_structs);
    try file_to_structs.put("test/test_runner.zap", &runner_structs);

    var file_imported_by = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_globs = std.StringHashMap([]const []const u8).init(alloc);
    var file_compile_after_files = std.StringHashMap([]const []const u8).init(alloc);
    const runner_patterns = [_][]const u8{"test/**/*_test.zap"};
    const runner_matches = [_][]const u8{"lib/provider.zap"};
    try file_compile_after_globs.put("test/test_runner.zap", &runner_patterns);
    try file_compile_after_files.put("test/test_runner.zap", &runner_matches);

    const graph = FrontendDependencyGraph{
        .file_to_structs = &file_to_structs,
        .file_imported_by = &file_imported_by,
        .file_compile_after_globs = &file_compile_after_globs,
        .file_compile_after_files = &file_compile_after_files,
    };
    const struct_order = [_][]const u8{ "Provider", "TestRunner" };
    const runner_source =
        "pub struct TestRunner {\n" ++
        "  pub fn main() -> i64 { 0 }\n" ++
        "}\n";

    var initial_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v1, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var initial = try state.prepare(alloc, &initial_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    try initial.commit();
    initial.deinit();

    var changed_units = [_]SourceUnit{
        .{ .file_path = "lib/provider.zap", .source = provider_v2, .primary_struct_name = "Provider" },
        .{ .file_path = "test/test_runner.zap", .source = runner_source, .primary_struct_name = "TestRunner" },
    };
    var changed = try state.prepare(alloc, &changed_units, graph, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    defer changed.deinit();

    try std.testing.expectEqual(expected_runner_invalidated, stringSliceContains(changed.invalidated_struct_names, "TestRunner"));
    try std.testing.expectEqual(
        expected_reflection_root,
        nodeIdSliceContainsKind(&changed.new_dependency_graph, changed.changed_graph_roots, .ctfe_reflection),
    );
}

fn testFunctionByStructLocal(program: ir.Program, struct_name: []const u8, local_name: []const u8) ?*const ir.Function {
    for (program.functions) |*function| {
        const owner = function.struct_name orelse continue;
        if (std.mem.eql(u8, owner, struct_name) and std.mem.eql(u8, function.local_name, local_name)) {
            return function;
        }
    }
    return null;
}

fn expectCtfeBool(
    alloc: std.mem.Allocator,
    program: ir.Program,
    function_name: []const u8,
    expected: bool,
) !void {
    var interpreter = zap.ctfe.Interpreter.init(alloc, &program);
    defer interpreter.deinit();
    const value = try interpreter.evalByName(function_name, &.{});

    try std.testing.expect(value == .bool_val);
    try std.testing.expectEqual(expected, value.bool_val);
}

/// Runs the pre-drop ARC ownership pipeline. Semantic/correctness passes always
/// run; Debug policy skips only the optimization-only rewrite boundaries.
fn runArcOwnershipAndVerify(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    ownership: *const zap.arc_liveness.ProgramArcOwnership,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!void {
    const policy = options.frontend_optimize_mode.passPolicy();
    try runRequiredArcOwnershipNormalization(alloc, program, ownership, type_store, options);
    if (policy.elide_borrowed_pass_through) {
        try runOptionalBorrowedPassThroughElision(alloc, program, options);
    }
    var uniqueness_artifacts = try computeArcUniquenessArtifacts(alloc, program, type_store, options);
    defer uniqueness_artifacts.deinit(alloc);
    if (policy.rewrite_unchecked_uniqueness) {
        try runOptionalUncheckedUniquenessRewrite(alloc, program, &uniqueness_artifacts, options);
    }
    try runArcOwnershipVerifier(alloc, program, &uniqueness_artifacts, options);
}

const ArcUniquenessArtifacts = struct {
    post_ownership: zap.arc_liveness.ProgramArcOwnership,
    signatures: zap.uniqueness_signature.ProgramSignatures,
    program_uniqueness: zap.uniqueness_interprocedural.ProgramUniqueness,

    fn deinit(self: *ArcUniquenessArtifacts, alloc: std.mem.Allocator) void {
        self.program_uniqueness.deinit(alloc);
        self.signatures.deinit(alloc);
        self.post_ownership.deinit();
    }
};

/// Semantic ARC normalization required before any drop insertion:
/// owned-mutating builtins and owned-call conventions must be reflected
/// in the IR, and ownership classification must match the type store.
/// These are correctness passes, not optional optimize-mode gates.
fn runRequiredArcOwnershipNormalization(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    ownership: *const zap.arc_liveness.ProgramArcOwnership,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!void {
    // Phase 4 (dense Map): rewrite owned-mutating call_builtin sites
    // (`Map.put`/`.delete`/`.merge`) at last-use BEFORE
    // classifyAndNormalize. The pass uses `last_use_map` (computed
    // before any IR mutation) to gate per-call-site share→move
    // rewrites; classifyAndNormalize replaces `local_get` with
    // `copy_value`/etc. and strips trailing `.retain` instructions,
    // which shifts the InstructionId-by-position relationship that
    // last_use_map keys depend on. Running here keeps the IR shape
    // identical to the one the analyzer saw.
    //
    // The matching consume-effect for the analyzer's dataflow lives
    // in `arc_liveness.applyOwnsEffect`'s `.call_builtin` branch (it
    // clears the receiver's owns bit at the call site so
    // `arc_drop_insertion` doesn't emit a stale post-call release on
    // top of the runtime's consume).
    progressStage(options, "ARC: rewriting owned builtins", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = ownership.get(function.id) orelse continue;
        zap.arc_ownership.rewriteOwnedConsumeBuiltinSites(alloc, function, fn_ownership) catch return error.OutOfMemory;
    }

    progressStage(options, "ARC: classifying ownership", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = ownership.get(function.id) orelse continue;
        zap.arc_ownership.classifyAndNormalizeWithProgram(alloc, function, fn_ownership, type_store, program) catch return error.OutOfMemory;
    }
    // Phase E.9 step 2: for each function whose param_conventions
    // contains an `.owned` slot (set by Step 1's inference), rewrite
    // every call site targeting it from `share_value`/`release` into
    // `move_value` (no caller-side retain) and drop the post-call
    // release. The callee's own scope-exit drop (Phase B's filter
    // releases `.owned` parameters) becomes the sole decrement,
    // closing the per-iteration leak that survived Phase E.8.
    progressStage(options, "ARC: rewriting owned calls", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        zap.arc_ownership.rewriteOwnedConsumeSites(alloc, function, program) catch return error.OutOfMemory;
    }
}

/// Optional borrowed pass-through elision. This removes redundant
/// retain/release pairs around borrowed calls but preserves ARC
/// semantics; Debug policy skips it and release policies keep it enabled.
fn runOptionalBorrowedPassThroughElision(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    options: CompileOptions,
) CompileError!void {
    // Phase 7: eliminate redundant retain/release atomic round-trips
    // for the canonical "borrowed pass-through" shape — a
    // `share_value` + `retain` + call (.borrowed slot) + `release`
    // sequence whose source local is itself `.borrowed` or `.owned`.
    // The pair brackets +1/-1 around the call but produces no
    // observable refcount change because something at higher scope
    // (the caller-of-our-caller for .borrowed sources, or our own
    // scope-exit drop for .owned sources) already keeps the cell
    // alive. Replacing the four-instruction sequence with a single
    // `borrow_value` strips two atomic ops per call without changing
    // semantics — the dominant wall-time cost on tight recursive
    // numeric loops like spectral-norm's `dot_a_row` /
    // `dot_at_row` and fannkuch's `count_flips` / `shift_left`.
    //
    // Must run AFTER `rewriteOwnedConsumeSites` so the only
    // remaining `share_value` instructions are on `.borrowed` slots
    // (consume sites are already rewritten to `move_value`). Must
    // run BEFORE `arc_drop_insertion` so it sees the post-rewrite
    // `local_ownership` and skips scope-exit releases for the now-
    // borrowed aliases.
    progressStage(options, "ARC: eliding borrowed pass-throughs", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        zap.arc_ownership.elideBorrowedPassThroughShares(alloc, function, program) catch return error.OutOfMemory;
    }
}

/// Compute the required verifier artifacts after semantic ARC rewrites. These
/// artifacts stay active in every frontend policy because ownership verification
/// depends on the current post-normalization IR shape.
fn computeArcUniquenessArtifacts(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!ArcUniquenessArtifacts {
    // Phase 2.5 + A1: compute the inputs the interprocedural fixpoint
    // (`uniqueness_interprocedural.analyzeProgramFull`) and the per-
    // function uniqueness dataflow both need:
    //
    //   1. `post_ownership` — per-function ARC ownership recomputed
    //      against the post-rewrite IR (after
    //      `rewriteOwnedConsumeBuiltinSites` / `classifyAndNormalize` /
    //      `rewriteOwnedConsumeSites`). The recompute is necessary so
    //      `last_use_sites` keys align with the InstructionIds the
    //      uniqueness dataflow assigns; `classifyAndNormalize` strips
    //      `local_get`/`retain` pairs which shifts the id space.
    //
    //   2. `signatures` — per-callee parameter uniqueness signatures
    //      (Phase 2.1 PU/CU/AL lattice + per-component return witness).
    //      Computed against the post-rewrite IR so the witness
    //      propagation matches the shape the uniqueness dataflow walks.
    //
    // Both inputs are produced BEFORE the fixpoint so the fixpoint's
    // per-iteration intraprocedural pass can synthesize `tuple_pending`
    // entries for callee tuple-returns and recognise the
    // `index_get + retain` destructure idiom as a uniqueness-preserving
    // move at the parent tuple's last-use. Without these in scope, the
    // fixpoint's intraprocedural pass would observe destructured tuple
    // components as non-unique and incorrectly demote the receiver
    // slot of every tail call fed by such a destructure — the cause of
    // the 28-50% COW rate that fannkuch's `pp_flips = count_flips(pp)
    // ; {pp, flips} = pp_flips; main_loop(p, pp, ...)` pattern exhibits.
    //
    // Architectural note: signatures and ownership are computed
    // against the same post-classify IR shape the fixpoint sees, and
    // neither depends on the fixpoint's output. The dependency chain
    // is therefore:
    //
    //   post_ownership  →  signatures  →  interprocedural fixpoint  →
    //   per-function uniqueness rewrite
    //
    // All three are then consumed by `analyzeUniquenessFull` for the
    // per-function rewrite pass.
    progressStage(options, "ARC: computing uniqueness ownership", .{});
    var post_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer post_ownership.deinit();

    progressStage(options, "ARC: computing uniqueness signatures", .{});
    var signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer signatures.deinit(alloc);

    // A1 (interprocedural uniqueness): run the whole-program fixpoint
    // to compute per-callee per-param unique-on-entry contracts. The
    // per-function pass then consults the fixpoint when classifying
    // `param_get`: a slot proven unique-on-entry across every
    // reachable caller produces a unique dest, propagating into the
    // function's owned-mutating call sites. This activates uniqueness
    // on accumulator-recursion patterns (fannkuch-redux, k-nucleotide)
    // where the receiver is passed through tail-recursive calls.
    //
    // Pass `signatures` and `post_ownership` so the fixpoint's
    // per-iteration intraprocedural pass propagates per-component
    // uniqueness through tuple destructure (Phase 2.5).
    progressStage(options, "ARC: interprocedural uniqueness", .{});
    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &signatures,
        &post_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer program_uniqueness.deinit(alloc);

    return .{
        .post_ownership = post_ownership,
        .signatures = signatures,
        .program_uniqueness = program_uniqueness,
    };
}

/// Optional uniqueness rewrite. The ownership/signature/fixpoint artifacts are
/// computed by `computeArcUniquenessArtifacts` even when this optimization is
/// disabled so the verifier surface stays active in Debug.
fn runOptionalUncheckedUniquenessRewrite(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    uniqueness_artifacts: *const ArcUniquenessArtifacts,
    options: CompileOptions,
) CompileError!void {
    progressStage(options, "ARC: rewriting unique call sites", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = uniqueness_artifacts.post_ownership.get(function.id);
        var uniqueness = zap.uniqueness.analyzeUniquenessFull(
            alloc,
            function,
            program,
            &uniqueness_artifacts.program_uniqueness,
            &uniqueness_artifacts.signatures,
            fn_ownership,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer uniqueness.deinit(alloc);
        if (fn_ownership) |ownership_for_function| {
            zap.arc_ownership.rewriteUncheckedUniquenessSitesWithOwnership(
                alloc,
                function,
                &uniqueness,
                program,
                ownership_for_function,
            ) catch return error.OutOfMemory;
        } else {
            zap.arc_ownership.rewriteUncheckedUniquenessSitesWithProgram(alloc, function, &uniqueness, program) catch return error.OutOfMemory;
        }
        // Wrapper bypass can introduce new direct call_builtin sites
        // after the first consume rewrite has already run. Re-run the
        // builtin consume rewrite against the post-classification
        // ownership table so direct `List.push_owned_unchecked` /
        // `List.set_owned_unchecked` sites drop releases for element
        // arguments consumed by the runtime ABI.
        if (fn_ownership) |ownership_for_function| {
            zap.arc_ownership.rewriteOwnedConsumeBuiltinSites(alloc, function, ownership_for_function) catch return error.OutOfMemory;
        }
    }
}

/// Correctness verifier for the pre-drop ARC pipeline. It runs regardless of
/// optimize mode; when optional uniqueness rewrites are enabled it also catches
/// optimization bugs before later ARC materialization or drop insertion.
fn runArcOwnershipVerifier(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    uniqueness_artifacts: *const ArcUniquenessArtifacts,
    options: CompileOptions,
) CompileError!void {
    progressStage(options, "ARC: verifying ownership invariants", .{});
    for (program.functions) |*function| {
        const fn_ownership = uniqueness_artifacts.post_ownership.get(function.id);
        zap.arc_verifier.verifyFull(
            alloc,
            function,
            program,
            &uniqueness_artifacts.program_uniqueness,
            &uniqueness_artifacts.signatures,
            fn_ownership,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Phase E (Phase 6 redux plan §3.E): the verifier rejects
            // IR that violates an ARC ownership invariant. The plan
            // is emphatic that any rejection points at an upstream
            // pass bug, not a verifier bug — we surface it as a hard
            // build error so the offending pass gets fixed at its
            // source. The diagnostic was already emitted via
            // `std.log.err` inside `verify`.
            error.ArcInvariantViolation => return error.IrFailed,
        };
    }
}

/// Walk every function in `program` and materialize the analysis-
/// context's `arc_ops` and `drop_specializations` records into
/// first-class `.retain { kind }` / `.release { kind }` IR
/// instructions inserted in the function body. Records that can't be
/// resolved (other function, deferred kind, unresolved path) remain
/// in the analysis context so the V10/V11 audits can surface them.
/// Shared between the whole-program (`compileForCtfe`) and per-
/// struct merged (`compileStructByStruct`) pipelines so both
/// entry points lower analysis records into canonical IR before
/// ZIR emission.
///
/// After materialization mutates each function's IR, re-runs the
/// V1-V11 invariants + V8/V9 reachability checks so any defect
/// introduced by the rewrite (wrong-path placement, fresh-LocalId
/// classification drift, retains without matching releases in
/// nested arms) is caught at compile time instead of leaking into
/// ZIR.
fn materializeAnalysisArcOps(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    analysis_context: *zap.escape_lattice.AnalysisContext,
    type_store: *const zap.types.TypeStore,
    declared_caps: u64,
    options: CompileOptions,
) CompileError!void {
    progressStage(options, "ARC: materializing analysis operations", .{});
    for (program.functions, 0..) |_, fi| {
        const function: *ir.Function = @constCast(&program.functions[fi]);
        zap.arc_materialize.materializeAnalysisArcOps(alloc, function, analysis_context, declared_caps) catch return error.IrFailed;
    }
    try runArcVerifier(alloc, program, type_store, options);
}

/// Run V1-V11 (fixpoint) + V8/V9 (post-drop reachability) over
/// every function in `program`. Recomputes the interprocedural
/// uniqueness summary fresh against the current IR shape, so it's
/// safe to call after any pass that mutates the IR (drop insertion,
/// analysis-record materialization, etc.).
fn runArcVerifier(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!void {
    // Recompute Phase-2.5 inputs against the post-materialize IR so the
    // fixpoint and verifier observe the same Phase 2.5 semantics the
    // Phase 5b rewriter observed. Without this the verifier rejects
    // unchecked sites the rewriter legitimately produced.
    progressStage(options, "ARC: verifying materialized ownership", .{});
    var post_materialize_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_materialize_ownership.deinit();

    progressStage(options, "ARC: verifying materialized signatures", .{});
    var post_materialize_signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_materialize_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_materialize_signatures.deinit(alloc);

    progressStage(options, "ARC: verifying interprocedural uniqueness", .{});
    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &post_materialize_signatures,
        &post_materialize_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer program_uniqueness.deinit(alloc);

    progressStage(options, "ARC: verifying materialized functions", .{});
    for (program.functions) |*function| {
        const fn_ownership = post_materialize_ownership.get(function.id);
        zap.arc_verifier.verifyFull(
            alloc,
            function,
            program,
            &program_uniqueness,
            &post_materialize_signatures,
            fn_ownership,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ArcInvariantViolation => return error.IrFailed,
        };
        zap.arc_verifier.verifyPostDropInsertion(alloc, function, program) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ArcInvariantViolation => return error.IrFailed,
        };
    }
}

fn runArcDropInsertion(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    ownership: *const zap.arc_liveness.ProgramArcOwnership,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!void {
    try runArcScopeExitDropInsertion(alloc, program, ownership, options);
    try runArcDropInsertionVerifier(alloc, program, type_store, options);
    dumpPostDropInsertionIrIfRequested(program);
}

/// Semantic drop insertion. These releases make ownership effects
/// explicit in IR before ZIR emission and are required for correctness.
fn runArcScopeExitDropInsertion(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    ownership: *const zap.arc_liveness.ProgramArcOwnership,
    options: CompileOptions,
) CompileError!void {
    progressStage(options, "ARC: inserting scope-exit drops", .{});
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = ownership.get(function.id) orelse continue;
        zap.arc_drop_insertion.insertScopeExitDrops(alloc, function, fn_ownership) catch return error.OutOfMemory;
        // Phase 2.7: component-release insertion is wired after
        // scope-exit drops so `insertScopeExitDrops` can consume the
        // pre-rewrite InstructionIds in `fn_ownership`. The component
        // pass recomputes aggregate last-use over the current stream
        // and uses `fn_ownership.arc_managed_locals` only for ARC
        // classification, which remains stable after the scope-exit
        // rewrite.
        zap.arc_drop_insertion.insertTupleComponentReleases(alloc, function, fn_ownership) catch return error.OutOfMemory;
        // Phase 1.2.5.d: re-tag every release whose target local is a
        // known protocol existential so the ZIR backend lowers it
        // through the synthetic `<Protocol>VTable.drop(box)` helper
        // instead of the generic `releaseAny` dispatcher (which
        // would mis-interpret the box's fat-pointer layout). The
        // sidecar map `function.protocol_box_locals` was populated
        // by the IR builder at function-build time; this pass
        // walks every release (including the ones the scope-exit
        // pass just inserted) and flips the `kind` + `protocol_name`
        // payload where the value local hits the sidecar.
        zap.arc_drop_insertion.rewriteProtocolBoxReleases(function);
    }
}

/// Correctness verifier for post-drop IR. It recomputes ownership,
/// signatures, and uniqueness against the final drop-inserted shape so
/// verifier diagnostics match the IR that will be lowered.
fn runArcDropInsertionVerifier(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    type_store: *const zap.types.TypeStore,
    options: CompileOptions,
) CompileError!void {
    // Recompute Phase-2.5 inputs (post_ownership + signatures) against
    // the post-drop-insertion IR and pass them into the fixpoint and
    // the verifier so the post-drop check observes the same Phase 2.5
    // semantics the Phase 5b rewriter observed. Without this the
    // verifier rejects unchecked sites that the rewriter legitimately
    // produced — Phase 2.5 tuple-destructure propagation only fires
    // when both signatures and ownership are threaded through.
    progressStage(options, "ARC: verifying drop ownership", .{});
    var post_drop_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_drop_ownership.deinit();

    progressStage(options, "ARC: verifying drop signatures", .{});
    var post_drop_signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_drop_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_drop_signatures.deinit(alloc);

    progressStage(options, "ARC: verifying drop uniqueness", .{});
    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &post_drop_signatures,
        &post_drop_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer program_uniqueness.deinit(alloc);

    progressStage(options, "ARC: verifying drop functions", .{});
    for (program.functions) |*function| {
        const fn_ownership = post_drop_ownership.get(function.id);
        zap.arc_verifier.verifyFull(
            alloc,
            function,
            program,
            &program_uniqueness,
            &post_drop_signatures,
            fn_ownership,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ArcInvariantViolation => return error.IrFailed,
        };
        // V8 (forward retain→release reachability) runs post-drop
        // insertion. Warning-only mode currently — diagnostics are
        // printed but don't halt compilation. See arc_verifier.zig's
        // V8 doc block for the rollout plan to fail-mode.
        zap.arc_verifier.verifyPostDropInsertion(alloc, function, program) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ArcInvariantViolation => return error.IrFailed,
        };
    }
}

fn dumpPostDropInsertionIrIfRequested(program: *const ir.Program) void {
    if (std.c.getenv("ZAP_DUMP_IR_FN")) |raw| {
        const glob_z: [*:0]const u8 = @ptrCast(raw);
        const glob = std.mem.span(glob_z);
        for (program.functions) |*function| {
            if (std.mem.indexOf(u8, function.name, glob)) |_| {
                std.debug.print("=== IR dump (post-drop-insertion): {s} (id={d}) ===\n", .{ function.name, function.id });
                std.debug.print("  param_conventions=[", .{});
                for (function.param_conventions, 0..) |c, ci| {
                    if (ci > 0) std.debug.print(", ", .{});
                    std.debug.print(".{s}", .{@tagName(c)});
                }
                std.debug.print("]\n", .{});
                for (function.body, 0..) |block, bidx| {
                    std.debug.print("  block[{d}]:\n", .{bidx});
                    dumpStream(block.instructions, 4);
                }
                std.debug.print("=== end ===\n", .{});
            }
        }
    }
}

fn dumpStream(stream: []const ir.Instruction, indent: usize) void {
    for (stream, 0..) |instr, idx| {
        var spaces: [32]u8 = undefined;
        const used = @min(indent, spaces.len);
        @memset(spaces[0..used], ' ');
        std.debug.print("{s}[{d}] {s}", .{ spaces[0..used], idx, @tagName(instr) });
        switch (instr) {
            .local_get => |lg| std.debug.print(" dest={d} source={d}", .{ lg.dest, lg.source }),
            .share_value => |sv| std.debug.print(" dest={d} source={d} mode={s}", .{ sv.dest, sv.source, @tagName(sv.mode) }),
            .move_value => |mv| std.debug.print(" dest={d} source={d}", .{ mv.dest, mv.source }),
            .borrow_value => |bv| std.debug.print(" dest={d} source={d}", .{ bv.dest, bv.source }),
            .copy_value => |cv| std.debug.print(" dest={d} source={d}", .{ cv.dest, cv.source }),
            .retain => |r| std.debug.print(" value={d}", .{r.value}),
            .release => |r| std.debug.print(" value={d}", .{r.value}),
            .map_init => |mi| std.debug.print(" dest={d}", .{mi.dest}),
            .ret => |r| std.debug.print(" value={?d}", .{r.value}),
            .call_named => |cn| {
                std.debug.print(" name={s} dest={d} args=[", .{ cn.name, cn.dest });
                for (cn.args, 0..) |a, ai| {
                    if (ai > 0) std.debug.print(",", .{});
                    std.debug.print("{d}", .{a});
                }
                std.debug.print("]", .{});
            },
            .call_builtin => |cb| {
                std.debug.print(" name={s} dest={d} args=[", .{ cb.name, cb.dest });
                for (cb.args, 0..) |a, ai| {
                    if (ai > 0) std.debug.print(",", .{});
                    std.debug.print("{d}", .{a});
                }
                std.debug.print("]", .{});
            },
            .call_direct => |cd| {
                std.debug.print(" dest={d} fn={d} args=[", .{ cd.dest, cd.function });
                for (cd.args, 0..) |a, ai| {
                    if (ai > 0) std.debug.print(",", .{});
                    std.debug.print("{d}", .{a});
                }
                std.debug.print("] modes=[", .{});
                for (cd.arg_modes, 0..) |m, mi| {
                    if (mi > 0) std.debug.print(",", .{});
                    std.debug.print(".{s}", .{@tagName(m)});
                }
                std.debug.print("]", .{});
            },
            .param_get => |pg| std.debug.print(" dest={d} index={d}", .{ pg.dest, pg.index }),
            .const_int => |ci| std.debug.print(" dest={d}", .{ci.dest}),
            .switch_literal => |sl| std.debug.print(" dest={d} scrut={d} cases={d}", .{ sl.dest, sl.scrutinee, sl.cases.len }),
            .tail_call => |tc| {
                std.debug.print(" name={s} args=[", .{tc.name});
                for (tc.args, 0..) |a, ai| {
                    if (ai > 0) std.debug.print(",", .{});
                    std.debug.print("{d}", .{a});
                }
                std.debug.print("]", .{});
            },
            .if_expr => |ie| std.debug.print(" dest={d}", .{ie.dest}),
            .local_set => |ls| std.debug.print(" dest={d} value={d}", .{ ls.dest, ls.value }),
            .list_get => |lg| std.debug.print(" dest={d} list={d} idx={d}", .{ lg.dest, lg.list, lg.index }),
            .list_head => |lh| std.debug.print(" dest={d} list={d}", .{ lh.dest, lh.list }),
            .list_tail => |lt| std.debug.print(" dest={d} list={d}", .{ lt.dest, lt.list }),
            .list_is_not_empty => |lne| std.debug.print(" dest={d} list={d}", .{ lne.dest, lne.list }),
            .list_len_check => |llc| std.debug.print(" dest={d} scrut={d} expected={d}", .{ llc.dest, llc.scrutinee, llc.expected_len }),
            .index_get => |ig| std.debug.print(" dest={d} obj={d} idx={d}", .{ ig.dest, ig.object, ig.index }),
            .match_atom => |ma| std.debug.print(" dest={d} scrut={d} atom={s}", .{ ma.dest, ma.scrutinee, ma.atom_name }),
            .guard_block => |gb| std.debug.print(" cond={d}", .{gb.condition}),
            .case_break => |cbk| std.debug.print(" value={?d}", .{cbk.value}),
            .const_string => |cs| std.debug.print(" dest={d}", .{cs.dest}),
            .const_atom => |ca| std.debug.print(" dest={d}", .{ca.dest}),
            .tuple_init => |ti| std.debug.print(" dest={d}", .{ti.dest}),
            .list_init => |li| std.debug.print(" dest={d}", .{li.dest}),
            .list_cons => |lc| std.debug.print(" dest={d} head={d} tail={d}", .{ lc.dest, lc.head, lc.tail }),
            .optional_dispatch => |od| std.debug.print(" scrutinee_param={d} payload_local={d}", .{ od.scrutinee_param, od.payload_local }),
            else => {},
        }
        std.debug.print("\n", .{});
        switch (instr) {
            .if_expr => |ie| {
                std.debug.print("{s}  then:\n", .{(spaces[0..used])});
                dumpStream(ie.then_instrs, indent + 4);
                std.debug.print("{s}  else:\n", .{(spaces[0..used])});
                dumpStream(ie.else_instrs, indent + 4);
            },
            .switch_literal => |sl| {
                for (sl.cases, 0..) |c, ci| {
                    std.debug.print("{s}  case[{d}]:\n", .{ spaces[0..used], ci });
                    dumpStream(c.body_instrs, indent + 4);
                }
                std.debug.print("{s}  default:\n", .{(spaces[0..used])});
                dumpStream(sl.default_instrs, indent + 4);
            },
            .switch_return => |sr| {
                for (sr.cases, 0..) |c, ci| {
                    std.debug.print("{s}  case[{d}]:\n", .{ spaces[0..used], ci });
                    dumpStream(c.body_instrs, indent + 4);
                }
                std.debug.print("{s}  default:\n", .{(spaces[0..used])});
                dumpStream(sr.default_instrs, indent + 4);
            },
            .guard_block => |gb| {
                std.debug.print("{s}  guard_body:\n", .{spaces[0..used]});
                dumpStream(gb.body, indent + 4);
            },
            .case_block => |cb| {
                std.debug.print("{s}  pre_instrs:\n", .{spaces[0..used]});
                dumpStream(cb.pre_instrs, indent + 4);
                for (cb.arms, 0..) |arm, ai| {
                    std.debug.print("{s}  arm[{d}].cond:\n", .{ spaces[0..used], ai });
                    dumpStream(arm.cond_instrs, indent + 4);
                    std.debug.print("{s}  arm[{d}].body:\n", .{ spaces[0..used], ai });
                    dumpStream(arm.body_instrs, indent + 4);
                }
            },
            .optional_dispatch => |od| {
                std.debug.print("{s}  nil", .{spaces[0..used]});
                if (od.nil_result) |result| std.debug.print(" result={d}", .{result});
                std.debug.print(":\n", .{});
                dumpStream(od.nil_instrs, indent + 4);
                std.debug.print("{s}  struct", .{spaces[0..used]});
                if (od.struct_result) |result| std.debug.print(" result={d}", .{result});
                std.debug.print(":\n", .{});
                dumpStream(od.struct_instrs, indent + 4);
            },
            else => {},
        }
    }
}

/// Move every per-function entry from `source` into `target` so the
/// per-struct ARC ownership tables coalesce into one program-wide
/// table. `source` is consumed: its hash-map storage is freed once
/// every entry has been transferred. The inner `ArcOwnership` values
/// keep their original allocator-owned hash-map allocations; only the
/// outer `by_function` map's storage is dropped.
fn mergeArcOwnership(
    alloc: std.mem.Allocator,
    target: *zap.arc_liveness.ProgramArcOwnership,
    source: zap.arc_liveness.ProgramArcOwnership,
) CompileError!void {
    var src = source;
    var it = src.by_function.iterator();
    while (it.next()) |entry| {
        target.by_function.put(alloc, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    target.consumes_marked += src.consumes_marked;
    target.return_sources_recorded += src.return_sources_recorded;
    src.by_function.deinit(src.allocator);
}

/// Extract a single-struct ast.Program from the merged program.
fn extractStructProgram(
    alloc: std.mem.Allocator,
    merged: *const ast.Program,
    mod_name: []const u8,
    interner: *const ast.StringInterner,
) ?ast.Program {
    for (merged.structs) |mod| {
        // Build struct name string from parts
        if (mod.name.parts.len == 1) {
            if (std.mem.eql(u8, interner.get(mod.name.parts[0]), mod_name)) {
                const mods = alloc.alloc(ast.StructDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .structs = mods, .top_items = &.{} };
            }
        } else {
            var buf: [256]u8 = undefined;
            var pos: usize = 0;
            for (mod.name.parts, 0..) |part, i| {
                if (i > 0 and pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
                const s = interner.get(part);
                const end = @min(pos + s.len, buf.len);
                @memcpy(buf[pos..end], s[0 .. end - pos]);
                pos = end;
            }
            if (std.mem.eql(u8, buf[0..pos], mod_name)) {
                const mods = alloc.alloc(ast.StructDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .structs = mods, .top_items = &.{} };
            }
        }
    }
    return null;
}

fn buildStructPrograms(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *const ast.StringInterner,
) ![]const StructProgram {
    const result = try alloc.alloc(StructProgram, program.structs.len);
    for (program.structs, 0..) |mod, i| {
        const name = try structNameToOwnedString(alloc, mod.name, interner);
        const mods = try alloc.alloc(ast.StructDecl, 1);
        mods[0] = mod;

        // Include impl_decls whose target_type matches this struct so the
        // struct's HIR/IR emits the impl function bodies as part of the
        // target struct's namespace. registerImplFunctionsInTargetScopes
        // makes the impl callable; this makes its body land in the right
        // struct's emitted code.
        var struct_top_items: std.ArrayList(ast.TopItem) = .empty;
        for (program.top_items) |item| {
            const impl = switch (item) {
                .impl_decl => |id| id,
                .priv_impl_decl => |id| id,
                else => continue,
            };
            if (structNameMatchesString(impl.target_type, name, interner)) {
                try struct_top_items.append(alloc, item);
            }
        }

        result[i] = .{
            .name = name,
            .program = .{
                .structs = mods,
                .top_items = try struct_top_items.toOwnedSlice(alloc),
            },
        };
    }
    return result;
}

/// Compare an AST StructName against a dotted string like "Integer" or "Foo.Bar".
fn structNameMatchesString(name: ast.StructName, target: []const u8, interner: *const ast.StringInterner) bool {
    var idx: usize = 0;
    for (name.parts, 0..) |part, part_idx| {
        const part_str = interner.get(part);
        if (idx + part_str.len > target.len) return false;
        if (!std.mem.eql(u8, target[idx .. idx + part_str.len], part_str)) return false;
        idx += part_str.len;
        if (part_idx + 1 < name.parts.len) {
            if (idx >= target.len or target[idx] != '.') return false;
            idx += 1;
        }
    }
    return idx == target.len;
}

fn buildCompilationUnits(
    alloc: std.mem.Allocator,
    struct_programs: []const StructProgram,
    source_units: []const SourceUnit,
) ![]CompilationUnit {
    // Build a unit for each struct by using parser source_id metadata first.
    // This stays correct when source_units also contains protocol/impl-only
    // files gathered from manifest globs.
    var units_list: std.ArrayListUnmanaged(CompilationUnit) = .empty;
    for (struct_programs, 0..) |entry, mod_idx| {
        const source_idx = findSourceUnitIndex(entry, mod_idx, struct_programs.len, source_units);
        const su = source_units[source_idx];
        try units_list.append(alloc, .{
            .file_path = su.file_path,
            .struct_name = entry.name,
            .source = su.source,
            .struct_index = @intCast(mod_idx),
            .ir_program = null,
            .dep = null,
        });
    }
    return try units_list.toOwnedSlice(alloc);
}

fn findSourceUnitIndex(
    entry: StructProgram,
    struct_index: usize,
    struct_count: usize,
    source_units: []const SourceUnit,
) usize {
    if (entry.program.structs.len > 0) {
        if (entry.program.structs[0].meta.span.source_id) |source_id| {
            if (source_id < source_units.len) return source_id;
        }
    }

    for (source_units, 0..) |unit, source_index| {
        if (unit.primary_struct_name) |struct_name| {
            if (std.mem.eql(u8, struct_name, entry.name)) return source_index;
        }
    }

    if (struct_count == source_units.len) return struct_index;

    for (source_units, 0..) |unit, source_index| {
        if (std.mem.find(u8, unit.source, entry.name)) |_| {
            return source_index;
        }
    }

    return @min(struct_index, if (source_units.len > 0) source_units.len - 1 else 0);
}

/// Rewrite every `pub error Foo { ... }` / `error Foo { ... }` in
/// `program.top_items` into the canonical `pub struct + pub impl Error
/// for Foo` pair. Runs in `collectAllFromUnits` between
/// `mergePrograms` and the first collect pass — by the time any
/// downstream stage sees the program, every `ErrorDecl` has been
/// replaced. The Desugarer instance is short-lived and uses a null
/// scope graph because the rewrite is purely structural: it does not
/// need name resolution or type information. The global interner is
/// required because the rewrite synthesizes new identifiers
/// (`message`, `cause`, the snake-cased kind atom, etc.).
fn applyErrorDeclDesugar(
    alloc: std.mem.Allocator,
    interner_arg: *ast.StringInterner,
    program: *ast.Program,
) CompileError!void {
    var desugarer = zap.Desugarer.init(alloc, interner_arg, null);
    desugarer.desugarErrorDecls(program) catch return error.DesugarFailed;
}

fn mergePrograms(alloc: std.mem.Allocator, programs: []const ast.Program) !ast.Program {
    var struct_count: usize = 0;
    var top_item_count: usize = 0;
    for (programs) |program| {
        struct_count += program.structs.len;
        top_item_count += program.top_items.len;
    }
    const structs = try alloc.alloc(ast.StructDecl, struct_count);
    const top_items = try alloc.alloc(ast.TopItem, top_item_count);
    var struct_index: usize = 0;
    var top_index: usize = 0;
    for (programs) |program| {
        @memcpy(structs[struct_index .. struct_index + program.structs.len], program.structs);
        @memcpy(top_items[top_index .. top_index + program.top_items.len], program.top_items);
        struct_index += program.structs.len;
        top_index += program.top_items.len;
    }
    return .{ .structs = structs, .top_items = top_items };
}

fn cloneAstProgramOwned(
    alloc: std.mem.Allocator,
    program: ast.Program,
    interner: *const ast.StringInterner,
) !ast.Program {
    var cloned = program;
    const identity_remap = try alloc.alloc(ast.StringId, interner.strings.items.len);
    for (identity_remap, 0..) |*slot, index| {
        slot.* = @intCast(index);
    }
    try remapProgram(alloc, &cloned, identity_remap);
    return cloned;
}

fn emitParseErrorsFromUnits(
    alloc: std.mem.Allocator,
    parse_errors: []const zap.Parser.Error,
    source_units: []const SourceUnit,
    use_color: bool,
) void {
    var engine = zap.DiagnosticEngine.init(alloc);
    engine.use_color = use_color;
    setDiagnosticSources(&engine, source_units);
    for (parse_errors) |parse_err| {
        engine.reportDiagnostic(.{
            .severity = .@"error",
            .message = parse_err.message,
            .span = parse_err.span,
            .label = parse_err.label,
            .help = parse_err.help,
        }) catch {};
    }
    emitDiagnostics(&engine, alloc);
}

fn setDiagnosticSources(engine: *zap.DiagnosticEngine, source_units: []const SourceUnit) void {
    const sources = engine.allocator.alloc(zap.DiagnosticEngine.SourceFile, source_units.len) catch return;
    defer engine.allocator.free(sources);
    for (source_units, 0..) |unit, i| {
        sources[i] = .{ .source = unit.source, .file_path = unit.file_path };
    }
    engine.setSources(sources);
}

fn emitDiagnosticsFromUnits(
    alloc: std.mem.Allocator,
    diagnostics: []const zap.diagnostics.Diagnostic,
    source_units: []const SourceUnit,
    use_color: bool,
) void {
    var engine = zap.DiagnosticEngine.init(alloc);
    engine.use_color = use_color;
    setDiagnosticSources(&engine, source_units);
    for (diagnostics) |diag| {
        engine.reportDiagnostic(.{
            .severity = diag.severity,
            .message = diag.message,
            .span = diag.span,
            .notes = diag.notes,
            .label = diag.label,
            .secondary_spans = diag.secondary_spans,
            .help = diag.help,
            .suggestion = diag.suggestion,
            .code = diag.code,
        }) catch {};
    }
    emitDiagnostics(&engine, alloc);
}

fn emitContextDiagnostics(ctx: *const CompilationContext, alloc: std.mem.Allocator) void {
    emitDiagnostics(@constCast(&ctx.diag_engine), alloc);
}

fn structNameToOwnedString(
    alloc: std.mem.Allocator,
    name: ast.StructName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    return name.toDottedString(alloc, interner);
}

fn lookupStructProgram(ctx: *const CompilationContext, mod_name: []const u8) ?*const ast.Program {
    for (ctx.struct_programs) |*entry| {
        if (std.mem.eql(u8, entry.name, mod_name)) return &entry.program;
    }
    return null;
}

/// Compile a Zap source file through the frontend and ZIR backend to produce
/// a native binary.
fn emitDiagnostics(diag_engine: *zap.DiagnosticEngine, alloc: std.mem.Allocator) void {
    // Honor the process-wide diagnostic-output policy (set once at CLI parse):
    // the security tier governs path stripping, and the format selects the
    // human text renderer or the stable LSP-projectable JSON schema.
    const policy = zap.diagnostics.outputPolicy();
    diag_engine.tier = policy.tier;

    switch (policy.format) {
        .text => {
            const rendered = diag_engine.format(alloc) catch return;
            // stderr writer: use debug.print in 0.16
            std.debug.print("{s}", .{rendered});
        },
        .json => {
            // `--error-format=json`: emit the canonical Error IR as a single
            // JSON document on STDOUT (the machine channel), so a tool can
            // consume it cleanly while human progress stays on stderr.
            const json_text = zap.error_json.serialize(diag_engine, alloc) catch return;
            writeStdoutAll(json_text);
            writeStdoutAll("\n");
        },
    }
}

/// Write `bytes` to STDOUT (fd 1) with a partial-write loop. Used by the
/// `--error-format=json` path so the machine-readable document goes to the
/// stdout channel (human progress stays on stderr). Best-effort: a write
/// failure is swallowed because diagnostics are already a terminal report.
fn writeStdoutAll(bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(std.posix.STDOUT_FILENO, bytes[index..].ptr, bytes.len - index);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return;
                index += written;
            },
            .INTR => {},
            else => return,
        }
    }
}

const testing = std.testing;

test "frontend optimize policies select Phase 3 pass behavior" {
    const debug_policy = FrontendOptimizeMode.debug.passPolicy();
    try testing.expect(!debug_policy.run_region_solver);
    try testing.expect(!debug_policy.run_lambda_specialization);
    try testing.expect(!debug_policy.run_perceus_reuse);
    try testing.expect(!debug_policy.run_arc_optimizer);
    try testing.expect(!debug_policy.run_contification);
    try testing.expect(!debug_policy.elide_borrowed_pass_through);
    try testing.expect(!debug_policy.rewrite_unchecked_uniqueness);
    try testing.expectEqual(FrontendVerifierMode.full, debug_policy.verifier_mode);

    const release_modes = [_]FrontendOptimizeMode{
        .release_safe,
        .release_fast,
        .release_small,
    };

    for (release_modes) |mode| {
        const policy = mode.passPolicy();
        try testing.expect(policy.run_region_solver);
        try testing.expect(policy.run_lambda_specialization);
        try testing.expect(policy.run_perceus_reuse);
        try testing.expect(policy.run_arc_optimizer);
        try testing.expect(policy.run_contification);
        try testing.expect(policy.elide_borrowed_pass_through);
        try testing.expect(policy.rewrite_unchecked_uniqueness);
        try testing.expectEqual(FrontendVerifierMode.full, policy.verifier_mode);
    }
}

test "frontend optimize policy cache tags are stable and mode-specific" {
    try testing.expectEqual(FrontendOptimizeMode.debug.cacheTag(), FrontendOptimizeMode.debug.cacheTag());
    try testing.expect(FrontendOptimizeMode.debug.passPolicy().cacheTag() != FrontendOptimizeMode.release_fast.passPolicy().cacheTag());
    try testing.expectEqual(FrontendOptimizeMode.release_safe.passPolicy().cacheTag(), FrontendOptimizeMode.release_fast.passPolicy().cacheTag());
    try testing.expectEqual(FrontendOptimizeMode.release_fast.passPolicy().cacheTag(), FrontendOptimizeMode.release_small.passPolicy().cacheTag());
    try testing.expect(FrontendOptimizeMode.debug.cacheTag() != FrontendOptimizeMode.release_safe.cacheTag());
    try testing.expect(FrontendOptimizeMode.release_safe.cacheTag() != FrontendOptimizeMode.release_fast.cacheTag());
    try testing.expect(FrontendOptimizeMode.release_fast.cacheTag() != FrontendOptimizeMode.release_small.cacheTag());
}

test "CTFE compile options hash includes frontend policy identity" {
    const debug_hash = ctfeCompileOptionsHash(.{
        .frontend_optimize_mode = .debug,
    });
    const release_hash = ctfeCompileOptionsHash(.{
        .frontend_optimize_mode = .release_fast,
    });

    try testing.expect(debug_hash != release_hash);
}

test "incremental frontend invalidates cached state when policy identity changes" {
    var state = FrontendIncrementalState.init(testing.allocator);
    defer state.deinit();

    const debug_policy_tag = FrontendOptimizeMode.debug.cacheTag();
    const fast_policy_tag = FrontendOptimizeMode.release_fast.cacheTag();

    state.ensurePolicyCacheTag(debug_policy_tag);
    state.initialized = true;
    try testing.expectEqual(debug_policy_tag, state.policy_cache_tag.?);

    state.ensurePolicyCacheTag(debug_policy_tag);
    try testing.expect(state.initialized);

    state.ensurePolicyCacheTag(fast_policy_tag);
    try testing.expect(!state.initialized);
    try testing.expectEqual(fast_policy_tag, state.policy_cache_tag.?);
}

/// Run a compiled binary by name from zap-out/bin/.
pub fn runBinary(allocator: std.mem.Allocator, pio: std.Io, bin_path: []const u8, program_args: []const []const u8) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path);
    for (program_args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = try std.process.spawn(pio, .{
        .argv = argv.items,
        .stderr = .inherit,
        .stdout = .inherit,
        .stdin = .inherit,
    });
    const term = try child.wait(pio);

    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Validate that a source file contains exactly one struct declaration and that the
/// struct name matches the file path. Returns an error message if validation
/// fails, or null if the file is valid.
///
/// `file_path` is relative to the lib root (e.g., "config/parser.zap").
/// The expected struct name is derived from the path: "config/parser.zap" → "Config.Parser".
pub fn validateOneStructPerFile(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
) ?[]const u8 {
    // Use an arena for scratch allocations (parser, name buffers).
    // Only the returned error message (if any) is allocated with the caller's allocator.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse without stdlib — we only need to count struct declarations
    var parser = zap.Parser.init(arena, source);

    const program = parser.parseProgram() catch {
        // Parse errors will be caught later in the full compilation.
        return null;
    };

    // The file's "primary" struct names the file. A struct with items
    // (methods, macros, attributes) takes precedence as the primary.
    // If a file has no method-bearing struct it must have exactly one
    // field-only data struct, which then becomes the primary. Field-
    // only data structs are allowed to coexist alongside a primary.
    var primary_count: u32 = 0;
    var data_struct_count: u32 = 0;
    var primary_name_parts: ?[]const ast.StringId = null;
    var data_name_parts: ?[]const ast.StringId = null;
    var has_protocol_or_impl_or_union = false;
    for (program.top_items) |item| {
        switch (item) {
            .struct_decl => |mod| {
                if (mod.items.len > 0) {
                    primary_count += 1;
                    primary_name_parts = mod.name.parts;
                } else {
                    data_struct_count += 1;
                    data_name_parts = mod.name.parts;
                }
            },
            .priv_struct_decl => |mod| {
                if (mod.items.len > 0) {
                    primary_count += 1;
                    primary_name_parts = mod.name.parts;
                } else {
                    data_struct_count += 1;
                    data_name_parts = mod.name.parts;
                }
            },
            .protocol, .priv_protocol => {
                has_protocol_or_impl_or_union = true;
            },
            .impl_decl, .priv_impl_decl => {
                has_protocol_or_impl_or_union = true;
            },
            // A standalone `pub union Foo {...}` file (e.g.,
            // `lib/io/mode.zap`) is a valid declaration — it carries
            // its own `@doc` and shows up in the docs as a kind of its
            // own. The "one struct per file" rule only kicks in when
            // a file actually declares a struct.
            .union_decl => {
                has_protocol_or_impl_or_union = true;
            },
            else => {},
        }
    }
    // Fall back to program.structs when top_items wasn't populated
    // (e.g., parser variants that only fill the structs slice).
    if (primary_count == 0 and data_struct_count == 0) {
        for (program.structs) |mod| {
            if (mod.items.len > 0) {
                primary_count += 1;
                primary_name_parts = mod.name.parts;
            } else {
                data_struct_count += 1;
                data_name_parts = mod.name.parts;
            }
        }
    }

    // Protocol, impl, and union files don't need a struct declaration
    if (has_protocol_or_impl_or_union and primary_count == 0 and data_struct_count == 0) {
        return null;
    }

    if (primary_count > 1) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one struct declaration, found {d}", .{ file_path, primary_count }) catch "file has multiple structs";
    }

    // No primary: exactly one data struct stands in as the primary.
    // More than one data struct (with no primary to anchor the file)
    // is ambiguous and rejected.
    if (primary_count == 0 and data_struct_count == 0) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one struct declaration, found none", .{file_path}) catch "file has no struct";
    }
    if (primary_count == 0 and data_struct_count > 1) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one struct declaration, found {d}", .{ file_path, data_struct_count }) catch "file has multiple structs";
    }

    const struct_name_parts: ?[]const ast.StringId = primary_name_parts orelse data_name_parts;

    // Build the actual struct name from the AST
    const parts = struct_name_parts orelse return null;
    var actual_name: std.ArrayListUnmanaged(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) actual_name.append(arena, '.') catch return null;
        actual_name.appendSlice(arena, parser.interner.get(part)) catch return null;
    }

    // Build the expected struct name from the file path
    // "config/parser.zap" → "Config.Parser"
    var expected_name: std.ArrayListUnmanaged(u8) = .empty;

    // Strip .zap extension
    const path_no_ext = if (std.mem.endsWith(u8, file_path, ".zap"))
        file_path[0 .. file_path.len - 4]
    else
        file_path;

    // Split on '/' and capitalize each segment
    var seg_iter = std.mem.splitScalar(u8, path_no_ext, '/');
    var first_seg = true;
    while (seg_iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (!first_seg) expected_name.append(arena, '.') catch return null;
        first_seg = false;

        // Capitalize: convert snake_case to PascalCase
        // "config_parser" → "ConfigParser", "config" → "Config"
        var capitalize_next = true;
        for (segment) |c| {
            if (c == '_') {
                capitalize_next = true;
            } else {
                if (capitalize_next) {
                    expected_name.append(arena, std.ascii.toUpper(c)) catch return null;
                    capitalize_next = false;
                } else {
                    expected_name.append(arena, c) catch return null;
                }
            }
        }
    }

    if (!std.mem.eql(u8, actual_name.items, expected_name.items)) {
        // Allocate the error message with the caller's allocator so it outlives the arena
        return std.fmt.allocPrint(
            alloc,
            "Struct name `{s}` does not match file path `{s}` — expected `{s}`",
            .{ actual_name.items, file_path, expected_name.items },
        ) catch "struct name does not match file path";
    }

    return null;
}

/// Get the embedded runtime source, applying the toolchain's
/// compile-time rewrites that should affect every Zap user binary it
/// produces. Six independent rewrites layer here, in order:
///
///   1. The Phase A Map workload instrumentation flag
///      (`INSTRUMENT_MAP_DEFAULT`). Flipped on when the host compiler
///      was built with `-Dinstrument-map=true`.
///   2. The Phase 6 active-manager capability bitmask
///      (`RUNTIME_DECLARED_CAPS_DEFAULT`). Rewritten with the resolved
///      manager's `declared_caps` so the user binary's runtime sees
///      `runtime.refcount_v1_active` resolve correctly without
///      pulling in `@import("root")` (the user binary's root has no
///      such override).
///   3. The active-manager source binding marker
///      (`RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT`). Rewritten to true
///      for user binaries after the driver resolves the selected
///      `Memory.Manager` adapter and registers its backend Zig source
///      as `zap_active_manager`.
///   4. The REFCOUNT_V1 v1.1 sized-extension marker
///      (`RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT`). Rewritten from
///      the selected manager's validated `.zapmem` descriptor surface.
///   5. The ARC stats collection flag (`COLLECT_ARC_STATS_DEFAULT`).
///      Rewritten to `true` only for builds that explicitly request
///      counter collection. `ZAP_ARC_STATS=1` remains a runtime output
///      trigger; it does not enable counter increments after this
///      compile-time flag has elided them.
///   6. The Phase 7e entry-startup guarantee
///      (`RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT`). Rewritten to
///      `true` only for executable binary outputs because the final
///      artifact has a generated entry boundary where the ZIR backend
///      emits an explicit call to `zap_runtime.memoryStartupForEntry()`
///      before user entry code runs. Dispatchers use the marker to
///      compile away the lazy startup fallback only in that guaranteed
///      executable shape; library and object outputs retain the
///      fallback.
///
/// Host tests import `runtime.zig` directly and therefore observe the
/// source-level defaults: instrumentation follows the host build
/// option, declared caps default to ARC, active-manager source binding
/// defaults to unavailable, the startup-prologue marker stays false so
/// lazy startup remains available, and ARC stats default to
/// `builtin.is_test`.
///
/// The returned slice is either a borrowed view of the embedded source
/// (no rewrites required) or a freshly-allocated owned buffer (one or
/// more rewrites applied). Callers that hold onto the slice past the
/// allocator's lifetime must duplicate.
///
/// `declared_caps` is the active manager's capability bitmask.
/// Defaults to `0` would leave the source unchanged at the caps
/// marker; rather than relying on that, the rewrite always runs so
/// the user-binary's runtime reflects the exact resolved value.
///
/// `refcount_sized_extension` is derived from the selected manager's
/// validated REFCOUNT_V1 capability descriptor, not from any manager
/// name table.
pub fn getRuntimeSource(
    declared_caps: u64,
    refcount_sized_extension: bool,
) []const u8 {
    return getRuntimeSourceForRuntimeControls(declared_caps, refcount_sized_extension, .{
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });
}

pub const RuntimeSourceControls = struct {
    /// True only when the generated artifact has an executable entry
    /// boundary that runs `zap_runtime.memoryStartupForEntry()` before
    /// runtime-managed memory can be touched.
    memory_startup_prologue_emitted: bool,
    /// True only for builds that deliberately collect ARC counters.
    /// Runtime `ZAP_ARC_STATS=1` still controls whether collected
    /// counters are printed.
    collect_arc_stats: bool = false,
};

/// Variant of `getRuntimeSource` for callers whose output mode does
/// not guarantee a generated entry prologue. `memory_startup_prologue_emitted`
/// must be true only for executable output shapes where
/// `zir_builder.zig` will emit `zap_runtime.memoryStartupForEntry()`
/// at a guaranteed artifact entry boundary before runtime-managed
/// memory can be touched. Library and object outputs pass false so
/// dispatchers retain the lazy startup fallback.
pub fn getRuntimeSourceForEntryShape(
    declared_caps: u64,
    refcount_sized_extension: bool,
    memory_startup_prologue_emitted: bool,
) []const u8 {
    return getRuntimeSourceForRuntimeControls(declared_caps, refcount_sized_extension, .{
        .memory_startup_prologue_emitted = memory_startup_prologue_emitted,
        .collect_arc_stats = false,
    });
}

pub fn getRuntimeSourceForRuntimeControls(
    declared_caps: u64,
    refcount_sized_extension: bool,
    controls: RuntimeSourceControls,
) []const u8 {
    const instrumented = @import("build_options").instrument_map;
    return rewriteRuntimeSource(.{
        .instrumented = instrumented,
        .declared_caps = declared_caps,
        .refcount_sized_extension = refcount_sized_extension,
        .memory_startup_prologue_emitted = controls.memory_startup_prologue_emitted,
        .collect_arc_stats = controls.collect_arc_stats,
    });
}

const RuntimeRewrite = struct {
    instrumented: bool,
    declared_caps: u64,
    refcount_sized_extension: bool,
    memory_startup_prologue_emitted: bool,
    collect_arc_stats: bool,
};

/// Lazily-built rewritten runtime source. Keyed by the rewrite
/// parameters so repeated invocations with the same shape (the
/// builder and full-build phases both call it during a single
/// compile) return the same stable pointer.
var rewritten_runtime_cache: std.AutoHashMapUnmanaged(u128, []const u8) = .empty;

/// Pack the rewrite parameters into a single 128-bit cache key. The
/// layout is intentionally explicit:
///
///   * bits  0..63 — `declared_caps` (the full u64 bitmask).
///   * bit   64    — `instrumented` (Map workload instrumentation flag).
///   * bit   65    — `memory_startup_prologue_emitted`.
///   * bit   66    — `collect_arc_stats`.
///   * bit   67    — `refcount_sized_extension`.
///   * bits 68..127 — reserved for future rewrite flags.
///
/// The (instrumented, declared_caps, refcount_sized_extension,
/// startup-prologue, ARC-stats) tuple must produce a unique key — two builds that
/// differ in any one field MUST alias to two distinct cache entries,
/// otherwise the second build's rewrite would silently inject the
/// first build's source.
fn rewriteCacheKey(req: RuntimeRewrite) u128 {
    var key: u128 = req.declared_caps;
    if (req.instrumented) key |= (@as(u128, 1) << 64);
    if (req.memory_startup_prologue_emitted) key |= (@as(u128, 1) << 65);
    if (req.collect_arc_stats) key |= (@as(u128, 1) << 66);
    if (req.refcount_sized_extension) key |= (@as(u128, 1) << 67);
    return key;
}

fn rewriteRuntimeSource(req: RuntimeRewrite) []const u8 {
    const key = rewriteCacheKey(req);
    if (rewritten_runtime_cache.get(key)) |cached| return cached;

    // Stage 1: instrumentation marker rewrite (cheap string-substitute).
    var staged: []const u8 = runtime_source;
    var staged_owned = false;
    if (req.instrumented) {
        const needle = "const INSTRUMENT_MAP_DEFAULT: bool = false;";
        const replacement = "const INSTRUMENT_MAP_DEFAULT: bool = true;";
        const idx = std.mem.indexOf(u8, staged, needle) orelse {
            @panic("runtime.zig is missing the INSTRUMENT_MAP_DEFAULT marker; instrumentation rewrite cannot proceed");
        };
        const total_len = staged.len - needle.len + replacement.len;
        var buf = std.heap.page_allocator.alloc(u8, total_len) catch
            @panic("out of memory rewriting runtime source for instrumentation");
        @memcpy(buf[0..idx], staged[0..idx]);
        @memcpy(buf[idx .. idx + replacement.len], replacement);
        @memcpy(buf[idx + replacement.len ..], staged[idx + needle.len ..]);
        staged = buf;
        staged_owned = true;
    }

    // Stage 2: declared_caps marker rewrite. The source-level default
    // is `REFCOUNT_V1_BIT` (`0x0000_0000_0000_0001`) so the host test
    // suite — which loads `runtime.zig` as a Zig module without going
    // through this rewrite — observes an ARC-shaped runtime. We
    // always rewrite for user binaries so the embedded runtime
    // matches the manager the build actually resolved. Even ARC
    // builds go through the rewrite (re-encoding the same value) to
    // keep the rewrite path self-validating.
    const caps_needle = "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0000_0000_0000_0001;";
    var caps_replacement_buf: [128]u8 = undefined;
    const caps_replacement = std.fmt.bufPrint(
        &caps_replacement_buf,
        "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x{x};",
        .{req.declared_caps},
    ) catch @panic("runtime caps rewrite: formatted replacement overflows fixed buffer");
    const caps_idx = std.mem.indexOf(u8, staged, caps_needle) orelse {
        @panic("runtime.zig is missing the RUNTIME_DECLARED_CAPS_DEFAULT marker; Phase 6 caps rewrite cannot proceed");
    };
    const caps_total_len = staged.len - caps_needle.len + caps_replacement.len;
    var caps_buf = std.heap.page_allocator.alloc(u8, caps_total_len) catch
        @panic("out of memory rewriting runtime source for declared_caps");
    @memcpy(caps_buf[0..caps_idx], staged[0..caps_idx]);
    @memcpy(caps_buf[caps_idx .. caps_idx + caps_replacement.len], caps_replacement);
    @memcpy(caps_buf[caps_idx + caps_replacement.len ..], staged[caps_idx + caps_needle.len ..]);

    // Stage-1's buffer is no longer needed once stage-2 produces its
    // own owned copy. Free it back to the page allocator so we don't
    // leak per (instrumented, caps) shape pair.
    if (staged_owned) {
        std.heap.page_allocator.free(@constCast(staged));
    }

    // Stage 3: source-manager binding marker rewrite. User binaries
    // always register the selected manager backend source as `zap_active_manager`;
    // host tests keep the source-level false marker and bind the
    // test-only ARC fallback through the vtable path.
    const source_needle = "const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;";
    const source_replacement = "const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;";
    const source_idx = std.mem.indexOf(u8, caps_buf, source_needle) orelse {
        @panic("runtime.zig is missing the RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT marker; source-binding rewrite cannot proceed");
    };
    const source_total_len = caps_buf.len - source_needle.len + source_replacement.len;
    var source_buf = std.heap.page_allocator.alloc(u8, source_total_len) catch
        @panic("out of memory rewriting runtime source for source-manager binding");
    @memcpy(source_buf[0..source_idx], caps_buf[0..source_idx]);
    @memcpy(source_buf[source_idx .. source_idx + source_replacement.len], source_replacement);
    @memcpy(source_buf[source_idx + source_replacement.len ..], caps_buf[source_idx + source_needle.len ..]);

    std.heap.page_allocator.free(caps_buf);

    // Stage 4: REFCOUNT_V1 v1.1 sized-extension marker rewrite. The
    // build driver derives this from the validated `.zapmem`
    // descriptor size for every manager through the same object
    // validation path.
    const sized_needle = "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = true;";
    const sized_replacement = if (req.refcount_sized_extension)
        "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = true;"
    else
        "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = false;";
    const sized_idx = std.mem.indexOf(u8, source_buf, sized_needle) orelse {
        @panic("runtime.zig is missing the RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT marker; sized-extension rewrite cannot proceed");
    };
    const sized_total_len = source_buf.len - sized_needle.len + sized_replacement.len;
    var sized_buf = std.heap.page_allocator.alloc(u8, sized_total_len) catch
        @panic("out of memory rewriting runtime source for REFCOUNT_V1 sized extension");
    @memcpy(sized_buf[0..sized_idx], source_buf[0..sized_idx]);
    @memcpy(sized_buf[sized_idx .. sized_idx + sized_replacement.len], sized_replacement);
    @memcpy(sized_buf[sized_idx + sized_replacement.len ..], source_buf[sized_idx + sized_needle.len ..]);

    std.heap.page_allocator.free(source_buf);

    // Stage 5: ARC stats collection marker rewrite. Runtime
    // `ZAP_ARC_STATS=1` controls the stderr dump only; this
    // compile-time marker controls whether the counter stores exist
    // in the generated binary at all.
    var final_buf: []u8 = sized_buf;
    if (req.collect_arc_stats) {
        const stats_needle = "const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;";
        const stats_replacement = "const COLLECT_ARC_STATS_DEFAULT: bool = true;";
        const stats_idx = std.mem.indexOf(u8, final_buf, stats_needle) orelse {
            @panic("runtime.zig is missing the COLLECT_ARC_STATS_DEFAULT marker; ARC stats rewrite cannot proceed");
        };
        const stats_total_len = final_buf.len - stats_needle.len + stats_replacement.len;
        var stats_buf = std.heap.page_allocator.alloc(u8, stats_total_len) catch
            @panic("out of memory rewriting runtime source for ARC stats collection");
        @memcpy(stats_buf[0..stats_idx], final_buf[0..stats_idx]);
        @memcpy(stats_buf[stats_idx .. stats_idx + stats_replacement.len], stats_replacement);
        @memcpy(stats_buf[stats_idx + stats_replacement.len ..], final_buf[stats_idx + stats_needle.len ..]);
        std.heap.page_allocator.free(final_buf);
        final_buf = stats_buf;
    }

    // Stage 6: entry-startup prologue marker rewrite. Only generated
    // executable binary outputs set this true: the final artifact has
    // an entry boundary where the ZIR backend emits an explicit call
    // to `memoryStartupForEntry()`. Host tests, libraries, objects,
    // and any runtime source imported without that executable-entry
    // guarantee must retain the source-level false marker so
    // dispatcher startup remains lazy and safe.
    if (req.memory_startup_prologue_emitted) {
        const prologue_needle = "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = false;";
        const prologue_replacement = "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = true;";
        const prologue_idx = std.mem.indexOf(u8, final_buf, prologue_needle) orelse {
            @panic("runtime.zig is missing the RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT marker; Phase 7e startup-prologue rewrite cannot proceed");
        };
        const prologue_total_len = final_buf.len - prologue_needle.len + prologue_replacement.len;
        var prologue_buf = std.heap.page_allocator.alloc(u8, prologue_total_len) catch
            @panic("out of memory rewriting runtime source for memory startup prologue");
        @memcpy(prologue_buf[0..prologue_idx], final_buf[0..prologue_idx]);
        @memcpy(prologue_buf[prologue_idx .. prologue_idx + prologue_replacement.len], prologue_replacement);
        @memcpy(prologue_buf[prologue_idx + prologue_replacement.len ..], final_buf[prologue_idx + prologue_needle.len ..]);
        std.heap.page_allocator.free(final_buf);
        final_buf = prologue_buf;
    }

    rewritten_runtime_cache.put(std.heap.page_allocator, key, final_buf) catch
        @panic("out of memory caching rewritten runtime source");
    return final_buf;
}

// ============================================================
// Parallel parsing support
// ============================================================

/// Per-file result from a parallel parse task.
const ParseTaskResult = struct {
    failed: bool = false,
    errors: []const zap.Parser.Error = &.{},
};

/// Task function for parallel file parsing via Io.Group.
/// Each task creates its own parser with a private local interner,
/// parses the source, and stores the result. No shared mutable state.
fn parseFileTask(
    alloc: std.mem.Allocator,
    source: []const u8,
    interner: *ast.StringInterner,
    source_id: u32,
    script_mode: bool,
    out_program: *ast.Program,
    out_result: *ParseTaskResult,
) void {
    var parser = zap.Parser.initWithSharedInternerScriptMode(alloc, source, interner, source_id, script_mode);
    defer parser.deinit();

    out_program.* = parser.parseProgram() catch {
        out_result.failed = true;
        out_result.errors = parser.errors.toOwnedSlice(alloc) catch &.{};
        return;
    };

    if (parser.errors.items.len > 0) {
        out_result.errors = parser.errors.toOwnedSlice(alloc) catch &.{};
    }
}

// ============================================================
// Interner merging and AST remapping
// ============================================================

/// Build a remap table from a local interner to the global interner.
/// For each string in `local_interner`, interns it into `global_interner`
/// and records the mapping: `remap[local_id] = global_id`.
fn buildInternerRemap(
    alloc: std.mem.Allocator,
    local_interner: *const ast.StringInterner,
    global_interner: *ast.StringInterner,
) ![]ast.StringId {
    const remap = try alloc.alloc(ast.StringId, local_interner.strings.items.len);
    for (local_interner.strings.items, 0..) |str, i| {
        remap[i] = try global_interner.intern(str);
    }
    return remap;
}

/// Remap every StringId in a parsed Program using the given remap table.
/// This walks all AST nodes exhaustively.
fn remapProgram(
    alloc: std.mem.Allocator,
    program: *ast.Program,
    remap: []const ast.StringId,
) !void {
    // Remap structs (mutable copy needed since program.structs is []const)
    if (program.structs.len > 0) {
        const mutable_structs = try alloc.alloc(ast.StructDecl, program.structs.len);
        @memcpy(mutable_structs, program.structs);
        for (mutable_structs) |*mod| {
            try remapStructDecl(alloc, mod, remap);
        }
        program.structs = mutable_structs;
    }

    // Remap top_items
    if (program.top_items.len > 0) {
        const mutable_top_items = try alloc.alloc(ast.TopItem, program.top_items.len);
        @memcpy(mutable_top_items, program.top_items);
        for (mutable_top_items) |*item| {
            try remapTopItem(alloc, item, remap);
        }
        program.top_items = mutable_top_items;
    }
}

fn remapStructName(alloc: std.mem.Allocator, name: *ast.StructName, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (name.parts.len > 0) {
        const mutable_parts = try alloc.alloc(ast.StringId, name.parts.len);
        for (name.parts, 0..) |part, i| {
            mutable_parts[i] = remap[part];
        }
        name.parts = mutable_parts;
    }
}

fn remapStructDecl(alloc: std.mem.Allocator, mod: *ast.StructDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapStructName(alloc, &mod.name, remap);
    if (mod.parent) |p| mod.parent = remap[p];
    // Parametric type parameters on `pub struct Foo(T)` carry the
    // formal type-var names. Their interner IDs come from the unit's
    // LOCAL interner — remap to the global interner alongside the
    // declaration's name so the typechecker's `type_var_scope`
    // population (in `types.zig`) sees the same StringId the IR layer
    // looks up later. Without this remap a unit-local id for `t`
    // would land in the global slot for some other identifier,
    // corrupting `applyToType`'s substitution.
    if (mod.type_params.len > 0) {
        const mutable_params = try alloc.alloc(ast.StringId, mod.type_params.len);
        for (mod.type_params, 0..) |tp, i| {
            mutable_params[i] = remap[tp];
        }
        mod.type_params = mutable_params;
    }
    if (mod.items.len > 0) {
        const mutable_items = try alloc.alloc(ast.StructItem, mod.items.len);
        @memcpy(mutable_items, mod.items);
        for (mutable_items) |*item| {
            try remapStructItem(alloc, item, remap);
        }
        mod.items = mutable_items;
    }
    if (mod.fields.len > 0) {
        const mutable_fields = try alloc.alloc(ast.StructFieldDecl, mod.fields.len);
        for (mod.fields, 0..) |f, i| {
            mutable_fields[i] = f;
            mutable_fields[i].name = remap[f.name];
            const mutable_te = try alloc.create(ast.TypeExpr);
            mutable_te.* = f.type_expr.*;
            try remapTypeExpr(alloc, mutable_te, remap);
            mutable_fields[i].type_expr = mutable_te;
            if (f.default) |def| {
                const mutable_def = try alloc.create(ast.Expr);
                mutable_def.* = def.*;
                try remapExpr(alloc, mutable_def, remap);
                mutable_fields[i].default = mutable_def;
            }
        }
        mod.fields = mutable_fields;
    }
}

fn remapTopItem(alloc: std.mem.Allocator, item: *ast.TopItem, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (item.*) {
        .struct_decl, .priv_struct_decl => |mod_ptr| {
            const mutable = try alloc.create(ast.StructDecl);
            mutable.* = mod_ptr.*;
            try remapStructDecl(alloc, mutable, remap);
            item.* = if (item.* == .struct_decl) .{ .struct_decl = mutable } else .{ .priv_struct_decl = mutable };
        },
        .type_decl => |td| {
            const mutable = try alloc.create(ast.TypeDecl);
            mutable.* = td.*;
            try remapTypeDecl(alloc, mutable, remap);
            item.* = .{ .type_decl = mutable };
        },
        .opaque_decl => |od| {
            const mutable = try alloc.create(ast.OpaqueDecl);
            mutable.* = od.*;
            try remapOpaqueDecl(alloc, mutable, remap);
            item.* = .{ .opaque_decl = mutable };
        },
        .union_decl => |ud| {
            const mutable = try alloc.create(ast.UnionDecl);
            mutable.* = ud.*;
            try remapUnionDecl(alloc, mutable, remap);
            item.* = .{ .union_decl = mutable };
        },
        .function, .priv_function => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            item.* = if (item.* == .function) .{ .function = mutable } else .{ .priv_function = mutable };
        },
        .macro, .priv_macro => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            item.* = if (item.* == .macro) .{ .macro = mutable } else .{ .priv_macro = mutable };
        },
        .protocol => |pd| {
            const mutable = try alloc.create(ast.ProtocolDecl);
            mutable.* = pd.*;
            try remapProtocolDecl(alloc, mutable, remap);
            item.* = .{ .protocol = mutable };
        },
        .priv_protocol => |pd| {
            const mutable = try alloc.create(ast.ProtocolDecl);
            mutable.* = pd.*;
            try remapProtocolDecl(alloc, mutable, remap);
            item.* = .{ .priv_protocol = mutable };
        },
        .impl_decl => |id| {
            const mutable = try alloc.create(ast.ImplDecl);
            mutable.* = id.*;
            try remapImplDecl(alloc, mutable, remap);
            item.* = .{ .impl_decl = mutable };
        },
        .priv_impl_decl => |id| {
            const mutable = try alloc.create(ast.ImplDecl);
            mutable.* = id.*;
            try remapImplDecl(alloc, mutable, remap);
            item.* = .{ .priv_impl_decl = mutable };
        },
        .attribute => |attr| {
            const mutable = try alloc.create(ast.AttributeDecl);
            mutable.* = attr.*;
            try remapAttributeDecl(alloc, mutable, remap);
            item.* = .{ .attribute = mutable };
        },
        .error_decl, .priv_error_decl => |ed| {
            // `pub error` / `error` survive the unit-local-to-global
            // interner remap because the remap runs BEFORE the front-end
            // desugar pass (see `compileCollectAllFromUnits` ordering).
            // We rewrite the declaration's StringIds — name, type-params,
            // fields, items, and the `@code` value when present — so the
            // desugar that follows sees globally-interned identifiers,
            // exactly like the struct path.
            const mutable = try alloc.create(ast.ErrorDecl);
            mutable.* = ed.*;
            try remapErrorDecl(alloc, mutable, remap);
            item.* = if (item.* == .error_decl) .{ .error_decl = mutable } else .{ .priv_error_decl = mutable };
        },
    }
}

fn remapErrorDecl(alloc: std.mem.Allocator, ed: *ast.ErrorDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapStructName(alloc, &ed.name, remap);
    if (ed.type_params.len > 0) {
        const mutable_params = try alloc.alloc(ast.StringId, ed.type_params.len);
        for (ed.type_params, 0..) |tp, i| {
            mutable_params[i] = remap[tp];
        }
        ed.type_params = mutable_params;
    }
    if (ed.items.len > 0) {
        const mutable_items = try alloc.alloc(ast.StructItem, ed.items.len);
        @memcpy(mutable_items, ed.items);
        for (mutable_items) |*item| {
            try remapStructItem(alloc, item, remap);
        }
        ed.items = mutable_items;
    }
    if (ed.fields.len > 0) {
        const mutable_fields = try alloc.alloc(ast.StructFieldDecl, ed.fields.len);
        for (ed.fields, 0..) |f, i| {
            mutable_fields[i] = f;
            mutable_fields[i].name = remap[f.name];
            const mutable_te = try alloc.create(ast.TypeExpr);
            mutable_te.* = f.type_expr.*;
            try remapTypeExpr(alloc, mutable_te, remap);
            mutable_fields[i].type_expr = mutable_te;
            if (f.default) |def| {
                const mutable_def = try alloc.create(ast.Expr);
                mutable_def.* = def.*;
                try remapExpr(alloc, mutable_def, remap);
                mutable_fields[i].default = mutable_def;
            }
        }
        ed.fields = mutable_fields;
    }
    if (ed.doc) |doc_attr| {
        const mutable_attr = try alloc.create(ast.AttributeDecl);
        mutable_attr.* = doc_attr.*;
        try remapAttributeDecl(alloc, mutable_attr, remap);
        ed.doc = mutable_attr;
    }
}

fn remapProtocolDecl(alloc: std.mem.Allocator, proto: *ast.ProtocolDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    // Remap protocol name parts
    const new_parts = try alloc.alloc(ast.StringId, proto.name.parts.len);
    for (proto.name.parts, 0..) |part, i| {
        new_parts[i] = if (part < remap.len) remap[part] else part;
    }
    proto.name.parts = new_parts;

    if (proto.type_params.len > 0) {
        const new_type_params = try alloc.alloc(ast.StringId, proto.type_params.len);
        for (proto.type_params, 0..) |type_param, i| {
            new_type_params[i] = if (type_param < remap.len) remap[type_param] else type_param;
        }
        proto.type_params = new_type_params;
    }

    // Remap function signature names and type expressions
    const new_fns = try alloc.alloc(ast.ProtocolFunctionSig, proto.functions.len);
    for (proto.functions, 0..) |sig, i| {
        var new_sig = sig;
        new_sig.name = if (sig.name < remap.len) remap[sig.name] else sig.name;
        // Remap param names
        const new_params = try alloc.alloc(ast.ProtocolParam, sig.params.len);
        for (sig.params, 0..) |param, j| {
            new_params[j] = param;
            new_params[j].name = if (param.name < remap.len) remap[param.name] else param.name;
            if (param.type_annotation) |type_annotation| {
                const mutable_type_annotation = try alloc.create(ast.TypeExpr);
                mutable_type_annotation.* = type_annotation.*;
                try remapTypeExpr(alloc, mutable_type_annotation, remap);
                new_params[j].type_annotation = mutable_type_annotation;
            }
        }
        new_sig.params = new_params;
        if (sig.return_type) |return_type| {
            const mutable_return_type = try alloc.create(ast.TypeExpr);
            mutable_return_type.* = return_type.*;
            try remapTypeExpr(alloc, mutable_return_type, remap);
            new_sig.return_type = mutable_return_type;
        }
        new_fns[i] = new_sig;
    }
    proto.functions = new_fns;
}

fn remapImplDecl(alloc: std.mem.Allocator, impl_d: *ast.ImplDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    // Remap protocol name parts
    const new_proto_parts = try alloc.alloc(ast.StringId, impl_d.protocol_name.parts.len);
    for (impl_d.protocol_name.parts, 0..) |part, i| {
        new_proto_parts[i] = if (part < remap.len) remap[part] else part;
    }
    impl_d.protocol_name.parts = new_proto_parts;

    if (impl_d.protocol_type_args.len > 0) {
        const new_protocol_type_args = try alloc.alloc(*const ast.TypeExpr, impl_d.protocol_type_args.len);
        for (impl_d.protocol_type_args, 0..) |type_arg, i| {
            const mutable_type_arg = try alloc.create(ast.TypeExpr);
            mutable_type_arg.* = type_arg.*;
            try remapTypeExpr(alloc, mutable_type_arg, remap);
            new_protocol_type_args[i] = mutable_type_arg;
        }
        impl_d.protocol_type_args = new_protocol_type_args;
    }

    // Remap target type name parts
    const new_type_parts = try alloc.alloc(ast.StringId, impl_d.target_type.parts.len);
    for (impl_d.target_type.parts, 0..) |part, i| {
        new_type_parts[i] = if (part < remap.len) remap[part] else part;
    }
    impl_d.target_type.parts = new_type_parts;

    // Remap impl-declared type parameter names. Without this, the
    // StringIds carried by `type_params` still point into the parser's
    // local interner — after merge they decode to whatever string lives
    // at that ID in the global interner, garbling the type-var names.
    if (impl_d.type_params.len > 0) {
        const new_type_params = try alloc.alloc(ast.StringId, impl_d.type_params.len);
        for (impl_d.type_params, 0..) |tp, i| {
            new_type_params[i] = if (tp < remap.len) remap[tp] else tp;
        }
        impl_d.type_params = new_type_params;
    }

    // Remap function declarations inside the impl
    const new_fns = try alloc.alloc(*const ast.FunctionDecl, impl_d.functions.len);
    for (impl_d.functions, 0..) |func, i| {
        const mutable = try alloc.create(ast.FunctionDecl);
        mutable.* = func.*;
        try remapFunctionDecl(alloc, mutable, remap);
        new_fns[i] = mutable;
    }
    impl_d.functions = new_fns;
}

fn remapStructItem(alloc: std.mem.Allocator, item: *ast.StructItem, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (item.*) {
        .type_decl => |td| {
            const mutable = try alloc.create(ast.TypeDecl);
            mutable.* = td.*;
            try remapTypeDecl(alloc, mutable, remap);
            item.* = .{ .type_decl = mutable };
        },
        .opaque_decl => |od| {
            const mutable = try alloc.create(ast.OpaqueDecl);
            mutable.* = od.*;
            try remapOpaqueDecl(alloc, mutable, remap);
            item.* = .{ .opaque_decl = mutable };
        },
        .struct_decl => |sd| {
            const mutable = try alloc.create(ast.StructDecl);
            mutable.* = sd.*;
            try remapStructDecl(alloc, mutable, remap);
            item.* = .{ .struct_decl = mutable };
        },
        .union_decl => |ud| {
            const mutable = try alloc.create(ast.UnionDecl);
            mutable.* = ud.*;
            try remapUnionDecl(alloc, mutable, remap);
            item.* = .{ .union_decl = mutable };
        },
        .function, .priv_function => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            item.* = if (item.* == .function) .{ .function = mutable } else .{ .priv_function = mutable };
        },
        .macro, .priv_macro => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            item.* = if (item.* == .macro) .{ .macro = mutable } else .{ .priv_macro = mutable };
        },
        .alias_decl => |ad| {
            const mutable = try alloc.create(ast.AliasDecl);
            mutable.* = ad.*;
            try remapStructName(alloc, &mutable.struct_path, remap);
            if (mutable.as_name) |*as_name| try remapStructName(alloc, as_name, remap);
            item.* = .{ .alias_decl = mutable };
        },
        .import_decl => |id| {
            const mutable = try alloc.create(ast.ImportDecl);
            mutable.* = id.*;
            try remapImportDecl(alloc, mutable, remap);
            item.* = .{ .import_decl = mutable };
        },
        .use_decl => |ud| {
            const mutable = try alloc.create(ast.UseDecl);
            mutable.* = ud.*;
            try remapStructName(alloc, &mutable.struct_path, remap);
            if (mutable.opts) |opts| {
                const mutable_opts = try alloc.create(ast.Expr);
                mutable_opts.* = opts.*;
                try remapExpr(alloc, mutable_opts, remap);
                mutable.opts = mutable_opts;
            }
            item.* = .{ .use_decl = mutable };
        },
        .attribute => |attr| {
            const mutable = try alloc.create(ast.AttributeDecl);
            mutable.* = attr.*;
            try remapAttributeDecl(alloc, mutable, remap);
            item.* = .{ .attribute = mutable };
        },
        .struct_level_expr => |expr| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = expr.*;
            try remapExpr(alloc, mutable, remap);
            item.* = .{ .struct_level_expr = mutable };
        },
    }
}

fn remapAttributeDecl(alloc: std.mem.Allocator, attr: *ast.AttributeDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    attr.name = remap[attr.name];
    if (attr.type_expr) |type_expr| {
        const mutable_type_expr = try alloc.create(ast.TypeExpr);
        mutable_type_expr.* = type_expr.*;
        try remapTypeExpr(alloc, mutable_type_expr, remap);
        attr.type_expr = mutable_type_expr;
    }
    if (attr.value) |value| {
        const mutable_value = try alloc.create(ast.Expr);
        mutable_value.* = value.*;
        try remapExpr(alloc, mutable_value, remap);
        attr.value = mutable_value;
    }
}

fn remapTypeDecl(alloc: std.mem.Allocator, td: *ast.TypeDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    td.name = remap[td.name];
    try remapTypeParams(alloc, td, remap);
    const mutable_body = try alloc.create(ast.TypeExpr);
    mutable_body.* = td.body.*;
    try remapTypeExpr(alloc, mutable_body, remap);
    td.body = mutable_body;
}

fn remapOpaqueDecl(alloc: std.mem.Allocator, od: *ast.OpaqueDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    od.name = remap[od.name];
    try remapOpaqueParams(alloc, od, remap);
    const mutable_body = try alloc.create(ast.TypeExpr);
    mutable_body.* = od.body.*;
    try remapTypeExpr(alloc, mutable_body, remap);
    od.body = mutable_body;
}

fn remapTypeParams(alloc: std.mem.Allocator, td: *ast.TypeDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (td.params.len > 0) {
        const mutable_params = try alloc.alloc(ast.TypeParam, td.params.len);
        for (td.params, 0..) |p, i| {
            mutable_params[i] = p;
            mutable_params[i].name = remap[p.name];
        }
        td.params = mutable_params;
    }
}

fn remapOpaqueParams(alloc: std.mem.Allocator, od: *ast.OpaqueDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (od.params.len > 0) {
        const mutable_params = try alloc.alloc(ast.TypeParam, od.params.len);
        for (od.params, 0..) |p, i| {
            mutable_params[i] = p;
            mutable_params[i].name = remap[p.name];
        }
        od.params = mutable_params;
    }
}

fn remapUnionDecl(alloc: std.mem.Allocator, ud: *ast.UnionDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    ud.name = remap[ud.name];
    // Parametric type parameters on `pub union Foo(T)` — same remap
    // contract as `remapStructDecl`'s `mod.type_params`. The
    // typechecker binds these names into `type_var_scope` for the
    // duration of variant payload resolution, so a local-id leak
    // here would unbind `T` from the union's variants and corrupt
    // per-instantiation substitution downstream.
    if (ud.type_params.len > 0) {
        const mutable_params = try alloc.alloc(ast.StringId, ud.type_params.len);
        for (ud.type_params, 0..) |tp, i| {
            mutable_params[i] = remap[tp];
        }
        ud.type_params = mutable_params;
    }
    if (ud.variants.len > 0) {
        const mutable_variants = try alloc.alloc(ast.UnionVariant, ud.variants.len);
        for (ud.variants, 0..) |v, i| {
            mutable_variants[i] = v;
            mutable_variants[i].name = remap[v.name];
            if (v.type_expr) |te| {
                const mutable_te = try alloc.create(ast.TypeExpr);
                mutable_te.* = te.*;
                try remapTypeExpr(alloc, mutable_te, remap);
                mutable_variants[i].type_expr = mutable_te;
            }
        }
        ud.variants = mutable_variants;
    }
}

fn remapFunctionDecl(alloc: std.mem.Allocator, fd: *ast.FunctionDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    fd.name = remap[fd.name];
    if (fd.name_expr) |ne| {
        const mutable_ne = try alloc.create(ast.Expr);
        mutable_ne.* = ne.*;
        try remapExpr(alloc, mutable_ne, remap);
        fd.name_expr = mutable_ne;
    }
    if (fd.clauses.len > 0) {
        const mutable_clauses = try alloc.alloc(ast.FunctionClause, fd.clauses.len);
        for (fd.clauses, 0..) |clause, i| {
            mutable_clauses[i] = clause;
            try remapFunctionClause(alloc, &mutable_clauses[i], remap);
        }
        fd.clauses = mutable_clauses;
    }
}

fn remapFunctionClause(alloc: std.mem.Allocator, clause: *ast.FunctionClause, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (clause.params.len > 0) {
        const mutable_params = try alloc.alloc(ast.Param, clause.params.len);
        for (clause.params, 0..) |p, i| {
            mutable_params[i] = p;
            const mutable_pat = try alloc.create(ast.Pattern);
            mutable_pat.* = p.pattern.*;
            try remapPattern(alloc, mutable_pat, remap);
            mutable_params[i].pattern = mutable_pat;
            if (p.type_annotation) |ta| {
                const mutable_ta = try alloc.create(ast.TypeExpr);
                mutable_ta.* = ta.*;
                try remapTypeExpr(alloc, mutable_ta, remap);
                mutable_params[i].type_annotation = mutable_ta;
            }
            if (p.default) |def| {
                const mutable_def = try alloc.create(ast.Expr);
                mutable_def.* = def.*;
                try remapExpr(alloc, mutable_def, remap);
                mutable_params[i].default = mutable_def;
            }
        }
        clause.params = mutable_params;
    }
    if (clause.return_type) |rt| {
        const mutable_rt = try alloc.create(ast.TypeExpr);
        mutable_rt.* = rt.*;
        try remapTypeExpr(alloc, mutable_rt, remap);
        clause.return_type = mutable_rt;
    }
    if (clause.raises) |declared_row| {
        // Each error-type expression in the `raises` row carries
        // StringIds from the parser's per-unit local interner. Remap them
        // into the global interner exactly like `return_type` and param
        // annotations — otherwise the type names decode against the wrong
        // interner after the merge (e.g. `String` -> whatever lives at the
        // same StringId globally).
        const mutable_row = try alloc.alloc(*const ast.TypeExpr, declared_row.len);
        for (declared_row, 0..) |error_type_expr, i| {
            const mutable_error_type = try alloc.create(ast.TypeExpr);
            mutable_error_type.* = error_type_expr.*;
            try remapTypeExpr(alloc, mutable_error_type, remap);
            mutable_row[i] = mutable_error_type;
        }
        clause.raises = mutable_row;
    }
    if (clause.refinement) |ref| {
        const mutable_ref = try alloc.create(ast.Expr);
        mutable_ref.* = ref.*;
        try remapExpr(alloc, mutable_ref, remap);
        clause.refinement = mutable_ref;
    }
    if (clause.body) |body| {
        try remapStmtsForClause(alloc, clause, remap, body);
    }
}

fn remapStmtsForClause(alloc: std.mem.Allocator, clause: *ast.FunctionClause, remap: []const ast.StringId, body: []const ast.Stmt) !void {
    const mutable_body = try alloc.alloc(ast.Stmt, body.len);
    @memcpy(mutable_body, body);
    for (mutable_body) |*stmt| {
        try remapStmt(alloc, stmt, remap);
    }
    clause.body = mutable_body;
}

fn remapStmt(alloc: std.mem.Allocator, stmt: *ast.Stmt, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (stmt.*) {
        .expr => |e| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = e.*;
            try remapExpr(alloc, mutable, remap);
            stmt.* = .{ .expr = mutable };
        },
        .assignment => |a| {
            const mutable = try alloc.create(ast.Assignment);
            mutable.* = a.*;
            const mutable_pat = try alloc.create(ast.Pattern);
            mutable_pat.* = a.pattern.*;
            try remapPattern(alloc, mutable_pat, remap);
            mutable.pattern = mutable_pat;
            const mutable_val = try alloc.create(ast.Expr);
            mutable_val.* = a.value.*;
            try remapExpr(alloc, mutable_val, remap);
            mutable.value = mutable_val;
            stmt.* = .{ .assignment = mutable };
        },
        .function_decl => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            stmt.* = .{ .function_decl = mutable };
        },
        .macro_decl => |fd| {
            const mutable = try alloc.create(ast.FunctionDecl);
            mutable.* = fd.*;
            try remapFunctionDecl(alloc, mutable, remap);
            stmt.* = .{ .macro_decl = mutable };
        },
        .import_decl => |id| {
            const mutable = try alloc.create(ast.ImportDecl);
            mutable.* = id.*;
            try remapImportDecl(alloc, mutable, remap);
            stmt.* = .{ .import_decl = mutable };
        },
        .attribute => |attr| {
            const mutable = try alloc.create(ast.AttributeDecl);
            mutable.* = attr.*;
            try remapAttributeDecl(alloc, mutable, remap);
            stmt.* = .{ .attribute = mutable };
        },
        .defer_stmt => |defer_node| {
            // StringId-remap gotcha (see the `raises` row fix): the deferred
            // cleanup expression carries per-unit-local StringIds (var refs,
            // calls, struct names) that MUST be remapped against the merged
            // global interner in the multi-unit script/project pipeline.
            const mutable = try alloc.create(ast.DeferStmt);
            mutable.* = defer_node.*;
            const mutable_expr = try alloc.create(ast.Expr);
            mutable_expr.* = defer_node.expr.*;
            try remapExpr(alloc, mutable_expr, remap);
            mutable.expr = mutable_expr;
            stmt.* = .{ .defer_stmt = mutable };
        },
    }
}

fn remapImportDecl(alloc: std.mem.Allocator, id: *ast.ImportDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapStructName(alloc, &id.struct_path, remap);
    if (id.filter) |*filter| {
        switch (filter.*) {
            .only => |entries| {
                const mutable_entries = try alloc.alloc(ast.ImportEntry, entries.len);
                for (entries, 0..) |entry, i| {
                    mutable_entries[i] = switch (entry) {
                        .function => |f| .{ .function = .{ .name = remap[f.name], .arity = f.arity } },
                        .type_import => |t| .{ .type_import = remap[t] },
                    };
                }
                filter.* = .{ .only = mutable_entries };
            },
            .except => |entries| {
                const mutable_entries = try alloc.alloc(ast.ImportEntry, entries.len);
                for (entries, 0..) |entry, i| {
                    mutable_entries[i] = switch (entry) {
                        .function => |f| .{ .function = .{ .name = remap[f.name], .arity = f.arity } },
                        .type_import => |t| .{ .type_import = remap[t] },
                    };
                }
                filter.* = .{ .except = mutable_entries };
            },
        }
    }
}

fn remapExpr(alloc: std.mem.Allocator, expr: *ast.Expr, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (expr.*) {
        .string_literal => |*sl| sl.value = remap[sl.value],
        .atom_literal => |*al| al.value = remap[al.value],
        .var_ref => |*vr| vr.name = remap[vr.name],
        .struct_ref => |*mr| {
            try remapStructName(alloc, &mr.name, remap);
            // Parametric variant constructors (`Option(i64).Some`,
            // `Result(i64, String).Err`) attach type-args on the
            // struct_ref via `tryParseInstantiatedVariantConstructor`.
            // Each arg's interner IDs reference the source unit's
            // LOCAL interner — translate them to the global interner
            // alongside `mr.name`. Without this remap the type-args
            // resolve to wildly wrong strings in the global interner
            // (the round-1 `Option_Any` / `Option_i8` symptom: a local
            // ID for "i64" lands in the global slot for "i8" or "any").
            if (mr.type_args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.TypeExpr, mr.type_args.len);
                for (mr.type_args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = arg.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                mr.type_args = mutable_args;
            }
        },
        .field_access => |*fa| {
            const mutable_obj = try alloc.create(ast.Expr);
            mutable_obj.* = fa.object.*;
            try remapExpr(alloc, mutable_obj, remap);
            fa.object = mutable_obj;
            fa.field = remap[fa.field];
        },
        .intrinsic => |*intr| {
            intr.name = remap[intr.name];
            if (intr.args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.Expr, intr.args.len);
                for (intr.args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.Expr);
                    mutable.* = arg.*;
                    try remapExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                intr.args = mutable_args;
            }
        },
        .attr_ref => |*ar| ar.name = remap[ar.name],
        .for_expr => |*fe| {
            // Remap the loop variable's pattern through the standard
            // pattern-remap helper so any nested binds (`{k, v}`) and
            // tagged tuples (`{:ok, n}`) get their StringIds rewritten.
            const mutable_pattern = try alloc.create(ast.Pattern);
            mutable_pattern.* = fe.var_pattern.*;
            try remapPattern(alloc, mutable_pattern, remap);
            fe.var_pattern = mutable_pattern;
            // Remap the optional `:: Type` annotation if present.
            if (fe.var_type_annotation) |ta| {
                const mutable_ta = try alloc.create(ast.TypeExpr);
                mutable_ta.* = ta.*;
                try remapTypeExpr(alloc, mutable_ta, remap);
                fe.var_type_annotation = mutable_ta;
            }
            const mutable_iter = try alloc.create(ast.Expr);
            mutable_iter.* = fe.iterable.*;
            try remapExpr(alloc, mutable_iter, remap);
            fe.iterable = mutable_iter;
            if (fe.filter) |f| {
                const mutable_filter = try alloc.create(ast.Expr);
                mutable_filter.* = f.*;
                try remapExpr(alloc, mutable_filter, remap);
                fe.filter = mutable_filter;
            }
            const mutable_body = try alloc.create(ast.Expr);
            mutable_body.* = fe.body.*;
            try remapExpr(alloc, mutable_body, remap);
            fe.body = mutable_body;
        },
        .string_interpolation => |*si| {
            if (si.parts.len > 0) {
                const mutable_parts = try alloc.alloc(ast.StringPart, si.parts.len);
                for (si.parts, 0..) |part, i| {
                    mutable_parts[i] = switch (part) {
                        .literal => |lit| .{ .literal = remap[lit] },
                        .expr => |e| blk: {
                            const mutable = try alloc.create(ast.Expr);
                            mutable.* = e.*;
                            try remapExpr(alloc, mutable, remap);
                            break :blk .{ .expr = mutable };
                        },
                    };
                }
                si.parts = mutable_parts;
            }
        },
        .struct_expr => |*se| {
            try remapStructName(alloc, &se.struct_name, remap);
            // Explicit type arguments at the literal (e.g. `i64` in
            // `%Box(i64){...}`) carry TypeExpr nodes whose interner
            // StringIds come from the unit's LOCAL interner. Without
            // remapping them alongside the rest of the expression, the
            // type-checker's `resolveTypeExpr` looks them up against
            // the global interner and either returns UNKNOWN (silent
            // failure: the substitution map binds the formal type-var
            // to UNKNOWN, then `field expects {type_var}` fires) or
            // resolves to an unrelated symbol that happens to share the
            // stale local id. Both are the script-mode parametric
            // struct gap surfaced by `pub struct Box(T) { value :: T }`
            // + `%Box(i64){value: 42}`. Mirror the `struct_ref.type_args`
            // remap at lines ~10616 above so the same gap closes on the
            // struct-literal surface too.
            if (se.type_args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.TypeExpr, se.type_args.len);
                for (se.type_args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = arg.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                se.type_args = mutable_args;
            }
            if (se.update_source) |us| {
                const mutable = try alloc.create(ast.Expr);
                mutable.* = us.*;
                try remapExpr(alloc, mutable, remap);
                se.update_source = mutable;
            }
            if (se.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.StructField, se.fields.len);
                for (se.fields, 0..) |f, i| {
                    mutable_fields[i] = f;
                    mutable_fields[i].name = remap[f.name];
                    const mutable_val = try alloc.create(ast.Expr);
                    mutable_val.* = f.value.*;
                    try remapExpr(alloc, mutable_val, remap);
                    mutable_fields[i].value = mutable_val;
                }
                se.fields = mutable_fields;
            }
        },
        .function_ref => |*fr| {
            if (fr.struct_name) |*m| try remapStructName(alloc, m, remap);
            fr.function = remap[fr.function];
        },
        .binary_op => |*bo| {
            const mutable_lhs = try alloc.create(ast.Expr);
            mutable_lhs.* = bo.lhs.*;
            try remapExpr(alloc, mutable_lhs, remap);
            bo.lhs = mutable_lhs;
            const mutable_rhs = try alloc.create(ast.Expr);
            mutable_rhs.* = bo.rhs.*;
            try remapExpr(alloc, mutable_rhs, remap);
            bo.rhs = mutable_rhs;
        },
        .unary_op => |*uo| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = uo.operand.*;
            try remapExpr(alloc, mutable, remap);
            uo.operand = mutable;
        },
        .call => |*ce| {
            const mutable_callee = try alloc.create(ast.Expr);
            mutable_callee.* = ce.callee.*;
            try remapExpr(alloc, mutable_callee, remap);
            ce.callee = mutable_callee;
            if (ce.args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.Expr, ce.args.len);
                for (ce.args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.Expr);
                    mutable.* = arg.*;
                    try remapExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                ce.args = mutable_args;
            }
        },
        .pipe => |*pe| {
            const mutable_lhs = try alloc.create(ast.Expr);
            mutable_lhs.* = pe.lhs.*;
            try remapExpr(alloc, mutable_lhs, remap);
            pe.lhs = mutable_lhs;
            const mutable_rhs = try alloc.create(ast.Expr);
            mutable_rhs.* = pe.rhs.*;
            try remapExpr(alloc, mutable_rhs, remap);
            pe.rhs = mutable_rhs;
        },
        .unwrap => |*uw| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = uw.expr.*;
            try remapExpr(alloc, mutable, remap);
            uw.expr = mutable;
        },
        .try_expr => |*te| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = te.value.*;
            try remapExpr(alloc, mutable, remap);
            te.value = mutable;
        },
        .try_rescue => |*tr| {
            // Remap the body, every rescue clause (pattern + type_annotation +
            // guard + body — `remapCaseClause` handles the StringId-bearing
            // fields, the canonical multi-unit interner gotcha), and the
            // optional `after` block.
            try remapStmtSlice(alloc, &tr.body, remap);
            if (tr.rescue_clauses.len > 0) {
                const mutable_clauses = try alloc.alloc(ast.CaseClause, tr.rescue_clauses.len);
                for (tr.rescue_clauses, 0..) |c, i| {
                    mutable_clauses[i] = c;
                    try remapCaseClause(alloc, &mutable_clauses[i], remap);
                }
                tr.rescue_clauses = mutable_clauses;
            }
            if (tr.after_block) |*cleanup| {
                try remapStmtSlice(alloc, cleanup, remap);
            }
        },
        .with_expr => |*we| {
            // Remap every step (pattern + optional `:: Type` + expr), the
            // do-body, and the optional else clauses. `with` is desugared
            // to nested `case` during macro expansion, but multi-unit
            // StringId-remap (`remapProgram`) runs on the parsed AST before
            // expansion, so the `with_expr` must rewrite its StringIds here
            // — the same canonical multi-unit interner gotcha `try_rescue`
            // and `for_expr` handle above.
            if (we.steps.len > 0) {
                const mutable_steps = try alloc.alloc(ast.WithStep, we.steps.len);
                for (we.steps, 0..) |step, i| {
                    mutable_steps[i] = step;
                    const mutable_pattern = try alloc.create(ast.Pattern);
                    mutable_pattern.* = step.pattern.*;
                    try remapPattern(alloc, mutable_pattern, remap);
                    mutable_steps[i].pattern = mutable_pattern;
                    if (step.type_annotation) |ta| {
                        const mutable_ta = try alloc.create(ast.TypeExpr);
                        mutable_ta.* = ta.*;
                        try remapTypeExpr(alloc, mutable_ta, remap);
                        mutable_steps[i].type_annotation = mutable_ta;
                    }
                    const mutable_step_expr = try alloc.create(ast.Expr);
                    mutable_step_expr.* = step.expr.*;
                    try remapExpr(alloc, mutable_step_expr, remap);
                    mutable_steps[i].expr = mutable_step_expr;
                }
                we.steps = mutable_steps;
            }
            try remapStmtSlice(alloc, &we.do_body, remap);
            if (we.else_clauses) |clauses| {
                if (clauses.len > 0) {
                    const mutable_clauses = try alloc.alloc(ast.CaseClause, clauses.len);
                    for (clauses, 0..) |c, i| {
                        mutable_clauses[i] = c;
                        try remapCaseClause(alloc, &mutable_clauses[i], remap);
                    }
                    we.else_clauses = mutable_clauses;
                }
            }
        },
        .if_expr => |*ie| {
            const mutable_cond = try alloc.create(ast.Expr);
            mutable_cond.* = ie.condition.*;
            try remapExpr(alloc, mutable_cond, remap);
            ie.condition = mutable_cond;
            try remapStmtSlice(alloc, &ie.then_block, remap);
            if (ie.else_block) |*eb| {
                try remapStmtSlice(alloc, eb, remap);
            }
        },
        .case_expr => |*ce| {
            const mutable_scrutinee = try alloc.create(ast.Expr);
            mutable_scrutinee.* = ce.scrutinee.*;
            try remapExpr(alloc, mutable_scrutinee, remap);
            ce.scrutinee = mutable_scrutinee;
            if (ce.clauses.len > 0) {
                const mutable_clauses = try alloc.alloc(ast.CaseClause, ce.clauses.len);
                for (ce.clauses, 0..) |c, i| {
                    mutable_clauses[i] = c;
                    try remapCaseClause(alloc, &mutable_clauses[i], remap);
                }
                ce.clauses = mutable_clauses;
            }
        },
        .cond_expr => |*ce| {
            if (ce.clauses.len > 0) {
                const mutable_clauses = try alloc.alloc(ast.CondClause, ce.clauses.len);
                for (ce.clauses, 0..) |c, i| {
                    mutable_clauses[i] = c;
                    const mutable_cond = try alloc.create(ast.Expr);
                    mutable_cond.* = c.condition.*;
                    try remapExpr(alloc, mutable_cond, remap);
                    mutable_clauses[i].condition = mutable_cond;
                    try remapStmtSlice(alloc, &mutable_clauses[i].body, remap);
                }
                ce.clauses = mutable_clauses;
            }
        },
        .tuple => |*te| {
            if (te.elements.len > 0) {
                const mutable_elems = try alloc.alloc(*const ast.Expr, te.elements.len);
                for (te.elements, 0..) |elem, i| {
                    const mutable = try alloc.create(ast.Expr);
                    mutable.* = elem.*;
                    try remapExpr(alloc, mutable, remap);
                    mutable_elems[i] = mutable;
                }
                te.elements = mutable_elems;
            }
        },
        .list => |*le| {
            if (le.elements.len > 0) {
                const mutable_elems = try alloc.alloc(*const ast.Expr, le.elements.len);
                for (le.elements, 0..) |elem, i| {
                    const mutable = try alloc.create(ast.Expr);
                    mutable.* = elem.*;
                    try remapExpr(alloc, mutable, remap);
                    mutable_elems[i] = mutable;
                }
                le.elements = mutable_elems;
            }
        },
        .map => |*me| {
            if (me.update_source) |us| {
                const mutable = try alloc.create(ast.Expr);
                mutable.* = us.*;
                try remapExpr(alloc, mutable, remap);
                me.update_source = mutable;
            }
            if (me.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.MapField, me.fields.len);
                for (me.fields, 0..) |f, i| {
                    const mutable_key = try alloc.create(ast.Expr);
                    mutable_key.* = f.key.*;
                    try remapExpr(alloc, mutable_key, remap);
                    const mutable_val = try alloc.create(ast.Expr);
                    mutable_val.* = f.value.*;
                    try remapExpr(alloc, mutable_val, remap);
                    mutable_fields[i] = .{ .key = mutable_key, .value = mutable_val };
                }
                me.fields = mutable_fields;
            }
        },
        .range => |*re| {
            const mutable_start = try alloc.create(ast.Expr);
            mutable_start.* = re.start.*;
            try remapExpr(alloc, mutable_start, remap);
            re.start = mutable_start;
            const mutable_end = try alloc.create(ast.Expr);
            mutable_end.* = re.end.*;
            try remapExpr(alloc, mutable_end, remap);
            re.end = mutable_end;
            if (re.step) |s| {
                const mutable_step = try alloc.create(ast.Expr);
                mutable_step.* = s.*;
                try remapExpr(alloc, mutable_step, remap);
                re.step = mutable_step;
            }
        },
        .list_cons_expr => |*lce| {
            const mutable_head = try alloc.create(ast.Expr);
            mutable_head.* = lce.head.*;
            try remapExpr(alloc, mutable_head, remap);
            lce.head = mutable_head;
            const mutable_tail = try alloc.create(ast.Expr);
            mutable_tail.* = lce.tail.*;
            try remapExpr(alloc, mutable_tail, remap);
            lce.tail = mutable_tail;
        },
        .quote_expr => |*qe| {
            try remapStmtSlice(alloc, &qe.body, remap);
        },
        .unquote_expr => |*ue| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = ue.expr.*;
            try remapExpr(alloc, mutable, remap);
            ue.expr = mutable;
        },
        .unquote_splicing_expr => |*use_| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = use_.expr.*;
            try remapExpr(alloc, mutable, remap);
            use_.expr = mutable;
        },
        .panic_expr => |*pe| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = pe.message.*;
            try remapExpr(alloc, mutable, remap);
            pe.message = mutable;
        },
        // Phase 1.4: the `raise_expr` value subtree carries StringIds (the
        // wrapped `%RuntimeError{message: ...}` struct name and field names,
        // or a `%CustomError{...}` literal), so it MUST be remapped across
        // the per-unit local interner → merged global interner boundary,
        // exactly like every other StringId-bearing AST field.
        .raise_expr => |*re| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = re.value.*;
            try remapExpr(alloc, mutable, remap);
            re.value = mutable;
        },
        .error_pipe => |*ep| {
            const mutable_chain = try alloc.create(ast.Expr);
            mutable_chain.* = ep.chain.*;
            try remapExpr(alloc, mutable_chain, remap);
            ep.chain = mutable_chain;
            switch (ep.handler) {
                .block => |clauses| {
                    if (clauses.len > 0) {
                        const mutable_clauses = try alloc.alloc(ast.CaseClause, clauses.len);
                        for (clauses, 0..) |c, i| {
                            mutable_clauses[i] = c;
                            try remapCaseClause(alloc, &mutable_clauses[i], remap);
                        }
                        ep.handler = .{ .block = mutable_clauses };
                    }
                },
                .function => |f| {
                    const mutable = try alloc.create(ast.Expr);
                    mutable.* = f.*;
                    try remapExpr(alloc, mutable, remap);
                    ep.handler = .{ .function = mutable };
                },
            }
        },
        .block => |*be| {
            try remapStmtSlice(alloc, &be.stmts, remap);
        },
        .binary_literal => |*bl| {
            try remapBinarySegments(alloc, bl, remap);
        },
        .anonymous_function => |*af| {
            const mutable_decl = try alloc.create(ast.FunctionDecl);
            mutable_decl.* = af.decl.*;
            try remapFunctionDecl(alloc, mutable_decl, remap);
            af.decl = mutable_decl;
        },
        .type_annotated => |*ta| {
            const mutable_expr = try alloc.create(ast.Expr);
            mutable_expr.* = ta.expr.*;
            try remapExpr(alloc, mutable_expr, remap);
            ta.expr = mutable_expr;
            const mutable_te = try alloc.create(ast.TypeExpr);
            mutable_te.* = ta.type_expr.*;
            try remapTypeExpr(alloc, mutable_te, remap);
            ta.type_expr = mutable_te;
        },
        // These have no StringId fields — only meta and numeric/bool values.
        // `poison` (Phase 4.b parse-error sentinel) likewise carries only its
        // span, so the StringId remap is a no-op for it.
        .int_literal, .float_literal, .bool_literal, .nil_literal, .poison => {},
    }
}

fn remapStmtSlice(alloc: std.mem.Allocator, stmts: *[]const ast.Stmt, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (stmts.len > 0) {
        const mutable = try alloc.alloc(ast.Stmt, stmts.len);
        @memcpy(mutable, stmts.*);
        for (mutable) |*stmt| {
            try remapStmt(alloc, stmt, remap);
        }
        stmts.* = mutable;
    }
}

fn remapCaseClause(alloc: std.mem.Allocator, clause: *ast.CaseClause, remap: []const ast.StringId) error{OutOfMemory}!void {
    const mutable_pat = try alloc.create(ast.Pattern);
    mutable_pat.* = clause.pattern.*;
    try remapPattern(alloc, mutable_pat, remap);
    clause.pattern = mutable_pat;
    if (clause.type_annotation) |ta| {
        const mutable_ta = try alloc.create(ast.TypeExpr);
        mutable_ta.* = ta.*;
        try remapTypeExpr(alloc, mutable_ta, remap);
        clause.type_annotation = mutable_ta;
    }
    if (clause.guard) |g| {
        const mutable_g = try alloc.create(ast.Expr);
        mutable_g.* = g.*;
        try remapExpr(alloc, mutable_g, remap);
        clause.guard = mutable_g;
    }
    try remapStmtSlice(alloc, &clause.body, remap);
}

fn remapBinarySegments(alloc: std.mem.Allocator, bl: *ast.BinaryLiteral, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (bl.segments.len > 0) {
        const mutable_segs = try alloc.alloc(ast.BinarySegment, bl.segments.len);
        for (bl.segments, 0..) |seg, i| {
            mutable_segs[i] = seg;
            try remapBinarySegment(alloc, &mutable_segs[i], remap);
        }
        bl.segments = mutable_segs;
    }
}

fn remapBinarySegment(alloc: std.mem.Allocator, seg: *ast.BinarySegment, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (seg.value) {
        .expr => |e| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = e.*;
            try remapExpr(alloc, mutable, remap);
            seg.value = .{ .expr = mutable };
        },
        .pattern => |p| {
            const mutable = try alloc.create(ast.Pattern);
            mutable.* = p.*;
            try remapPattern(alloc, mutable, remap);
            seg.value = .{ .pattern = mutable };
        },
        .string_literal => |sl| seg.value = .{ .string_literal = remap[sl] },
    }
    if (seg.size) |*size| {
        switch (size.*) {
            .variable => |v| size.* = .{ .variable = remap[v] },
            .literal => {},
        }
    }
}

fn remapPattern(alloc: std.mem.Allocator, pattern: *ast.Pattern, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (pattern.*) {
        .bind => |*bp| bp.name = remap[bp.name],
        .pin => |*pp| pp.name = remap[pp.name],
        .literal => |*lp| {
            switch (lp.*) {
                .string => |*s| s.value = remap[s.value],
                .atom => |*a| a.value = remap[a.value],
                .int, .float, .bool_lit, .nil => {},
            }
        },
        .tuple => |*tp| {
            if (tp.elements.len > 0) {
                const mutable_elems = try alloc.alloc(*const ast.Pattern, tp.elements.len);
                for (tp.elements, 0..) |elem, i| {
                    const mutable = try alloc.create(ast.Pattern);
                    mutable.* = elem.*;
                    try remapPattern(alloc, mutable, remap);
                    mutable_elems[i] = mutable;
                }
                tp.elements = mutable_elems;
            }
        },
        .list => |*lp| {
            if (lp.elements.len > 0) {
                const mutable_elems = try alloc.alloc(*const ast.Pattern, lp.elements.len);
                for (lp.elements, 0..) |elem, i| {
                    const mutable = try alloc.create(ast.Pattern);
                    mutable.* = elem.*;
                    try remapPattern(alloc, mutable, remap);
                    mutable_elems[i] = mutable;
                }
                lp.elements = mutable_elems;
            }
        },
        .list_cons => |*lcp| {
            if (lcp.heads.len > 0) {
                const mutable_heads = try alloc.alloc(*const ast.Pattern, lcp.heads.len);
                for (lcp.heads, 0..) |h, i| {
                    const mutable = try alloc.create(ast.Pattern);
                    mutable.* = h.*;
                    try remapPattern(alloc, mutable, remap);
                    mutable_heads[i] = mutable;
                }
                lcp.heads = mutable_heads;
            }
            const mutable_tail = try alloc.create(ast.Pattern);
            mutable_tail.* = lcp.tail.*;
            try remapPattern(alloc, mutable_tail, remap);
            lcp.tail = mutable_tail;
        },
        .map => |*mp| {
            if (mp.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.MapPatternField, mp.fields.len);
                for (mp.fields, 0..) |f, i| {
                    const mutable_key = try alloc.create(ast.Expr);
                    mutable_key.* = f.key.*;
                    try remapExpr(alloc, mutable_key, remap);
                    const mutable_val = try alloc.create(ast.Pattern);
                    mutable_val.* = f.value.*;
                    try remapPattern(alloc, mutable_val, remap);
                    mutable_fields[i] = .{ .key = mutable_key, .value = mutable_val };
                }
                mp.fields = mutable_fields;
            }
        },
        .struct_pattern => |*sp| {
            try remapStructName(alloc, &sp.struct_name, remap);
            if (sp.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.StructPatternField, sp.fields.len);
                for (sp.fields, 0..) |f, i| {
                    mutable_fields[i] = f;
                    mutable_fields[i].name = remap[f.name];
                    const mutable_pat = try alloc.create(ast.Pattern);
                    mutable_pat.* = f.pattern.*;
                    try remapPattern(alloc, mutable_pat, remap);
                    mutable_fields[i].pattern = mutable_pat;
                }
                sp.fields = mutable_fields;
            }
        },
        .paren => |*pp| {
            const mutable = try alloc.create(ast.Pattern);
            mutable.* = pp.inner.*;
            try remapPattern(alloc, mutable, remap);
            pp.inner = mutable;
        },
        .binary => |*bp| {
            if (bp.segments.len > 0) {
                const mutable_segs = try alloc.alloc(ast.BinarySegment, bp.segments.len);
                for (bp.segments, 0..) |seg, i| {
                    mutable_segs[i] = seg;
                    try remapBinarySegment(alloc, &mutable_segs[i], remap);
                }
                bp.segments = mutable_segs;
            }
        },
        .tagged_union_variant => |*tuv| {
            // Variant qualifiers carry interned segment names that must
            // be remapped exactly like a struct_pattern's struct_name —
            // otherwise an `Option.Some` reference in a quote-expanded
            // pattern would resolve through the local interner ID in
            // the merged program, silently aliasing to an unrelated
            // string. Type-args carry their own interned identifiers;
            // remap each TypeExpr in place. Payload patterns recurse.
            try remapStructName(alloc, &tuv.qualifier, remap);
            if (tuv.type_args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.TypeExpr, tuv.type_args.len);
                for (tuv.type_args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = arg.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                tuv.type_args = mutable_args;
            }
            if (tuv.payload) |payload| {
                const mutable_payload = try alloc.create(ast.Pattern);
                mutable_payload.* = payload.*;
                try remapPattern(alloc, mutable_payload, remap);
                tuv.payload = mutable_payload;
            }
        },
        .wildcard => {},
    }
}

fn remapTypeExpr(alloc: std.mem.Allocator, te: *ast.TypeExpr, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (te.*) {
        .name => |*tne| {
            tne.name = remap[tne.name];
            if (tne.args.len > 0) {
                const mutable_args = try alloc.alloc(*const ast.TypeExpr, tne.args.len);
                for (tne.args, 0..) |arg, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = arg.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_args[i] = mutable;
                }
                tne.args = mutable_args;
            }
        },
        .variable => |*tve| tve.name = remap[tve.name],
        .tuple => |*tte| {
            if (tte.elements.len > 0) {
                const mutable_elems = try alloc.alloc(*const ast.TypeExpr, tte.elements.len);
                for (tte.elements, 0..) |elem, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = elem.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_elems[i] = mutable;
                }
                tte.elements = mutable_elems;
            }
        },
        .list => |*tle| {
            const mutable = try alloc.create(ast.TypeExpr);
            mutable.* = tle.element.*;
            try remapTypeExpr(alloc, mutable, remap);
            tle.element = mutable;
        },
        .map => |*tme| {
            if (tme.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.TypeMapField, tme.fields.len);
                for (tme.fields, 0..) |f, i| {
                    const mutable_key = try alloc.create(ast.TypeExpr);
                    mutable_key.* = f.key.*;
                    try remapTypeExpr(alloc, mutable_key, remap);
                    const mutable_val = try alloc.create(ast.TypeExpr);
                    mutable_val.* = f.value.*;
                    try remapTypeExpr(alloc, mutable_val, remap);
                    mutable_fields[i] = .{ .key = mutable_key, .value = mutable_val };
                }
                tme.fields = mutable_fields;
            }
        },
        .struct_type => |*tse| {
            try remapStructName(alloc, &tse.struct_name, remap);
            if (tse.fields.len > 0) {
                const mutable_fields = try alloc.alloc(ast.TypeStructField, tse.fields.len);
                for (tse.fields, 0..) |f, i| {
                    mutable_fields[i] = f;
                    mutable_fields[i].name = remap[f.name];
                    const mutable_te = try alloc.create(ast.TypeExpr);
                    mutable_te.* = f.type_expr.*;
                    try remapTypeExpr(alloc, mutable_te, remap);
                    mutable_fields[i].type_expr = mutable_te;
                }
                tse.fields = mutable_fields;
            }
        },
        .union_type => |*tue| {
            if (tue.members.len > 0) {
                const mutable_members = try alloc.alloc(*const ast.TypeExpr, tue.members.len);
                for (tue.members, 0..) |m, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = m.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_members[i] = mutable;
                }
                tue.members = mutable_members;
            }
        },
        .function => |*tfe| {
            if (tfe.params.len > 0) {
                const mutable_params = try alloc.alloc(*const ast.TypeExpr, tfe.params.len);
                for (tfe.params, 0..) |p, i| {
                    const mutable = try alloc.create(ast.TypeExpr);
                    mutable.* = p.*;
                    try remapTypeExpr(alloc, mutable, remap);
                    mutable_params[i] = mutable;
                }
                tfe.params = mutable_params;
            }
            const mutable_ret = try alloc.create(ast.TypeExpr);
            mutable_ret.* = tfe.return_type.*;
            try remapTypeExpr(alloc, mutable_ret, remap);
            tfe.return_type = mutable_ret;
        },
        .literal => |*tle| {
            switch (tle.value) {
                .string => |s| tle.value = .{ .string = remap[s] },
                .int, .bool_val, .nil => {},
            }
        },
        .paren => |*tpe| {
            const mutable = try alloc.create(ast.TypeExpr);
            mutable.* = tpe.inner.*;
            try remapTypeExpr(alloc, mutable, remap);
            tpe.inner = mutable;
        },
        .never => {},
    }
}

// ============================================================
// Tests
// ============================================================

test "validateOneStructPerFile: valid single struct" {
    const alloc = std.testing.allocator;
    const source = "pub struct Config {\n  pub fn load() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "config.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneStructPerFile: valid nested struct name" {
    const alloc = std.testing.allocator;
    const source = "pub struct Config.Parser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "config/parser.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneStructPerFile: valid source-root relative test struct names" {
    const alloc = std.testing.allocator;

    const root_source = "pub struct PatternMatchingTest {\n  pub fn run() -> String {\n    \"ok\"\n  }\n}\n";
    const root_result = validateOneStructPerFile(alloc, root_source, "pattern_matching_test.zap");
    try std.testing.expectEqual(null, root_result);

    const nested_source = "pub struct Zap.ListTest {\n  pub fn run() -> String {\n    \"ok\"\n  }\n}\n";
    const nested_result = validateOneStructPerFile(alloc, nested_source, "zap/list_test.zap");
    try std.testing.expectEqual(null, nested_result);
}

test "validateOneStructPerFile: valid private struct" {
    const alloc = std.testing.allocator;
    const source = "struct Config.Helpers {\n  pub fn help() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "config/helpers.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneStructPerFile: field-only struct is a valid struct" {
    const alloc = std.testing.allocator;
    const source = "pub struct Point {\n  x :: i64\n}\n";
    const result = validateOneStructPerFile(alloc, source, "point.zap");
    // Field-only data structs are valid struct declarations.
    try std.testing.expect(result == null);
}

test "validateOneStructPerFile: multiple structs is error" {
    const alloc = std.testing.allocator;
    const source = "pub struct Foo {\n  pub fn foo() -> i64 {\n    1\n  }\n}\npub struct Bar {\n  pub fn bar() -> i64 {\n    2\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "foo.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "found 2") != null);
    alloc.free(result.?);
}

test "validateOneStructPerFile: name mismatch is error" {
    const alloc = std.testing.allocator;
    const source = "pub struct WrongName {\n  pub fn foo() -> i64 {\n    1\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "config.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "does not match") != null);
    alloc.free(result.?);
}

test "validateOneStructPerFile: data structs alongside primary struct" {
    const alloc = std.testing.allocator;
    const source =
        "pub struct Point {\n  x :: i64\n  y :: i64\n}\n" ++
        "pub struct Config {\n  name :: String\n}\n" ++
        "pub struct StructTest {\n  pub fn run() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "struct_test.zap");
    // The single method-bearing struct names the file; field-only
    // data structs ride along as supporting declarations.
    try std.testing.expect(result == null);
}

test "validateOneStructPerFile: multiple data structs without primary is error" {
    const alloc = std.testing.allocator;
    const source =
        "pub struct Point {\n  x :: i64\n}\n" ++
        "pub struct Config {\n  name :: String\n}\n";
    const result = validateOneStructPerFile(alloc, source, "data.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "found 2") != null);
    alloc.free(result.?);
}

test "validateOneStructPerFile: snake_case path to PascalCase" {
    const alloc = std.testing.allocator;
    const source = "pub struct JsonParser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "json_parser.zap");
    try std.testing.expectEqual(null, result);
}

test "buildStructPrograms stores per-struct AST programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub struct Foo {\n" ++
        "}\n" ++
        "pub struct Bar.Baz {\n" ++
        "}\n" ++
        "";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    const struct_programs = try buildStructPrograms(alloc, &program, parser.interner);
    try std.testing.expectEqual(@as(usize, 2), struct_programs.len);
    try std.testing.expectEqualStrings("Foo", struct_programs[0].name);
    try std.testing.expectEqual(@as(usize, 1), struct_programs[0].program.structs.len);
    try std.testing.expectEqualStrings("Bar.Baz", struct_programs[1].name);
    try std.testing.expectEqual(@as(usize, 1), struct_programs[1].program.structs.len);
}

test "buildCompilationUnits derives units from struct programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub struct Foo {\n" ++
        "}\n" ++
        "pub struct Bar.Baz {\n" ++
        "}\n";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();
    const struct_programs = try buildStructPrograms(alloc, &program, parser.interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "fixture.zap", .source = "pub struct Foo {\n}\n" },
        .{ .file_path = "fixture.zap", .source = "pub struct Bar.Baz {\n}\n" },
    };
    const units = try buildCompilationUnits(alloc, struct_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].struct_name);
    try std.testing.expectEqualStrings("fixture.zap", units[0].file_path);
    try std.testing.expectEqual(@as(u32, 0), units[0].struct_index.?);
    try std.testing.expectEqualStrings("Bar.Baz", units[1].struct_name);
    try std.testing.expectEqual(@as(u32, 1), units[1].struct_index.?);
}

test "buildCompilationUnits uses source ids when globbed files have no struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    const impl_source =
        "impl Display for Foo {\n" ++
        "  pub fn show(_value :: Foo) -> String {\n" ++
        "    \"foo\"\n" ++
        "  }\n" ++
        "}\n";
    const foo_source =
        "pub struct Foo {\n" ++
        "  pub fn value() -> i64 {\n" ++
        "    1\n" ++
        "  }\n" ++
        "}\n";

    var impl_parser = zap.Parser.initWithSharedInterner(alloc, impl_source, &interner, 0);
    defer impl_parser.deinit();
    var foo_parser = zap.Parser.initWithSharedInterner(alloc, foo_source, &interner, 1);
    defer foo_parser.deinit();

    const programs = [_]ast.Program{
        try impl_parser.parseProgram(),
        try foo_parser.parseProgram(),
    };
    const merged = try mergePrograms(alloc, &programs);
    const struct_programs = try buildStructPrograms(alloc, &merged, &interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "display_impl.zap", .source = impl_source },
        .{ .file_path = "foo.zap", .source = foo_source, .primary_struct_name = "Foo" },
    };

    const units = try buildCompilationUnits(alloc, struct_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].struct_name);
    try std.testing.expectEqualStrings("foo.zap", units[0].file_path);
}

test "per-unit parser assigns source_id and file-local spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    var parser = zap.Parser.initWithSharedInterner(
        alloc,
        "pub struct Bar {\n  bad(\n}\n",
        &interner,
        7,
    );
    defer parser.deinit();

    _ = parser.parseProgram() catch {};
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqual(@as(?u32, 7), parser.errors.items[0].span.source_id);
}

test "collector can build graph from per-struct programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub struct Foo {\n" ++
        "  pub fn run() -> i64 {\n" ++
        "    1\n" ++
        "  }\n" ++
        "}\n" ++
        "pub struct Bar {\n" ++
        "  pub fn call() -> i64 {\n" ++
        "    Foo.run()\n" ++
        "  }\n" ++
        "}\n";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();
    const struct_programs = try buildStructPrograms(alloc, &program, parser.interner);
    const program_slices = try alloc.alloc(ast.Program, struct_programs.len);
    for (struct_programs, 0..) |entry, i| program_slices[i] = entry.program;

    var collector = zap.Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    for (struct_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    try std.testing.expectEqual(@as(usize, 2), collector.graph.structs.items.len);
}

test "compileStructByStruct isolates per-struct diagnostics" {
    // Regression: errors from one struct would re-fire downstream because
    // `failWithExisting` rendered the entire diagnostic engine on every
    // per-struct failure, and `hasErrors()` checks tripped on prior
    // structs' residual errors. The downstream symptom is that any struct
    // following a failed one would itself fail — even when its own source
    // was perfectly clean — and the same error block would print over and
    // over with each subsequent struct's progress label.
    //
    // Fix verification: with one broken struct followed by two clean ones,
    // the clean structs must still produce IR functions.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "broken.zap",
            .source = "pub struct Broken {\n" ++
                "  pub fn go() -> i64 {\n" ++
                "    nonexistent_function(1)\n" ++
                "  }\n" ++
                "}\n",
        },
        .{
            .file_path = "clean_a.zap",
            .source = "pub struct CleanA {\n" ++
                "  pub fn ok() -> i64 { 1 }\n" ++
                "}\n",
        },
        .{
            .file_path = "clean_b.zap",
            .source = "pub struct CleanB {\n" ++
                "  pub fn ok() -> i64 { 2 }\n" ++
                "}\n",
        },
    };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ctx.struct_programs) |mp| {
        names.append(alloc, mp.name) catch {};
    }

    const result = compileStructByStruct(
        alloc,
        &ctx,
        names.items,
        .{ .show_progress = false },
    ) catch |err| {
        std.debug.print("compileStructByStruct failed unexpectedly: {}\n", .{err});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(ctx.diag_engine.errorCount() >= 1);

    var found_clean_a = false;
    var found_clean_b = false;
    for (result.ir_program.functions) |func| {
        if (func.struct_name) |mod_name| {
            if (std.mem.eql(u8, mod_name, "CleanA")) found_clean_a = true;
            if (std.mem.eql(u8, mod_name, "CleanB")) found_clean_b = true;
        }
    }
    try std.testing.expect(found_clean_a);
    try std.testing.expect(found_clean_b);
}

test "compileStructByStruct dedupes a struct that appears twice in struct_order" {
    // Regression for the duplicate-name IR-function bug. If discovery
    // ever regresses and produces a `struct_order` that lists the
    // same struct name twice, the per-struct HIR loop must NOT lower
    // the struct twice. A second lowering produces a second
    // `ir.Function` record with the same name but a different
    // `FunctionId`, which silently breaks every downstream pass that
    // maps function names to ids — most importantly the uniqueness fixpoint
    // signature table and the ARC-convention `lift_set`. Both keys
    // are `FunctionId`s, so callers reaching the duplicate via name
    // resolution land on a different id than the audit walker does,
    // and the lookups silently miss.
    //
    // The fix has two layers: (a) discovery canonicalizes file paths
    // so duplicates cannot enter `struct_order` in the first place,
    // and (b) `compileStructByStruct` defensively skips a struct it
    // has already lowered. This test exercises layer (b) by passing
    // a deliberately-duplicated `struct_order`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "dup_target.zap",
            .source = "pub struct DupTarget {\n" ++
                "  pub fn answer() -> i64 { 42 }\n" ++
                "}\n",
        },
    };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    // Pass the struct twice on purpose. Without the dedup, the
    // pipeline would lower DupTarget.answer twice, producing two
    // `ir.Function` records with the same `name` but different
    // `FunctionId`s — the duplicate-IR hazard.
    const duplicated_order = [_][]const u8{ "DupTarget", "DupTarget" };

    const result = try compileStructByStruct(
        alloc,
        &ctx,
        &duplicated_order,
        .{ .show_progress = false },
    );

    var seen_function_names: std.StringHashMapUnmanaged(usize) = .empty;
    for (result.ir_program.functions) |func| {
        const gop = try seen_function_names.getOrPut(alloc, func.name);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    var dup_iter = seen_function_names.iterator();
    while (dup_iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            std.debug.print(
                "duplicate IR function name detected: '{s}' x{d}\n",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            return error.DuplicateIrFunctionName;
        }
    }
}

test "remapFunctionDecl rewrites name_expr through the remap table" {
    // Regression: name_expr (used for `pub fn unquote(name)(...)`) holds
    // a var_ref to a local-interner StringId. Before the fix, the
    // remapping skipped name_expr entirely, so the inner var_ref kept
    // its local id and resolved to whatever string sat at that index in
    // the global interner — typically an unrelated identifier. The
    // user-visible symptom in the Zest test framework was generated
    // `pub fn unquote(fn_name)()` declarations losing the name `fn_name`
    // and decoding to whatever happened to share the local id.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const meta: ast.NodeMeta = .{ .span = .{ .start = 0, .end = 0 } };

    // Construct a remap table that swaps two ids so we can detect
    // whether name_expr's inner var_ref gets traversed: id 0 in the
    // local interner maps to id 5 in the global, and id 5 maps to 0.
    // Any path that bypasses the remap surfaces id 5 unchanged.
    const remap = try alloc.alloc(ast.StringId, 6);
    remap[0] = 5;
    remap[1] = 1;
    remap[2] = 2;
    remap[3] = 3;
    remap[4] = 4;
    remap[5] = 0;

    // Build `pub fn unquote(<id 5>)() -> void`. The 5 simulates the
    // local id of `fn_name`; after remap it should become 0.
    const inner_var_ref = try alloc.create(ast.Expr);
    inner_var_ref.* = .{ .var_ref = .{ .meta = meta, .name = 5 } };
    const unquote = try alloc.create(ast.Expr);
    unquote.* = .{ .unquote_expr = .{ .meta = meta, .expr = inner_var_ref } };

    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = meta,
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = null,
    };
    var fd: ast.FunctionDecl = .{
        .meta = meta,
        .name = 1, // placeholder — irrelevant for this test
        .name_expr = unquote,
        .clauses = clauses,
        .visibility = .public,
    };

    try remapFunctionDecl(alloc, &fd, remap);

    try std.testing.expect(fd.name_expr != null);
    try std.testing.expect(fd.name_expr.?.* == .unquote_expr);
    const remapped_inner = fd.name_expr.?.unquote_expr.expr;
    try std.testing.expect(remapped_inner.* == .var_ref);
    try std.testing.expectEqual(@as(ast.StringId, 0), remapped_inner.var_ref.name);
}

test "SourceGraph structs exposes structs collected from source units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "lib/app.zap",
            .source = "pub struct App {\n" ++
                "  pub fn main() -> i64 { Helper.value() }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/helper.zap",
            .source = "pub struct Helper {\n" ++
                "  pub fn value() -> i64 { 42 }\n" ++
                "}\n",
        },
        .{
            .file_path = "test/app_test.zap",
            .source = "pub struct Test.AppTest {\n" ++
                "  pub fn run() -> String { \"ok\" }\n" ++
                "}\n",
        },
    };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{ .show_progress = false });

    try std.testing.expectEqual(@as(usize, 3), ctx.collector.graph.structs.items.len);

    var found_app = false;
    var found_helper = false;
    var found_test_app_test = false;
    for (ctx.collector.graph.structs.items) |entry| {
        if (entry.name.parts.len == 1) {
            const name = ctx.interner.get(entry.name.parts[0]);
            if (std.mem.eql(u8, name, "App")) found_app = true;
            if (std.mem.eql(u8, name, "Helper")) found_helper = true;
        } else if (entry.name.parts.len == 2) {
            const first = ctx.interner.get(entry.name.parts[0]);
            const second = ctx.interner.get(entry.name.parts[1]);
            if (std.mem.eql(u8, first, "Test") and std.mem.eql(u8, second, "AppTest")) {
                found_test_app_test = true;
            }
        }
    }

    try std.testing.expect(found_app);
    try std.testing.expect(found_helper);
    try std.testing.expect(found_test_app_test);
}

test "staged macro expansion can call previously compiled Zap functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "lib/lib.zap",
            .source = "pub struct Lib {\n" ++
                "  pub fn value() -> String { \"ok\" }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/macro_provider.zap",
            .source = "pub struct MacroProvider {\n" ++
                "  pub macro build() -> Expr {\n" ++
                "    value = Lib.value()\n" ++
                "    quote { unquote(value) }\n" ++
                "  }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/caller.zap",
            .source = "pub struct Caller {\n" ++
                "  pub fn main() -> String {\n" ++
                "    MacroProvider.build()\n" ++
                "  }\n" ++
                "}\n",
        },
    };
    const struct_order = [_][]const u8{ "Lib", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    var result = try compileStructByStruct(alloc, &ctx, &struct_order, .{ .show_progress = false });

    var interpreter = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interpreter.deinit();
    const value = try interpreter.evalByName("Caller__main__0", &.{});

    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("ok", value.string);
}

test "staged macro expansion can call compiled Zap functions that use allowed CTFE primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "lib/globber.zap",
            .source = "pub struct Globber {\n" ++
                "  pub fn files() -> [String] { :zig.Prim.glob(\"test/zap/zest_runner_test.zap\") }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/macro_provider.zap",
            .source = "pub struct MacroProvider {\n" ++
                "  pub macro build() -> Expr {\n" ++
                "    paths = Globber.files()\n" ++
                "    count = list_length(paths)\n" ++
                "    quote { unquote(count) }\n" ++
                "  }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/caller.zap",
            .source = "pub struct Caller {\n" ++
                "  pub fn main() -> i64 {\n" ++
                "    MacroProvider.build()\n" ++
                "  }\n" ++
                "}\n",
        },
    };
    const struct_order = [_][]const u8{ "Globber", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    var result = try compileStructByStruct(alloc, &ctx, &struct_order, .{ .show_progress = false });

    var interpreter = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interpreter.deinit();
    const value = try interpreter.evalByName("Caller__main__0", &.{});

    try std.testing.expect(value == .int);
    try std.testing.expectEqual(@as(i64, 1), value.int);
}

test "staged use macro expansion can call previously compiled Zap functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "lib/globber.zap",
            .source = "pub struct Globber {\n" ++
                "  pub fn files() -> [String] { :zig.Prim.glob(\"test/zap/zest_runner_test.zap\") }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/macro_provider.zap",
            .source = "pub struct MacroProvider {\n" ++
                "  pub macro __using__(_opts :: Expr) -> Expr {\n" ++
                "    paths = Globber.files()\n" ++
                "    count = list_length(paths)\n" ++
                "    quote { pub fn main() -> i64 { unquote(count) } }\n" ++
                "  }\n" ++
                "}\n",
        },
        .{
            .file_path = "lib/caller.zap",
            .source = "pub struct Caller {\n" ++
                "  use MacroProvider\n" ++
                "}\n",
        },
    };
    const struct_order = [_][]const u8{ "Globber", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .struct_order = &struct_order,
    });
    var result = try compileStructByStruct(alloc, &ctx, &struct_order, .{ .show_progress = false });

    var interpreter = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interpreter.deinit();
    const value = try interpreter.evalByName("Caller__main__0", &.{});

    try std.testing.expect(value == .int);
    try std.testing.expectEqual(@as(i64, 1), value.int);
}

test "staged macro provider rejects direct underscore-prefixed call before compilation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_units = [_]SourceUnit{
        .{
            .file_path = "lib/macro_provider.zap",
            .source = "pub struct MacroProvider {\n" ++
                "  pub macro build() -> Expr {\n" ++
                "    _helper()\n" ++
                "  }\n" ++
                "}\n",
        },
    };
    const struct_order = [_][]const u8{"MacroProvider"};

    try std.testing.expectError(
        error.TypeCheckFailed,
        collectAllFromUnits(alloc, &source_units, .{
            .show_progress = false,
            .struct_order = &struct_order,
        }),
    );
}

test "Phase 2 memory adapters: getRuntimeSource rewrites REFCOUNT_V1 caps" {
    const src = getRuntimeSource(0x1, true);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0000_0000_0000_0001;") == null);
}

test "Phase 2 memory adapters: getRuntimeSource rewrites zero caps" {
    const src = getRuntimeSource(0, false);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = false;") != null);
}

test "Phase 2 memory adapters: getRuntimeSource encodes arbitrary caps bitmasks" {
    const multi_caps: u64 = 0xDEADBEEFCAFEBABE;
    const src = getRuntimeSource(multi_caps, false);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0xdeadbeefcafebabe;") != null);
}

test "Phase 2 memory adapters: getRuntimeSource enables active manager source binding" {
    const src = getRuntimeSource(0x1, true);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = false;") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = true;") != null);
}

test "Phase 7e: getRuntimeSource rewrites memory startup prologue marker for executable binaries" {
    const src = getRuntimeSource(0x1, true);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = false;") == null);
}

test "Phase 7e: runtime rewrite cache separates startup prologue shape" {
    const lazy_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = true,
        .memory_startup_prologue_emitted = false,
        .collect_arc_stats = false,
    });
    const prologue_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = true,
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });

    try std.testing.expect(lazy_src.ptr != prologue_src.ptr);
    try std.testing.expect(std.mem.indexOf(u8, lazy_src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, prologue_src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = true;") != null);
}

test "Phase 7e: library-shaped runtime source keeps lazy startup marker" {
    const src = getRuntimeSourceForEntryShape(0x1, true, false);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT: bool = true;") != null);
}

test "Phase 7e: object-shaped runtime source keeps lazy startup marker" {
    const src = getRuntimeSourceForEntryShape(0x1, true, false);

    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_MEMORY_STARTUP_PROLOGUE_DEFAULT: bool = true;") == null);
}

test "Phase 2 ARC stats: runtime source keeps collection elided by default" {
    const src = getRuntimeSourceForRuntimeControls(0x1, true, .{
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });

    try std.testing.expect(std.mem.indexOf(u8, src, "const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const COLLECT_ARC_STATS_DEFAULT: bool = true;") == null);
}

test "Phase 2 ARC stats: runtime source rewrites collection marker on explicit opt-in" {
    const src = getRuntimeSourceForRuntimeControls(0x1, true, .{
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = true,
    });

    try std.testing.expect(std.mem.indexOf(u8, src, "const COLLECT_ARC_STATS_DEFAULT: bool = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;") == null);
}

test "Phase 2 ARC stats: runtime rewrite cache separates collection shape" {
    const elided_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = true,
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });
    const collecting_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = true,
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = true,
    });

    try std.testing.expect(elided_src.ptr != collecting_src.ptr);
    try std.testing.expect(std.mem.indexOf(u8, elided_src, "const COLLECT_ARC_STATS_DEFAULT: bool = builtin.is_test;") != null);
    try std.testing.expect(std.mem.indexOf(u8, collecting_src, "const COLLECT_ARC_STATS_DEFAULT: bool = true;") != null);
}

test "Phase 2 memory adapters: runtime rewrite cache separates refcount sized extension shape" {
    const sized_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = true,
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });
    const unsized_src = rewriteRuntimeSource(.{
        .instrumented = false,
        .declared_caps = 0x1,
        .refcount_sized_extension = false,
        .memory_startup_prologue_emitted = true,
        .collect_arc_stats = false,
    });

    try std.testing.expect(sized_src.ptr != unsized_src.ptr);
    try std.testing.expect(std.mem.indexOf(u8, sized_src, "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsized_src, "const RUNTIME_REFCOUNT_SIZED_EXTENSION_DEFAULT: bool = false;") != null);
}
