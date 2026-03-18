const std = @import("std");
const zap = @import("zap");

const runtime_source = @embedFile("runtime.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Usage: zap [run] [--emit-zig] [--lib] [--strict-types] [--explain CODE] <file.zap> [zig-flags...]\n", .{});
        std.process.exit(1);
    }

    // Separate zap flags, the .zap file, and zig flags
    var emit_zig = false;
    var lib_mode = false;
    var strict_types = false;
    var run_after_build = false;
    var explain_code: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var zig_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zig_flags.deinit(allocator);
    var run_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer run_args.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "run") and file_path == null and !run_after_build) {
            run_after_build = true;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            lib_mode = true;
        } else if (std.mem.eql(u8, arg, "--strict-types")) {
            strict_types = true;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            i += 1;
            if (i < args.len) {
                explain_code = args[i];
            } else {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                try stderr.print("Error: --explain requires an error code (e.g., --explain Z0001)\n", .{});
                std.process.exit(1);
            }
        } else if (file_path == null and std.mem.endsWith(u8, arg, ".zap")) {
            file_path = arg;
        } else if (run_after_build and file_path != null) {
            // Arguments after the .zap file in run mode are passed to the program
            try run_args.append(allocator, arg);
        } else {
            try zig_flags.append(allocator, arg);
        }
    }

    // Handle --explain before requiring a file
    if (explain_code) |code| {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        if (getErrorExplanation(code)) |explanation| {
            try stdout.print("{s}\n", .{explanation});
        } else {
            try stdout.print("Unknown error code: {s}\n\nValid error codes: Z0001-Z0005, Z0100-Z0102, Z0200-Z0202\n", .{code});
        }
        std.process.exit(0);
    }

    const path = file_path orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: no input file specified\n", .{});
        std.process.exit(1);
    };

    // Use arena for all compilation allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Multi-file mode: discover sibling .zap files only when inside a project
    // directory (the parent directory basename is NOT the root examples dir).
    // A project directory is one where the .zap file lives alongside other .zap files
    // that are meant to be compiled together (e.g., myapp/types.zap + myapp/app.zap).
    // Single standalone files always use single-file mode.
    const zap_files = zap.project.discoverZapFiles(alloc, path) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error discovering .zap files: {}\n", .{err});
        std.process.exit(1);
    };

    // Multi-file mode: compile all files together
    if (zap_files.len > 1 and !emit_zig) {
        const exit_code = compileMultiFile(allocator, alloc, zap_files, lib_mode, strict_types, zig_flags.items) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            switch (err) {
                error.CircularDependency => try stderr.print("Error: circular dependency between .zap files\n", .{}),
                error.NoMainFile => try stderr.print("Error: no file defines a `main` function\n", .{}),
                error.MultipleMainFiles => try stderr.print("Error: multiple files define a `main` function\n", .{}),
                else => try stderr.print("Error during multi-file compilation: {}\n", .{err}),
            }
            std.process.exit(1);
        };
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
        if (run_after_build) {
            // Find the main file stem for binary name
            const main_stem = blk: {
                for (zap_files) |zf| {
                    const src = std.fs.cwd().readFileAlloc(alloc, zf, 10 * 1024 * 1024) catch continue;
                    if (std.mem.indexOf(u8, src, "def main(") != null) {
                        const bn = std.fs.path.basename(zf);
                        break :blk if (std.mem.endsWith(u8, bn, ".zap")) bn[0 .. bn.len - 4] else bn;
                    }
                }
                break :blk "main";
            };
            const run_exit = runBinaryByName(allocator, main_stem, run_args.items) catch |err| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                try stderr.print("Error running program: {}\n", .{err});
                std.process.exit(1);
            };
            std.process.exit(run_exit);
        }
        return;
    }

    const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    // Create shared DiagnosticEngine
    var diag_engine = zap.DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.use_color = zap.diagnostics.detectColor();

    // Phase 1: Parse (with stdlib prepended)
    const prepend_result = zap.stdlib.prependStdlib(alloc, source) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error loading standard library\n", .{});
        std.process.exit(1);
    };
    const full_source = prepend_result.source;

    diag_engine.setSource(full_source, path);
    diag_engine.setLineOffset(prepend_result.stdlib_line_count);

    var parser = zap.Parser.init(alloc, full_source);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        // Drain parser errors into DiagnosticEngine
        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Drain any parser errors (even on success, there may be warnings)
    for (parser.errors.items) |parse_err| {
        try diag_engine.reportDiagnostic(.{
            .severity = .@"error",
            .message = parse_err.message,
            .span = parse_err.span,
            .label = parse_err.label,
            .help = parse_err.help,
        });
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    }

    // Phase 2: Collect declarations
    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Drain collector errors
    for (collector.errors.items) |collect_err| {
        try diag_engine.err(collect_err.message, collect_err.span);
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    }

    // Phase 3: Macro expansion
    var macro_engine = zap.MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Drain macro errors
    for (macro_engine.errors.items) |macro_err| {
        try diag_engine.err(macro_err.message, macro_err.span);
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    }

    // Phase 4: Desugaring
    var desugarer = zap.Desugarer.init(alloc, &parser.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        try diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 });
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Phase 5: Type checking
    var type_checker = zap.types.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    // Drain type checker errors — hard errors always block, others respect --strict-types
    const type_severity: zap.Severity = if (strict_types) .@"error" else .warning;
    for (type_checker.errors.items) |type_err| {
        try diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        });
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    }

    // Phase 6: HIR lowering
    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Drain HIR errors
    for (hir_builder.errors.items) |hir_err| {
        try diag_engine.err(hir_err.message, hir_err.span);
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    }

    // Phase 7: IR lowering
    var ir_builder = zap.ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    const ir_program = ir_builder.buildProgram(&hir_program) catch {
        try diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 });
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Phase 8: Code generation
    var codegen = zap.CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.lib_mode = lib_mode;
    codegen.emitProgram(&ir_program) catch {
        try diag_engine.err("Error during code generation", .{ .start = 0, .end = 0 });
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Emit any accumulated warnings before proceeding
    if (diag_engine.warningCount() > 0) {
        try emitDiagnostics(&diag_engine, alloc);
    }

    const output = codegen.getOutput();

    // Validate generated Zig by parsing it — catches malformed output before
    // writing to disk, giving a clear Zap error instead of a cryptic zig build failure.
    if (output.len > 0) {
        const sentinel = try alloc.dupeZ(u8, output);
        const zig_ast = try std.zig.Ast.parse(alloc, sentinel, .zig);
        if (zig_ast.errors.len > 0) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("internal error: generated Zig source is malformed ({d} parse errors)\n", .{zig_ast.errors.len});
            try stderr.print("this is a bug in the Zap compiler — please report it\n", .{});
            try stderr.print("use --emit-zig to inspect the generated code\n", .{});
            std.process.exit(1);
        }
    }

    if (emit_zig) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("{s}", .{output});
    } else {
        // Write generated Zig + runtime to .zap-cache, invoke zig build
        const exit_code = compileWithZig(allocator, path, output, lib_mode, zig_flags.items) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Error invoking zig compiler: {}\n", .{err});
            std.process.exit(1);
        };
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }

        if (run_after_build) {
            const run_exit = runBinary(allocator, path, run_args.items) catch |err| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                try stderr.print("Error running program: {}\n", .{err});
                std.process.exit(1);
            };
            std.process.exit(run_exit);
        }
    }
}

