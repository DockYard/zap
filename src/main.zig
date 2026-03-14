const std = @import("std");
const zap = @import("zap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Usage: zap [--emit-zig] <file.zap>\n", .{});
        std.process.exit(1);
    }

    var emit_zig = false;
    var file_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
        } else {
            file_path = arg;
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

    // Phase 1: Parse
    var parser = zap.Parser.init(alloc, source);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        for (parser.errors.items) |err| {
            try stderr.print("{s}:{d}:{d}: error: {s}\n", .{
                path,
                err.span.line,
                err.span.start,
                err.message,
            });
        }
        std.process.exit(1);
    };

    // Phase 2: Collect declarations
    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error during declaration collection\n", .{});
        std.process.exit(1);
    };

    // Phase 4: Type checking
    var type_store = zap.types.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    // Phase 6: HIR lowering
    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&program) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error during HIR lowering\n", .{});
        std.process.exit(1);
    };

    // Phase 7: IR lowering
    var ir_builder = zap.ir.IrBuilder.init(alloc, &parser.interner);
    defer ir_builder.deinit();
    const ir_program = ir_builder.buildProgram(&hir_program) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error during IR lowering\n", .{});
        std.process.exit(1);
    };

    // Phase 8: Code generation
    var codegen = zap.CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.emitProgram(&ir_program) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error during code generation\n", .{});
        std.process.exit(1);
    };

    const output = codegen.getOutput();

    if (emit_zig) {
        // Write generated Zig source to stdout
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("{s}", .{output});
    } else {
        // Summary output
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Compiled {s}: {d} top-level items, {d} modules\n", .{
            path,
            program.top_items.len,
            program.modules.len,
        });
        try stdout.print("Generated {d} bytes of Zig source\n", .{output.len});
        try stdout.print("Functions: {d}\n", .{ir_program.functions.len});
    }
}

test "main module tests" {
    _ = @import("zap");
}
