//! Runtime OS-portability grep-gate (the lock-in for the
//! runtime-OS-portability campaign).
//!
//! The embedded runtime (`src/runtime.zig`) is `@embedFile`'d into **every**
//! Zap user binary, so any raw per-OS syscall in it (`std.c.write`,
//! `std.posix.open`, `std.os.linux.getrandom`, …) is a per-OS assumption in
//! every Zap program on every target. The campaign's architecture confines
//! such calls to the comptime-selected `runtime_os` seam (and, until Phase D,
//! the crash-handler region). This test ENFORCES that confinement: it scans
//! `runtime.zig` and FAILS the build if a raw `std.c.` / `std.posix.` /
//! `std.os.` call appears OUTSIDE the allowlisted regions.
//!
//! ## Allowlisted regions (where per-OS calls legitimately live)
//!
//!  * The `runtime_os` seam — between `// ZAP_RUNTIME_OS_SEAM_BEGIN` and
//!    `// ZAP_RUNTIME_OS_SEAM_END`. This is the comptime-selected OS-primitive
//!    layer; per-OS calls are its whole purpose.
//!  * The Domain-B crash handler — between `// ZAP_RUNTIME_OS_CRASH_BEGIN` and
//!    `// ZAP_RUNTIME_OS_CRASH_END`. POSIX signals / `_exit` / the ASLR-slide
//!    query have no uniform `std` abstraction and are the explicit Phase-D
//!    port; until then their raw calls are allowlisted by this marker so the
//!    gate tracks the deep domain precisely.
//!  * Test-only scaffolding — between `// ZAP_RUNTIME_OS_TESTONLY_BEGIN` and
//!    `// ZAP_RUNTIME_OS_TESTONLY_END` (the `builtin.is_test`-gated ARC
//!    slab-pool), and inside any top-level `test { … }` / `test "…" { … }`
//!    block. This code never ships in a user binary, so it is not part of the
//!    port surface.
//!  * A short, explicitly-enumerated list of genuinely-irreducible
//!    comptime references (see `irreducible_allowlist`), each with a
//!    documented reason.
//!
//! A new raw `std.c.write` / `std.posix.open` / etc. added to the GENERAL
//! runtime body fails this test with the precise `runtime.zig:<line>` and the
//! offending call, instructing the author to move it into the `runtime_os`
//! seam. This makes portability ENFORCED architecture, not a convention.

const std = @import("std");

/// The embedded-runtime source — the single port surface this gate guards.
/// Embedded at comptime so the test has no filesystem dependency and runs in
/// the normal `zig build test` gate on any host. This file is a sibling of
/// `runtime.zig` so the embed stays inside the package path.
const runtime_source = @embedFile("runtime.zig");

/// The banned raw-OS-call prefixes. `std.os.` is included because the
/// non-portable members (`std.os.linux.*`, `std.os.windows.*`, `std.os.wasi.*`)
/// are per-OS; the portable `std.os.tag`-style references do not appear as
/// call prefixes in the runtime body, and any that did would correctly be
/// flagged for review. The seam itself uses these prefixes — that is exactly
/// why the seam region is allowlisted.
const banned_prefixes = [_][]const u8{
    "std.c.",
    "std.posix.",
    "std.os.",
};

/// One genuinely-irreducible reference that the gate permits in the general
/// body, with the reason it cannot move into the seam. These are comptime
/// TYPE references / capability probes, not runtime syscalls.
const Irreducible = struct {
    /// Exact substring that must appear on the offending (comment-stripped)
    /// line for the allowance to apply.
    needle: []const u8,
    /// Why this reference is irreducible (documentation; not checked).
    reason: []const u8,
};

const irreducible_allowlist = [_]Irreducible{
    .{
        .needle = "std.posix.mode_t",
        .reason =
        \\Comptime capability probe, not a syscall. The Domain-C file-mode
        \\code uses `std.posix.mode_t != u0` to decide AT COMPTIME whether the
        \\selected target has POSIX permission bits (it does on POSIX; it is
        \\`u0` on Windows/WASI, where std selects its portable Permissions
        \\variant). This is portable type introspection that compiles on every
        \\target — moving it into the seam would not change its behavior and
        \\would obscure that it is a portability guard, not an OS call.
        ,
    },
};

