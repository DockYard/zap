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

// ---------------------------------------------------------------------------
// Phase 2 — first-party memory manager source embedding.
//
// Each first-party manager's `.zig` source is embedded into the compiler
// binary so later phases (3+) can emit it as a sibling Zig module named
// `zap_active_manager` alongside the user binary's runtime. The runtime's
// comptime-dispatched `retain`/`release` call sites then resolve through
// the manager's hot paths in the same compilation unit, which is the
// precondition for LLVM to inline across the boundary (the original
// reason every Zap binary linked the manager as a separate object file
// and lost the inline opportunity).
//
// Symmetry obligation — the set of `@embedFile` declarations below MUST
// remain in 1:1 correspondence with the first-party cases of
// `BuiltinManagerTag` in `src/memory/driver.zig`. Adding a sixth
// first-party manager means landing the manager's `.zap` stdlib decl,
// its `BuiltinManagerTag` case, its classifier arm, its `manager.zig`
// Zig source, AND a new `@embedFile` here plus a new arm in
// `getBuiltinManagerSource`'s switch. The comptime assertion below
// fires if the enum's case count drifts away from the switch.
const arc_manager_source = @embedFile("memory/arc/manager.zig");
const arena_manager_source = @embedFile("memory/arena/manager.zig");
const no_op_manager_source = @embedFile("memory/no_op/manager.zig");
const leak_manager_source = @embedFile("memory/leak/manager.zig");
const tracking_manager_source = @embedFile("memory/tracking/manager.zig");

/// Return the embedded Zig source bytes for a first-party memory
/// manager identified by its `BuiltinManagerTag`, or `null` for the
/// `.third_party` sentinel.
///
/// The returned slice is a borrowed view into the compiler binary's
/// read-only data section (every byte came from `@embedFile` at
/// compile time), so the call is zero-cost and the slice is valid for
/// the full process lifetime — callers do not need to free it.
///
/// Why this exists — Phase 1 introduced `BuiltinManagerTag` so the
/// compiler can identify which first-party manager a build resolved
/// to. Phase 2 (this accessor) gives the rest of the pipeline a
/// byte-stable handle on the manager's Zig source keyed by that tag.
/// Phase 3 will emit the returned bytes as a sibling module so the
/// runtime's comptime dispatch sites can be inlined through to the
/// manager's hot paths — eliminating the cross-object-file boundary
/// that currently blocks LLVM inlining and motivated the
/// perf-recovery effort.
///
/// `.third_party` is the explicit non-built-in sentinel:
/// third-party managers ship their `.zig` source through the build
/// manifest, not the compiler binary, so the embedded-source surface
/// is intentionally first-party-only. The build pipeline must
/// consult the manifest for `.third_party` instead of this accessor.
pub fn getBuiltinManagerSource(tag: zap.memory_driver.BuiltinManagerTag) ?[]const u8 {
    return switch (tag) {
        .arc => arc_manager_source,
        .arena => arena_manager_source,
        .no_op => no_op_manager_source,
        .leak => leak_manager_source,
        .tracking => tracking_manager_source,
        .third_party => null,
    };
}

/// Return the canonical Zig-module import name under which the
/// active first-party manager's embedded source is registered, or
/// `null` for `.third_party`.
///
/// Why one shared name — only one first-party manager is active per
/// build, so the runtime's `@import("zap_active_manager")` resolves
/// to whichever first-party manager Phase 3 registered for this
/// compile. Returning a per-tag name (e.g., `"zap_active_manager_arc"`)
/// would force the runtime to encode a conditional import surface
/// per tag, which defeats the goal of letting LLVM see a single
/// call-graph through the active manager's hot paths. A uniform
/// name keeps the runtime source identical across first-party
/// builds and isolates the manager swap to module-registration
/// time.
///
/// `.third_party` returns `null` because the manifest, not the
/// compiler, names the third-party module — the runtime does not
/// `@import("zap_active_manager")` under a third-party manager;
/// it links the manager's object file the way it does today.
pub fn managerSourceUnitName(tag: zap.memory_driver.BuiltinManagerTag) ?[]const u8 {
    return switch (tag) {
        .arc, .arena, .no_op, .leak, .tracking => "zap_active_manager",
        .third_party => null,
    };
}

// Compile-time guard for the symmetry obligation documented above:
// `getBuiltinManagerSource`'s switch hard-codes one arm per
// first-party tag plus the explicit `.third_party` arm, so any change
// to `BuiltinManagerTag`'s shape (adding, removing, or renaming a
// case) MUST be accompanied by a matching change here. Bumping the
// expected count without updating the switch — or vice versa — will
// fail the build at this site instead of silently degrading a new
// first-party manager to a missing-arm runtime crash. This assertion
// is intentionally separate from the one in `src/memory/driver.zig`:
// that one protects the classifier; this one protects the embedded-
// source switch. Both must stay green.
comptime {
    const fields = @typeInfo(zap.memory_driver.BuiltinManagerTag).@"enum".fields;
    if (fields.len != 6) @compileError(
        "getBuiltinManagerSource and managerSourceUnitName: switches must be updated when adding a BuiltinManagerTag case; also add a matching @embedFile constant",
    );
}

/// Stub registered as `zap_active_manager` when the build selects a
/// third-party memory manager. The runtime's `.third_party` comptime
/// branch never references symbols from this module; it routes through
/// the manager `.o`'s `.zapmem`-registered vtable instead. This stub
/// exists solely so the runtime's top-level
/// `@import("zap_active_manager")` resolves cleanly under every
/// user-binary build, regardless of which manager the manifest
/// selected.
///
/// The bytes MUST parse as valid Zig — they are handed straight to
/// `zir_compilation_add_struct_source`, which feeds them to the Zig
/// compiler's parser. A regression that emits non-Zig text (or empty
/// bytes) would surface as a Sema parse error during every
/// third-party user-binary build.
const THIRD_PARTY_ACTIVE_MANAGER_STUB = @embedFile("zap_active_manager_stub.zig");

/// Return the Zig source bytes to register as the user binary's
/// `zap_active_manager` module. For first-party tags this is the
/// active manager's embedded `manager.zig` source (Phase 4's comptime
/// branches in `runtime.zig` call into it directly so LLVM can inline
/// across the boundary, which is the whole motivation behind Phases
/// 3-5 of the perf-recovery plan). For `.third_party` it is the
/// minimal `THIRD_PARTY_ACTIVE_MANAGER_STUB`; the runtime's
/// `.third_party` branch never references the stub's symbols, so the
/// stub only needs to be valid Zig for parsing/registration purposes.
///
/// Non-nullable return: every user-binary build MUST register
/// `zap_active_manager` (the runtime's top-level
/// `@import("zap_active_manager")` would otherwise fail to resolve,
/// failing every Zap user binary's compile). Returning a sentinel
/// instead of a nullable value forces the caller to wire the bytes
/// through end-to-end. The returned slice is a borrowed view into the
/// compiler binary's read-only data (either an `@embedFile` blob or
/// the constant stub literal above), so the call is zero-cost and the
/// slice is valid for the full process lifetime — callers do not need
/// to free it.
pub fn getActiveManagerSourceBytes(tag: zap.memory_driver.BuiltinManagerTag) []const u8 {
    return switch (tag) {
        .arc, .arena, .no_op, .leak, .tracking => getBuiltinManagerSource(tag).?,
        .third_party => THIRD_PARTY_ACTIVE_MANAGER_STUB,
    };
}

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
};

pub const CompileOptions = struct {
    /// Show progress output to stderr.
    show_progress: bool = true,
    /// lib mode — skip main function emission in ZIR.
    lib_mode: bool = false,
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
};

