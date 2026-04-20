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
    /// Treat type warnings as hard errors.
    strict_types: bool = false,
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
//   Pass 1 (collectAll): Parse all files, collect declarations into shared context
//   Pass 2 (compileFile): Per-file macro expand → desugar → typecheck → HIR → IR
//   Pass 3 (mergeAndFinalize): Merge IR programs, run analysis pipeline
// ============================================================

/// Shared compilation state from Pass 1. Holds the scope graph, type store,
/// and interner that all files compile against.
pub const CompilationContext = struct {
    alloc: std.mem.Allocator,
    /// The merged program AST (all files' modules combined)
    merged_program: ast.Program,
    /// Single-module AST programs keyed by module name, used by the
    /// module-by-module pipeline so it does not need to re-extract modules
    /// from the merged AST during later stages.
    module_programs: []const ModuleProgram,
    /// First-class per-module compilation units derived during collectAll.
    units: []CompilationUnit,
    /// Original per-file source units used to derive merged parser input.
    source_units: []const SourceUnit,
    /// String interner shared across all parsed source units.
    interner: ast.StringInterner,
    /// Scope graph with all modules' declarations
    collector: zap.Collector,
    /// Diagnostic engine
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
};

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

    var collector = zap.Collector.init(alloc, &interner);
    {
        const pre_module_programs = try buildModulePrograms(alloc, &program, &interner);
        for (pre_module_programs) |entry| {
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
            const top_only = ast.Program{ .modules = &.{}, .top_items = program.top_items };
            collector.collectProgramSurface(&top_only) catch {
                for (collector.errors.items) |collect_err| {
                    diag_engine.err(collect_err.message, collect_err.span) catch {};
                }
                if (options.show_progress) std.debug.print("\r\x1b[K", .{});
                emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
                return error.CollectFailed;
            };
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

    // Run macro expansion and desugaring on the MERGED program — all modules
    // together. This ensures every if_expr is expanded to case_expr, every
    // pipe is desugared, etc., before the AST is split into per-module programs.
    // The scope graph (collector) is already populated, so macros can resolve.
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Macro expand", .{ step, total_steps });

    var macro_engine = zap.MacroEngine.init(alloc, &interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.MacroExpansionFailed;
    };
    for (macro_engine.errors.items) |macro_err| {
        diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.MacroExpansionFailed;
    }

    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps });

    var desugarer = zap.Desugarer.init(alloc, &interner, &collector.graph);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitDiagnosticsFromUnits(alloc, diag_engine.diagnostics.items, all_source_units, diag_engine.use_color);
        return error.DesugarFailed;
    };

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

    var final_collector = zap.Collector.init(alloc, &interner);
    for (module_programs) |entry| {
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
        const top_only = ast.Program{ .modules = &.{}, .top_items = desugared_program.top_items };
        final_collector.collectProgramSurface(&top_only) catch {
            for (final_collector.errors.items) |collect_err| {
                diag_engine.err(collect_err.message, collect_err.span) catch {};
            }
            return error.CollectFailed;
        };
    }
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
    // progress writer: use debug.print in 0.16
    const total_steps: u32 = 11;
    var step: u32 = 2; // already past parse + collect

    // Attribute substitution (replace @name references with attribute values)
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Substitute attributes", .{ step, total_steps });

    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const substituted_program = zap.attr_substitute.substituteAttributes(
        alloc,
        &ctx.merged_program,
        &ctx.collector.graph,
        &ctx.interner,
        &subst_errors,
    ) catch {
        ctx.diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    }

    // Macro expansion
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Expand macros", .{ step, total_steps });

    var macro_engine = zap.MacroEngine.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&substituted_program) catch {
        for (macro_engine.errors.items) |macro_err| {
            ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    };

    for (macro_engine.errors.items) |macro_err| {
        ctx.diag_engine.err(macro_err.message, macro_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.MacroExpansionFailed;
    }

    // Re-collect: register functions generated by macro expansion using the SAME
    // collectFunction path as source-written functions. This creates proper scopes,
    // node_scope_map entries, and parameter bindings — ensuring uniform lowering.
    for (expanded_program.modules) |*mod| {
        const mod_scope = ctx.collector.graph.findModuleScope(mod.name) orelse continue;
        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const key = zap.scope.FamilyKey{
                        .name = func.name,
                        .arity = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0,
                    };
                    const scope_data = ctx.collector.graph.getScope(mod_scope);
                    if (scope_data.function_families.get(key) == null) {
                        ctx.collector.collectFunction(func, mod_scope) catch {};
                    }
                },
                else => {},
            }
        }
    }

    // Desugaring
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Desugar", .{ step, total_steps });

    var desugarer = zap.Desugarer.init(alloc, &ctx.interner, &ctx.collector.graph);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        ctx.diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };

    // Register new functions added by desugaring (e.g., __for_N helpers from for comprehensions).
    // Walk the desugared program and collect any priv_function items that aren't already in scope.
    for (desugared_program.modules) |*mod| {
        // Find the existing module scope
        const mod_scope = ctx.collector.graph.findModuleScope(mod.name) orelse continue;
        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const key = zap.scope.FamilyKey{
                        .name = func.name,
                        .arity = @intCast(func.clauses[0].params.len),
                    };
                    const scope_data = ctx.collector.graph.getScope(mod_scope);
                    if (scope_data.function_families.get(key) == null) {
                        // New function — register it
                        ctx.collector.collectFunction(func, mod_scope) catch {};
                    }
                },
                else => {},
            }
        }
    }

    // Type checking (first pass)
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Type check", .{ step, total_steps });

    var type_checker = zap.types.TypeChecker.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer type_checker.deinit();

    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // HIR lowering
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] HIR", .{ step, total_steps });

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.interner, &ctx.collector.graph, type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };

    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    }

    // Monomorphization pass
    var mono_next_group_id = hir_builder.next_group_id;
    const mono_result = zap.monomorphize.monomorphize(alloc, &hir_program, type_checker.store, &mono_next_group_id, &ctx.interner) catch {
        ctx.diag_engine.err("Error during monomorphization", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };
    const mono_program = mono_result.program;

    // IR lowering
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] IR", .{ step, total_steps });

    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.interner);
    ir_builder.type_store = type_checker.store;
    defer ir_builder.deinit();
    var ir_program = ir_builder.buildProgram(&mono_program) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };

    // CTFE for computed attributes
    if (options.module_order) |module_order| {
        _ = zap.ctfe.evaluateModuleAttributesInOrder(
            alloc,
            &ir_program,
            &ctx.collector.graph,
            &ctx.interner,
            module_order,
            options.cache_dir,
            ctfeCompileOptionsHash(options),
        ) catch {};
    } else {
        _ = zap.ctfe.evaluateComputedAttributes(
            alloc,
            &ir_program,
            &ctx.collector.graph,
            &ctx.interner,
            options.cache_dir,
            ctfeCompileOptionsHash(options),
        ) catch {};
    }

    // Analysis pipeline
    step += 1;
    if (options.show_progress) std.debug.print("\r\x1b[K  [{d}/{d}] Escape analysis", .{ step, total_steps });

    var pipeline_result = zap.analysis_pipeline.runAnalysisPipeline(alloc, &ir_program) catch {
        ctx.diag_engine.err("Error during escape analysis", .{ .start = 0, .end = 0 }) catch {};
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };
    zap.contification_rewrite.rewriteContifiedContinuations(alloc, &ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return error.IrFailed,
    };

    // Second type-check pass (with analysis context)
    type_checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    type_checker.errors.clearRetainingCapacity();
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    for (pipeline_result.diagnostics.items) |analysis_diag| {
        ctx.diag_engine.reportDiagnostic(analysis_diag) catch {};
    }

    for (type_checker.errors.items) |type_err| {
        ctx.diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
        return error.TypeCheckFailed;
    }

    // Emit warnings
    if (ctx.diag_engine.warningCount() > 0) {
        if (options.show_progress) std.debug.print("\r\x1b[K", .{});
        emitContextDiagnostics(ctx, alloc);
    }

    if (options.show_progress) std.debug.print("\r\x1b[K", .{});

    return .{ .ir_program = ir_program, .analysis_context = pipeline_result.context };
}

