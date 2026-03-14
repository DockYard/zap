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
        try stderr.print("Usage: zap [--emit-zig] <file.zap> [zig-flags...]\n", .{});
        std.process.exit(1);
    }

    // Separate zap flags, the .zap file, and zig flags
    var emit_zig = false;
    var file_path: ?[]const u8 = null;
    var zig_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zig_flags.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
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
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("{s}", .{output});
    } else {
        // Write generated Zig + runtime to temp dir, invoke zig build-exe
        const exit_code = compileWithZig(allocator, path, output, zig_flags.items) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Error invoking zig compiler: {}\n", .{err});
            std.process.exit(1);
        };
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
    }
}

const build_zig_prefix =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const exe = b.addExecutable(.{
    \\        .name = "
;

const build_zig_suffix =
    \\",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\    b.installArtifact(exe);
    \\}
    \\
;

fn compileWithZig(allocator: std.mem.Allocator, zap_path: []const u8, zig_source: []const u8, zig_flags: []const []const u8) !u8 {
    // Determine output name from input path
    const basename = std.fs.path.basename(zap_path);
    const stem = if (std.mem.endsWith(u8, basename, ".zap"))
        basename[0 .. basename.len - 4]
    else
        basename;

    // Create temp directory with src/ subdirectory
    var tmp_dir = try std.fs.cwd().makeOpenPath(".zig-cache/zap-tmp", .{});
    defer {
        std.fs.cwd().deleteTree(".zig-cache/zap-tmp") catch {};
    }
    defer tmp_dir.close();

    try tmp_dir.makePath("src");

    // Write generated source
    try tmp_dir.writeFile(.{ .sub_path = "src/main.zig", .data = zig_source });

    // Write runtime alongside it so @import("zap_runtime.zig") resolves
    try tmp_dir.writeFile(.{ .sub_path = "src/zap_runtime.zig", .data = runtime_source });

    // Write build.zig
    const build_zig = try std.mem.concat(allocator, u8, &.{ build_zig_prefix, stem, build_zig_suffix });
    defer allocator.free(build_zig);
    try tmp_dir.writeFile(.{ .sub_path = "build.zig", .data = build_zig });

    // Get absolute paths
    const tmp_path = try tmp_dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // Resolve output install prefix to cwd's zap-out/
    const prefix = try std.fs.path.join(allocator, &.{ cwd_path, "zap-out" });
    defer allocator.free(prefix);

    // Build argv: zig build --prefix <zap-out> --build-file <tmp>/build.zig [flags...]
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
    child.cwd = tmp_path;
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