fn ctfeCompileOptionsHash(options: CompileOptions) u64 {
    return if (options.ctfe_target != null or options.ctfe_optimize != null)
        zap.ctfe.hashCompileOptions(options.ctfe_target orelse "", options.ctfe_optimize orelse "")
    else
        0;
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
    interner: ast.StringInterner,

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
};

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

    if (options.show_progress) {
        std.debug.print("Compiling\n", .{});
    }

    var diag_engine = zap.DiagnosticEngine.init(alloc);
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Parse each source unit with its own local interner, then merge
    // interners and remap AST StringIds. This architecture supports
    // parallel parsing (each parser is independent).
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Parse", .{ step, total_steps });

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
            group.async(io_val, parseFileTask, .{ alloc, unit.source, &local_interners[i], @as(u32, @intCast(i)), &parsed_programs[i], &parse_results[i] });
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
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
            return error.ParseFailed;
        }
    } else {
        // Sequential fallback: single file or no Io available
        for (all_source_units, 0..) |unit, i| {
            local_interners[i] = ast.StringInterner.init(alloc);
            var parser = zap.Parser.initWithSharedInterner(alloc, unit.source, &local_interners[i], @intCast(i));
            defer parser.deinit();

            parsed_programs[i] = parser.parseProgram() catch {
                emitParseErrorsFromUnits(alloc, parser.errors.items, all_source_units, diag_engine.use_color);
                if (options.show_progress) std.debug.print("\r\x1b[K", .{});
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
    var interner = global_interner;

    if (diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitDiagnostics(&diag_engine, alloc);
        return error.ParseFailed;
    }

    const program = try mergePrograms(alloc, parsed_programs);

    // Collect declarations from the merged program first (needed for
    // macro expansion to resolve Kernel macros etc.)
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Collect", .{ step, total_steps });

    // Intern the auto-imported Kernel struct's name once — needed for
    // auto-import injection. The literal name lives in
    // `discovery.kernel_struct_name`.
    const kernel_name_id = try interner.intern(zap.discovery.kernel_struct_name);
    var collector = zap.Collector.init(alloc, &interner, kernel_name_id);
    try registerSourceUnits(&collector.graph, all_source_units);
    {
        const pre_struct_programs = try buildStructPrograms(alloc, &program, &interner);

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
                if (options.show_progress) std.debug.print("\r\x1b[K", .{});
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
                if (options.show_progress) std.debug.print("\r\x1b[K", .{});
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
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        }

        const pre_slices = try alloc.alloc(ast.Program, pre_struct_programs.len);
        for (pre_struct_programs, 0..) |entry, i| pre_slices[i] = entry.program;
        collector.finalizeCollectedPrograms(pre_slices) catch {
            for (collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return error.CollectFailed;
        };
    }

    for (collector.errors.items) |collect_err| {
        diag_engine.err(collect_err.message, collect_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.CollectFailed;
    }

    // Static capability inference: walk every macro/function body, identify
    // direct uses of impure intrinsics, and propagate to the fixed point so
    // each `MacroFamily.required_caps` reflects what the body actually does.
    // Replaces the historical `@requires` annotation; macro authors no
    // longer write capability sets by hand.
    zap.capability_inference.inferAndApply(alloc, &collector.graph, &interner) catch {};

    // Run macro expansion and desugaring. When the discovery graph supplies a
    // struct order, expand one struct at a time and compile each completed
    // dependency level to IR so later macros can call already compiled Zap
    // functions through CTFE. Without a graph order, keep the legacy merged
    // expansion path.
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Macro expand", .{ step, total_steps });

    const desugared_program = if (options.struct_order) |struct_order|
        stagedMacroExpandAndDesugar(
            alloc,
            &program,
            struct_order,
            &interner,
            &collector,
            &diag_engine,
        ) catch |err| {
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return err;
        }
    else
        legacyMacroExpandAndDesugar(
            alloc,
            &program,
            &interner,
            &collector,
            &diag_engine,
        ) catch |err| {
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
            emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
            return err;
        };

    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps });

    // NOW split into per-struct programs from the expanded/desugared AST.
    // All if_expr nodes are gone, all pipes desugared, all macros expanded.
    const struct_programs = try buildStructPrograms(alloc, &desugared_program, &interner);

    // Rebuild the scope graph from the desugared AST. The original collector
    // was built from pre-expansion AST, so its function declaration pointers
    // are stale. The HIR builder compares AST node pointers to determine
    // which functions belong to the current struct, so the scope graph must
    // reference the same AST nodes as the desugared struct programs.
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Re-collect", .{ step, total_steps });

    var final_collector = zap.Collector.init(alloc, &interner, kernel_name_id);
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
            if (options.show_progress) std.debug.print("\r\x1b[K", .{});
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
    zap.capability_inference.inferAndApply(alloc, &final_collector.graph, &interner) catch {};

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

    var analysis_result = try pipeline.runAnalysisAndContify(&ir_program);

    // Materialize the analysis-context records into first-class
    // `.retain { kind }` / `.release { kind }` IR instructions so
    // the whole-program codegen path consumes the same canonical
    // IR shape as `compileStructByStruct`'s merged path.
    try materializeAnalysisArcOps(alloc, &ir_program, &analysis_result.context, type_checker.store, options.declared_caps);

    // Second type-check pass — borrow / move diagnostics live behind
    // the analysis context, so they only fire on this re-check.
    // Replays `checkProgram` + `checkUnusedBindings` against the same
    // desugared AST, now wired up to the analysis context.
    type_checker.setAnalysisContext(&analysis_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
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
            std.debug.print("\r\x1b[K  [{d}/{d}] {s}", .{ self.step, self.total_steps, name });
        }
    }

    fn clearProgress(self: *const Pipeline) void {
        if (self.progress_enabled) std.debug.print("\r\x1b[K", .{});
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
            &self.ctx.interner,
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
        var macro_engine = zap.MacroEngine.init(self.alloc, &self.ctx.interner, &self.ctx.collector.graph);
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
        var desugarer = zap.Desugarer.init(self.alloc, &self.ctx.interner, &self.ctx.collector.graph);
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
            break :blk zap.types.TypeChecker.initWithSharedStore(self.alloc, store, &self.ctx.interner, &self.ctx.collector.graph);
        } else zap.types.TypeChecker.init(self.alloc, &self.ctx.interner, &self.ctx.collector.graph);
        errdefer type_checker.deinit();

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
        var hir_builder = zap.hir.HirBuilder.init(self.alloc, &self.ctx.interner, &self.ctx.collector.graph, type_store);
        hir_builder.next_group_id = group_id_offset;
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
        const result = zap.monomorphize.monomorphize(self.alloc, hir_program, type_store, next_group_id, &self.ctx.interner) catch
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
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, &self.ctx.interner);
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
        runArcOwnershipAndVerify(self.alloc, &program, &ownership, type_store) catch
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
        runArcDropInsertion(self.alloc, &program, &ownership, type_store) catch
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
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, &self.ctx.interner);
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
                &self.ctx.interner,
                order,
                cache_dir,
                opts_hash,
            ) catch {};
        } else {
            _ = zap.ctfe.evaluateComputedAttributes(
                self.alloc,
                ir_program,
                &self.ctx.collector.graph,
                &self.ctx.interner,
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
            &self.ctx.interner,
            mod_name,
            self.options.cache_dir,
            ctfeCompileOptionsHash(self.options),
        ) catch null;
        if (ctfe_result) |cr| {
            if (cr.errors.len > 0) zap.ctfe.emitCtfeErrors(self.alloc, cr.errors);
        }
    }

    fn runAnalysisAndContify(
        self: *Pipeline,
        ir_program: *ir.Program,
    ) CompileError!zap.analysis_pipeline.PipelineResult {
        self.progress("Escape analysis");
        var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(self.alloc, ir_program) catch
            return self.failWith("Error during escape analysis", error.IrFailed);
        zap.contification_rewrite.rewriteContifiedContinuations(self.alloc, ir_program, &pipeline_result.context) catch |err| switch (err) {
            error.UnsupportedContifiedRewrite => {},
            else => return error.IrFailed,
        };
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
) CompileError!ast.Program {
    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
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
    for (struct_order) |struct_name| {
        const original = lookupStructProgramInSlice(original_structs, struct_name) orelse continue;
        staged_timer.reset();
        const desugared = try expandAndDesugarStagedStruct(
            alloc,
            original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
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

    for (original_structs) |original| {
        if (seen_structs.contains(original.name)) continue;
        const desugared = try expandAndDesugarStagedStruct(
            alloc,
            &original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
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
) CompileError!ast.Program {
    const top_program = ast.Program{ .structs = &.{}, .top_items = top_items };
    const error_baseline = diag_engine.errorCount();

    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
    defer macro_engine.deinit();
    macro_engine.setCompiledExecutor(compiled_executor);
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

    reCollectFunctionsInProgram(collector, &expanded);
    updateImplDeclsInProgram(collector, &expanded);

    var desugarer = zap.Desugarer.init(alloc, interner, &collector.graph);
    const desugared = desugarer.desugarProgram(&expanded) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        return error.DesugarFailed;
    };
    reCollectFunctionsInProgram(collector, &desugared);
    updateImplDeclsInProgram(collector, &desugared);
    try expandGraphImplsForProgram(alloc, &desugared, interner, collector, diag_engine, compiled_executor);
    return desugared;
}

fn expandGraphImplsForProgram(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
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
            entry.decl = switch (desugared_impl_program.top_items[0]) {
                .impl_decl => |decl| decl,
                .priv_impl_decl => |decl| decl,
                else => entry.decl,
            };
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
        .unwrap => |unwrap| findUndesugaredMacroFormInExpr(unwrap.expr),
        .type_annotated => |type_annotated| findUndesugaredMacroFormInExpr(type_annotated.expr),
        .anonymous_function => |anonymous| findUndesugaredMacroFormInFunction(anonymous.decl),
        .list_cons_expr => |list_cons| findUndesugaredMacroFormInExpr(list_cons.head) orelse findUndesugaredMacroFormInExpr(list_cons.tail),
        .error_pipe => |error_pipe| findUndesugaredMacroFormInErrorPipeChain(error_pipe.chain) orelse findUndesugaredMacroFormInErrorHandler(error_pipe.handler),
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

fn reCollectFunctionsInProgram(collector: *zap.Collector, program: *const ast.Program) void {
    for (program.structs) |*mod| {
        const mod_scope = collector.graph.findStructScope(mod.name) orelse continue;
        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const arity: u8 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                    const key = zap.scope.FamilyKey{ .name = func.name, .arity = arity };
                    const scope_data = collector.graph.getScope(mod_scope);
                    if (scope_data.function_families.get(key) == null) {
                        collector.collectFunction(func, mod_scope) catch {};
                    }
                },
                else => {},
            }
        }
    }
}

fn updateImplDeclsInProgram(collector: *zap.Collector, program: *const ast.Program) void {
    for (program.top_items) |item| {
        const impl = switch (item) {
            .impl_decl => |decl| decl,
            .priv_impl_decl => |decl| decl,
            else => continue,
        };
        for (collector.graph.impls.items) |*entry| {
            if (!structNamesEqual(entry.protocol_name, impl.protocol_name)) continue;
            if (!structNamesEqual(entry.target_type, impl.target_type)) continue;
            entry.decl = impl;
            break;
        }
    }
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
pub fn compileStructByStruct(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    struct_order: []const []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;

    // Collect all IR functions and type defs across structs.
    var all_functions: std.ArrayListUnmanaged(ir.Function) = .empty;
    var all_type_defs: std.ArrayListUnmanaged(ir.TypeDef) = .empty;
    var entry_id: ?ir.FunctionId = null;

    // Shared TypeStore + globally-unique group IDs pipeline.
    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, &ctx.interner);

    // Phase 1: every struct → HIR. Shared TypeStore and globally-
    // unique group IDs let later phases monomorphize across struct
    // boundaries.
    //
    // Dedupe `struct_order` defensively. Discovery already canonicalizes
    // file paths so the same on-disk struct cannot be queued twice via
    // different surface paths, but per-struct HIR lowering must run at
    // most once per struct regardless: a second lowering would emit a
    // second `ir.Function` record for every public function with the
    // same name but a different `FunctionId`, which silently breaks
    // every downstream pass that maps function names to IDs (the uniqueness
    // fixpoint signature table, the ARC convention `lift_set`, the
    // chain-consistency audit). Treat upstream duplicates as a bug to
    // surface — once discovery is the single source of truth this
    // guard becomes a defensive no-op, but it also keeps callers that
    // assemble `struct_order` themselves from triggering the same
    // hazard.
    var phase_timer = ZapTimer.start();
    var per_struct_timer = ZapTimer.start();
    var hir_results: std.ArrayListUnmanaged(StructHirResult) = .empty;
    var group_id_offset: u32 = 0;
    var lowered_structs = std.StringHashMap(void).init(alloc);
    defer lowered_structs.deinit();
    for (struct_order, 0..) |mod_name, mod_idx| {
        if (lowered_structs.contains(mod_name)) continue;
        if (options.show_progress) {
            std.debug.print("\r\x1b[K  [hir {d}/{d}] {s}", .{ mod_idx + 1, struct_order.len, mod_name });
        }
        const mod_program = lookupStructProgram(ctx, mod_name) orelse continue;
        // Per-struct failures are routed through the diagnostic
        // engine inside the helper; the loop continues so other
        // structs still compile and the user sees as many errors as
        // possible in one run.
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

    // Phase 2: merge per-struct HIR programs.
    var all_hir_structs: std.ArrayListUnmanaged(zap.hir.Struct) = .empty;
    var all_hir_top_fns: std.ArrayListUnmanaged(zap.hir.FunctionGroup) = .empty;
    var all_hir_protocols: std.ArrayListUnmanaged(zap.hir.ProtocolInfo) = .empty;
    var all_hir_impls: std.ArrayListUnmanaged(zap.hir.ImplInfo) = .empty;
    for (hir_results.items) |*result| {
        for (result.hir_program.structs) |mod| {
            all_hir_structs.append(alloc, mod) catch return error.OutOfMemory;
        }
        for (result.hir_program.top_functions) |tf| {
            all_hir_top_fns.append(alloc, tf) catch return error.OutOfMemory;
        }
        for (result.hir_program.protocols) |proto| {
            all_hir_protocols.append(alloc, proto) catch return error.OutOfMemory;
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

    // Phase 3: whole-program monomorphization.
    var mono_next = group_id_offset;
    combined_hir = try pipeline.runMonomorphize(&combined_hir, shared_store, &mono_next);
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase3-Monomorphize] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    // Phase 4: each struct's HIR → IR. Function IDs are already
    // globally unique from the HIR stage (group_id_offset advancement
    // in phase 1), so no cloneWithOffset is needed — collect
    // functions directly. `next_try_id` is threaded across structs so
    // synthesized `__try` variants get globally unique IDs that don't
    // collide with another struct's regular HIR groups.
    var next_try_id: u32 = mono_next;
    // Merged ARC ownership table aggregated across every per-struct
    // IR-lowering call. Each per-struct call returns its own
    // `ProgramArcOwnership`; we move the entries into this combined
    // map so downstream phases can look up any function by id without
    // tracking which struct it came from.
    var combined_arc_ownership = zap.arc_liveness.ProgramArcOwnership.init(alloc);
    errdefer combined_arc_ownership.deinit();
    for (combined_hir.structs) |mod| {
        const single_mod_hir = zap.hir.Program{
            .structs = try alloc.dupe(zap.hir.Struct, &.{mod}),
            .top_functions = &.{},
        };
        const mod_name_str = if (mod.name.parts.len > 0) ctx.interner.get(mod.name.parts[mod.name.parts.len - 1]) else "unknown";
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
        for (mod_ir.functions) |func| {
            all_functions.append(alloc, func) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |eid| entry_id = eid;
        for (mod_ir.type_defs) |td| {
            all_type_defs.append(alloc, td) catch return error.OutOfMemory;
        }
    }
    if (combined_hir.top_functions.len > 0) {
        const top_hir = zap.hir.Program{
            .structs = &.{},
            .top_functions = combined_hir.top_functions,
            .impls = combined_hir.impls,
        };
        const mod_lower = compileHirToIr(alloc, ctx, "top", &top_hir, shared_store, options, &next_try_id, &combined_hir) catch return error.IrFailed;
        const mod_ir = mod_lower.program;
        try mergeArcOwnership(alloc, &combined_arc_ownership, mod_lower.arc_ownership);
        for (mod_ir.functions) |func| {
            all_functions.append(alloc, func) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |eid| entry_id = eid;
        for (mod_ir.type_defs) |td| {
            all_type_defs.append(alloc, td) catch return error.OutOfMemory;
        }
    }

    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase4-AllIR] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    // Phase 5: analysis + contification on the merged IR.
    var merged_ir = ir.Program{
        .functions = all_functions.items,
        .type_defs = all_type_defs.items,
        .entry = entry_id,
    };
    var analysis_result = try pipeline.runAnalysisAndContify(&merged_ir);
    if (profilingEnabled()) {
        std.debug.print("\n[stage Phase5-AnalysisAndContify] ms={d}\n", .{phase_timer.lapMs()});
    } else {
        _ = phase_timer.lapMs();
    }

    // Phase 5b: re-run the ARC convention inference + ownership rewriting
    // on the merged IR so cross-struct call sites can promote callee
    // params from `.borrowed` to `.owned`. The per-struct pipeline only
    // sees its own struct's call sites (the per-struct `name_to_id`
    // table only contains that struct's functions), so wrappers like
    // `List.set` and `Map.put` whose only callers live in OTHER
    // structs (e.g. user code in `FannkuchRedux`, `KNucleotide`) are
    // missed by the per-struct inference. This pass runs against the
    // merged program so EVERY caller is visible.
    //
    // Idempotency: every pass in this block is idempotent against
    // post-per-struct IR — `arc_param_convention` is monotonic
    // (.borrowed → .owned, never the other way); `rewriteOwnedConsumeBuiltinSites`,
    // `classifyAndNormalize`, and `rewriteOwnedConsumeSites` look for
    // pre-rewrite IR shapes that no longer exist after the first run;
    // `arc_drop_insertion` recomputes liveness against the current IR
    // and only adds releases for locals genuinely live-before-ret
    // (existing releases are already "uses" in the recomputed view).
    //
    // This wiring fix unblocks the rc-1 fast path for ARC-managed
    // wrappers whose callers are in other structs — without it, every
    // `List.set`/`Map.put`/etc. call from user code enters the
    // runtime at refcount >= 2 and triggers the COW clone path.
    {
        // Recompute ownership against the merged IR so the inference
        // sees the post-Phase-5 last-use map (contification may have
        // moved instructions; arc_param_convention reads
        // `last_use_map` to gate share-source promotions).
        var merged_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, &merged_ir, shared_store) catch
            return error.IrFailed;
        zap.arc_param_convention.inferConventions(alloc, &merged_ir, &merged_ownership, shared_store) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        runArcOwnershipAndVerify(alloc, &merged_ir, &merged_ownership, shared_store) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        // Recompute ownership AFTER the rewrites so drop-insertion
        // sees the post-rewrite liveness shape.
        merged_ownership.deinit();
        merged_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, &merged_ir, shared_store) catch
            return error.IrFailed;
        runArcDropInsertion(alloc, &merged_ir, &merged_ownership, shared_store) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        // Phase 2: materialize the analysis-context records
        // (arc_ops, drop_specializations) into first-class
        // `.retain { kind }` / `.release { kind }` IR instructions
        // inserted directly into the function body. Records that
        // can't be resolved against the merged IR remain in the
        // analysis context for the V10 audit to surface.
        materializeAnalysisArcOps(alloc, &merged_ir, &analysis_result.context, shared_store, options.declared_caps) catch {
            merged_ownership.deinit();
            return error.IrFailed;
        };
        // Replace the per-struct combined ownership with the
        // recomputed merged ownership so downstream consumers
        // (ZIR backend, `arc_share_skipped`, etc.) see the
        // post-merge analysis.
        combined_arc_ownership.deinit();
        combined_arc_ownership = merged_ownership;
        if (profilingEnabled()) {
            std.debug.print("\n[stage Phase5b-MergedArcRedux] ms={d}\n", .{phase_timer.lapMs()});
        } else {
            _ = phase_timer.lapMs();
        }
    }

    // Single rendering pass for all per-struct diagnostics. Each
    // sub-pipeline accumulated into the shared engine without flushing,
    // so we emit exactly once here regardless of how many structs
    // failed.
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

/// Phase 6 of the ARC ownership initiative: walk every function in
/// `program` and, for each function that has a per-function entry in
/// `ownership`, insert scope-exit `release` IR instructions before
/// every ret-equivalent terminator (sourced from
/// `ArcOwnership.live_before_ret`). The pass is generic, type-blind,
/// and runs uniformly on every function regardless of whether any
/// ARC-managed locals are present — but the actual mutation only
/// fires when the analyzer recorded a non-empty live-before-ret set
/// for at least one terminator in the function.
///
/// `program.functions` is exposed as `[]const Function` so the
/// `@constCast` here is the seam where the drop-insertion pass
/// reaches through to mutate body slices in place. This is the same
/// pattern `arc_liveness.writeBackConsumeModes` uses to update
/// `share_value.mode` fields.
/// Phase A of the Phase 6 redux plan: run the new
/// `arc_ownership.classifyAndNormalize` pass followed by
/// `arc_verifier.verify` on every function in `program`. Both passes
/// are scaffolds at Phase A (no IR mutation, no rejected programs);
/// the wiring exists so subsequent phases (C populates the
/// classifier, E activates the verifier rules) can light up without
/// further plumbing changes.
///
/// Functions absent from `ownership` (no last-use data recorded)
/// still go through both passes — `arc_ownership` will be expected
/// to handle that edge case in Phase C, and even today the verifier
/// must run on every function regardless of whether the liveness
/// analyzer recorded any ARC locals.
fn runArcOwnershipAndVerify(
    alloc: std.mem.Allocator,
    program: *ir.Program,
    ownership: *const zap.arc_liveness.ProgramArcOwnership,
    type_store: *const zap.types.TypeStore,
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
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = ownership.get(function.id) orelse continue;
        zap.arc_ownership.rewriteOwnedConsumeBuiltinSites(alloc, function, fn_ownership) catch return error.OutOfMemory;
    }

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
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        zap.arc_ownership.rewriteOwnedConsumeSites(alloc, function, program) catch return error.OutOfMemory;
    }
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
    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        zap.arc_ownership.elideBorrowedPassThroughShares(alloc, function, program) catch return error.OutOfMemory;
    }
    // Phase H/uniqueness (codegen): for each owned-mutating call site whose
    // uniqueness static-uniqueness predicate holds, swap the callee name to
    // its `*_owned_unchecked` peer. This is a strict refinement of
    // Phase 4's move-on-last-use rewrite — uniqueness holds only at sites
    // where Phase 4 also fired (and additionally proved that the
    // receiver's cell was never aliased before the call).
    //
    // Runs AFTER `rewriteOwnedConsumeSites` so the IR shape
    // consumed by uniqueness matches the post-classification shape, and
    // BEFORE `arc_verifier.verify` so the uniqueness invariant in the
    // verifier sees this pass's rewrites and catches any mistake.
    //
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
    var post_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_ownership.deinit();

    var signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer signatures.deinit(alloc);

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
    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &signatures,
        &post_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer program_uniqueness.deinit(alloc);

    for (program.functions, 0..) |_, i| {
        const function: *ir.Function = @constCast(&program.functions[i]);
        const fn_ownership = post_ownership.get(function.id);
        var uniqueness = zap.uniqueness.analyzeUniquenessFull(
            alloc,
            function,
            program,
            &program_uniqueness,
            &signatures,
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
    for (program.functions) |*function| {
        const fn_ownership = post_ownership.get(function.id);
        zap.arc_verifier.verifyFull(
            alloc,
            function,
            program,
            &program_uniqueness,
            &signatures,
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
) CompileError!void {
    for (program.functions, 0..) |_, fi| {
        const function: *ir.Function = @constCast(&program.functions[fi]);
        zap.arc_materialize.materializeAnalysisArcOps(alloc, function, analysis_context, declared_caps) catch return error.IrFailed;
    }
    try runArcVerifier(alloc, program, type_store);
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
) CompileError!void {
    // Recompute Phase-2.5 inputs against the post-materialize IR so the
    // fixpoint and verifier observe the same Phase 2.5 semantics the
    // Phase 5b rewriter observed. Without this the verifier rejects
    // unchecked sites the rewriter legitimately produced.
    var post_materialize_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_materialize_ownership.deinit();

    var post_materialize_signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_materialize_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_materialize_signatures.deinit(alloc);

    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &post_materialize_signatures,
        &post_materialize_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer program_uniqueness.deinit(alloc);

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
) CompileError!void {
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
    }

    // Recompute Phase-2.5 inputs (post_ownership + signatures) against
    // the post-drop-insertion IR and pass them into the fixpoint and
    // the verifier so the post-drop check observes the same Phase 2.5
    // semantics the Phase 5b rewriter observed. Without this the
    // verifier rejects unchecked sites that the rewriter legitimately
    // produced — Phase 2.5 tuple-destructure propagation only fires
    // when both signatures and ownership are threaded through.
    var post_drop_ownership = zap.arc_liveness.runProgramArcOwnership(alloc, program, type_store) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_drop_ownership.deinit();

    var post_drop_signatures = zap.uniqueness_fixpoint.computeSignaturesWithOwnership(alloc, program, &post_drop_ownership) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer post_drop_signatures.deinit(alloc);

    var program_uniqueness = zap.uniqueness_interprocedural.analyzeProgramFull(
        alloc,
        program,
        &post_drop_signatures,
        &post_drop_ownership,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer program_uniqueness.deinit(alloc);

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
    const rendered = diag_engine.format(alloc) catch return;
    // stderr writer: use debug.print in 0.16
    std.debug.print("{s}", .{rendered});
}

const testing = std.testing;

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
/// produces. Three independent rewrites layer here, in order:
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
///   3. The Phase 3 active-manager identity tag
///      (`RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT`). Rewritten with the
///      resolved manager's `builtin_tag` so Phase 4's comptime
///      branches in `runtime.zig` see the right case at compile time;
///      a first-party manager build then resolves through
///      `@import("zap_active_manager")` directly (LLVM-inlineable),
///      while a `.third_party` build routes through the vtable.
///
/// The host test suite uses separate `@import("root")` overrides
/// inside `runtime.zig` for both flags (see `src/root.zig`), so
/// neither rewrite affects the host's own build.
///
/// The returned slice is either a borrowed view of the embedded source
/// (no rewrites required) or a freshly-allocated owned buffer (one or
/// both rewrites applied). Callers that hold onto the slice past the
/// allocator's lifetime must duplicate.
///
/// `declared_caps` is the active manager's capability bitmask.
/// Defaults to `0` would leave the source unchanged at the caps
/// marker; rather than relying on that, the rewrite always runs so
/// the user-binary's runtime reflects the exact resolved value.
///
/// `builtin_tag` is the resolved manager's identity classification
/// (`.arc` / `.arena` / `.no_op` / `.leak` / `.tracking` for the
/// first-party managers, `.third_party` for everything else). The
/// rewrite always runs so the third-party path is self-validating
/// (a no-op rewrite for `.third_party` would silently leave a future
/// bug in the rewrite path uncaught on third-party builds).
pub fn getRuntimeSource(
    declared_caps: u64,
    builtin_tag: zap.memory_driver.BuiltinManagerTag,
) []const u8 {
    const instrumented = @import("build_options").instrument_map;
    return rewriteRuntimeSource(.{
        .instrumented = instrumented,
        .declared_caps = declared_caps,
        .builtin_tag = builtin_tag,
    });
}

const RuntimeRewrite = struct {
    instrumented: bool,
    declared_caps: u64,
    builtin_tag: zap.memory_driver.BuiltinManagerTag,
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
///   * bits 65..71 — reserved for future single-bit rewrite flags.
///   * bits 72..79 — `builtin_tag` ordinal (u8; the enum is declared
///                  `enum(u8)` in `runtime.zig`'s `ActiveManagerTag`
///                  and mirrored unannotated here via `@intFromEnum`).
///
/// The (instrumented, declared_caps, builtin_tag) triple must produce
/// a unique key — two builds that differ in any one of the three MUST
/// alias to two distinct cache entries, otherwise the second build's
/// rewrite would silently inject the first build's source.
fn rewriteCacheKey(req: RuntimeRewrite) u128 {
    var key: u128 = req.declared_caps;
    if (req.instrumented) key |= (@as(u128, 1) << 64);
    const tag_ordinal: u128 = @intFromEnum(req.builtin_tag);
    key |= (tag_ordinal << 72);
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

    // Stage 3: active-manager identity marker rewrite. The source-level
    // default is `.third_party` so the host test suite (which loads
    // `runtime.zig` as a Zig module without going through this
    // rewrite) naturally exercises the vtable path — the same path a
    // third-party-manager build follows. For every Zap user binary we
    // always rewrite (even on `.third_party` builds, which re-encode
    // the same value) so the rewrite path is self-validating end-to-end.
    const tag_needle = "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .third_party;";
    const tag_name = activeManagerTagName(req.builtin_tag);
    var tag_replacement_buf: [128]u8 = undefined;
    const tag_replacement = std.fmt.bufPrint(
        &tag_replacement_buf,
        "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .{s};",
        .{tag_name},
    ) catch @panic("runtime active-manager-tag rewrite: formatted replacement overflows fixed buffer");
    const tag_idx = std.mem.indexOf(u8, caps_buf, tag_needle) orelse {
        @panic("runtime.zig is missing the RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT marker; Phase 3 tag rewrite cannot proceed");
    };
    const tag_total_len = caps_buf.len - tag_needle.len + tag_replacement.len;
    var tag_buf = std.heap.page_allocator.alloc(u8, tag_total_len) catch
        @panic("out of memory rewriting runtime source for active-manager tag");
    @memcpy(tag_buf[0..tag_idx], caps_buf[0..tag_idx]);
    @memcpy(tag_buf[tag_idx .. tag_idx + tag_replacement.len], tag_replacement);
    @memcpy(tag_buf[tag_idx + tag_replacement.len ..], caps_buf[tag_idx + tag_needle.len ..]);

    // Stage-2's buffer is no longer needed once stage-3 produces its
    // own owned copy. Free it back to the page allocator so we don't
    // leak per (instrumented, caps, tag) shape triple.
    std.heap.page_allocator.free(caps_buf);

    rewritten_runtime_cache.put(std.heap.page_allocator, key, tag_buf) catch
        @panic("out of memory caching rewritten runtime source");
    return tag_buf;
}

/// Map a `BuiltinManagerTag` to its lowercase identifier as it appears
/// in the runtime's `ActiveManagerTag` enum source. The names MUST
/// match `runtime.zig`'s enum-field identifiers verbatim because the
/// Phase 3 marker rewrite splices the result directly into Zig source
/// at the `.<name>` literal — a mismatch would compile but bind the
/// runtime to the wrong arm at every user-binary build. Kept in
/// lock-step with `runtime.zig:ActiveManagerTag` via the comptime
/// exhaustiveness assert directly below.
fn activeManagerTagName(tag: zap.memory_driver.BuiltinManagerTag) []const u8 {
    return switch (tag) {
        .arc => "arc",
        .arena => "arena",
        .no_op => "no_op",
        .leak => "leak",
        .tracking => "tracking",
        .third_party => "third_party",
    };
}

// Compile-time guard for the symmetry obligation between
// `activeManagerTagName`'s switch and `BuiltinManagerTag`'s shape.
// The Phase 3 tag-marker rewrite treats the tag as a closed set; a
// silent shape drift would surface as a Sema parse error at every
// user-binary build (the rewritten `.<missing_name>` literal would
// not be a valid `ActiveManagerTag` field), so we fail the build at
// this site instead.
comptime {
    const fields = @typeInfo(zap.memory_driver.BuiltinManagerTag).@"enum".fields;
    if (fields.len != 6) @compileError(
        "activeManagerTagName: switch must be updated when adding a BuiltinManagerTag case",
    );
}

// Phase 3 — ordinal-pair tripwire pinning `runtime.zig`'s
// `ActiveManagerTag(enum(u8))` ordinals to `driver.zig`'s
// `BuiltinManagerTag` ordinals.
//
// The runtime enum cannot be referenced from this site because
// `runtime.zig` is `@embedFile`'d into the compiler (it is a source
// blob, not a Zig module in scope here). The runtime side is the
// canonical wire encoding — the embedded source is what every Zap
// user binary sees, with `ActiveManagerTag` declared as
// `enum(u8) { arc = 0, arena = 1, no_op = 2, leak = 3, tracking = 4, third_party = 5 }`.
// `BuiltinManagerTag` must agree on every (name, ordinal) pair so
// that the `@intFromEnum` value packed into `rewriteCacheKey`'s
// `bits 72..79` slot resolves to the same comptime arm at every
// user-binary build.
//
// Adding a case to either enum without matching the other (in name,
// position, AND ordinal) breaks the wire encoding. This block fails
// the build before that drift can ship.
comptime {
    const DriverTag = zap.memory_driver.BuiltinManagerTag;
    const expected = [_]struct { name: []const u8, ord: u8 }{
        .{ .name = "arc", .ord = 0 },
        .{ .name = "arena", .ord = 1 },
        .{ .name = "no_op", .ord = 2 },
        .{ .name = "leak", .ord = 3 },
        .{ .name = "tracking", .ord = 4 },
        .{ .name = "third_party", .ord = 5 },
    };
    for (expected) |e| {
        const driver_field = @field(DriverTag, e.name);
        if (@intFromEnum(driver_field) != e.ord) @compileError(
            "Phase 3: BuiltinManagerTag ordinals drifted from runtime.zig's ActiveManagerTag — " ++
                "both enums must agree on (name, ordinal) because the runtime's enum(u8) " ++
                "wire encoding is consumed by `rewriteCacheKey` via @intFromEnum.",
        );
    }
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
    out_program: *ast.Program,
    out_result: *ParseTaskResult,
) void {
    var parser = zap.Parser.initWithSharedInterner(alloc, source, interner, source_id);
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
        .struct_ref => |*mr| try remapStructName(alloc, &mr.name, remap),
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
        // These have no StringId fields — only meta and numeric/bool values
        .int_literal, .float_literal, .bool_literal, .nil_literal => {},
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

test "Phase 6: getRuntimeSource rewrites RUNTIME_DECLARED_CAPS_DEFAULT for REFCOUNT_V1" {
    // User binaries built against a REFCOUNT_V1 manager (Zap.Memory.ARC)
    // see the same `runtime.refcount_v1_active = true` shape the host
    // tests see — the rewrite path is exercised even when the source-
    // level default already encodes the right value, so a drift in
    // the default value cannot mask a rewrite-path bug.
    const arc_caps: u64 = 0x0000_0000_0000_0001;
    const src = getRuntimeSource(arc_caps, .arc);
    // The rewritten source must contain the resolved caps literal.
    const expected = "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x1;";
    try std.testing.expect(std.mem.indexOf(u8, src, expected) != null);
    // And must NOT still carry the source-level default (the original
    // literal would short-circuit the runtime's comptime caps query
    // and the rewrite would be silently no-op).
    const original = "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0000_0000_0000_0001;";
    try std.testing.expect(std.mem.indexOf(u8, src, original) == null);
}

test "Phase 6: getRuntimeSource rewrites RUNTIME_DECLARED_CAPS_DEFAULT to 0 under Arena/NoOp" {
    // Arena and NoOp managers declare zero capabilities. The rewrite
    // must produce a runtime source whose embedded
    // `RUNTIME_DECLARED_CAPS_DEFAULT == 0`, so the user-binary
    // runtime's comptime `refcount_v1_active` resolves to `false` and
    // the inline `ArcHeader` field collapses to `@sizeOf == 0`.
    const arena_caps: u64 = 0;
    const src = getRuntimeSource(arena_caps, .arena);
    const expected = "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x0;";
    try std.testing.expect(std.mem.indexOf(u8, src, expected) != null);
}

test "Phase 6: getRuntimeSource rewrite encodes arbitrary caps bitmasks" {
    // A hypothetical multi-capability manager would declare a
    // bitmask with more than one bit set. The rewrite path is
    // pure string substitution — it must reproduce whatever
    // `declared_caps` the caller passes, verbatim as a hex literal.
    const multi_caps: u64 = 0xDEADBEEFCAFEBABE;
    const src = getRuntimeSource(multi_caps, .third_party);
    const expected = "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0xdeadbeefcafebabe;";
    try std.testing.expect(std.mem.indexOf(u8, src, expected) != null);
}

// ---------------------------------------------------------------------------
// Phase 2 — first-party manager source embedding (see Phase 1's
// `BuiltinManagerTag` in `src/memory/driver.zig`). These tests pin the
// per-tag accessor contract so later phases can rely on byte-stable
// access to the manager source by tag without re-reading from disk.
// ---------------------------------------------------------------------------

test "Phase 2: getBuiltinManagerSource returns non-empty bytes for each first-party tag" {
    // Exhaustive coverage of the five first-party tags is intentional:
    // a regression that drops a tag (e.g., a future enum reorder) would
    // pass any non-exhaustive test, but the perf-recovery plan requires
    // every first-party manager to be reachable by tag from the
    // compiler. The `const std = @import("std");` substring pins both
    // the embed-path correctness AND the self-contained manager
    // convention each `manager.zig` documents in its file header.
    const std_import_needle = "const std = @import(\"std\");";
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arc, .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const source = getBuiltinManagerSource(tag);
        try std.testing.expect(source != null);
        try std.testing.expect(source.?.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, source.?, std_import_needle) != null);
    }
}

test "Phase 2: getBuiltinManagerSource returns null for .third_party" {
    // Third-party managers ship their own `.zig` source through the
    // build manifest, not through the compiler binary — Phase 2's
    // embed-and-expose contract is explicitly first-party-only. A
    // non-null return here would leak a default first-party manager
    // into third-party builds, breaking the manifest as the sole
    // source of truth for non-built-in managers.
    try std.testing.expect(getBuiltinManagerSource(.third_party) == null);
}

test "Phase 2: managerSourceUnitName returns 'zap_active_manager' for every first-party tag" {
    // The accessor returns a single canonical import name across all
    // first-party tags so the runtime's `@import("zap_active_manager")`
    // works uniformly without a conditional import surface per tag —
    // only one first-party manager is active per build, and the
    // import name is intentionally tag-agnostic.
    const expected = "zap_active_manager";
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arc, .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const name = managerSourceUnitName(tag);
        try std.testing.expect(name != null);
        try std.testing.expectEqualStrings(expected, name.?);
    }
}

test "Phase 2: managerSourceUnitName returns null for .third_party" {
    // Symmetric with `getBuiltinManagerSource(.third_party) == null`:
    // third-party managers do not participate in the embedded-source
    // import-name surface — the manifest names the module instead.
    try std.testing.expect(managerSourceUnitName(.third_party) == null);
}

test "Phase 2: each embedded first-party manager source matches the on-disk file" {
    // `@embedFile` is path-relative to the caller's file. A typo in
    // the embed path would silently grab the wrong bytes — every
    // `manager.zig` opens with the same `//! ` doc-comment shape, so
    // substring asserts alone cannot detect a swap. Byte-equality
    // against the on-disk source pins each embed path verbatim across
    // all five first-party managers — not just ARC — so any
    // single-path drift surfaces here before reaching Phase 3's
    // emission step.
    const cases = [_]struct {
        tag: zap.memory_driver.BuiltinManagerTag,
        path: []const u8,
    }{
        .{ .tag = .arc, .path = "src/memory/arc/manager.zig" },
        .{ .tag = .arena, .path = "src/memory/arena/manager.zig" },
        .{ .tag = .no_op, .path = "src/memory/no_op/manager.zig" },
        .{ .tag = .leak, .path = "src/memory/leak/manager.zig" },
        .{ .tag = .tracking, .path = "src/memory/tracking/manager.zig" },
    };
    for (cases) |c| {
        const on_disk = try std.Io.Dir.cwd().readFileAlloc(
            std.Options.debug_io,
            c.path,
            std.testing.allocator,
            .limited(16 * 1024 * 1024),
        );
        defer std.testing.allocator.free(on_disk);
        const embedded = getBuiltinManagerSource(c.tag).?;
        try std.testing.expectEqualSlices(u8, on_disk, embedded);
    }
}

test "Phase 2: every first-party manager source opens with a doc-comment header and imports std" {
    // Pins the file-shape contract documented in every first-party
    // `manager.zig` header: the file is self-contained (imports std)
    // and is a Zig source file (opens with a doc-comment). Both
    // signatures must be present in every embedded source — a future
    // refactor that, say, splits the file or strips the header would
    // be caught here before reaching Phase 3's emission step.
    const doc_comment_needle = "//! ";
    const std_import_needle = "const std = @import(\"std\");";
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arc, .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const source = getBuiltinManagerSource(tag).?;
        try std.testing.expect(std.mem.startsWith(u8, source, doc_comment_needle));
        try std.testing.expect(std.mem.indexOf(u8, source, std_import_needle) != null);
    }
}

// ---------------------------------------------------------------------------
// Phase 3 — per-user-binary active-manager source registration. Each Zap
// user binary registers exactly one Zig module named `zap_active_manager`
// alongside the runtime: for a first-party manager the module IS the
// manager's `manager.zig` source (Phase 4's comptime branches call into
// it directly so LLVM can inline through the boundary); for third-party
// managers it is a minimal stub (Phase 4's comptime branches route
// through the manager-`.o`'s vtable instead and never touch the stub's
// symbols). These tests pin the registration contract end-to-end:
//   * `getActiveManagerSourceBytes` returns the right bytes for every tag.
//   * `getRuntimeSource` rewrites the runtime's `ACTIVE_MANAGER_TAG`
//     marker per resolved manager and treats the tag as part of the
//     cache key so two builds with different tags never alias the same
//     rewritten source slice.
// ---------------------------------------------------------------------------

test "Phase 3: getActiveManagerSourceBytes returns embedded source for first-party tags" {
    // Phase 3's first-party path simply forwards to
    // `getBuiltinManagerSource`'s embedded bytes — the active-manager
    // registration MUST hand the Zig compiler the same backing storage
    // the embed-time switch produced so the test suite, the build
    // pipeline, and the watch-mode incremental path all see the same
    // bytes. Pointer equality (not just slice equality) pins that there
    // is no hidden copy or allocator buffer on the first-party path —
    // any divergence would mean a future caller could pass a stale
    // pointer through to `zir_compilation_add_struct_source`.
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arc, .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const embedded = getBuiltinManagerSource(tag).?;
        const active = getActiveManagerSourceBytes(tag);
        try std.testing.expectEqual(embedded.ptr, active.ptr);
        try std.testing.expectEqual(embedded.len, active.len);
    }
}

test "Phase 3: getActiveManagerSourceBytes returns a valid Zig stub for third_party" {
    // Third-party managers route every retain/release through the
    // manager `.o`'s `.zapmem`-registered vtable, but the runtime's
    // top-level `@import("zap_active_manager")` still needs to resolve
    // — so Phase 3 registers a minimal Zig stub under that name. The
    // stub must be (a) non-empty and (b) a valid Zig source unit (it
    // gets fed to the Zig compiler via `zir_compilation_add_struct_source`).
    // We pin both invariants here: a regression that emits empty bytes
    // would break the `addStructSource` call, and a regression that
    // emits non-Zig text would surface as a Sema parse error during
    // every third-party user-binary build.
    const stub = getActiveManagerSourceBytes(.third_party);
    try std.testing.expect(stub.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, stub, "const std = @import(\"std\")") != null);
}

