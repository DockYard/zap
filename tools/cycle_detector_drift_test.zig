//! Phase 4.d — drift guard for the Bacon–Rajan cycle detector.
//!
//! `src/memory/cycle_detector.zig` is the ALGORITHM + `domain=cycle` report
//! REFERENCE: a host-test module with the trial-deletion engine, the purple
//! candidate buffer, and the renderer, pinned by its own unit tests. The
//! PRODUCTION integration lives in `src/runtime.zig` (engine port + report)
//! because `runtime.zig` is `@embedFile`'d and injected into Zap binaries as
//! standalone source and therefore cannot `@import` the sibling reference (the
//! same constraint behind `RuntimeFormat`, the slab-pool mirror, and
//! `envGetRuntime`).
//!
//! This test reads BOTH files as text and asserts the load-bearing,
//! externally-observable contracts have byte-identical spellings on both
//! sides, so the runtime copy and the tested reference cannot drift apart:
//!
//!   * the `domain=cycle` report's machine + human strings (the JSON object
//!     prefix, the `participants` key, the text header / retain-path label /
//!     footer line), which are what consumers (`--error-format=json`, Zest's
//!     4.e `assert_no_cycles`, golden snapshots) bind to;
//!   * the zero-hot-path rule literal (`prev_refcount <= 1` ⇒ no enqueue),
//!     which is the HARD guarantee that a release-to-zero never touches the
//!     purple buffer.
//!
//! A unilateral edit to either side that changes one of these contracts fails
//! the build with a diagnostic naming the missing token.

const std = @import("std");

const reference_path = "src/memory/cycle_detector.zig";
const runtime_path = "src/runtime.zig";

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
}

/// A literal token that MUST appear verbatim in BOTH files.
const SharedToken = struct {
    description: []const u8,
    token: []const u8,
};

// NOTE: these JSON tokens are matched against the on-disk SOURCE text, where
// the renderers spell the JSON quotes as the escape sequence `\"` (two bytes:
// backslash, quote). So each `\"` in the rendered string corresponds to the
// literal bytes `\` `"` in the file — hence the doubled `\\\"` here (which is
// the runtime string `\"`, i.e. the two source bytes we search for).
const shared_tokens = [_]SharedToken{
    // --- domain=cycle JSON projection (the machine-readable contract) ---
    .{
        .description = "domain=cycle JSON object prefix",
        .token = "{\\\"domain\\\":\\\"cycle\\\",\\\"severity\\\":\\\"warning\\\",\\\"sub_kind\\\":\\\"reference_cycle\\\",\\\"trace_policy\\\":\\\"allocation\\\",\\\"message\\\":\\\"reference cycle: ",
    },
    .{
        .description = "machine_data object_count/bytes/participants key",
        .token = "\\\",\\\"machine_data\\\":{\\\"object_count\\\":",
    },
    .{
        .description = "participants array key",
        .token = ",\\\"participants\\\":[",
    },
    .{
        .description = "participant type key",
        .token = "{\\\"type\\\":\\\"",
    },
    .{
        .description = "JSON plural object-count phrase",
        .token = " objects held alive by a cycle",
    },
    .{
        .description = "JSON singular object-count phrase",
        .token = " object held alive by a cycle",
    },
    // --- text report (the human contract / golden-snapshot anchors) ---
    .{
        .description = "text header label",
        .token = "reference cycle: ",
    },
    .{
        .description = "text plural objects-held phrase",
        .token = " objects (",
    },
    .{
        .description = "text bytes-held suffix",
        .token = " B) held alive by a cycle",
    },
    .{
        .description = "text retain-path label",
        .token = "retain path: ",
    },
    .{
        .description = "text footer line",
        .token = " reference cycle (no owner outside the cycle)",
    },
};

/// The zero-hot-path purple-buffer rule (`prev_refcount <= 1` ⇒ no enqueue) is
/// the HARD guarantee, but it lives ONLY in the reference's `PurpleBuffer`
/// (the ARC release-site hook drains that buffer; the Tracking runtime path
/// uses the deinit live-set registry instead and has no purple buffer). It is
/// pinned by the reference's own unit tests, so this guard asserts only that
/// the rule is still present in the reference — not in the runtime.
const reference_only_tokens = [_]SharedToken{
    .{
        .description = "purple-buffer decrement-to-positive guard (prev <= 1 ⇒ no enqueue)",
        .token = "prev_refcount <= 1",
    },
    .{
        .description = "purple-buffer recordDecrementToPositive entry point",
        .token = "pub fn recordDecrementToPositive(",
    },
};

test "runtime cycle detector mirrors cycle_detector.zig report + hot-path contracts" {
    const alloc = std.testing.allocator;

    const reference = try readFile(alloc, reference_path);
    defer alloc.free(reference);
    const runtime_src = try readFile(alloc, runtime_path);
    defer alloc.free(runtime_src);

    // Sanity: the reference engine + the runtime port both exist.
    try std.testing.expect(std.mem.indexOf(u8, reference, "pub const Engine = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, reference, "pub const PurpleBuffer = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_src, "const CycleEngine = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_src, "fn runCycleDetectionAndReport") != null);

    for (shared_tokens) |st| {
        if (std.mem.indexOf(u8, reference, st.token) == null) {
            std.debug.print(
                "cycle-detector drift: token '{s}' ({s}) missing from {s}\n",
                .{ st.token, st.description, reference_path },
            );
            return error.TokenMissingFromReference;
        }
        if (std.mem.indexOf(u8, runtime_src, st.token) == null) {
            std.debug.print(
                "cycle-detector drift: token '{s}' ({s}) missing from {s}\n",
                .{ st.token, st.description, runtime_path },
            );
            return error.TokenMissingFromRuntime;
        }
    }

    for (reference_only_tokens) |st| {
        if (std.mem.indexOf(u8, reference, st.token) == null) {
            std.debug.print(
                "cycle-detector drift: reference-only token '{s}' ({s}) missing from {s}\n",
                .{ st.token, st.description, reference_path },
            );
            return error.ReferenceOnlyTokenMissing;
        }
    }
}