/// Compile a single file's module through macro expansion, desugaring,
/// type checking, HIR, and IR. Stores the result in the CompilationUnit.
///
/// This is the per-file compilation entry point. Currently it requires the
/// full merged program (via CompilationContext) because the type checker,
/// HIR builder, and IR builder operate on the full program. When these
/// phases support single-module operation, this function will process only
/// the unit's module.
///
/// For now, this delegates to compileFiles for the actual work and extracts
/// the per-module IR. The function signature is the correct API for future
/// per-file parallelism.
pub fn compileFile(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    unit: *CompilationUnit,
    options: CompileOptions,
) CompileError!void {
    const mod_program = lookupModuleProgram(ctx, unit.module_name) orelse {
        ctx.diag_engine.err("Module disappeared during per-module compilation", .{ .start = 0, .end = 0 }) catch {};
        emitDiagnostics(&ctx.diag_engine, alloc);
        return error.CollectFailed;
    };
    unit.ir_program = try compileSingleModuleIr(alloc, ctx, unit.module_name, mod_program, options);
}

/// Pass 3: Finalize compilation — wrap the IR program with analysis context.
///
/// Currently this is a no-op wrapper since analysis runs inside compileFiles.
/// When per-file IR generation is implemented, this will merge per-file IR
/// programs and run the analysis pipeline on the merged result.
/// Pass 3: Merge per-file IR programs and run the analysis pipeline.
///
/// When per-file IR generation is implemented, this will accept multiple
/// per-file IR programs, merge them, and run analysis on the merged result.
/// Currently takes a single pre-merged IR program.
pub fn mergeAndFinalize(
    alloc: std.mem.Allocator,
    ir_program: *ir.Program,
) CompileError!CompileResult {
    return mergeAndFinalizeWithIo(alloc, ir_program, null);
}

