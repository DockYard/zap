//! Phase 4.a — drift guard for the shared diagnostic visual-format spec.
//!
//! The compile-time renderer (`src/diagnostics.zig`) draws its visual
//! constants from `src/error_format.zig`; the async-signal-safe runtime crash
//! printer (`src/runtime.zig`) MIRRORS the same constants in its
//! `RuntimeFormat` block. The two cannot share a Zig `@import` because
//! `runtime.zig` is injected into Zap binaries as standalone source with no
//! sibling files (the same constraint behind `envGetRuntime` and the
//! slab-pool / zap-symbol-ABI mirrors).
//!
//! This test reads BOTH files as text and asserts every mirrored constant has
//! a byte-identical value on both sides, so neither the compile renderer nor
//! the runtime crash printer can change the visual language unilaterally. A
//! unilateral edit fails the build with a clear diagnostic naming the constant
//! that drifted — exactly the guarantee the brief's "one visual language"
//! requirement needs given the injection boundary.
//!
//! Limitation: this is a textual cross-check of the load-bearing format
//! constants and the security-tier fold. It does not assert the renderers
//! *use* the constants identically (the box-drawing layout lives only on the
//! compile side; the runtime emits a flat backtrace). Visual parity of the
//! shared elements — header sigil, frame prefix, source separator, SGR
//! palette — is what this pins; the per-surface layout is exercised by the
//! `diagnostics.zig` renderer tests and the runtime crash-report tests.

const std = @import("std");

const error_format_path = "src/error_format.zig";
const runtime_path = "src/runtime.zig";

/// Read a repo-relative file via the fork's `std.Io.Dir` API (the classic
/// `std.fs` read surface is deprecated in this Zig 0.16 fork). Mirrors the
/// `readFile` helper in `slab_pool_drift_test.zig`.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
}

/// One constant that MUST appear with the same string value on both sides.
/// `canonical_decl` is the declaration text in `error_format.zig`;
/// `mirror_decl` is the declaration text in `runtime.zig`'s `RuntimeFormat`.
/// Both are matched as `pub const NAME = "VALUE";` / `const NAME = "VALUE";`
/// and the extracted VALUE bytes are compared.
const MirroredConstant = struct {
    name: []const u8,
    canonical_decl: []const u8,
    mirror_decl: []const u8,
};

const mirrored_constants = [_]MirroredConstant{
    .{ .name = "header_sigil_open", .canonical_decl = "pub const header_sigil_open = ", .mirror_decl = "const header_sigil_open = " },
    .{ .name = "header_sigil_close", .canonical_decl = "pub const header_sigil_close = ", .mirror_decl = "const header_sigil_close = " },
    .{ .name = "frame_indent", .canonical_decl = "pub const frame_indent = ", .mirror_decl = "const frame_indent = " },
    .{ .name = "frame_source_separator", .canonical_decl = "pub const frame_source_separator = ", .mirror_decl = "const frame_source_separator = " },
    .{ .name = "source_line_separator", .canonical_decl = "pub const source_line_separator = ", .mirror_decl = "const source_line_separator = " },
    .{ .name = "ert_section_header", .canonical_decl = "pub const ert_section_header = ", .mirror_decl = "const ert_section_header = " },
    .{ .name = "cause_prefix", .canonical_decl = "pub const cause_prefix = ", .mirror_decl = "const cause_prefix = " },
};

/// One SGR escape that must match between `error_format.sgr` and
/// `RuntimeFormat`. The canonical side is `pub const NAME = "...";` inside the
/// `sgr` struct; the mirror side is `const sgr_NAME = "...";`.
const MirroredSgr = struct {
    canonical_decl: []const u8,
    mirror_decl: []const u8,
};

const mirrored_sgr = [_]MirroredSgr{
    .{ .canonical_decl = "pub const reset = ", .mirror_decl = "const sgr_reset = " },
    .{ .canonical_decl = "pub const bold = ", .mirror_decl = "const sgr_bold = " },
    .{ .canonical_decl = "pub const bold_red = ", .mirror_decl = "const sgr_bold_red = " },
    .{ .canonical_decl = "pub const cyan = ", .mirror_decl = "const sgr_cyan = " },
};