test "Phase 3: getRuntimeSource rewrites RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT to the requested tag" {
    // The runtime ships with `.third_party` as the source-level default
    // so the host test suite — which loads `runtime.zig` as a Zig
    // module without going through `getRuntimeSource` — naturally
    // exercises the vtable path. For every Zap user binary the rewrite
    // replaces the marker with the resolved tag so Phase 4's comptime
    // branches in `runtime.zig` see the right case at compile time.
    // The rewrite must produce the exact `.<tag>` literal AND drop the
    // original `.third_party` literal — a no-op rewrite would silently
    // leave every first-party build dispatching through the vtable
    // path, defeating the whole inlining motivation behind Phases 3-4.
    const cases = [_]struct {
        tag: zap.memory_driver.BuiltinManagerTag,
        name: []const u8,
    }{
        .{ .tag = .arc, .name = "arc" },
        .{ .tag = .arena, .name = "arena" },
        .{ .tag = .no_op, .name = "no_op" },
        .{ .tag = .leak, .name = "leak" },
        .{ .tag = .tracking, .name = "tracking" },
    };
    for (cases) |c| {
        const src = getRuntimeSource(0, c.tag);
        var expected_buf: [256]u8 = undefined;
        const expected = std.fmt.bufPrint(
            &expected_buf,
            "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .{s};",
            .{c.name},
        ) catch unreachable;
        try std.testing.expect(std.mem.indexOf(u8, src, expected) != null);
        const original = "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .third_party;";
        try std.testing.expect(std.mem.indexOf(u8, src, original) == null);
    }
}

