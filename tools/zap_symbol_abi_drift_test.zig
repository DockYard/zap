//! Cross-check that the two independent declarations of the Phase 0
//! `.zap-symbols` sidecar format stay in lockstep.
//!
//! The format is decoded in two places that cannot import one another:
//!
//!   1. `src/zap_symbol_table.zig` — the canonical *builder* + `Reader`,
//!      and the authoritative format documentation. Linked into the
//!      compiler.
//!
//!   2. `src/runtime.zig` — a self-contained read-only `ZapSymbolReader`.
//!      `runtime.zig` is injected into every Zap binary as standalone source
//!      with no sibling files in the emission cache, so it physically cannot
//!      `@import` (1). The decoder is therefore duplicated, on purpose.
//!
//! A unilateral edit to either side's format constants would silently
//! corrupt the Phase 2 crash reporter: the runtime would mis-decode a
//! sidecar the compiler wrote. This test reads both files as text and
//! asserts the load-bearing format constants match, failing the build with a
//! clear diagnostic on drift.
//!
//! (The backtrace capture and symbolize primitives are implemented directly
//! in `src/runtime.zig` against the fork's `std.debug`, with no C-ABI
//! boundary — the runtime IS the Zig source compiled into each Zap binary —
//! so there is no third declaration to keep in sync.)
//!
//! Limitations: this is a textual cross-check of format constants.
//! Behavioural parity of the `ZapSymbolReader` decoder against the canonical
//! `Reader` is exercised by the unit tests in `src/runtime.zig` (which
//! round-trip a blob built with the same byte layout the canonical
//! `Builder.encode` produces) and by the canonical `Reader` tests in
//! `src/zap_symbol_table.zig`.

const std = @import("std");

/// Read a repo-relative source file. The Zig build system runs unit tests
/// with the repository root as the working directory, so a path like
/// `src/runtime.zig` resolves directly. Uses `std.Io.Dir.cwd()` for symmetry
/// with the other `tools/*_drift_test.zig` cross-checks (this fork's `std.fs`
/// has no `cwd`; filesystem access goes through `std.Io.Dir`).
fn readRepoFile(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        rel_path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
}

test "ZSYM format constants match between canonical table and runtime decoder" {
    const allocator = std.testing.allocator;

    const canonical = try readRepoFile(allocator, "src/zap_symbol_table.zig");
    defer allocator.free(canonical);
    const runtime = try readRepoFile(allocator, "src/runtime.zig");
    defer allocator.free(runtime);

    // Magic bytes: canonical `magic: [4]u8 = .{ 'Z', 'S', 'Y', 'M' }`,
    // runtime `ZSYM_MAGIC: [4]u8 = .{ 'Z', 'S', 'Y', 'M' }`.
    try std.testing.expect(std.mem.indexOf(u8, canonical, ".{ 'Z', 'S', 'Y', 'M' }") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, ".{ 'Z', 'S', 'Y', 'M' }") != null);

    // Format version 1 on both sides.
    try std.testing.expect(std.mem.indexOf(u8, canonical, "format_version: u32 = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "ZSYM_FORMAT_VERSION: u32 = 1") != null);

    // Packed entry width: seven u32 fields. Canonical computes it as
    // `@sizeOf(u32) * 7`; runtime mirrors `@sizeOf(u32) * 7`.
    try std.testing.expect(std.mem.indexOf(u8, canonical, "@sizeOf(u32) * 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "ZSYM_PACKED_ENTRY_SIZE: usize = @sizeOf(u32) * 7") != null);

    // Header size: magic + three u32s on both sides.
    try std.testing.expect(std.mem.indexOf(u8, canonical, "magic.len + @sizeOf(u32) * 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "ZSYM_MAGIC.len + @sizeOf(u32) * 3") != null);
}