/// Extract the double-quoted string literal value that follows `decl` in
/// `source`. Returns the RAW bytes BETWEEN the quotes (including escape
/// sequences like `\x1b` verbatim, which is fine — both sides spell them the
/// same way). Errors if the declaration is absent or malformed.
fn extractStringValue(source: []const u8, decl: []const u8) ![]const u8 {
    const decl_at = std.mem.indexOf(u8, source, decl) orelse return error.DeclNotFound;
    const after = decl_at + decl.len;
    if (after >= source.len or source[after] != '"') return error.NotAStringLiteral;
    const value_start = after + 1;
    // Find the closing quote, respecting backslash escapes.
    var i = value_start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1; // skip the escaped byte
            continue;
        }
        if (source[i] == '"') return source[value_start..i];
    }
    return error.UnterminatedStringLiteral;
}

test "runtime crash-printer format constants mirror error_format.zig byte-for-byte" {
    const alloc = std.testing.allocator;

    const canonical = try readFile(alloc, error_format_path);
    defer alloc.free(canonical);
    const runtime_src = try readFile(alloc, runtime_path);
    defer alloc.free(runtime_src);

    // Confirm the runtime mirror block exists at all.
    try std.testing.expect(std.mem.indexOf(u8, runtime_src, "const RuntimeFormat = struct") != null);

    for (mirrored_constants) |constant| {
        const canonical_value = extractStringValue(canonical, constant.canonical_decl) catch |err| {
            std.debug.print("error_format.zig: cannot read constant `{s}`: {s}\n", .{ constant.name, @errorName(err) });
            return error.CanonicalConstantUnreadable;
        };
        const mirror_value = extractStringValue(runtime_src, constant.mirror_decl) catch |err| {
            std.debug.print("runtime.zig RuntimeFormat: cannot read mirror of `{s}`: {s}\n", .{ constant.name, @errorName(err) });
            return error.MirrorConstantUnreadable;
        };
        if (!std.mem.eql(u8, canonical_value, mirror_value)) {
            std.debug.print(
                "DRIFT: format constant `{s}` differs:\n  error_format.zig: \"{s}\"\n  runtime.zig:      \"{s}\"\n",
                .{ constant.name, canonical_value, mirror_value },
            );
            return error.FormatConstantDrift;
        }
    }
}

test "runtime crash-printer SGR palette mirrors error_format.sgr byte-for-byte" {
    const alloc = std.testing.allocator;

    const canonical = try readFile(alloc, error_format_path);
    defer alloc.free(canonical);
    const runtime_src = try readFile(alloc, runtime_path);
    defer alloc.free(runtime_src);

    for (mirrored_sgr) |entry| {
        const canonical_value = try extractStringValue(canonical, entry.canonical_decl);
        const mirror_value = try extractStringValue(runtime_src, entry.mirror_decl);
        if (!std.mem.eql(u8, canonical_value, mirror_value)) {
            std.debug.print(
                "DRIFT: SGR escape differs:\n  error_format.zig (`{s}`): \"{s}\"\n  runtime.zig (`{s}`):      \"{s}\"\n",
                .{ entry.canonical_decl, canonical_value, entry.mirror_decl, mirror_value },
            );
            return error.SgrPaletteDrift;
        }
    }
}

test "security tier fold matches between error_format and runtime" {
    const alloc = std.testing.allocator;

    const canonical = try readFile(alloc, error_format_path);
    defer alloc.free(canonical);
    const runtime_src = try readFile(alloc, runtime_path);
    defer alloc.free(runtime_src);

    // Both must fold Debug/ReleaseSafe -> dev_local and
    // ReleaseFast/ReleaseSmall -> user_safe. We assert the runtime's
    // comptime tier switch carries the same two arms (textually) as the
    // canonical `defaultTierForMode`.
    try std.testing.expect(std.mem.indexOf(u8, canonical, ".Debug, .ReleaseSafe => .dev_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, ".ReleaseFast, .ReleaseSmall => .user_safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_src, ".Debug, .ReleaseSafe => .dev_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_src, ".ReleaseFast, .ReleaseSmall => .user_safe") != null);
}
