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

test "stringAt bounds-check hardening is present and identical on both readers (os-seam--01)" {
    // os-seam--01 (audit RT-08): the canonical `Reader.stringAt` previously
    // sliced the string blob with NO bounds check while its runtime mirror was
    // hardened — the two drifted, leaving an out-of-bounds read on the
    // untrusted `.zap-symbols` sidecar reachable through `zap addr2line`. The
    // fix brings both to the SAME widened-`usize`-arithmetic bounds check.
    // These textual assertions fail the build if either reader loses the guard
    // or reverts to wrap-prone `u32` arithmetic, so the hardening cannot
    // silently drift apart again.
    const allocator = std.testing.allocator;

    const canonical = try readRepoFile(allocator, "src/zap_symbol_table.zig");
    defer allocator.free(canonical);
    const runtime = try readRepoFile(allocator, "src/runtime.zig");
    defer allocator.free(runtime);

    // The widened end computation: `const end = @as(usize, offset) +
    // @as(usize, length);` — guarantees no `u32` wrap before the bounds test.
    const widened_end = "const end = @as(usize, offset) + @as(usize, length);";
    try std.testing.expect(std.mem.indexOf(u8, canonical, widened_end) != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, widened_end) != null);

    // The bounds guard itself, byte-identical on both sides.
    const bounds_guard = "if (offset > self.string_blob.len or end > self.string_blob.len) return \"\";";
    try std.testing.expect(std.mem.indexOf(u8, canonical, bounds_guard) != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, bounds_guard) != null);

    // The validated slice uses the precomputed `end`, not a re-derived
    // `offset + length` (which would re-introduce the wrap on one side).
    const validated_slice = "return self.string_blob[offset..end];";
    try std.testing.expect(std.mem.indexOf(u8, canonical, validated_slice) != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, validated_slice) != null);

    // Neither reader may retain the old unchecked `offset .. offset + length`
    // slice form that caused the OOB read.
    const unchecked_slice = "self.string_blob[offset .. offset + length]";
    try std.testing.expect(std.mem.indexOf(u8, canonical, unchecked_slice) == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, unchecked_slice) == null);
}
