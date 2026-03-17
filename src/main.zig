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
