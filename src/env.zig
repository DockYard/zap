const std = @import("std");

/// Look up an environment variable, returning a Zig-native slice.
///
/// Wraps std.c.getenv so every call site gets ?[]const u8 instead of
/// ?[*:0]u8, removing the need for std.mem.span at each usage.
/// Isolating the C FFI call here also improves future WASM portability.
///
/// Accepts a comptime-known string literal (which is already
/// null-terminated in Zig).
pub fn getenv(comptime name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

/// Same as `getenv` but for runtime-known names.
/// Copies the name into a stack buffer and null-terminates it.
/// Returns null if the name exceeds the buffer or if the variable is unset.
pub fn getenvRuntime(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z: [*:0]const u8 = buf[0..name.len :0];
    const ptr = std.c.getenv(name_z) orelse return null;
    return std.mem.span(ptr);
}