fn mergeAndFinalizeWithIo(
    alloc: std.mem.Allocator,
    ir_program: *ir.Program,
    pio: ?std.Io,
) CompileError!CompileResult {
    var pipeline_result = zap.analysis_pipeline.runAnalysisPipelineWithIo(alloc, ir_program, pio) catch {
        return error.IrFailed;
    };
    zap.contification_rewrite.rewriteContifiedContinuations(alloc, ir_program, &pipeline_result.context) catch |err| switch (err) {
        error.UnsupportedContifiedRewrite => {},
        else => return error.IrFailed,
    };

    return .{ .ir_program = ir_program.*, .analysis_context = pipeline_result.context };
}

/// Compile a single module to HIR only (no monomorphization, no IR).
/// Used by whole-program monomorphization pipeline.
fn compileSingleModuleHir(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    mod_program: *const ast.Program,
    shared_store: *zap.types.TypeStore,
    group_id_offset: u32,
    options: CompileOptions,
) CompileError!ModuleHirResult {
    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const desugared = zap.attr_substitute.substituteAttributes(
        alloc,
        mod_program,
        &ctx.collector.graph,
        &ctx.interner,
        &subst_errors,
    ) catch {
        ctx.diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    }

    var type_checker = zap.types.TypeChecker.initWithSharedStore(alloc, shared_store, &ctx.interner, &ctx.collector.graph);
    defer type_checker.deinit();

    shared_store.inferred_signatures.clearRetainingCapacity();

    type_checker.checkProgram(&desugared) catch {};
    for (type_checker.errors.items) |type_err| {
        ctx.diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.TypeCheckFailed;
    }

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.interner, &ctx.collector.graph, shared_store);
    // Offset group IDs so they're globally unique across modules
    hir_builder.next_group_id = group_id_offset;
    const hir_program = hir_builder.buildProgram(&desugared) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };
    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    }

    return .{
        .mod_name = mod_name,
        .hir_program = hir_program,
        .next_group_id = hir_builder.next_group_id,
    };
}

/// Compile a monomorphized HIR program to IR for a single module.
fn compileHirToIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    hir_program: *const zap.hir.Program,
    type_store: *zap.types.TypeStore,
    options: CompileOptions,
) CompileError!ir.Program {
    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.interner);
    ir_builder.type_store = type_store;
    defer ir_builder.deinit();
    const mod_ir = ir_builder.buildProgram(hir_program) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };

    const ctfe_result = zap.ctfe.evaluateComputedAttributesForModule(
        alloc,
        &mod_ir,
        &ctx.collector.graph,
        &ctx.interner,
        mod_name,
        options.cache_dir,
        ctfeCompileOptionsHash(options),
    ) catch null;
    if (ctfe_result) |cr| {
        if (cr.errors.len > 0) zap.ctfe.emitCtfeErrors(alloc, cr.errors);
    }

    return mod_ir;
}