test "Phase 3: getRuntimeSource preserves the .third_party marker for third-party builds" {
    // The third-party path is a deliberate identity rewrite: the
    // resolved tag IS `.third_party`, so the rewritten source must
    // still contain the original marker verbatim. We test this
    // explicitly (rather than skipping the rewrite for `.third_party`)
    // because the rewrite path is self-validating only when it always
    // runs — a future bug that silently no-ops the rewrite on
    // `.third_party` would not be caught by the first-party assertions
    // alone.
    const src = getRuntimeSource(0, .third_party);
    const expected = "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .third_party;";
    try std.testing.expect(std.mem.indexOf(u8, src, expected) != null);
}

test "Phase 3: getRuntimeSource cache key separates by builtin_tag" {
    // The rewrite cache keys on (instrumented, declared_caps, builtin_tag).
    // Two builds with identical declared_caps but different tags MUST
    // produce distinct cached buffers — otherwise the builder and full-
    // build phases would alias the wrong rewrite for the second build
    // in a multi-target run (a `zap build foo` followed by
    // `zap build bar` from the same compiler process), silently
    // injecting the wrong manager source into one of them. Pointer
    // inequality is the strongest invariant the cache layer can
    // expose to a black-box test.
    const arc_src = getRuntimeSource(0, .arc);
    const arena_src = getRuntimeSource(0, .arena);
    try std.testing.expect(arc_src.ptr != arena_src.ptr);
}