fn runBinaryByName(allocator: std.mem.Allocator, stem: []const u8, program_args: []const []const u8) !u8 {
    const bin_path = try std.fs.path.join(allocator, &.{ "zap-out", "bin", stem });
    defer allocator.free(bin_path);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path);
    for (program_args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn compileMultiFile(
    allocator: std.mem.Allocator,
    alloc: std.mem.Allocator,
    zap_files: []const []const u8,
    lib_mode: bool,
    strict_types: bool,
    zig_flags: []const []const u8,
) !u8 {
    const stderr_writer = std.fs.File.stderr().deprecatedWriter();

    // Phase 1: Parse all files and analyze dependencies
    var file_units: std.ArrayList(zap.project.FileUnit) = .empty;

    for (zap_files) |zf| {
        const source = try std.fs.cwd().readFileAlloc(alloc, zf, 10 * 1024 * 1024);

        var diag_engine = zap.DiagnosticEngine.init(alloc);
        defer diag_engine.deinit();
        diag_engine.use_color = zap.diagnostics.detectColor();

        const prepend_result = try zap.stdlib.prependStdlib(alloc, source);
        const full_source = prepend_result.source;

        diag_engine.setSource(full_source, zf);
        diag_engine.setLineOffset(prepend_result.stdlib_line_count);

        var parser = zap.Parser.init(alloc, full_source);
        defer parser.deinit();

        const program = parser.parseProgram() catch {
            for (parser.errors.items) |parse_err| {
                diag_engine.reportDiagnostic(.{
                    .severity = .@"error",
                    .message = parse_err.message,
                    .span = parse_err.span,
                    .label = parse_err.label,
                    .help = parse_err.help,
                }) catch {};
            }
            try emitDiagnostics(&diag_engine, alloc);
            return 1;
        };

        // Analyze what the file defines and references
        const analysis = try zap.project.analyzeProgram(alloc, &program, &parser.interner);

        const basename = std.fs.path.basename(zf);
        const stem = if (std.mem.endsWith(u8, basename, ".zap"))
            basename[0 .. basename.len - 4]
        else
            basename;

        try file_units.append(alloc, .{
            .path = zf,
            .stem = stem,
            .source = source,
            .defines_types = analysis.defines_types,
            .defines_modules = analysis.defines_modules,
            .defines_functions = analysis.defines_functions,
            .references_types = analysis.references_types,
            .references_modules = analysis.references_modules,
            .has_main = analysis.has_main,
        });
    }

    const files = try file_units.toOwnedSlice(alloc);

    // Phase 2: Build dependency graph and check for cycles
    const dep_graph = try zap.project.DependencyGraph.init(alloc, files);
    const sorted = dep_graph.topologicalSort(alloc) catch |err| {
        switch (err) {
            error.CircularDependency => {
                const cycle_msg = dep_graph.formatCycleError(alloc) catch "error: circular dependency between .zap files\n";
                try stderr_writer.print("{s}", .{cycle_msg});
                return 1;
            },
            else => return err,
        }
    };

    // Phase 3: Find the main file
    const main_idx = try dep_graph.findMainFile();

    // Phase 4: Concatenate all sources in dependency order and compile as one unit.
    // This ensures cross-file type references resolve correctly through the
    // shared parser/interner/collector/type-checker pipeline.
    var combined_source: std.ArrayList(u8) = .empty;
    for (sorted) |file_idx| {
        const file = files[file_idx];
        try combined_source.appendSlice(alloc, file.source);
        try combined_source.append(alloc, '\n');
    }
    const merged_source = try combined_source.toOwnedSlice(alloc);

    var diag_engine = zap.DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();
    diag_engine.use_color = zap.diagnostics.detectColor();

    const prepend_result = try zap.stdlib.prependStdlib(alloc, merged_source);
    const full_source = prepend_result.source;
    diag_engine.setSource(full_source, files[main_idx].path);
    diag_engine.setLineOffset(prepend_result.stdlib_line_count);

    var parser = zap.Parser.init(alloc, full_source);
    defer parser.deinit();
    const program = parser.parseProgram() catch {
        for (parser.errors.items) |parse_err| {
            diag_engine.reportDiagnostic(.{
                .severity = .@"error",
                .message = parse_err.message,
                .span = parse_err.span,
                .label = parse_err.label,
                .help = parse_err.help,
            }) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        for (collector.errors.items) |collect_err| {
            diag_engine.err(collect_err.message, collect_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var macro_engine = zap.MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded_program = macro_engine.expandProgram(&program) catch {
        for (macro_engine.errors.items) |macro_err| {
            diag_engine.err(macro_err.message, macro_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var desugarer = zap.Desugarer.init(alloc, &parser.interner);
    const desugared_program = desugarer.desugarProgram(&expanded_program) catch {
        try diag_engine.err("Error during desugaring", .{ .start = 0, .end = 0 });
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var type_checker = zap.types.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.stdlib_line_count = prepend_result.stdlib_line_count;
    type_checker.checkProgram(&desugared_program) catch {};
    type_checker.checkUnusedBindings() catch {};

    const type_severity: zap.Severity = if (strict_types) .@"error" else .warning;
    for (type_checker.errors.items) |type_err| {
        try diag_engine.reportDiagnostic(.{
            .severity = type_err.severity orelse type_severity,
            .message = type_err.message,
            .span = type_err.span,
            .label = type_err.label,
            .help = type_err.help,
            .secondary_spans = type_err.secondary_spans,
        });
    }
    if (diag_engine.hasErrors()) {
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    }

    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared_program) catch {
        for (hir_builder.errors.items) |hir_err| {
            diag_engine.err(hir_err.message, hir_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var ir_builder = zap.ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    const ir_program = ir_builder.buildProgram(&hir_program) catch {
        try diag_engine.err("Error during IR lowering", .{ .start = 0, .end = 0 });
        try emitDiagnostics(&diag_engine, alloc);
        return 1;
    };

    var codegen = zap.CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.emitProgram(&ir_program) catch {
        try stderr_writer.print("Error during code generation\n", .{});
        return 1;
    };

    if (diag_engine.warningCount() > 0) {
        try emitDiagnostics(&diag_engine, alloc);
    }

    const output = codegen.getOutput();

    // Phase 5: Split output into per-file .zig files with @import headers
    var cache_dir = try std.fs.cwd().makeOpenPath(".zap-cache", .{});
    defer cache_dir.close();
    try cache_dir.makePath("src");

    // If the Zap compiler binary changed, invalidate the Zig build cache
    invalidateCacheIfCompilerChanged(alloc, cache_dir);

    _ = try writeIfChanged(cache_dir, "src/zap_runtime.zig", runtime_source);

    const main_file = files[main_idx];

    if (files.len <= 1) {
        // Single file — write as-is
        _ = try writeIfChanged(cache_dir, "src/main.zig", output);
    } else {
        // Multi-file: split output by source file ownership
        try splitAndWritePerFile(alloc, cache_dir, output, files, &dep_graph, main_idx);
    }

    // Generate and write build.zig — use the main file's stem as binary name
    const build_zig = try generateBuildZig(alloc, main_file.stem, lib_mode);
    _ = try writeIfChanged(cache_dir, "build.zig", build_zig);

    // Invoke zig build
    const cache_path = try cache_dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_path);

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const prefix = try std.fs.path.join(allocator, &.{ cwd_path, "zap-out" });
    defer allocator.free(prefix);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig");
    try argv.append(allocator, "build");
    try argv.append(allocator, "--prefix");
    try argv.append(allocator, prefix);
    for (zig_flags) |flag| {
        try argv.append(allocator, flag);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.cwd = cache_path;
    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Split a merged Zig output into per-file .zig files based on which source file
/// defines each type and module. Adds @import headers for cross-file references.
fn splitAndWritePerFile(
    alloc: std.mem.Allocator,
    cache_dir: std.fs.Dir,
    output: []const u8,
    files: []const zap.project.FileUnit,
    dep_graph: *const zap.project.DependencyGraph,
    main_idx: usize,
) !void {
    // Parse the merged output into chunks: header, type defs, functions
    // Each chunk is attributed to a source file based on name matching.

    // Collect all lines, grouping consecutive lines into definition blocks.
    // A definition block starts with "pub const" or "fn " at column 0.
    const Block = struct {
        text: []const u8,
        kind: enum { header, type_def, function, other },
        name: []const u8, // extracted type/function name
    };

    var blocks: std.ArrayList(Block) = .empty;
    var pos: usize = 0;

    // Skip the standard header (first few lines: comments, imports)
    var header_end: usize = 0;
    while (pos < output.len) {
        const line_end = std.mem.indexOfScalar(u8, output[pos..], '\n') orelse output.len - pos;
        const line = output[pos .. pos + line_end];
        if (std.mem.startsWith(u8, line, "pub const ") or
            std.mem.startsWith(u8, line, "fn ") or
            std.mem.startsWith(u8, line, "pub fn "))
        {
            header_end = pos;
            break;
        }
        pos += line_end + 1;
    }

    const header = output[0..header_end];
    pos = header_end;

    // Parse remaining output into definition blocks
    while (pos < output.len) {
        // Skip blank lines
        while (pos < output.len and output[pos] == '\n') : (pos += 1) {}
        if (pos >= output.len) break;

        const block_start = pos;
        const first_line_end = (std.mem.indexOfScalar(u8, output[pos..], '\n') orelse output.len - pos);
        const first_line = output[pos .. pos + first_line_end];

        if (std.mem.startsWith(u8, first_line, "pub const ")) {
            // Type definition — find the closing "};
            const name_start = "pub const ".len;
            const name_end = std.mem.indexOfScalar(u8, first_line[name_start..], ' ') orelse first_line.len - name_start;
            const name = first_line[name_start .. name_start + name_end];

            // Find closing "};\n"
            pos += first_line_end + 1;
            while (pos < output.len) {
                if (std.mem.startsWith(u8, output[pos..], "};\n")) {
                    pos += 3;
                    break;
                }
                pos += (std.mem.indexOfScalar(u8, output[pos..], '\n') orelse output.len - pos) + 1;
            }
            try blocks.append(alloc, .{
                .text = output[block_start..pos],
                .kind = .type_def,
                .name = name,
            });
        } else if (std.mem.startsWith(u8, first_line, "fn ") or std.mem.startsWith(u8, first_line, "pub fn ")) {
            // Function — find the closing "}\n" at column 0
            const fn_prefix = if (std.mem.startsWith(u8, first_line, "pub fn ")) "pub fn " else "fn ";
            const name_start = fn_prefix.len;
            const name_end = std.mem.indexOfScalar(u8, first_line[name_start..], '(') orelse first_line.len - name_start;
            const name = first_line[name_start .. name_start + name_end];

            pos += first_line_end + 1;
            while (pos < output.len) {
                if (output[pos] == '}' and (pos + 1 >= output.len or output[pos + 1] == '\n')) {
                    pos += 2;
                    break;
                }
                pos += (std.mem.indexOfScalar(u8, output[pos..], '\n') orelse output.len - pos) + 1;
            }
            try blocks.append(alloc, .{
                .text = output[block_start..pos],
                .kind = .function,
                .name = name,
            });
        } else {
            // Skip unknown line
            pos += first_line_end + 1;
        }
    }

    // Map each block to a source file
    for (files, 0..) |file, file_idx| {
        var file_output: std.ArrayList(u8) = .empty;

        // Write header with @import for dependencies
        try file_output.appendSlice(alloc, "// Generated by Zap compiler\n");
        try file_output.appendSlice(alloc, "const std = @import(\"std\");\n");
        try file_output.appendSlice(alloc, "const zap_runtime = @import(\"zap_runtime.zig\");\n");

        // Collect all generated code for this file's functions to check type usage
        var file_func_text: std.ArrayList(u8) = .empty;
        for (blocks.items) |block| {
            if (block.kind == .function) {
                var belongs_check = false;
                for (file.defines_modules) |dm| {
                    const pfx = try std.fmt.allocPrint(alloc, "{s}__", .{dm});
                    if (std.mem.startsWith(u8, block.name, pfx)) {
                        belongs_check = true;
                        break;
                    }
                }
                if (!belongs_check and std.mem.eql(u8, block.name, "main") and file.has_main) {
                    belongs_check = true;
                }
                if (!belongs_check and std.mem.endsWith(u8, block.name, "__main") and file.has_main) {
                    belongs_check = true;
                }
                if (belongs_check) {
                    try file_func_text.appendSlice(alloc, block.text);
                }
            }
        }
        const func_text = file_func_text.items;

        // Add @import for each dependency file, importing types used in this file's code
        for (dep_graph.edges[file_idx]) |dep_idx| {
            const dep_file = files[dep_idx];
            var any_imported = false;
            var type_aliases: std.ArrayList(u8) = .empty;

            for (dep_file.defines_types) |type_name| {
                // Check if this type is used anywhere in this file's functions
                const used_in_funcs = std.mem.indexOf(u8, func_text, type_name) != null;
                const used_in_refs = blk: {
                    for (file.references_types) |ref_type| {
                        if (std.mem.eql(u8, ref_type, type_name)) break :blk true;
                    }
                    break :blk false;
                };
                if (used_in_funcs or used_in_refs) {
                    const dep_zig = if (dep_idx == main_idx) "main.zig" else try std.fmt.allocPrint(alloc, "{s}.zig", .{dep_file.stem});
                    if (!any_imported) {
                        const import_line = try std.fmt.allocPrint(alloc, "const {s} = @import(\"{s}\");\n", .{ dep_file.stem, dep_zig });
                        try file_output.appendSlice(alloc, import_line);
                        any_imported = true;
                    }
                    const alias = try std.fmt.allocPrint(alloc, "const {s} = {s}.{s};\n", .{ type_name, dep_file.stem, type_name });
                    try type_aliases.appendSlice(alloc, alias);
                }
            }
            if (any_imported) {
                try file_output.appendSlice(alloc, type_aliases.items);
            }
        }

        try file_output.appendSlice(alloc, "\n");

        // Add type definitions owned by this file
        for (blocks.items) |block| {
            if (block.kind == .type_def) {
                for (file.defines_types) |dt| {
                    if (std.mem.eql(u8, block.name, dt)) {
                        try file_output.appendSlice(alloc, block.text);
                        try file_output.appendSlice(alloc, "\n");
                        break;
                    }
                }
            }
        }

        // Add functions owned by this file
        for (blocks.items) |block| {
            if (block.kind == .function) {
                var belongs = false;

                // Check if function belongs to a module defined in this file
                for (file.defines_modules) |dm| {
                    const prefix = try std.fmt.allocPrint(alloc, "{s}__", .{dm});
                    if (std.mem.startsWith(u8, block.name, prefix)) {
                        belongs = true;
                        break;
                    }
                }

                // Top-level function "main" belongs to the file with has_main
                if (!belongs and std.mem.eql(u8, block.name, "main") and file.has_main) {
                    belongs = true;
                }

                // Stdlib functions (Kernel__, IO__) — include in every file that needs them
                // For simplicity, include in the main file only
                if (!belongs and file_idx == main_idx) {
                    if (std.mem.startsWith(u8, block.name, "Kernel__") or
                        std.mem.startsWith(u8, block.name, "IO__"))
                    {
                        belongs = true;
                    }
                }

                if (belongs) {
                    try file_output.appendSlice(alloc, block.text);
                    try file_output.appendSlice(alloc, "\n");
                }
            }
        }

        // Also add union type defs (synthesized — name ends with _Union)
        for (blocks.items) |block| {
            if (block.kind == .type_def and std.mem.endsWith(u8, block.name, "_Union")) {
                // Check if a function in this file uses this union
                for (blocks.items) |fn_block| {
                    if (fn_block.kind != .function) continue;
                    for (file.defines_modules) |dm| {
                        const prefix = try std.fmt.allocPrint(alloc, "{s}__", .{dm});
                        if (std.mem.startsWith(u8, fn_block.name, prefix)) {
                            if (std.mem.indexOf(u8, fn_block.text, block.name) != null) {
                                try file_output.appendSlice(alloc, block.text);
                                try file_output.appendSlice(alloc, "\n");
                                break;
                            }
                        }
                    }
                }
            }
        }

        const file_content = try file_output.toOwnedSlice(alloc);
        if (file_idx == main_idx) {
            _ = try writeIfChanged(cache_dir, "src/main.zig", file_content);
        } else {
            const sub_path = try std.fmt.allocPrint(alloc, "src/{s}.zig", .{file.stem});
            _ = try writeIfChanged(cache_dir, sub_path, file_content);
        }
    }

    _ = header;
}

fn emitDiagnostics(diag_engine: *const zap.DiagnosticEngine, alloc: std.mem.Allocator) !void {
    const output = try diag_engine.format(alloc);
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print("{s}", .{output});
}

/// Check if the Zap compiler has been rebuilt since the last compilation.
/// If so, delete the Zig build cache to force a full recompile.
fn invalidateCacheIfCompilerChanged(allocator: std.mem.Allocator, cache_dir: std.fs.Dir) void {
    // Get the Zap binary's modification time as its identity
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch return;
    const self_file = std.fs.cwd().openFile(self_path, .{}) catch return;
    defer self_file.close();
    const self_stat = self_file.stat() catch return;

    // Use mtime + size as a simple identity
    const stamp = std.fmt.allocPrint(allocator, "{d}:{d}", .{ self_stat.mtime, self_stat.size }) catch return;

    // Read the stored stamp
    const stamp_match = blk: {
        const stamp_file = cache_dir.openFile(".zap-compiler-stamp", .{}) catch break :blk false;
        defer stamp_file.close();
        var buf: [64]u8 = undefined;
        const n = stamp_file.readAll(&buf) catch break :blk false;
        break :blk std.mem.eql(u8, buf[0..n], stamp);
    };

    if (!stamp_match) {
        // Compiler changed — nuke the Zig cache so everything rebuilds
        cache_dir.deleteTree(".zig-cache") catch {};
        cache_dir.deleteTree("zig-cache") catch {};

        // Write new stamp
        cache_dir.writeFile(.{ .sub_path = ".zap-compiler-stamp", .data = stamp }) catch {};
    }
}

/// Write file only if content differs from what's on disk.
/// Returns true if the file was written (content changed or didn't exist).
fn writeIfChanged(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !bool {
    if (dir.openFile(sub_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.size == content.len) {
            // Read existing content and compare
            const buf = try std.heap.page_allocator.alloc(u8, content.len);
            defer std.heap.page_allocator.free(buf);
            const bytes_read = try file.readAll(buf);
            if (bytes_read == content.len and std.mem.eql(u8, buf[0..bytes_read], content)) {
                return false; // unchanged
            }
        }
    } else |_| {} // file doesn't exist, write it

    try dir.writeFile(.{ .sub_path = sub_path, .data = content });
    return true; // changed
}

fn generateBuildZig(allocator: std.mem.Allocator, name: []const u8, lib_mode: bool) ![]const u8 {
    const artifact_call = if (lib_mode) "addLibrary" else "addExecutable";
    const source_file = if (lib_mode) "src/root.zig" else "src/main.zig";

    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const artifact = b.{s}(.{{
        \\        .name = "{s}",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("{s}"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\    b.installArtifact(artifact);
        \\}}
        \\
    , .{ artifact_call, name, source_file });
}

fn runBinary(allocator: std.mem.Allocator, zap_path: []const u8, program_args: []const []const u8) !u8 {
    const basename = std.fs.path.basename(zap_path);
    const stem = if (std.mem.endsWith(u8, basename, ".zap"))
        basename[0 .. basename.len - 4]
    else
        basename;

    const bin_path = try std.fs.path.join(allocator, &.{ "zap-out", "bin", stem });
    defer allocator.free(bin_path);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path);
    for (program_args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stdin_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn compileWithZig(allocator: std.mem.Allocator, zap_path: []const u8, zig_source: []const u8, lib_mode: bool, zig_flags: []const []const u8) !u8 {
    // Determine output name from input path
    const basename = std.fs.path.basename(zap_path);
    const stem = if (std.mem.endsWith(u8, basename, ".zap"))
        basename[0 .. basename.len - 4]
    else
        basename;

    // Persistent cache directory — survives across runs for Zig cache reuse
    var cache_dir = try std.fs.cwd().makeOpenPath(".zap-cache", .{});
    defer cache_dir.close();
    try cache_dir.makePath("src");

    // If the Zap compiler binary changed, invalidate the Zig build cache
    invalidateCacheIfCompilerChanged(allocator, cache_dir);

    // Write source files only when content changes (enables Zig cache hits)
    const source_file = if (lib_mode) "src/root.zig" else "src/main.zig";
    _ = try writeIfChanged(cache_dir, source_file, zig_source);
    _ = try writeIfChanged(cache_dir, "src/zap_runtime.zig", runtime_source);

    // Generate and write build.zig
    const build_zig = try generateBuildZig(allocator, stem, lib_mode);
    defer allocator.free(build_zig);
    _ = try writeIfChanged(cache_dir, "build.zig", build_zig);

    // Get absolute paths
    const cache_path = try cache_dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_path);

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // Resolve output install prefix to cwd's zap-out/
    const prefix = try std.fs.path.join(allocator, &.{ cwd_path, "zap-out" });
    defer allocator.free(prefix);

    // Build argv: zig build --prefix <zap-out> [flags...]
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "build");
    try argv.append(allocator, "--prefix");
    try argv.append(allocator, prefix);

    // Forward all flags to zig build
    for (zig_flags) |flag| {
        try argv.append(allocator, flag);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.cwd = cache_path;
    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

// ============================================================
// Error code explanations (--explain)
// ============================================================

fn getErrorExplanation(code: []const u8) ?[]const u8 {
    const explanations = std.StaticStringMap([]const u8).initComptime(.{
        // Syntax errors (Z00xx)
        .{ "Z0001",
            \\Error Z0001: Missing `do` keyword
            \\
            \\Function and module definitions in Zap require a `do` keyword to
            \\start their body, and `end` to close it.
            \\
            \\  # Incorrect
            \\  def greet(name)
            \\    "hello " <> name
            \\  end
            \\
            \\  # Correct
            \\  def greet(name) do
            \\    "hello " <> name
            \\  end
        },
        .{ "Z0002",
            \\Error Z0002: Missing `end` keyword
            \\
            \\Every `do` block must be closed with a matching `end`.
            \\Check that your `def`, `defmodule`, `if`, `case`, and `with`
            \\blocks all have their closing `end`.
        },
        .{ "Z0003",
            \\Error Z0003: Unclosed delimiter
            \\
            \\An opening delimiter `(`, `[`, or `{` was never closed.
            \\Check that every opening delimiter has a matching closing one.
        },
        .{ "Z0004",
            \\Error Z0004: Unexpected token in expression
            \\
            \\The parser found a token that cannot start an expression.
            \\Expressions can start with: literals (numbers, strings, atoms),
            \\variables, operators, or keywords like `if`, `case`, `with`.
        },
        .{ "Z0005",
            \\Error Z0005: Invalid pattern
            \\
            \\Patterns appear on the left side of `=` and in `case` clauses.
            \\Valid patterns: literals, variables, tuples `{a, b}`, lists `[a, b]`,
            \\the wildcard `_`, and pin expressions `^var`.
        },

        // Name resolution errors (Z01xx)
        .{ "Z0100",
            \\Error Z0100: Undefined variable
            \\
            \\A variable was referenced but never defined in this scope.
            \\Variables must be assigned before use:
            \\
            \\  name = "world"
            \\  greet(name)   # ok — `name` is defined above
        },
        .{ "Z0101",
            \\Error Z0101: Undefined function
            \\
            \\A function was called but is not defined or imported.
            \\Make sure the function exists and is imported if it's in
            \\another module:
            \\
            \\  import MyModule, only: [my_func: 1]
        },
        .{ "Z0102",
            \\Error Z0102: Misspelled keyword
            \\
            \\An identifier looks very similar to a Zap keyword.
            \\Check for typos in keywords like `defmodule`, `def`, `do`, `end`.
        },

        // Type errors (Z02xx)
        .{ "Z0200",
            \\Error Z0200: Type mismatch
            \\
            \\An expression produces a different type than expected.
            \\This commonly happens with return types:
            \\
            \\  def bad() :: i64 do
            \\    "not a number"   # String, but i64 expected
            \\  end
        },
        .{ "Z0201",
            \\Error Z0201: Arithmetic type mismatch
            \\
            \\Arithmetic operators (+, -, *, /) require both operands to
            \\be the same numeric type. You cannot mix String and i64, for example.
        },
        .{ "Z0202",
            \\Error Z0202: Non-boolean condition
            \\
            \\`if` expressions require a Bool condition. If you have a number
            \\or other value, compare it explicitly:
            \\
            \\  if count > 0 do    # correct — comparison returns Bool
            \\    ...
            \\  end
        },
    });

    return explanations.get(code);
}

test "main module tests" {
    _ = @import("zap");
}