/// A half-open `[start_line, end_line)` allowlisted line range, plus the
/// marker name (for diagnostics). Lines are 1-based.
const Region = struct {
    name: []const u8,
    start_line: usize,
    end_line: usize,
};

/// Sentinel comment markers that open/close a named allowlisted region.
/// Each is matched as a trimmed line prefix so trailing marker arguments
/// (e.g. `slab-pool`) are tolerated.
const RegionMarker = struct {
    name: []const u8,
    begin: []const u8,
    end: []const u8,
};

const region_markers = [_]RegionMarker{
    .{ .name = "runtime_os seam", .begin = "// ZAP_RUNTIME_OS_SEAM_BEGIN", .end = "// ZAP_RUNTIME_OS_SEAM_END" },
    .{ .name = "crash handler (Phase D)", .begin = "// ZAP_RUNTIME_OS_CRASH_BEGIN", .end = "// ZAP_RUNTIME_OS_CRASH_END" },
    .{ .name = "test-only scaffolding", .begin = "// ZAP_RUNTIME_OS_TESTONLY_BEGIN", .end = "// ZAP_RUNTIME_OS_TESTONLY_END" },
};

/// Strip a `//`-comment (line or doc comment) from `line`, returning only the
/// code portion. Quote-aware: a `//` inside a string/char literal is NOT a
/// comment. Zap runtime source uses no `\\`-multiline-string lines that
/// contain banned prefixes outside comments, but quote tracking keeps the
/// scanner correct if one were added.
fn codePortion(line: []const u8) []const u8 {
    var i: usize = 0;
    var in_string = false;
    var in_char = false;
    while (i + 1 <= line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (in_char) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '\'') in_char = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '\'' => in_char = true,
            '/' => {
                if (i + 1 < line.len and line[i + 1] == '/') {
                    return line[0..i];
                }
            },
            else => {},
        }
    }
    return line;
}