test "Phase 3: getRuntimeSource applies both caps and tag rewrites in one pass" {
    // The Phase 6 caps rewrite (stage 2) and the Phase 3 tag rewrite
    // (stage 3) chain through the same allocator-owned buffer in a
    // single `rewriteRuntimeSource` call. A regression that drops
    // either stage — or runs them against the wrong intermediate
    // buffer — would let the other stage's marker survive untouched
    // in the returned slice. Pin the end-to-end invariant by asserting
    // BOTH rewritten literals appear together for an ARC build with
    // `REFCOUNT_V1` set: the caps literal `0x1` from stage 2 AND the
    // matching `.arc` tag literal from stage 3 must both be present.
    const src = getRuntimeSource(0x1, .arc);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .arc;") != null);
}

// ---------------------------------------------------------------------------
// Phase 4 — uniform first-party manager interface. Each first-party
// `manager.zig` exposes the same set of public symbols (`init`, `deinit`,
// `allocate`, `deallocate`, `allocateRefcounted`, `retain`, `release`,
// `retainSized`, `releaseSized`, `refcountSized`, `getCapabilityDesc`)
// so the runtime's comptime dispatch in `src/runtime.zig` can call into
// the active manager's hot paths through `@import("zap_active_manager")`
// uniformly. The runtime arm that selects the direct-call path
// (`if (comptime ACTIVE_MANAGER_TAG != .third_party)`) compiles only
// when these symbols all resolve; the third-party stub
// (`src/zap_active_manager_stub.zig`) must mirror the same interface.
// These tests pin the symbol set across every embedded source so a
// future refactor that drops one of the aliases is caught at the
// compile-test boundary rather than at the user-binary compile.
// ---------------------------------------------------------------------------