fn compileSingleModuleIr(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    mod_program: *const ast.Program,
    options: CompileOptions,
) CompileError!ir.Program {
    const type_severity: zap.Severity = if (options.strict_types) .@"error" else .warning;

    // Macro expansion and desugaring were already run on the merged program
    // in collectAllFromUnits. The mod_program AST is fully expanded — no
    // if_expr, no pipe operators, no unexpanded macros. Proceed directly
    // to type checking.

    // Attribute substitution still runs per-module since @computed values
    // are evaluated per-module via CTFE.
    var subst_errors: std.ArrayListUnmanaged(zap.attr_substitute.SubstitutionError) = .empty;
    const desugared = zap.attr_substitute.substituteAttributes(
        alloc,
        mod_program,
        &ctx.collector.graph,
        &ctx.interner,
        &subst_errors,
    ) catch {
        ctx.diag_engine.err("Error during attribute substitution", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    };
    for (subst_errors.items) |subst_err| {
        ctx.diag_engine.err(subst_err.message, subst_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.DesugarFailed;
    }

    var type_checker = zap.types.TypeChecker.init(alloc, &ctx.interner, &ctx.collector.graph);
    defer type_checker.deinit();

    type_checker.checkProgram(&desugared) catch {};
    // Skip checkUnusedBindings — the type checker has a shared scope graph
    // but only visits this module's bindings. Checking all bindings here
    // would report false "unused" warnings for bindings in other modules.
    // Unused binding warnings are emitted during diagnostics instead.
    for (type_checker.errors.items) |type_err| {
        ctx.diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        }) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.TypeCheckFailed;
    }

    var hir_builder = zap.hir.HirBuilder.init(alloc, &ctx.interner, &ctx.collector.graph, type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared) catch {
        for (hir_builder.errors.items) |hir_err| {
            ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };
    for (hir_builder.errors.items) |hir_err| {
        ctx.diag_engine.err(hir_err.message, hir_err.span) catch {};
    }
    if (ctx.diag_engine.hasErrors()) {
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    }

    // Monomorphization pass
    var mono_next_group_id2 = hir_builder.next_group_id;
    const mono_result2 = zap.monomorphize.monomorphize(alloc, &hir_program, type_checker.store, &mono_next_group_id2, &ctx.interner) catch {
        ctx.diag_engine.err("Error during monomorphization", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.HirFailed;
    };
    const mono_program2 = mono_result2.program;

    var ir_builder = zap.ir.IrBuilder.init(alloc, &ctx.interner);
    ir_builder.type_store = type_checker.store;
    defer ir_builder.deinit();
    const mod_ir = ir_builder.buildProgram(&mono_program2) catch {
        ctx.diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 }) catch {};
        emitContextDiagnostics(ctx, alloc);
        return error.IrFailed;
    };

    const ctfe_result = zap.ctfe.evaluateComputedAttributesForModule(
        alloc,
        &mod_ir,
        &ctx.collector.graph,
        &ctx.interner,
        mod_name,
        options.cache_dir,
        ctfeCompileOptionsHash(options),
    ) catch null;
    if (ctfe_result) |cr| {
        if (cr.errors.len > 0) zap.ctfe.emitCtfeErrors(alloc, cr.errors);
    }

    return mod_ir;
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
    const pio = options.io;

    // Collect all IR functions and type defs across modules
    var all_functions: std.ArrayListUnmanaged(ir.Function) = .empty;
    var all_type_defs: std.ArrayListUnmanaged(ir.TypeDef) = .empty;
    var entry_id: ?ir.FunctionId = null;

    _ = pio;

    // Shared TypeStore + globally-unique group IDs pipeline.
    {
        const shared_store = alloc.create(zap.types.TypeStore) catch return error.OutOfMemory;
        shared_store.* = zap.types.TypeStore.init(alloc, &ctx.interner);

        // Phase 1: all modules → HIR with shared TypeStore and globally-unique group IDs
        var hir_results: std.ArrayListUnmanaged(ModuleHirResult) = .empty;
        var group_id_offset: u32 = 0;
        for (module_order, 0..) |mod_name, mod_idx| {
            if (options.show_progress) {
                std.debug.print("\r\x1b[K  [hir {d}/{d}] {s}", .{ mod_idx + 1, module_order.len, mod_name });
            }
            const mod_program = findModuleProgram(ctx, mod_name) orelse continue;
            const hir_result = compileSingleModuleHir(alloc, ctx, mod_name, mod_program, shared_store, group_id_offset, options) catch continue;
            group_id_offset = hir_result.next_group_id;
            hir_results.append(alloc, hir_result) catch return error.OutOfMemory;
        }

        // Phase 2: merge all HIR modules
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

        // Phase 3: whole-program monomorphization
        {
            var mono_next = group_id_offset;
            const mono_result = zap.monomorphize.monomorphize(alloc, &combined_hir, shared_store, &mono_next, &ctx.interner) catch {
                ctx.diag_engine.err("Error during whole-program monomorphization", .{ .start = 0, .end = 0 }) catch {};
                emitContextDiagnostics(ctx, alloc);
                return error.HirFailed;
            };
            combined_hir = mono_result.program;
        }

        // Phase 4: each module HIR → IR
        // Function IDs are already globally unique from the HIR stage (group_id_offset),
        // so no cloneWithOffset needed — just collect functions directly.
        for (combined_hir.modules) |mod| {
            const single_mod_hir = zap.hir.Program{
                .modules = try alloc.dupe(zap.hir.Module, &.{mod}),
                .top_functions = &.{},
            };
            const mod_name_str = if (mod.name.parts.len > 0) ctx.interner.get(mod.name.parts[mod.name.parts.len - 1]) else "unknown";
            const mod_ir = compileHirToIr(alloc, ctx, mod_name_str, &single_mod_hir, shared_store, options) catch {
                std.debug.print("IR failed for module: {s}\n", .{mod_name_str});
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
            };
            const mod_ir = compileHirToIr(alloc, ctx, "top", &top_hir, shared_store, options) catch return error.IrFailed;
            for (mod_ir.functions) |func| {
                all_functions.append(alloc, func) catch return error.OutOfMemory;
            }
            if (mod_ir.entry) |eid| entry_id = eid;
            for (mod_ir.type_defs) |td| {
                all_type_defs.append(alloc, td) catch return error.OutOfMemory;
            }
        }
    }

    // Build merged IR program
    var merged_ir = ir.Program{
        .functions = all_functions.items,
        .type_defs = all_type_defs.items,
        .entry = entry_id,
    };

    // Run analysis pipeline on merged result
    return mergeAndFinalize(alloc, &merged_ir);
}

