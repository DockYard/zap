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
        try stderr.print("Usage: zap [--emit-zig] [--lib] [--strict-types] <file.zap> [zig-flags...]\n", .{});
        std.process.exit(1);
    }

    // Separate zap flags, the .zap file, and zig flags
    var emit_zig = false;
    var lib_mode = false;
    var strict_types = false;
    var file_path: ?[]const u8 = null;
    var zig_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zig_flags.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            lib_mode = true;
        } else if (std.mem.eql(u8, arg, "--strict-types")) {
            strict_types = true;
        } else if (file_path == null and std.mem.endsWith(u8, arg, ".zap")) {
            file_path = arg;
        } else {
            try zig_flags.append(allocator, arg);
        }
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

    const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    // Create shared DiagnosticEngine
    var diag_engine = zap.DiagnosticEngine.init(alloc);
    defer diag_engine.deinit();

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
            diag_engine.err(parse_err.message, parse_err.span) catch {};
        }
        try emitDiagnostics(&diag_engine, alloc);
        std.process.exit(1);
    };

    // Drain any parser errors (even on success, there may be warnings)
    for (parser.errors.items) |parse_err| {
        try diag_engine.err(parse_err.message, parse_err.span);
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
    type_checker.checkProgram(&desugared_program) catch {};

    // Drain type checker errors as warnings (or errors if --strict-types)
    const type_severity: zap.Severity = if (strict_types) .@"error" else .warning;
    for (type_checker.errors.items) |type_err| {
        try diag_engine.report(type_severity, type_err.message, type_err.span);
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
    }
}

fn emitDiagnostics(diag_engine: *const zap.DiagnosticEngine, alloc: std.mem.Allocator) !void {
    const output = try diag_engine.format(alloc);
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print("{s}", .{output});
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

test "main module tests" {
    _ = @import("zap");
}