test "Phase 4: every first-party manager source exposes the uniform interface aliases" {
    // The Phase 4 runtime dispatch arm calls `active_manager.<fn>(...)`
    // for each of these names. A missing alias in any first-party
    // `manager.zig` would break the user-binary compile for that
    // manager but would NOT be caught by the host test suite (which
    // loads `runtime.zig` against the third-party stub instead). This
    // test pins the symbol set across all five first-party sources
    // so a missing alias surfaces immediately.
    //
    // The substring shape (`pub const <name> =`) is the canonical
    // declaration pattern documented in `src/memory/arc/manager.zig`.
    // The first-party managers route their `init`/`deinit`/...
    // aliases at the **bottom of the file** where the implementing
    // functions are already in scope; a regression that moves the
    // aliases above the function definitions (an order-of-declaration
    // mistake) would surface during the user-binary compile, but the
    // substring check here catches the simpler "alias missing
    // entirely" regression.
    const uniform_aliases = [_][]const u8{
        "pub const init = ",
        "pub const deinit = ",
        "pub const allocate = ",
        "pub const deallocate = ",
        "pub const allocateRefcounted = ",
        "pub const retain = ",
        "pub const release = ",
        "pub const retainSized = ",
        "pub const releaseSized = ",
        "pub const refcountSized = ",
        "pub const getCapabilityDesc = ",
    };
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arc, .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const source = getBuiltinManagerSource(tag).?;
        for (uniform_aliases) |needle| {
            if (std.mem.indexOf(u8, source, needle) == null) {
                std.debug.print(
                    "\n  manager tag={s} is missing uniform alias `{s}`\n",
                    .{ @tagName(tag), needle },
                );
                try std.testing.expect(false);
            }
        }
    }
}