/// Whether `code` (a comment-stripped line) contains a banned raw-OS-call
/// prefix that is part of an actual reference (not, e.g., the tail of a longer
/// identifier). Returns the matched prefix, or `null`.
fn bannedPrefixIn(code: []const u8) ?[]const u8 {
    for (banned_prefixes) |prefix| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, code, search_from, prefix)) |idx| {
            // Reject a match whose char immediately before is an identifier
            // char (so `my_std.c.x` or `xstd.posix.y` would not false-match);
            // `std` must start a token.
            const ok_before = idx == 0 or !isIdentChar(code[idx - 1]);
            if (ok_before) return prefix;
            search_from = idx + prefix.len;
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Whether the trimmed `code` line matches an enumerated irreducible.
fn isIrreducible(code: []const u8) bool {
    for (irreducible_allowlist) |entry| {
        if (std.mem.indexOf(u8, code, entry.needle) != null) return true;
    }
    return false;
}

/// A detected violation: a banned prefix on a general-body code line.
const Violation = struct {
    line_number: usize,
    prefix: []const u8,
    line_text: []const u8,
};

/// Scan `source` and return the list of violations (raw OS calls outside any
/// allowlisted region). Caller owns the returned slice. Also returns, via
/// out-params, the count of allowlisted hits per region kind for a sanity
/// assertion (the gate must SEE the seam/crash calls, proving region tracking
/// works rather than silently matching nothing).
const ScanResult = struct {
    violations: []Violation,
    seam_hits: usize,
    crash_hits: usize,
    testonly_hits: usize,
    testblock_hits: usize,
    irreducible_hits: usize,
};

fn scan(allocator: std.mem.Allocator, source: []const u8) !ScanResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);

    var seam_hits: usize = 0;
    var crash_hits: usize = 0;
    var testonly_hits: usize = 0;
    var testblock_hits: usize = 0;
    var irreducible_hits: usize = 0;

    // Region state: which marker region (if any) we are currently inside.
    var in_region: ?usize = null; // index into region_markers

    // `test { … }` / `test "…" { … }` brace-depth state. A top-level test
    // block opens at brace depth 0 and we track nesting to find its close.
    var in_test_block = false;
    var test_block_depth: usize = 0;

    var line_number: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        line_number += 1;
        const trimmed = std.mem.trimStart(u8, raw_line, " \t");

        // --- Region marker transitions (matched on the trimmed RAW line so a
        //     marker is recognized even though it is itself a comment). ---
        if (in_region) |region_idx| {
            if (std.mem.startsWith(u8, trimmed, region_markers[region_idx].end)) {
                in_region = null;
                continue;
            }
        } else {
            var matched_open = false;
            for (region_markers, 0..) |marker, idx| {
                if (std.mem.startsWith(u8, trimmed, marker.begin)) {
                    in_region = idx;
                    matched_open = true;
                    break;
                }
            }
            if (matched_open) continue;
        }

        // --- `test` block tracking (only when not inside a marker region). ---
        if (in_region == null) {
            if (!in_test_block) {
                // A top-level test block: a line that begins with `test ` or
                // `test"` at column 0 (top-level) — the runtime's test blocks
                // are all top-level. Use the raw line so indentation matters.
                if (std.mem.startsWith(u8, raw_line, "test ") or std.mem.startsWith(u8, raw_line, "test\"")) {
                    in_test_block = true;
                    test_block_depth = 0;
                }
            }
            if (in_test_block) {
                // Track braces on the CODE portion so a `{`/`}` in a comment or
                // string does not skew the depth.
                const code_for_braces = codePortion(raw_line);
                for (code_for_braces) |c| {
                    if (c == '{') test_block_depth += 1;
                    if (c == '}') {
                        if (test_block_depth > 0) test_block_depth -= 1;
                        if (test_block_depth == 0) {
                            // Closing brace of the test block; it closes at the
                            // END of this line.
                            in_test_block = false;
                        }
                    }
                }
            }
        }

        // --- Banned-prefix detection on the comment-stripped code. ---
        const code = codePortion(raw_line);
        const matched = bannedPrefixIn(code) orelse continue;

        // Classify the hit by region.
        if (in_region) |region_idx| {
            switch (region_idx) {
                0 => seam_hits += 1,
                1 => crash_hits += 1,
                2 => testonly_hits += 1,
                else => {},
            }
            continue;
        }
        if (in_test_block) {
            testblock_hits += 1;
            continue;
        }
        if (isIrreducible(code)) {
            irreducible_hits += 1;
            continue;
        }

        // Not allowlisted anywhere → a violation.
        try violations.append(allocator, .{
            .line_number = line_number,
            .prefix = matched,
            .line_text = std.mem.trim(u8, raw_line, " \t\r"),
        });
    }

    return .{
        .violations = try violations.toOwnedSlice(allocator),
        .seam_hits = seam_hits,
        .crash_hits = crash_hits,
        .testonly_hits = testonly_hits,
        .testblock_hits = testblock_hits,
        .irreducible_hits = irreducible_hits,
    };
}

