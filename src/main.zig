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
        try stderr.print("Usage: zap [--emit-zig] [--lib] <file.zap> [zig-flags...]\n", .{});
        std.process.exit(1);
    }

    // Separate zap flags, the .zap file, and zig flags
    var emit_zig = false;
    var lib_mode = false;
    var file_path: ?[]const u8 = null;
    var zig_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zig_flags.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            lib_mode = true;
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
    codegen.lib_mode = lib_mode;
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