const ModuleCompileResult = struct {
    err: bool = false,
};

fn compileModuleTask(
    alloc: std.mem.Allocator,
    ctx: *CompilationContext,
    mod_name: []const u8,
    options: CompileOptions,
    result: *ModuleCompileResult,
) void {
    const unit = lookupCompilationUnit(ctx, mod_name) orelse {
        result.err = true;
        return;
    };
    compileFile(alloc, ctx, unit, options) catch {
        result.err = true;
        return;
    };
    if (unit.ir_program == null) {
        result.err = true;
    }
}

/// Extract a single-module ast.Program from the merged program.
fn extractModuleProgram(
    alloc: std.mem.Allocator,
    merged: *const ast.Program,
    mod_name: []const u8,
    interner: *const ast.StringInterner,
) ?ast.Program {
    for (merged.modules) |mod| {
        // Build module name string from parts
        if (mod.name.parts.len == 1) {
            if (std.mem.eql(u8, interner.get(mod.name.parts[0]), mod_name)) {
                const mods = alloc.alloc(ast.ModuleDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .modules = mods, .top_items = &.{} };
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
                const mods = alloc.alloc(ast.ModuleDecl, 1) catch return null;
                mods[0] = mod;
                return .{ .modules = mods, .top_items = &.{} };
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
    const result = try alloc.alloc(ModuleProgram, program.modules.len);
    for (program.modules, 0..) |mod, i| {
        const name = try moduleNameToOwnedString(alloc, mod.name, interner);
        const mods = try alloc.alloc(ast.ModuleDecl, 1);
        mods[0] = mod;
        result[i] = .{
            .name = name,
            .program = .{ .modules = mods, .top_items = &.{} },
        };
    }
    return result;
}

fn buildCompilationUnits(
    alloc: std.mem.Allocator,
    module_programs: []const ModuleProgram,
    source_units: []const SourceUnit,
) ![]CompilationUnit {
    // Build a unit for each module by matching module names to source files.
    // Source files that contain only top-level items (e.g., Zap.zap with pub struct)
    // won't have a matching module_program and are skipped.
    var units_list: std.ArrayListUnmanaged(CompilationUnit) = .empty;
    for (module_programs, 0..) |entry, mod_idx| {
        // Find the source unit whose file path best matches this module name.
        // For 1:1 cases (same count), use index mapping. Otherwise, try to
        // match by checking if the source file contains the module definition.
        const source_idx: usize = if (module_programs.len == source_units.len)
            mod_idx
        else blk: {
            // Convert module name to expected file basename: "Foo.Bar" -> "bar.zap"
            // Check each source unit for a match.
            for (source_units, 0..) |unit, si| {
                if (std.mem.find(u8, unit.source, entry.name)) |_| {
                    break :blk si;
                }
            }
            // Fallback: use mod_idx clamped to source_units range
            break :blk @min(mod_idx, if (source_units.len > 0) source_units.len - 1 else 0);
        };
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

fn mergePrograms(alloc: std.mem.Allocator, programs: []const ast.Program) !ast.Program {
    var module_count: usize = 0;
    var top_item_count: usize = 0;
    for (programs) |program| {
        module_count += program.modules.len;
        top_item_count += program.top_items.len;
    }
    const modules = try alloc.alloc(ast.ModuleDecl, module_count);
    const top_items = try alloc.alloc(ast.TopItem, top_item_count);
    var module_index: usize = 0;
    var top_index: usize = 0;
    for (programs) |program| {
        @memcpy(modules[module_index .. module_index + program.modules.len], program.modules);
        @memcpy(top_items[top_index .. top_index + program.top_items.len], program.top_items);
        module_index += program.modules.len;
        top_index += program.top_items.len;
    }
    return .{ .modules = modules, .top_items = top_items };
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

fn moduleNameToOwnedString(
    alloc: std.mem.Allocator,
    name: ast.ModuleName,
    interner: *const ast.StringInterner,
) ![]const u8 {
    if (name.parts.len == 1) return alloc.dupe(u8, interner.get(name.parts[0]));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, interner.get(part));
    }
    return buf.toOwnedSlice(alloc);
}

fn lookupModuleProgram(ctx: *const CompilationContext, mod_name: []const u8) ?*const ast.Program {
    for (ctx.module_programs) |*entry| {
        if (std.mem.eql(u8, entry.name, mod_name)) return &entry.program;
    }
    return null;
}

fn findModuleProgram(ctx: *CompilationContext, mod_name: []const u8) ?*const ast.Program {
    for (ctx.module_programs) |*mp| {
        if (std.mem.eql(u8, mp.name, mod_name)) return &mp.program;
    }
    return null;
}

fn lookupCompilationUnit(ctx: *CompilationContext, mod_name: []const u8) ?*CompilationUnit {
    for (ctx.units) |*unit| {
        if (std.mem.eql(u8, unit.module_name, mod_name)) return unit;
    }
    return null;
}

fn cloneFunctionWithOffset(alloc: std.mem.Allocator, func: ir.Function, function_id_offset: u32) error{OutOfMemory}!ir.Function {
    const blocks = try alloc.alloc(ir.Block, func.body.len);
    for (func.body, 0..) |block, i| {
        blocks[i] = .{
            .label = block.label,
            .instructions = try cloneInstructionsWithOffset(alloc, block.instructions, function_id_offset),
        };
    }

    var adjusted = func;
    adjusted.id = function_id_offset + func.id;
    adjusted.body = blocks;
    return adjusted;
}

fn cloneInstructionsWithOffset(alloc: std.mem.Allocator, instrs: []const ir.Instruction, function_id_offset: u32) error{OutOfMemory}![]const ir.Instruction {
    const cloned = try alloc.alloc(ir.Instruction, instrs.len);
    for (instrs, 0..) |instr, i| {
        cloned[i] = try cloneInstructionWithOffset(alloc, instr, function_id_offset);
    }
    return cloned;
}

fn cloneInstructionWithOffset(alloc: std.mem.Allocator, instr: ir.Instruction, function_id_offset: u32) error{OutOfMemory}!ir.Instruction {
    var adjusted = instr;
    switch (instr) {
        .call_direct => |call| {
            var next = call;
            next.function += function_id_offset;
            adjusted = .{ .call_direct = next };
        },
        .call_dispatch => |call| {
            var next = call;
            next.group_id += function_id_offset;
            adjusted = .{ .call_dispatch = next };
        },
        .make_closure => |closure| {
            var next = closure;
            next.function += function_id_offset;
            adjusted = .{ .make_closure = next };
        },
        .if_expr => |if_expr| {
            var next = if_expr;
            next.then_instrs = try cloneInstructionsWithOffset(alloc, if_expr.then_instrs, function_id_offset);
            next.else_instrs = try cloneInstructionsWithOffset(alloc, if_expr.else_instrs, function_id_offset);
            adjusted = .{ .if_expr = next };
        },
        .guard_block => |guard| {
            var next = guard;
            next.body = try cloneInstructionsWithOffset(alloc, guard.body, function_id_offset);
            adjusted = .{ .guard_block = next };
        },
        .case_block => |case_block| {
            var next = case_block;
            next.pre_instrs = try cloneInstructionsWithOffset(alloc, case_block.pre_instrs, function_id_offset);
            next.default_instrs = try cloneInstructionsWithOffset(alloc, case_block.default_instrs, function_id_offset);
            const arms = try alloc.alloc(ir.IrCaseArm, case_block.arms.len);
            for (case_block.arms, 0..) |arm, i| {
                var arm_copy = arm;
                arm_copy.cond_instrs = try cloneInstructionsWithOffset(alloc, arm.cond_instrs, function_id_offset);
                arm_copy.body_instrs = try cloneInstructionsWithOffset(alloc, arm.body_instrs, function_id_offset);
                arms[i] = arm_copy;
            }
            next.arms = arms;
            adjusted = .{ .case_block = next };
        },
        .switch_literal => |switch_literal| {
            var next = switch_literal;
            next.default_instrs = try cloneInstructionsWithOffset(alloc, switch_literal.default_instrs, function_id_offset);
            const cases = try alloc.alloc(ir.LitCase, switch_literal.cases.len);
            for (switch_literal.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .switch_literal = next };
        },
        .switch_return => |switch_return| {
            var next = switch_return;
            next.default_instrs = try cloneInstructionsWithOffset(alloc, switch_return.default_instrs, function_id_offset);
            const cases = try alloc.alloc(ir.ReturnCase, switch_return.cases.len);
            for (switch_return.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .switch_return = next };
        },
        .union_switch_return => |switch_return| {
            var next = switch_return;
            const cases = try alloc.alloc(ir.UnionCase, switch_return.cases.len);
            for (switch_return.cases, 0..) |case, i| {
                var case_copy = case;
                case_copy.body_instrs = try cloneInstructionsWithOffset(alloc, case.body_instrs, function_id_offset);
                cases[i] = case_copy;
            }
            next.cases = cases;
            adjusted = .{ .union_switch_return = next };
        },
        else => {},
    }
    return adjusted;
}

/// Compile a Zap source file through the frontend and ZIR backend to produce
/// a native binary.
fn emitDiagnostics(diag_engine: *zap.DiagnosticEngine, alloc: std.mem.Allocator) void {
    const rendered = diag_engine.format(alloc) catch return;
    // stderr writer: use debug.print in 0.16
    std.debug.print("{s}", .{rendered});
}

const testing = std.testing;

test "cloneFunctionWithOffset rewrites nested function references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const func = ir.Function{
        .id = 2,
        .name = "Test__nested",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{ir.Block{
            .label = 0,
            .instructions = &.{
                .{ .call_direct = .{ .dest = 0, .function = 1, .args = &.{}, .arg_modes = &.{} } },
                .{ .if_expr = .{
                    .dest = 1,
                    .condition = 0,
                    .then_instrs = &.{.{ .make_closure = .{ .dest = 2, .function = 3, .captures = &.{} } }},
                    .then_result = 2,
                    .else_instrs = &.{.{ .call_dispatch = .{ .dest = 3, .group_id = 4, .args = &.{}, .arg_modes = &.{} } }},
                    .else_result = 3,
                } },
                .{ .ret = .{ .value = null } },
            },
        }},
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
    };

    const adjusted = try cloneFunctionWithOffset(alloc, func, 10);
    try testing.expectEqual(@as(ir.FunctionId, 12), adjusted.id);
    try testing.expectEqual(@as(ir.FunctionId, 11), adjusted.body[0].instructions[0].call_direct.function);
    try testing.expectEqual(@as(ir.FunctionId, 13), adjusted.body[0].instructions[1].if_expr.then_instrs[0].make_closure.function);
    try testing.expectEqual(@as(u32, 14), adjusted.body[0].instructions[1].if_expr.else_instrs[0].call_dispatch.group_id);
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

/// Validate that a source file contains exactly one module declaration and that the
/// module name matches the file path. Returns an error message if validation
/// fails, or null if the file is valid.
///
/// `file_path` is relative to the lib root (e.g., "config/parser.zap").
/// The expected module name is derived from the path: "config/parser.zap" → "Config.Parser".
pub fn validateOneModulePerFile(
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

    // Count top-level declarations (module, protocol, or impl)
    var module_count: u32 = 0;
    var module_name_parts: ?[]const ast.StringId = null;
    var has_protocol_or_impl = false;
    for (program.top_items) |item| {
        switch (item) {
            .module => |mod| {
                module_count += 1;
                module_name_parts = mod.name.parts;
            },
            .priv_module => |mod| {
                module_count += 1;
                module_name_parts = mod.name.parts;
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
    // Also count from program.modules (the parser populates both)
    if (module_count == 0) {
        for (program.modules) |mod| {
            module_count += 1;
            module_name_parts = mod.name.parts;
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
    // Remap modules (mutable copy needed since program.modules is []const)
    if (program.modules.len > 0) {
        const mutable_modules = try alloc.alloc(ast.ModuleDecl, program.modules.len);
        @memcpy(mutable_modules, program.modules);
        for (mutable_modules) |*mod| {
            try remapModuleDecl(alloc, mod, remap);
        }
        program.modules = mutable_modules;
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

fn remapModuleName(alloc: std.mem.Allocator, name: *ast.ModuleName, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (name.parts.len > 0) {
        const mutable_parts = try alloc.alloc(ast.StringId, name.parts.len);
        for (name.parts, 0..) |part, i| {
            mutable_parts[i] = remap[part];
        }
        name.parts = mutable_parts;
    }
}

fn remapModuleDecl(alloc: std.mem.Allocator, mod: *ast.ModuleDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapModuleName(alloc, &mod.name, remap);
    if (mod.parent) |p| mod.parent = remap[p];
    if (mod.items.len > 0) {
        const mutable_items = try alloc.alloc(ast.ModuleItem, mod.items.len);
        @memcpy(mutable_items, mod.items);
        for (mutable_items) |*item| {
            try remapModuleItem(alloc, item, remap);
        }
        mod.items = mutable_items;
    }
}

fn remapTopItem(alloc: std.mem.Allocator, item: *ast.TopItem, remap: []const ast.StringId) error{OutOfMemory}!void {
    switch (item.*) {
        .module, .priv_module => |mod_ptr| {
            const mutable = try alloc.create(ast.ModuleDecl);
            mutable.* = mod_ptr.*;
            try remapModuleDecl(alloc, mutable, remap);
            item.* = if (item.* == .module) .{ .module = mutable } else .{ .priv_module = mutable };
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

fn remapModuleItem(alloc: std.mem.Allocator, item: *ast.ModuleItem, remap: []const ast.StringId) error{OutOfMemory}!void {
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
            try remapModuleName(alloc, &mutable.module_path, remap);
            if (mutable.as_name) |*as_name| try remapModuleName(alloc, as_name, remap);
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
            try remapModuleName(alloc, &mutable.module_path, remap);
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
        .module_level_expr => |expr| {
            const mutable = try alloc.create(ast.Expr);
            mutable.* = expr.*;
            try remapExpr(alloc, mutable, remap);
            item.* = .{ .module_level_expr = mutable };
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

fn remapStructDecl(alloc: std.mem.Allocator, sd: *ast.StructDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    if (sd.name) |n| sd.name = remap[n];
    if (sd.parent) |p| sd.parent = remap[p];
    if (sd.fields.len > 0) {
        const mutable_fields = try alloc.alloc(ast.StructFieldDecl, sd.fields.len);
        for (sd.fields, 0..) |f, i| {
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
        sd.fields = mutable_fields;
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
    }
}

fn remapImportDecl(alloc: std.mem.Allocator, id: *ast.ImportDecl, remap: []const ast.StringId) error{OutOfMemory}!void {
    try remapModuleName(alloc, &id.module_path, remap);
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
        .module_ref => |*mr| try remapModuleName(alloc, &mr.name, remap),
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
            fe.var_name = remap[fe.var_name];
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
            try remapModuleName(alloc, &se.module_name, remap);
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
            if (fr.module) |*m| try remapModuleName(alloc, m, remap);
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
            try remapModuleName(alloc, &sp.module_name, remap);
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
            try remapModuleName(alloc, &tse.module_name, remap);
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

test "validateOneModulePerFile: valid single module" {
    const alloc = std.testing.allocator;
    const source = "pub module Config {\n  pub fn load() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid nested module name" {
    const alloc = std.testing.allocator;
    const source = "pub module Config.Parser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config/parser.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: valid private module" {
    const alloc = std.testing.allocator;
    const source = "module Config.Helpers {\n  pub fn help() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config/helpers.zap");
    try std.testing.expectEqual(null, result);
}

test "validateOneModulePerFile: zero modules is error" {
    const alloc = std.testing.allocator;
    const source = "pub struct Point {\n  x :: i64\n}\n";
    const result = validateOneModulePerFile(alloc, source, "point.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "found none") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: multiple modules is error" {
    const alloc = std.testing.allocator;
    const source = "pub module Foo {\n  pub fn foo() -> i64 {\n    1\n  }\n}\npub module Bar {\n  pub fn bar() -> i64 {\n    2\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "foo.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "found 2") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: name mismatch is error" {
    const alloc = std.testing.allocator;
    const source = "pub module WrongName {\n  pub fn foo() -> i64 {\n    1\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "config.zap");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.find(u8, result.?, "does not match") != null);
    alloc.free(result.?);
}

test "validateOneModulePerFile: snake_case path to PascalCase" {
    const alloc = std.testing.allocator;
    const source = "pub module JsonParser {\n  pub fn parse() -> String {\n    \"ok\"\n  }\n}\n";
    const result = validateOneModulePerFile(alloc, source, "json_parser.zap");
    try std.testing.expectEqual(null, result);
}

test "buildModulePrograms stores per-module AST programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub module Foo {\n" ++
        "}\n" ++
        "pub module Bar.Baz {\n" ++
        "}\n" ++
        "";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    try std.testing.expectEqual(@as(usize, 2), module_programs.len);
    try std.testing.expectEqualStrings("Foo", module_programs[0].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[0].program.modules.len);
    try std.testing.expectEqualStrings("Bar.Baz", module_programs[1].name);
    try std.testing.expectEqual(@as(usize, 1), module_programs[1].program.modules.len);
}

test "buildCompilationUnits derives units from module programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        "pub module Foo {\n" ++
        "}\n" ++
        "pub module Bar.Baz {\n" ++
        "}\n";

    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();
    const module_programs = try buildModulePrograms(alloc, &program, parser.interner);
    const source_units = [_]SourceUnit{
        .{ .file_path = "fixture.zap", .source = "pub module Foo {\n}\n" },
        .{ .file_path = "fixture.zap", .source = "pub module Bar.Baz {\n}\n" },
    };
    const units = try buildCompilationUnits(alloc, module_programs, &source_units);

    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("Foo", units[0].module_name);
    try std.testing.expectEqualStrings("fixture.zap", units[0].file_path);
    try std.testing.expectEqual(@as(u32, 0), units[0].module_index.?);
    try std.testing.expectEqualStrings("Bar.Baz", units[1].module_name);
    try std.testing.expectEqual(@as(u32, 1), units[1].module_index.?);
}

test "per-unit parser assigns source_id and file-local spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var interner = ast.StringInterner.init(alloc);

    var parser = zap.Parser.initWithSharedInterner(
        alloc,
        "pub module Bar {\n  bad(\n}\n",
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
        "pub module Foo {\n" ++
        "  pub fn run() -> i64 {\n" ++
        "    1\n" ++
        "  }\n" ++
        "}\n" ++
        "pub module Bar {\n" ++
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

    var collector = zap.Collector.init(alloc, parser.interner);
    defer collector.deinit();
    for (module_programs) |entry| {
        try collector.collectProgramSurface(&entry.program);
    }
    try collector.finalizeCollectedPrograms(program_slices);

    try std.testing.expectEqual(@as(usize, 2), collector.graph.modules.items.len);
}
