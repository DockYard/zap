//! Spike: exercise `zap_fork_compile_zig_to_object` directly.
//!
//! Links against `libzap_compiler.a` from the Zap Zig fork and calls
//! the new C-ABI entry point to compile
//! `spike/manager_v1/src/manager.zig` to an object file. After the
//! call, the driver opens the resulting object file, runs
//! `section_parser.extractSection` over it, and validates the
//! `.zapmem` header.
//!
//! Built/run by build script: see `spike/test_driver/build.zig`.

const std = @import("std");
const parser = @import("section_parser");

const ZapForkTarget = extern struct {
    arch_tag: u16,
    os_tag: u16,
    abi_tag: u16,
    _reserved: u16,
};

const ZapForkOptimize = enum(c_int) {
    Debug = 0,
    ReleaseSafe = 1,
    ReleaseFast = 2,
    ReleaseSmall = 3,
};

const ZapForkResult = enum(c_int) {
    Ok = 0,
    SourceNotFound = 1,
    CompilationFailed = 2,
    TargetUnsupported = 3,
    InternalError = 99,
};

extern "c" fn zap_fork_compile_zig_to_object(
    source_path: [*:0]const u8,
    target: *const ZapForkTarget,
    optimize: ZapForkOptimize,
    out_object_path: [*:0]const u8,
    out_diagnostic_buffer: ?[*]u8,
    out_diagnostic_capacity: usize,
    zig_lib_dir_opt: ?[*:0]const u8,
) ZapForkResult;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const source_path: [:0]const u8 = "spike/manager_v1/src/manager.zig";
    const out_path: [:0]const u8 = "spike/manager_v1/manager_inproc.o";

    // Native target sentinel: arch_tag = 0xFFFF (per spec).
    const target: ZapForkTarget = .{
        .arch_tag = 0xFFFF,
        .os_tag = 0,
        .abi_tag = 0,
        ._reserved = 0,
    };

    var diag: [1024]u8 = undefined;
    // The spike binary is run from the project root; supply ZIG_LIB_DIR
    // from the environment so the primitive can find the Zig stdlib.
    // The user is expected to set ZIG_LIB_DIR (e.g., to the fork's
    // lib/) before running.
    const zig_lib_dir_ptr_c = std.c.getenv("ZIG_LIB_DIR") orelse {
        std.debug.print("ZIG_LIB_DIR not set; export it to the Zig fork's lib/ dir\n", .{});
        std.process.exit(1);
    };
    const zig_lib_dir_z: [:0]const u8 = std.mem.span(zig_lib_dir_ptr_c);
    const result = zap_fork_compile_zig_to_object(
        source_path.ptr,
        &target,
        .ReleaseSafe,
        out_path.ptr,
        &diag,
        diag.len,
        zig_lib_dir_z.ptr,
    );
    if (result != .Ok) {
        const msg = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&diag)), 0);
        std.debug.print("zap_fork_compile_zig_to_object FAILED ({s}): {s}\n", .{ @tagName(result), msg });
        std.process.exit(1);
    }
    std.debug.print("zap_fork_compile_zig_to_object OK\n", .{});

    var io_impl: std.Io.Threaded = .init(ar, .{ .stack_size = 1 * 1024 * 1024 });
    defer io_impl.deinit();
    const io = io_impl.io();
    const dir = std.Io.Dir.cwd();

    const bytes = try dir.readFileAlloc(io, out_path, ar, .limited(16 * 1024 * 1024));
    std.debug.print("output object: {d} bytes\n", .{bytes.len});

    const fmt = parser.detectFormat(bytes);
    std.debug.print("detected format: {s}\n", .{@tagName(fmt)});

    const section = parser.extractSection(bytes) catch |err| {
        std.debug.print("extractSection failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var meta: parser.ZapMemoryManagerMetaV1 = undefined;
    @memcpy(std.mem.asBytes(&meta), section[0..@sizeOf(parser.ZapMemoryManagerMetaV1)]);

    std.debug.print("meta.magic         = 0x{x:0>8}\n", .{meta.magic});
    std.debug.print("meta.abi_major     = {d}\n", .{meta.abi_major});
    std.debug.print("meta.abi_minor     = {d}\n", .{meta.abi_minor});
    std.debug.print("meta.desc_count    = {d}\n", .{meta.desc_count});
    std.debug.print("meta.declared_caps = 0x{x:0>16}\n", .{meta.declared_caps});

    if (meta.magic != parser.ZMEM_MAGIC_LE) {
        std.debug.print("FAIL: magic mismatch\n", .{});
        std.process.exit(1);
    }
    if (meta.abi_major != 1 or meta.size != 32 or meta.declared_caps != 0) {
        std.debug.print("FAIL: meta header invariants\n", .{});
        std.process.exit(1);
    }
    std.debug.print("OK: in-process compile + section parse round-trips\n", .{});
}