test "Phase 4: third-party stub exposes the uniform interface as pub fn declarations" {
    // The third-party stub's panic functions are declared with
    // `pub fn <name>(...)` (rather than `pub const <name> = ...`)
    // because each function has a body. Either declaration form
    // would satisfy the runtime's `active_manager.<fn>(...)` call
    // site, but the stub uses `pub fn` so the source reads as
    // intentionally unreachable defensive code rather than an alias
    // table. Pin both contracts here: the stub must declare every
    // name on the uniform interface, AND every panic body must
    // mention `unreachable` so a reader knows the call site is by
    // design dead.
    const stub_source = getActiveManagerSourceBytes(.third_party);
    const uniform_pub_fn_aliases = [_][]const u8{
        "pub fn init(",
        "pub fn deinit(",
        "pub fn allocate(",
        "pub fn deallocate(",
        "pub fn allocateRefcounted(",
        "pub fn retain(",
        "pub fn release(",
        "pub fn retainSized(",
        "pub fn releaseSized(",
        "pub fn refcountSized(",
        "pub fn getCapabilityDesc(",
    };
    for (uniform_pub_fn_aliases) |needle| {
        if (std.mem.indexOf(u8, stub_source, needle) == null) {
            std.debug.print(
                "\n  third-party stub is missing uniform alias `{s}`\n",
                .{needle},
            );
            try std.testing.expect(false);
        }
    }
    // Every stub body @panics with an "unreachable" diagnostic; pin
    // the substring so a regression that swaps a panic for a real
    // implementation (which would silently mis-route under a
    // `.third_party` build) is caught at the source level.
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "unreachable") != null);
}

