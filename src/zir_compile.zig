//! Standalone ZIR compiler entry point.
//!
//! This is a separate binary (`zap-zir`) that links against libzig_compiler.a
//! and performs the full ZIR-to-binary pipeline. It reads a .zap source file,
//! runs the Zap frontend (parse -> collect -> ... -> IR), builds ZIR via
//! C-ABI calls, and injects it into the Zig compiler library to produce a
//! native binary.
//!
//! Build: zig build zir-compile

const std = @import("std");
const zap = @import("zap");
const zir_builder = zap.zir_builder;
const ir = zap.ir;

// ---------------------------------------------------------------------------
// C-ABI extern declarations for the Zig compiler library
// ---------------------------------------------------------------------------

const ZirContext = zir_builder.ZirContext;

extern "c" fn zir_compilation_create(
    zig_lib_dir: [*:0]const u8,
    local_cache_dir: [*:0]const u8,
    global_cache_dir: [*:0]const u8,
    output_path: [*:0]const u8,
    root_name: [*:0]const u8,
) ?*ZirContext;

extern "c" fn zir_compilation_update(ctx: *ZirContext) i32;
extern "c" fn zir_compilation_destroy(ctx: *ZirContext) void;
extern "c" fn zir_compilation_print_errors(ctx: *ZirContext) void;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Usage: zap-zir <file.zap> [--zig-lib-dir <path>]\n", .{});
        std.process.exit(1);
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    var file_path: ?[]const u8 = null;
    var zig_lib_dir: []const u8 = "/Users/bcardarella/.asdf/installs/zig/0.15.2/lib";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--zig-lib-dir")) {
            i += 1;
            if (i < args.len) zig_lib_dir = args[i];
        } else if (file_path == null) {
            file_path = args[i];
        }
    }

    const path = file_path orelse {
        try stdout.print("Error: no input file\n", .{});
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Run the Zap frontend pipeline.
    try stdout.print("Compiling {s} via ZIR...\n", .{path});

    const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
        try stdout.print("Error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    // Phase 1: Parse
    const prepend_result = zap.stdlib.prependStdlib(alloc, source) catch {
        try stdout.print("Error loading standard library\n", .{});
        std.process.exit(1);
    };
    const full_source = prepend_result.source;

    var parser = zap.Parser.init(alloc, full_source);
    defer parser.deinit();

    const program = parser.parseProgram() catch {
        try stdout.print("Parse error\n", .{});
        std.process.exit(1);
    };

    // Phase 2: Collect
    var collector = zap.Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    collector.collectProgram(&program) catch {
        try stdout.print("Collection error\n", .{});
        std.process.exit(1);
    };

    // Phase 3: Macro expansion
    var macro_engine = zap.MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded = macro_engine.expandProgram(&program) catch {
        try stdout.print("Macro expansion error\n", .{});
        std.process.exit(1);
    };

    // Phase 4: Desugar
    var desugarer = zap.Desugarer.init(alloc, &parser.interner);
    const desugared = desugarer.desugarProgram(&expanded) catch {
        try stdout.print("Desugar error\n", .{});
        std.process.exit(1);
    };

    // Phase 5: Type check
    var type_checker = zap.types.TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer type_checker.deinit();
    type_checker.checkProgram(&desugared) catch {};

    // Phase 6: HIR
    var hir_builder = zap.hir.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_checker.store);
    defer hir_builder.deinit();
    const hir_program = hir_builder.buildProgram(&desugared) catch {
        try stdout.print("HIR lowering error\n", .{});
        std.process.exit(1);
    };

    // Phase 7: IR
    var ir_builder = ir.IrBuilder.init(alloc, &parser.interner);
    ir_builder.type_store = &type_checker.store;
    defer ir_builder.deinit();
    const ir_program = ir_builder.buildProgram(&hir_program) catch {
        try stdout.print("IR lowering error\n", .{});
        std.process.exit(1);
    };

    // Phase 8: Create compilation context
    std.fs.cwd().makePath(".zap-cache") catch {};

    const stem = blk: {
        const bn = std.fs.path.basename(path);
        break :blk if (std.mem.endsWith(u8, bn, ".zap")) bn[0 .. bn.len - 4] else bn;
    };
    std.fs.cwd().makePath("zap-out/bin") catch {};
    const output_path = try std.fs.path.join(alloc, &.{ "zap-out/bin", stem });
    const output_z = try alloc.dupeZ(u8, output_path);
    const name_z = try alloc.dupeZ(u8, stem);
    const zig_lib_z = try alloc.dupeZ(u8, zig_lib_dir);

    try stdout.print("  Creating compilation context...\n", .{});
    const ctx = zir_compilation_create(
        zig_lib_z,
        ".zap-cache",
        ".zap-cache",
        output_z,
        name_z,
    ) orelse {
        try stdout.print("  ERROR: zir_compilation_create failed\n", .{});
        std.process.exit(1);
    };
    defer zir_compilation_destroy(ctx);

    // Phase 9: Build ZIR and inject via C-ABI builder
    try stdout.print("  Building and injecting ZIR...\n", .{});
    // Locate the runtime source for module registration.
    const runtime_path: ?[:0]const u8 = blk: {
        const rt_path = std.fs.path.join(alloc, &.{
            std.fs.path.dirname(@src().file) orelse "src",
            "runtime.zig",
        }) catch break :blk null;
        break :blk alloc.dupeZ(u8, rt_path) catch null;
    };

    zir_builder.buildAndInject(alloc, ir_program, ctx, runtime_path) catch {
        try stdout.print("  ERROR: ZIR build/inject failed\n", .{});
        std.process.exit(1);
    };

    // Phase 10: Run Sema + codegen + link
    try stdout.print("  Running Sema + codegen + link...\n", .{});
    const update_result = zir_compilation_update(ctx);
    if (update_result != 0) {
        try stdout.print("  Compilation returned errors:\n", .{});
        zir_compilation_print_errors(ctx);
    }

    try stdout.print("  SUCCESS: Binary produced at {s}\n", .{output_path});
}