test "runtime.zig has no raw std.c/std.posix/std.os calls outside the runtime_os seam, crash region, or test scaffolding" {
    const allocator = std.testing.allocator;
    const result = try scan(allocator, runtime_source);
    defer allocator.free(result.violations);

    if (result.violations.len != 0) {
        // Emit a precise, actionable report for every violation, then fail.
        std.debug.print(
            \\
            \\========================================================================
            \\runtime OS-portability gate FAILED: {d} raw per-OS call(s) found in
            \\src/runtime.zig OUTSIDE the allowlisted regions.
            \\
            \\The embedded runtime ships into EVERY Zap user binary on EVERY target,
            \\so a raw `std.c.` / `std.posix.` / `std.os.` call here is a per-OS
            \\assumption in every Zap program. Move it into the `runtime_os` seam
            \\(`src/runtime_os/{{posix,windows,wasi}}.zig` + the inline seam between
            \\`// ZAP_RUNTIME_OS_SEAM_BEGIN`/`END` in runtime.zig), adding the
            \\primitive to ALL THREE backends, OR — if it belongs to the Domain-B
            \\crash handler — place it inside the
            \\`// ZAP_RUNTIME_OS_CRASH_BEGIN`/`END` region.
            \\------------------------------------------------------------------------
            \\
        , .{result.violations.len});
        for (result.violations) |v| {
            std.debug.print("  src/runtime.zig:{d}: raw `{s}` call — move it into the runtime_os seam\n    {s}\n", .{
                v.line_number, v.prefix, v.line_text,
            });
        }
        std.debug.print(
            \\========================================================================
            \\
        , .{});
        return error.RawOsCallOutsideRuntimeOsSeam;
    }

    // Sanity: the scanner MUST have seen the known per-OS calls in the
    // allowlisted regions. If these are zero, region tracking is broken (e.g.
    // a renamed marker), and a "PASS" would be vacuous. The seam and crash
    // region both contain many raw calls today.
    try std.testing.expect(result.seam_hits > 0);
    try std.testing.expect(result.crash_hits > 0);
}

test "gate detects a planted raw call in the general body" {
    // Prove the gate actually fires: synthesize a tiny source with one raw
    // call in the general body (outside any region) and confirm it is
    // reported as a violation, AND a copy of that same call inside the seam
    // region is NOT reported.
    const allocator = std.testing.allocator;
    const planted =
        \\const std = @import("std");
        \\fn general() void {
        \\    _ = std.c.write(1, "x", 1);
        \\}
        \\// ZAP_RUNTIME_OS_SEAM_BEGIN
        \\fn seamed() void {
        \\    _ = std.c.write(1, "y", 1);
        \\}
        \\// ZAP_RUNTIME_OS_SEAM_END
    ;
    const result = try scan(allocator, planted);
    defer allocator.free(result.violations);

    try std.testing.expectEqual(@as(usize, 1), result.violations.len);
    try std.testing.expectEqual(@as(usize, 3), result.violations[0].line_number);
    try std.testing.expectEqualStrings("std.c.", result.violations[0].prefix);
    // The seam copy was counted as an allowlisted hit, not a violation.
    try std.testing.expectEqual(@as(usize, 1), result.seam_hits);
}

test "gate ignores raw-call mentions inside comments" {
    // A `std.posix.open` named only in a comment is documentation, not a
    // call, and must not trip the gate.
    const allocator = std.testing.allocator;
    const commented =
        \\fn f() void {
        \\    // historical: this used std.posix.open(.RDONLY) before the seam
        \\    return;
        \\}
    ;
    const result = try scan(allocator, commented);
    defer allocator.free(result.violations);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

test "gate allowlists an enumerated irreducible comptime probe" {
    // The `std.posix.mode_t` comptime capability probe is permitted in the
    // general body via the irreducible allowlist.
    const allocator = std.testing.allocator;
    const probe =
        \\fn f() void {
        \\    const has_mode = builtin.os.tag != .windows and std.posix.mode_t != u0;
        \\    _ = has_mode;
        \\}
    ;
    const result = try scan(allocator, probe);
    defer allocator.free(result.violations);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
    try std.testing.expectEqual(@as(usize, 1), result.irreducible_hits);
}

test "gate allowlists raw calls inside a top-level test block" {
    const allocator = std.testing.allocator;
    const with_test =
        \\test "uses libc directly for a stdin-redirect harness" {
        \\    const c = struct {
        \\        extern "c" fn pipe(fds: *[2]std.c.fd_t) c_int;
        \\    };
        \\    _ = c;
        \\    var fd: [2]std.c.fd_t = undefined;
        \\    _ = std.c.write(1, "x", 1);
        \\    _ = fd;
        \\}
        \\fn afterTest() void {
        \\    return;
        \\}
    ;
    const result = try scan(allocator, with_test);
    defer allocator.free(result.violations);
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
    try std.testing.expectEqual(@as(usize, 3), result.testblock_hits);
}
