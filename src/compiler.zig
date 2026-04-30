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

pub const CompileResult = struct {
    ir_program: ir.Program,
    analysis_context: ?zap.escape_lattice.AnalysisContext = null,
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
    /// Module names in dependency order for CTFE evaluation.
    /// When set, computed attributes are evaluated per-module in this order.
    module_order: ?[]const []const u8 = null,
    /// Indices into module_order marking where each dependency level ends.
    /// Modules within the same level have no dependencies on each other
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
    /// modules within the same dependency level are compiled concurrently
    /// using Io.Group.
    io: ?std.Io = null,
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
//   Pass 2 (compileForCtfe / compileModuleByModule): Run the
//     post-collect pipeline. The phase methods on `Pipeline` handle
//     the shared front-end (substitute → macro → desugar →
//     re-collect → type check → HIR → mono → IR), and each entry
//     point composes the phases it needs and adds its own divergent
//     steps (build-time CTFE re-checks types after analysis; per-
//     module compilation runs whole-program monomorphization once
//     across all modules).
//   Pass 3 (analysis + contify): Last phase of pass 2 — escape /
//     alias analysis, contification rewrite, and (for compileForCtfe)
//     a borrow re-check.
// ============================================================

/// Shared compilation state from Pass 1. Holds the scope graph, type store,
/// and interner that all files compile against.
pub const CompilationContext = struct {
    alloc: std.mem.Allocator,

    // ---- Parallel views into the same compilation. Each lives at a
    // different granularity (whole-program AST / per-module AST /
    // per-file metadata / per-file source / per-module scope), and
    // they're populated at different points during `collectAll`.
    // Always call the corresponding `findX` helper instead of
    // iterating the slice directly so the lookup convention has one
    // home.

    /// Whole-program merged AST — every `pub struct` from every source
    /// file lives in `.structs`, and every top-level `impl` lives in
    /// `.top_items`. Source of truth for macro expansion, scope
    /// collection, and CTFE; downstream phases mostly read from the
    /// per-module split below.
    merged_program: ast.Program,

    /// Per-module AST programs split out of `merged_program` after
    /// macro expansion / desugaring. Keyed by `name` (the dotted
    /// module path). The per-module pipeline reads from here so it
    /// does not need to re-walk the merged tree at every stage.
    module_programs: []const ModuleProgram,

    /// Per-file compilation state: source path, owning module, the
    /// raw file source, and (when produced) the per-file IR program.
    /// `units.len == source_units.len`; one unit per file.
    units: []CompilationUnit,

    /// Original per-file source units used to drive parsing and to
    /// resolve span → file mappings in diagnostics.
    source_units: []const SourceUnit,

    /// String interner shared across all parsed source units.
    interner: ast.StringInterner,

    /// Scope graph populated by the collector. `collector.graph.structs`
    /// is the per-module scope view (one entry per module containing
    /// its `ScopeId`, declared functions, and attributes); the graph
    /// also holds bindings, function families, types, protocols, and
    /// impls. The scope graph and `module_programs` always stay in
    /// sync — same modules, different views.
    collector: zap.Collector,

    /// Diagnostic engine — collects errors and warnings emitted across
    /// every phase before they're rendered to the user.
    diag_engine: zap.DiagnosticEngine,
};

pub const ModuleProgram = struct {
    name: []const u8,
    program: ast.Program,
};

/// Per-file compilation state.
pub const CompilationUnit = struct {
    file_path: []const u8,
    module_name: []const u8,
    source: []const u8,
    /// Index of this file's module in the merged program's modules array
    module_index: ?u32 = null,
    /// Per-file IR program, populated by compileFile
    ir_program: ?ir.Program = null,
    /// Which dep this file belongs to (null for project files)
    dep: ?[]const u8 = null,
};

/// Result of compiling a single module to HIR (before monomorphization).
/// Used by whole-program monomorphization to collect all module HIRs,
/// then monomorphize across module boundaries.
pub const ModuleHirResult = struct {
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
        try graph.registerSourceFile(@intCast(source_index), unit.file_path);
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

    // Intern the auto-imported Kernel module's name once — needed for
    // auto-import injection. The literal name lives in
    // `discovery.kernel_module_name`.
    const kernel_name_id = try interner.intern(zap.discovery.kernel_module_name);
    var collector = zap.Collector.init(alloc, &interner, kernel_name_id);
    try registerSourceUnits(&collector.graph, all_source_units);
    {
        const pre_module_programs = try buildModulePrograms(alloc, &program, &interner);

        // Collect Kernel FIRST so its scope exists when other modules'
        // auto-import resolves. This mirrors Elixir's bootstrap ordering.
        for (pre_module_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_module_name)) {
                collector.collectProgramSurface(&entry.program) catch {};
                break;
            }
        }
        for (pre_module_programs) |entry| {
            if (std.mem.eql(u8, entry.name, zap.discovery.kernel_module_name)) continue;
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
        // Validate protocol conformance and register impl functions in target modules
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

        const pre_slices = try alloc.alloc(ast.Program, pre_module_programs.len);
        for (pre_module_programs, 0..) |entry, i| pre_slices[i] = entry.program;
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

    // Run macro expansion and desugaring. When the discovery graph supplies a
    // module order, expand one module at a time and compile each completed
    // dependency level to IR so later macros can call already compiled Zap
    // functions through CTFE. Without a graph order, keep the legacy merged
    // expansion path.
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Macro expand", .{ step, total_steps });

    const desugared_program = if (options.module_order) |module_order|
        stagedMacroExpandAndDesugar(
            alloc,
            &program,
            module_order,
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

    // NOW split into per-module programs from the expanded/desugared AST.
    // All if_expr nodes are gone, all pipes desugared, all macros expanded.
    const module_programs = try buildModulePrograms(alloc, &desugared_program, &interner);

    // Rebuild the scope graph from the desugared AST. The original collector
    // was built from pre-expansion AST, so its function declaration pointers
    // are stale. The HIR builder compares AST node pointers to determine
    // which functions belong to the current module, so the scope graph must
    // reference the same AST nodes as the desugared module programs.
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Re-collect", .{ step, total_steps });

    var final_collector = zap.Collector.init(alloc, &interner, kernel_name_id);
    try registerSourceUnits(&final_collector.graph, all_source_units);
    // Collect Kernel first in the second pass too
    for (module_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_module_name)) {
            final_collector.collectProgramSurface(&entry.program) catch {};
            break;
        }
    }
    for (module_programs) |entry| {
        if (std.mem.eql(u8, entry.name, zap.discovery.kernel_module_name)) continue;
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
    // Re-register impl functions in their target module scopes. The first
    // collector did this on its own graph, but the final_collector built a
    // fresh graph and per-module HIR/type-check reads from THIS graph. Without
    // re-registration, impl functions like `Integer.+` are invisible.
    final_collector.validateImplConformance() catch {};
    final_collector.registerImplFunctionsInTargetScopes() catch {};
    {
        const slices = try alloc.alloc(ast.Program, module_programs.len);
        for (module_programs, 0..) |entry, i| slices[i] = entry.program;
        final_collector.finalizeCollectedPrograms(slices) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }

    const units = try buildCompilationUnits(alloc, module_programs, all_source_units);

    return .{
        .alloc = alloc,
        .merged_program = desugared_program,
        .module_programs = module_programs,
        .units = units,
        .source_units = all_source_units,
        .interner = interner,
        .collector = final_collector,
        .diag_engine = diag_engine,
    };
}

/// Compile the build.zap manifest through the full pipeline.
/// This is ONLY used by the builder for CTFE manifest evaluation —
/// NOT for project compilation. Project compilation uses compileModuleByModule.
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
    var ir_program = try pipeline.runIrLowering(&mono_program, type_checker.store);

    pipeline.runCtfeAttributes(&ir_program, options.module_order);

    var analysis_result = try pipeline.runAnalysisAndContify(&ir_program);

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

    return .{ .ir_program = ir_program, .analysis_context = analysis_result.context };
}