test "Phase 4: managers without REFCOUNT_V1 declare panic stubs that name the missing capability" {
    // The four first-party managers that do NOT declare REFCOUNT_V1
    // (Arena, NoOp, Leak, Tracking) expose the uniform interface with
    // panic stubs in place of the refcount slot aliases. The stub
    // bodies must mention `REFCOUNT_V1` so a regression that bypasses
    // codegen elision and reaches one of these stubs surfaces with a
    // clear diagnostic naming the missing capability — not an
    // anonymous "panic" with no actionable signal.
    const tags = [_]zap.memory_driver.BuiltinManagerTag{ .arena, .no_op, .leak, .tracking };
    for (tags) |tag| {
        const source = getBuiltinManagerSource(tag).?;
        try std.testing.expect(std.mem.indexOf(u8, source, "REFCOUNT_V1") != null);
        // The diagnostic phrase is shared across every panic stub —
        // see `src/memory/arena/manager.zig` for the canonical
        // wording. Match a substring of that wording so an
        // accidental message change in one stub surfaces here.
        try std.testing.expect(std.mem.indexOf(u8, source, "codegen should have elided this call") != null);
    }
}

test "Phase 4: ARC manager's uniform interface aliases name the real implementation functions" {
    // ARC is the only first-party manager that declares REFCOUNT_V1;
    // its uniform-interface aliases must point at the real
    // implementation functions (`arcInit`, `arcRetainSized`, ...)
    // rather than at panic stubs. A regression that aliased a panic
    // stub instead would silently regress every ARC build's
    // retain/release into an immediate process crash.
    const source = getBuiltinManagerSource(.arc).?;
    const real_alias_pairs = [_]struct { alias: []const u8, target: []const u8 }{
        .{ .alias = "pub const init = ", .target = "arcInit" },
        .{ .alias = "pub const deinit = ", .target = "arcDeinit" },
        .{ .alias = "pub const allocate = ", .target = "arcAllocate" },
        .{ .alias = "pub const deallocate = ", .target = "arcDeallocate" },
        .{ .alias = "pub const allocateRefcounted = ", .target = "arcAllocateRefcounted" },
        .{ .alias = "pub const retain = ", .target = "arcRetain" },
        .{ .alias = "pub const release = ", .target = "arcRelease" },
        .{ .alias = "pub const retainSized = ", .target = "arcRetainSized" },
        .{ .alias = "pub const releaseSized = ", .target = "arcReleaseSized" },
        .{ .alias = "pub const refcountSized = ", .target = "arcRefcountSized" },
        .{ .alias = "pub const getCapabilityDesc = ", .target = "arcGetCapabilityDesc" },
    };
    for (real_alias_pairs) |pair| {
        // Build the expected line literal and assert it appears
        // verbatim — pointer equality of the alias name and the
        // implementation function name pins both ends of the alias
        // table.
        var buf: [128]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "{s}{s};", .{ pair.alias, pair.target }) catch unreachable;
        if (std.mem.indexOf(u8, source, expected) == null) {
            std.debug.print(
                "\n  ARC manager is missing the alias line `{s}`\n",
                .{expected},
            );
            try std.testing.expect(false);
        }
    }
}

test "Phase 4: managers without REFCOUNT_V1 alias panic stubs for the capability functions" {
    // Symmetric to the ARC alias test above. Arena, NoOp, Leak, and
    // Tracking declare `declared_caps = 0`, so their refcount-aliased
    // names (`retain`, `release`, `retainSized`, `releaseSized`,
    // `refcountSized`, `allocateRefcounted`) MUST resolve to
    // panic-stub functions — never to a real refcount routine. The
    // panic-stub convention Phase 4 established is the `Stub` name
    // suffix (e.g. `arenaRetainStub`); pinning that substring at the
    // alias-arrow site catches a regression that wired a real
    // refcount impl into a non-REFCOUNT manager (which would
    // silently misbehave at runtime under those builds).
    const non_refcount_managers = [_]struct {
        tag: zap.memory_driver.BuiltinManagerTag,
        name: []const u8,
    }{
        .{ .tag = .arena, .name = "arena" },
        .{ .tag = .no_op, .name = "no_op" },
        .{ .tag = .leak, .name = "leak" },
        .{ .tag = .tracking, .name = "tracking" },
    };

    const refcount_aliases = [_][]const u8{
        "pub const retain = ",
        "pub const release = ",
        "pub const retainSized = ",
        "pub const releaseSized = ",
        "pub const refcountSized = ",
        "pub const allocateRefcounted = ",
    };

    for (non_refcount_managers) |mgr| {
        const source = getBuiltinManagerSource(mgr.tag).?;
        for (refcount_aliases) |needle| {
            const idx = std.mem.indexOf(u8, source, needle) orelse {
                std.debug.print(
                    "\n  {s} manager is missing the alias line beginning `{s}`\n",
                    .{ mgr.name, needle },
                );
                try std.testing.expect(false);
                return;
            };
            const semi = std.mem.indexOfScalarPos(u8, source, idx, ';') orelse source.len;
            const alias_line = source[idx..semi];
            if (std.mem.indexOf(u8, alias_line, "Stub") == null) {
                std.debug.print(
                    "\n  {s} manager alias `{s}` does NOT name a panic stub: `{s}`\n",
                    .{ mgr.name, needle, alias_line },
                );
                try std.testing.expect(false);
                return;
            }
        }
    }
}
