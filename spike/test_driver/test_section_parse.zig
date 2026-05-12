//! Spike: validate `.zapmem` section emission and parsing end-to-end.
//!
//! For each pre-compiled spike-manager object file (Mach-O and ELF):
//!   1. Read the entire .o file into memory.
//!   2. Run `section_parser.extractSection` to pull out the .zapmem
//!      blob.
//!   3. Reinterpret the first 32 bytes as `ZapMemoryManagerMetaV1`.
//!   4. Validate magic, ABI version, core_vtable_offset, etc.
//!   5. Print a summary so the human running the spike can confirm.
//!
//! Run with: `zig run spike/test_driver/test_section_parse.zig`.

const std = @import("std");
const parser = @import("section_parser");

const FIXTURES = [_]struct {
    path: []const u8,
    label: []const u8,
}{
    .{ .path = "spike/manager_v1/manager_macho.o", .label = "macOS Mach-O aarch64" },
    .{ .path = "spike/manager_v1/manager_linux.o", .label = "Linux ELF aarch64" },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    var any_failure = false;

    for (FIXTURES) |fixture| {
        std.debug.print("=== {s} ===\n", .{fixture.label});
        const result = checkFixture(ar, fixture.path) catch |err| {
            std.debug.print("  ERROR: {s}\n", .{@errorName(err)});
            any_failure = true;
            continue;
        };
        if (!result) any_failure = true;
        std.debug.print("\n", .{});
    }

    if (any_failure) {
        std.process.exit(1);
    }
}

fn checkFixture(ar: std.mem.Allocator, path: []const u8) !bool {
    // Run with a small Threaded IO instance; the test driver reads two
    // small object files synchronously and exits.
    var io_impl: std.Io.Threaded = .init(ar, .{ .stack_size = 1 * 1024 * 1024 });
    defer io_impl.deinit();
    const io = io_impl.io();
    const dir = std.Io.Dir.cwd();
    const bytes = dir.readFileAlloc(io, path, ar, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("  readFileAlloc({s}) failed: {s}\n", .{ path, @errorName(err) });
        return false;
    };

    const fmt = parser.detectFormat(bytes);
    std.debug.print("  detected format: {s}\n", .{@tagName(fmt)});

    const section = parser.extractSection(bytes) catch |err| {
        std.debug.print("  extractSection failed: {s}\n", .{@errorName(err)});
        return false;
    };

    std.debug.print("  section size: {d} bytes\n", .{section.len});

    if (section.len < @sizeOf(parser.ZapMemoryManagerMetaV1)) {
        std.debug.print("  section truncated: {d} < {d}\n", .{ section.len, @sizeOf(parser.ZapMemoryManagerMetaV1) });
        return false;
    }
    var meta: parser.ZapMemoryManagerMetaV1 = undefined;
    @memcpy(std.mem.asBytes(&meta), section[0..@sizeOf(parser.ZapMemoryManagerMetaV1)]);

    std.debug.print(
        "  meta.magic            = 0x{x:0>8} (expected 0x{x:0>8})\n",
        .{ meta.magic, parser.ZMEM_MAGIC_LE },
    );
    if (meta.magic != parser.ZMEM_MAGIC_LE) {
        std.debug.print("  FAIL: magic mismatch\n", .{});
        return false;
    }

    std.debug.print("  meta.abi_major        = {d}\n", .{meta.abi_major});
    std.debug.print("  meta.abi_minor        = {d}\n", .{meta.abi_minor});
    std.debug.print("  meta.size             = {d}\n", .{meta.size});
    std.debug.print("  meta._reserved2       = {d}\n", .{meta._reserved2});
    std.debug.print("  meta.desc_count       = {d}\n", .{meta.desc_count});
    std.debug.print("  meta.declared_caps    = 0x{x:0>16}\n", .{meta.declared_caps});
    std.debug.print("  meta.core_vtable_offset = {d}\n", .{meta.core_vtable_offset});
    std.debug.print("  meta.reserved         = {d}\n", .{meta.reserved});

    // ABI v1.0 invariants.
    if (meta.abi_major != 1) return false;
    if (meta.size != 32) return false;
    if (meta.desc_count != 0) return false;
    if (meta.declared_caps != 0) return false;
    if (meta.core_vtable_offset != 32) return false;
    if (meta.reserved != 0) return false;
    if (meta._reserved2 != 0) return false;

    if (section.len < meta.core_vtable_offset + 56) {
        std.debug.print("  FAIL: section too small for core vtable\n", .{});
        return false;
    }
    std.debug.print("  core vtable region    = {d} bytes (at offset {d})\n", .{
        section.len - meta.core_vtable_offset,
        meta.core_vtable_offset,
    });

    std.debug.print("  OK\n", .{});
    return true;
}