// ============================================================
// Pipeline — phase orchestration for the post-collect compiler
//
// `Pipeline` holds the shared state every phase needs (allocator,
// CompilationContext, options, progress counter) and exposes one
// method per phase. Each entry point — `compileForCtfe` for the
// build-time manifest pass, `compileModuleByModule` for project
// compilation — composes the phases it needs in the order it needs
// them, including divergent steps. The intentional differences
// (compileForCtfe re-checks types after escape analysis to catch
// borrow diagnostics; the per-module path skips
// `checkUnusedBindings` because the shared scope graph would
// produce false positives across modules) live at the call site,
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
    /// per-module pipelines don't trip on residual errors from earlier
    /// modules sharing the same DiagnosticEngine.
    error_baseline: usize,
    /// When true, `failWith`/`failWithExisting` accumulate errors into the
    /// engine but do not flush them to stderr. Used by the per-module
    /// loop in `compileModuleByModule`, which renders all collected
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
    /// DiagnosticEngine accumulates across modules, so a raw
    /// `hasErrors()` check would treat any prior module's failures as
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
    /// module. Used after macro expansion or desugaring introduces
    /// helpers (e.g., `__for_N` from for-comprehensions) that need a
    /// scope before HIR lowering can resolve their callsites — the
    /// HIR builder compares AST node pointers to determine which
    /// functions belong to the current module, so the scope graph
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
    /// is either shared across modules (`shared_store != null`, used
    /// by the whole-program monomorphization path so call-site
    /// inferred signatures travel between modules) or owned by the
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
            // Per-module typecheck reuses the shared store; clear
            // call-site-specific inferred signatures from the previous
            // module so they don't leak between modules.
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
    /// IDs across modules; pass 0 for a single-module run.
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

    fn runIrLowering(
        self: *Pipeline,
        hir_program: *const zap.hir.Program,
        type_store: *zap.types.TypeStore,
    ) CompileError!ir.Program {
        self.progress("IR");
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, &self.ctx.interner);
        ir_builder.type_store = type_store;
        ir_builder.scope_graph = &self.ctx.collector.graph;
        defer ir_builder.deinit();
        return ir_builder.buildProgram(hir_program) catch
            self.failWith("Error during IR lowering", error.IrFailed);
    }

    /// Per-module IR build variant that threads a globally-unique
    /// `__try` ID counter across module boundaries. Without this,
    /// each per-module IR build would derive `next_try_id` from the
    /// per-module max group ID and a `__try` variant produced for
    /// module A's multi-clause function could share the ID of module
    /// B's regular HIR group, causing call_direct dispatches to
    /// resolve to the wrong function.
    fn runIrLoweringWithTryIdSeed(
        self: *Pipeline,
        hir_program: *const zap.hir.Program,
        type_store: *zap.types.TypeStore,
        next_try_id: *u32,
    ) CompileError!ir.Program {
        self.progress("IR");
        var ir_builder = zap.ir.IrBuilder.init(self.alloc, &self.ctx.interner);
        ir_builder.type_store = type_store;
        ir_builder.scope_graph = &self.ctx.collector.graph;
        ir_builder.next_try_id = next_try_id.*;
        defer ir_builder.deinit();
        const program = ir_builder.buildProgram(hir_program) catch
            return self.failWith("Error during IR lowering", error.IrFailed);
        next_try_id.* = ir_builder.next_try_id;
        return program;
    }

    /// CTFE attribute evaluation across the whole IR program. When a
    /// `module_order` is supplied each module's attributes are
    /// evaluated in dependency order so each module can read its
    /// dependencies' resolved values; otherwise the legacy
    /// whole-program evaluator runs. CTFE errors are emitted through
    /// the CTFE module's own path, so the return is best-effort.
    fn runCtfeAttributes(
        self: *Pipeline,
        ir_program: *ir.Program,
        module_order: ?[]const []const u8,
    ) void {
        const cache_dir = self.options.cache_dir;
        const opts_hash = ctfeCompileOptionsHash(self.options);
        if (module_order) |order| {
            _ = zap.ctfe.evaluateModuleAttributesInOrder(
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

    /// Per-module CTFE used when each module's IR is built in
    /// isolation. Surfaces any errors directly through the CTFE
    /// emit path.
    fn runCtfeAttributesForModule(
        self: *Pipeline,
        mod_name: []const u8,
        mod_ir: *ir.Program,
    ) void {
        const ctfe_result = zap.ctfe.evaluateComputedAttributesForModule(
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

/// Compile a single module's AST through attribute substitution → type
/// check → HIR build. Used by `compileModuleByModule`'s phase-1 loop
/// to gather every module's HIR before whole-program monomorphization.
fn compileSingleModuleHir(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    mod_program: *const ast.Program,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
    options: CompileOptions,
) CompileError!ModuleHirResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    const desugared = try pipeline.runSubstitute(mod_program);

    // checkUnusedBindings is intentionally skipped — the type checker
    // shares the scope graph across modules but only visits the
    // current module's bindings, so checking all bindings here would
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
/// attributes for the module so downstream modules can read the
/// resolved values. Per-module half of the IR-lowering loop in
/// `compileModuleByModule`.
fn compileHirToIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    hir_program: *const zap.hir.Program,
    type_store: *zap.types.TypeStore,
    options: CompileOptions,
    next_try_id: *u32,
) CompileError!ir.Program {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;
    var mod_ir = try pipeline.runIrLoweringWithTryIdSeed(hir_program, type_store, next_try_id);
    pipeline.runCtfeAttributesForModule(mod_name, &mod_ir);
    return mod_ir;
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
    module_order: []const []const u8,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
) CompileError!ast.Program {
    const original_modules = buildModulePrograms(alloc, program, interner) catch return error.OutOfMemory;
    var expanded_modules: std.ArrayListUnmanaged(ModuleProgram) = .empty;
    var seen_modules = std.StringHashMap(void).init(alloc);

    var cumulative_ir = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };
    var compiled_executor = @import("macro.zig").CompiledMacroExecutor.init(alloc, &cumulative_ir);
    defer compiled_executor.deinit();

    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, interner);

    var hir_results: std.ArrayListUnmanaged(ModuleHirResult) = .empty;
    var group_id_offset: u32 = 0;

    for (module_order) |module_name| {
        const original = lookupModuleProgramInSlice(original_modules, module_name) orelse continue;
        const desugared = try expandAndDesugarStagedModule(
            alloc,
            original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
        );
        try expanded_modules.append(alloc, .{ .name = original.name, .program = desugared });
        try seen_modules.put(original.name, {});

        const hir_result = try compileStagedModuleHir(
            alloc,
            &desugared,
            original.name,
            interner,
            collector,
            diag_engine,
            shared_store,
            group_id_offset,
        );
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
    }

    for (original_modules) |original| {
        if (seen_modules.contains(original.name)) continue;
        const desugared = try expandAndDesugarStagedModule(
            alloc,
            &original,
            interner,
            collector,
            diag_engine,
            &compiled_executor,
        );
        try expanded_modules.append(alloc, .{ .name = original.name, .program = desugared });
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
    const slices = try alloc.alloc(ast.Program, expanded_modules.items.len + extra_top_level_count);
    for (expanded_modules.items, 0..) |entry, index| {
        slices[index] = entry.program;
    }
    if (top_level_program) |top_program| {
        slices[expanded_modules.items.len] = top_program;
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

fn expandAndDesugarStagedModule(
    alloc: std.mem.Allocator,
    module_program: *const ModuleProgram,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    compiled_executor: *@import("macro.zig").CompiledMacroExecutor,
) CompileError!ast.Program {
    const error_baseline = diag_engine.errorCount();

    var macro_engine = zap.MacroEngine.init(alloc, interner, &collector.graph);
    defer macro_engine.deinit();
    macro_engine.setCompiledExecutor(compiled_executor);
    const expanded = macro_engine.expandProgram(&module_program.program) catch {
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
        for (program.structs) |module| {
            if (structNamesEqual(module.name, entry.target_type)) {
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

fn compileStagedModuleHir(
    alloc: std.mem.Allocator,
    desugared: *const ast.Program,
    module_name: []const u8,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    diag_engine: *zap.DiagnosticEngine,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
) CompileError!ModuleHirResult {
    const error_baseline = diag_engine.errorCount();
    if (findUndesugaredMacroForm(desugared) orelse findUndesugaredMacroFormInGraphImpls(&collector.graph, desugared)) |form| {
        diag_engine.err(
            std.fmt.allocPrint(
                alloc,
                "staged macro expansion left raw `{s}` before HIR in `{s}`",
                .{ form.name, module_name },
            ) catch "staged macro expansion left raw macro form before HIR",
            form.span,
        ) catch {};
        return error.MacroExpansionFailed;
    }
    shared_store.inferred_signatures.clearRetainingCapacity();

    var type_checker = zap.types.TypeChecker.initWithSharedStore(alloc, shared_store, interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.checkProgram(desugared) catch {};
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
    const hir_program = hir_builder.buildProgram(desugared) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        return error.HirFailed;
    };
    for (hir_builder.errors.items) |hir_err| {
        diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (diag_engine.errorCount() > error_baseline) return error.HirFailed;

    return .{
        .mod_name = module_name,
        .hir_program = hir_program,
        .next_group_id = hir_builder.next_group_id,
    };
}

const UndesugaredMacroForm = struct {
    name: []const u8,
    span: ast.SourceSpan,
};

fn findUndesugaredMacroForm(program: *const ast.Program) ?UndesugaredMacroForm {
    for (program.structs) |module| {
        for (module.items) |item| {
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
        for (program.structs) |module| {
            if (structNamesEqual(module.name, impl_entry.target_type)) {
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
    hir_results: []const ModuleHirResult,
    interner: *ast.StringInterner,
    collector: *zap.Collector,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
) CompileError!ir.Program {
    var all_hir_modules: std.ArrayListUnmanaged(zap.hir.Module) = .empty;
    var all_hir_top_fns: std.ArrayListUnmanaged(zap.hir.FunctionGroup) = .empty;
    var all_hir_protocols: std.ArrayListUnmanaged(zap.hir.ProtocolInfo) = .empty;
    var all_hir_impls: std.ArrayListUnmanaged(zap.hir.ImplInfo) = .empty;
    for (hir_results) |*result| {
        for (result.hir_program.modules) |mod| {
            all_hir_modules.append(alloc, mod) catch return error.OutOfMemory;
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
        .modules = all_hir_modules.toOwnedSlice(alloc) catch return error.OutOfMemory,
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
    return ir_builder.buildProgram(&combined_hir) catch return error.IrFailed;
}

fn lookupModuleProgramInSlice(module_programs: []const ModuleProgram, module_name: []const u8) ?*const ModuleProgram {
    for (module_programs) |*entry| {
        if (std.mem.eql(u8, entry.name, module_name)) return entry;
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

/// True per-module compilation: process each module independently through
/// macro → desugar → typecheck → HIR → IR, in dependency order.
///
/// After each module's IR is built, runs CTFE on its computed attributes
/// and registers the results for downstream modules to reference.
///
/// This is the architecture described in ir-interpreter-plan.md Phase 5:
/// "split macro expansion, desugaring, typechecking, HIR, and IR lowering
/// into real per-module units."
///
/// Requires that collectAll has already populated the shared scope graph
/// with all modules' declarations. Each module compiles against the full
/// scope graph (for cross-module type resolution) but only processes its
/// own AST through the pipeline.
pub fn compileModuleByModule(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    module_order: []const []const u8,
    options: CompileOptions,
) CompileError!CompileResult {
    var pipeline = Pipeline.init(alloc, ctx, options, 0, 0);
    pipeline.defer_render = true;

    // Collect all IR functions and type defs across modules.
    var all_functions: std.ArrayListUnmanaged(ir.Function) = .empty;
    var all_type_defs: std.ArrayListUnmanaged(ir.TypeDef) = .empty;
    var entry_id: ?ir.FunctionId = null;

    // Shared TypeStore + globally-unique group IDs pipeline.
    const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
    shared_store.* = zap.types.TypeStore.init(alloc, &ctx.interner);

    // Phase 1: every module → HIR. Shared TypeStore and globally-
    // unique group IDs let later phases monomorphize across module
    // boundaries.
    var hir_results: std.ArrayListUnmanaged(ModuleHirResult) = .empty;
    var group_id_offset: u32 = 0;
    for (module_order, 0..) |mod_name, mod_idx| {
        if (options.show_progress) {
            std.debug.print("\r\x1b[K  [hir {d}/{d}] {s}", .{ mod_idx + 1, module_order.len, mod_name });
        }
        const mod_program = lookupModuleProgram(ctx, mod_name) orelse continue;
        // Per-module failures are routed through the diagnostic
        // engine inside the helper; the loop continues so other
        // modules still compile and the user sees as many errors as
        // possible in one run.
        const hir_result = compileSingleModuleHir(alloc, ctx, mod_name, mod_program, shared_store, group_id_offset, options) catch continue;
        group_id_offset = hir_result.next_group_id;
        hir_results.append(alloc, hir_result) catch return error.OutOfMemory;
    }

    // Phase 2: merge per-module HIR programs.
    var all_hir_modules: std.ArrayListUnmanaged(zap.hir.Module) = .empty;
    var all_hir_top_fns: std.ArrayListUnmanaged(zap.hir.FunctionGroup) = .empty;
    var all_hir_protocols: std.ArrayListUnmanaged(zap.hir.ProtocolInfo) = .empty;
    var all_hir_impls: std.ArrayListUnmanaged(zap.hir.ImplInfo) = .empty;
    for (hir_results.items) |*result| {
        for (result.hir_program.modules) |mod| {
            all_hir_modules.append(alloc, mod) catch return error.OutOfMemory;
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
        .modules = all_hir_modules.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .top_functions = all_hir_top_fns.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .protocols = all_hir_protocols.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .impls = all_hir_impls.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };

    // Phase 3: whole-program monomorphization.
    var mono_next = group_id_offset;
    combined_hir = try pipeline.runMonomorphize(&combined_hir, shared_store, &mono_next);

    // Phase 4: each module's HIR → IR. Function IDs are already
    // globally unique from the HIR stage (group_id_offset advancement
    // in phase 1), so no cloneWithOffset is needed — collect
    // functions directly. `next_try_id` is threaded across modules so
    // synthesized `__try` variants get globally unique IDs that don't
    // collide with another module's regular HIR groups.
    var next_try_id: u32 = mono_next;
    for (combined_hir.modules) |mod| {
        const single_mod_hir = zap.hir.Program{
            .modules = try alloc.dupe(zap.hir.Module, &.{mod}),
            .top_functions = &.{},
        };
        const mod_name_str = if (mod.name.parts.len > 0) ctx.interner.get(mod.name.parts[mod.name.parts.len - 1]) else "unknown";
        const mod_ir = compileHirToIr(alloc, ctx, mod_name_str, &single_mod_hir, shared_store, options, &next_try_id) catch {
            continue;
        };
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
            .modules = &.{},
            .top_functions = combined_hir.top_functions,
            .impls = combined_hir.impls,
        };
        const mod_ir = compileHirToIr(alloc, ctx, "top", &top_hir, shared_store, options, &next_try_id) catch return error.IrFailed;
        for (mod_ir.functions) |func| {
            all_functions.append(alloc, func) catch return error.OutOfMemory;
        }
        if (mod_ir.entry) |eid| entry_id = eid;
        for (mod_ir.type_defs) |td| {
            all_type_defs.append(alloc, td) catch return error.OutOfMemory;
        }
    }

    // Phase 5: analysis + contification on the merged IR.
    var merged_ir = ir.Program{
        .functions = all_functions.items,
        .type_defs = all_type_defs.items,
        .entry = entry_id,
    };
    const analysis_result = try pipeline.runAnalysisAndContify(&merged_ir);

    // Single rendering pass for all per-module diagnostics. Each
    // sub-pipeline accumulated into the shared engine without flushing,
    // so we emit exactly once here regardless of how many modules
    // failed.
    if (ctx.diag_engine.hasErrors()) {
        pipeline.clearProgress();
        emitContextDiagnostics(ctx, alloc);
    }

    return .{ .ir_program = merged_ir, .analysis_context = analysis_result.context };
}

/// Extract a single-module ast.Program from the merged program.
fn extractModuleProgram(
    alloc: std.mem.Allocator,
    merged: *const ast.Program,
    mod_name: []const u8,
    interner: *const ast.StringInterner,
) ?ast.Program {
    for (merged.structs) |mod| {
        // Build module name string from parts
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

fn buildModulePrograms(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    interner: *const ast.StringInterner,
) ![]const ModuleProgram {
    const result = try alloc.alloc(ModuleProgram, program.structs.len);
    for (program.structs, 0..) |mod, i| {
        const name = try structNameToOwnedString(alloc, mod.name, interner);
        const mods = try alloc.alloc(ast.StructDecl, 1);
        mods[0] = mod;

        // Include impl_decls whose target_type matches this module so the
        // module's HIR/IR emits the impl function bodies as part of the
        // target module's namespace. registerImplFunctionsInTargetScopes
        // makes the impl callable; this makes its body land in the right
        // module's emitted code.
        var module_top_items: std.ArrayList(ast.TopItem) = .empty;
        for (program.top_items) |item| {
            const impl = switch (item) {
                .impl_decl => |id| id,
                .priv_impl_decl => |id| id,
                else => continue,
            };
            if (structNameMatchesString(impl.target_type, name, interner)) {
                try module_top_items.append(alloc, item);
            }
        }

        result[i] = .{
            .name = name,
            .program = .{
                .structs = mods,
                .top_items = try module_top_items.toOwnedSlice(alloc),
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
    module_programs: []const ModuleProgram,
    source_units: []const SourceUnit,
) ![]CompilationUnit {
    // Build a unit for each struct by using parser source_id metadata first.
    // This stays correct when source_units also contains protocol/impl-only
    // files gathered from manifest globs.
    var units_list: std.ArrayListUnmanaged(CompilationUnit) = .empty;
    for (module_programs, 0..) |entry, mod_idx| {
        const source_idx = findSourceUnitIndex(entry, mod_idx, module_programs.len, source_units);
        const su = source_units[source_idx];
        try units_list.append(alloc, .{
            .file_path = su.file_path,
            .module_name = entry.name,
            .source = su.source,
            .module_index = @intCast(mod_idx),
            .ir_program = null,
            .dep = null,
        });
    }
    return try units_list.toOwnedSlice(alloc);
}

fn findSourceUnitIndex(
    entry: ModuleProgram,
    module_index: usize,
    module_count: usize,
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

    if (module_count == source_units.len) return module_index;

    for (source_units, 0..) |unit, source_index| {
        if (std.mem.find(u8, unit.source, entry.name)) |_| {
            return source_index;
        }
    }

    return @min(module_index, if (source_units.len > 0) source_units.len - 1 else 0);
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

fn lookupModuleProgram(ctx: *const CompilationContext, mod_name: []const u8) ?*const ast.Program {
    for (ctx.module_programs) |*entry| {
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

/// Validate that a source file contains exactly one module declaration and that the
/// module name matches the file path. Returns an error message if validation
/// fails, or null if the file is valid.
///
/// `file_path` is relative to the lib root (e.g., "config/parser.zap").
/// The expected module name is derived from the path: "config/parser.zap" → "Config.Parser".
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

    // Parse without stdlib — we only need to count module declarations
    var parser = zap.Parser.init(arena, source);

    const program = parser.parseProgram() catch {
        // Parse errors will be caught later in the full compilation.
        return null;
    };

    // Count top-level declarations (struct, protocol, or impl)
    var module_count: u32 = 0;
    var module_name_parts: ?[]const ast.StringId = null;
    var has_protocol_or_impl = false;
    for (program.top_items) |item| {
        switch (item) {
            .struct_decl => |mod| {
                // Only count module-like structs (with items), not field-only data structs
                if (mod.items.len > 0) {
                    module_count += 1;
                    module_name_parts = mod.name.parts;
                }
            },
            .priv_struct_decl => |mod| {
                if (mod.items.len > 0) {
                    module_count += 1;
                    module_name_parts = mod.name.parts;
                }
            },
            .protocol, .priv_protocol => {
                has_protocol_or_impl = true;
            },
            .impl_decl, .priv_impl_decl => {
                has_protocol_or_impl = true;
            },
            else => {},
        }
    }
    // Also count from program.structs (the parser populates both)
    if (module_count == 0) {
        for (program.structs) |mod| {
            if (mod.items.len > 0) {
                module_count += 1;
                module_name_parts = mod.name.parts;
            }
        }
    }

    // Protocol and impl files don't need a module declaration
    if (has_protocol_or_impl and module_count == 0) {
        return null;
    }

    if (module_count == 0) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one module declaration, found none", .{file_path}) catch "file has no module";
    }

    if (module_count > 1) {
        return std.fmt.allocPrint(alloc, "File `{s}` must contain exactly one module declaration, found {d}", .{ file_path, module_count }) catch "file has multiple modules";
    }

    // Build the actual module name from the AST
    const parts = module_name_parts orelse return null;
    var actual_name: std.ArrayListUnmanaged(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) actual_name.append(arena, '.') catch return null;
        actual_name.appendSlice(arena, parser.interner.get(part)) catch return null;
    }

    // Build the expected module name from the file path
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
            "Module name `{s}` does not match file path `{s}` — expected `{s}`",
            .{ actual_name.items, file_path, expected_name.items },
        ) catch "module name does not match file path";
    }

    return null;
}

/// Get the embedded runtime source.
pub fn getRuntimeSource() []const u8 {
    return runtime_source;
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
        .attribute => {},
    }
}

fn remapProtocolDecl(alloc: std.mem.Allocator, proto: *ast.ProtocolDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    // Remap protocol name parts
    const new_parts = try alloc.alloc(ast.StringId, proto.name.parts.len);
    for (proto.name.parts, 0..) |part, i| {
        new_parts[i] = if (part < remap.len) remap[part] else part;
    }
    proto.name.parts = new_parts;

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
        }
        new_sig.params = new_params;
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
            try remapStructName(alloc, &mutable.module_path, remap);
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
            try remapStructName(alloc, &mutable.module_path, remap);
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
            mutable.name = remap[attr.name];
            if (mutable.type_expr) |te| {
                const mutable_te = try alloc.create(ast.TypeExpr);
                mutable_te.* = te.*;
                try remapTypeExpr(alloc, mutable_te, remap);
                mutable.type_expr = mutable_te;
            }
            if (mutable.value) |v| {
                const mutable_v = try alloc.create(ast.Expr);
                mutable_v.* = v.*;
                try remapExpr(alloc, mutable_v, remap);
                mutable.value = mutable_v;
            }
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
            if (attr.type_expr) |type_expr| {
                const mutable_type = try alloc.create(ast.TypeExpr);
                mutable_type.* = type_expr.*;
                try remapTypeExpr(alloc, mutable_type, remap);
                mutable.type_expr = mutable_type;
            }
            if (attr.value) |value| {
                const mutable_value = try alloc.create(ast.Expr);
                mutable_value.* = value.*;
                try remapExpr(alloc, mutable_value, remap);
                mutable.value = mutable_value;
            }
            stmt.* = .{ .attribute = mutable };
        },
    }
}

fn remapImportDecl(alloc: std.mem.Allocator, id: *ast.ImportDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapStructName(alloc, &id.module_path, remap);
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
        .module_ref => |*mr| try remapStructName(alloc, &mr.name, remap),
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
            try remapStructName(alloc, &se.module_name, remap);
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
            if (fr.module) |*m| try remapStructName(alloc, m, remap);
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
            try remapStructName(alloc, &sp.module_name, remap);
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
            try remapStructName(alloc, &tse.module_name, remap);
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

test "validateOneStructPerFile: valid single module" {
    const alloc = std.testing.allocator;
    const source = "pub struct Config {\n  pub fn load() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "config.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneStructPerFile: valid nested module name" {
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

test "validateOneStructPerFile: field-only struct does not count as module" {
    const alloc = std.testing.allocator;
    const source = "pub struct Point {\n  x :: i64\n}\n";
    const result = validateOneStructPerFile(alloc, source, "point.zap");
    // Field-only structs don't count as module declarations
    // An empty file or one with only data structs has no module
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "validateOneStructPerFile: multiple modules is error" {
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

test "validateOneStructPerFile: snake_case path to PascalCase" {
    const alloc = std.testing.allocator;
    const source = "pub struct JsonParser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneStructPerFile(alloc, source, "json_parser.zap");
    try std.testing.expectEqual(null, result);
}

test "buildModulePrograms stores per-module AST programs" {
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

    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    try std.testing.expectEqual(@as(usize, 2), module_programs.len);
    try std.testing.expectEqualStrings("Foo", module_programs[0].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[0].program.structs.len);
    try std.testing.expectEqualStrings("Bar.Baz", module_programs[1].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[1].program.structs.len);
}

test "buildCompilationUnits derives units from module programs" {
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
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "fixture.zap", .source = "pub struct Foo {\n}\n" },
        .{ .file_path = "fixture.zap", .source = "pub struct Bar.Baz {\n}\n" },
    };
    const units = try buildCompilationUnits(alloc, module_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].module_name);
    try std.testing.expectEqualStrings("fixture.zap", units[0].file_path);
    try std.testing.expectEqual(@as(u32, 0), units[0].module_index.?);
    try std.testing.expectEqualStrings("Bar.Baz", units[1].module_name);
    try std.testing.expectEqual(@as(u32, 1), units[1].module_index.?);
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
    const module_programs = try buildModulePrograms(alloc, &merged, &interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "display_impl.zap", .source = impl_source },
        .{ .file_path = "foo.zap", .source = foo_source, .primary_struct_name = "Foo" },
    };

    const units = try buildCompilationUnits(alloc, module_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].module_name);
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

test "collector can build graph from per-module programs" {
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
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const program_slices = try alloc.alloc(ast.Program, module_programs.len);
    for (module_programs, 0..) |entry, i| program_slices[i] = entry.program;

    var collector = zap.Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    for (module_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    try std.testing.expectEqual(@as(usize, 2), collector.graph.structs.items.len);
}

test "compileModuleByModule isolates per-module diagnostics" {
    // Regression: errors from one module would re-fire downstream because
    // `failWithExisting` rendered the entire diagnostic engine on every
    // per-module failure, and `hasErrors()` checks tripped on prior
    // modules' residual errors. The downstream symptom is that any module
    // following a failed one would itself fail — even when its own source
    // was perfectly clean — and the same error block would print over and
    // over with each subsequent module's progress label.
    //
    // Fix verification: with one broken module followed by two clean ones,
    // the clean modules must still produce IR functions.
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
    for (ctx.module_programs) |mp| {
        names.append(alloc, mp.name) catch {};
    }

    const result = compileModuleByModule(
        alloc,
        &ctx,
        names.items,
        .{ .show_progress = false },
    ) catch |err| {
        std.debug.print("compileModuleByModule failed unexpectedly: {}\n", .{err});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(ctx.diag_engine.errorCount() >= 1);

    var found_clean_a = false;
    var found_clean_b = false;
    for (result.ir_program.functions) |func| {
        if (func.module_name) |mod_name| {
            if (std.mem.eql(u8, mod_name, "CleanA")) found_clean_a = true;
            if (std.mem.eql(u8, mod_name, "CleanB")) found_clean_b = true;
        }
    }
    try std.testing.expect(found_clean_a);
    try std.testing.expect(found_clean_b);
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

test "SourceGraph structs exposes modules collected from source units" {
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
    const module_order = [_][]const u8{ "Lib", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .module_order = &module_order,
    });
    var result = try compileModuleByModule(alloc, &ctx, &module_order, .{ .show_progress = false });

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
                "  @requires = [:read_file]\n" ++
                "  pub macro build() -> Expr {\n" ++
                "    paths = Globber.files()\n" ++
                "    count = __zap_list_len__(paths)\n" ++
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
    const module_order = [_][]const u8{ "Globber", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .module_order = &module_order,
    });
    var result = try compileModuleByModule(alloc, &ctx, &module_order, .{ .show_progress = false });

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
                "  @requires = [:read_file]\n" ++
                "  pub macro __using__(_opts :: Expr) -> Expr {\n" ++
                "    paths = Globber.files()\n" ++
                "    count = __zap_list_len__(paths)\n" ++
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
    const module_order = [_][]const u8{ "Globber", "MacroProvider", "Caller" };

    var ctx = try collectAllFromUnits(alloc, &source_units, .{
        .show_progress = false,
        .module_order = &module_order,
    });
    var result = try compileModuleByModule(alloc, &ctx, &module_order, .{ .show_progress = false });

    var interpreter = zap.ctfe.Interpreter.init(alloc, &result.ir_program);
    defer interpreter.deinit();
    const value = try interpreter.evalByName("Caller__main__0", &.{});

    try std.testing.expect(value == .int);
    try std.testing.expectEqual(@as(i64, 1), value.int);
}
