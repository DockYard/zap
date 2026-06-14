//! Regression guard for the `src/root.zig` test-aggregation invariant.
//!
//! In Zig, a top-level `pub const x = @import("x.zig")` does NOT cause
//! `x.zig`'s `test {}` blocks to run under `zig build test`. ONLY a reference
//! inside an aggregating `test {}` block pulls a module's tests into the test
//! binary. `src/root.zig` carries exactly such an aggregating `test {}` block.
//! A test-bearing `src/*.zig` module that is omitted from that block is
//! silently dead: it compiles, but the guarantees its tests encode never run.
//!
//! This meta-test makes that failure mode impossible to reintroduce silently.
//! It is fully data-driven — it reads NO hand-maintained list:
//!
//!   1. It parses `src/root.zig`, locates the aggregating `test {}` block, and
//!      collects every `@import("...")` path referenced inside it (the set of
//!      modules whose tests actually run via the `zap` module test binary).
//!   2. It parses the same block's leading comment for the `DELIBERATE
//!      EXCLUSIONS` allow-list — modules intentionally NOT aggregated here
//!      because `build.zig` runs their tests through a dedicated test target
//!      (different compile target, or a generated import the `zap` module does
//!      not provide). The allow-list is read from the source comment so the
//!      guard and the human-readable rationale can never drift apart.
//!   3. It walks `src/` recursively and, for every `*.zig` file that contains a
//!      real `test {}` block (comment/string-aware detection), asserts the file
//!      is either aggregated (1) or explicitly excluded (2).
//!
//! A new test-bearing module that nobody wired up FAILS this test with a
//! precise message naming the file and the two ways to fix it. This is the
//! automated enforcement of the invariant documented at the top of
//! `src/root.zig`'s `test {}` block.

const std = @import("std");

const io = std.Options.debug_io;

const GuardError = error{
    UnaggregatedTestModule,
    RootTestBlockNotFound,
    ExclusionListNotFound,
};

test "every test-bearing src module is aggregated into src/root.zig" {
    const allocator = std.testing.allocator;

    const root_source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/root.zig",
        allocator,
        .limited(8 * 1024 * 1024),
    );
    defer allocator.free(root_source);

    // (1) Locate the aggregating `test {}` block in root.zig.
    const root_test_block = findNextTestBlock(root_source, 0) orelse {
        std.debug.print("guard: could not find the aggregating `test {{}}` block in src/root.zig\n", .{});
        return GuardError.RootTestBlockNotFound;
    };
    const block_body = root_source[root_test_block.start..root_test_block.end];

    // (1) Collect the set of aggregated `@import("...")` paths (normalized to
    // forward slashes — they are already written that way, but normalize for
    // robustness against either separator).
    var aggregated = std.StringHashMap(void).init(allocator);
    defer freeKeysAndDeinit(&aggregated, allocator);
    try collectImports(allocator, block_body, &aggregated);

    // (2) Parse the `DELIBERATE EXCLUSIONS` allow-list out of the block's
    // leading comment. Each excluded module is named in a `` `src/<path>` ``
    // backtick span on a comment line; we accept any backticked `src/...zig`
    // token inside the block comment as an exclusion entry.
    var excluded = std.StringHashMap(void).init(allocator);
    defer freeKeysAndDeinit(&excluded, allocator);
    try collectExclusions(allocator, block_body, &excluded);
    if (excluded.count() == 0) {
        std.debug.print(
            "guard: found no `DELIBERATE EXCLUSIONS` entries in the src/root.zig test block comment; " ++
                "the exclusion allow-list must be declared there (backticked `src/<path>.zig` tokens)\n",
            .{},
        );
        return GuardError.ExclusionListNotFound;
    }

    // (3) Walk src/ recursively for every test-bearing module.
    var src_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    var failures: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Normalize the walker's OS-native separators to the `@import` form.
        const import_path = try allocator.dupe(u8, entry.path);
        defer allocator.free(import_path);
        std.mem.replaceScalar(u8, import_path, std.fs.path.sep, '/');

        const source = try src_dir.readFileAlloc(io, entry.path, allocator, .limited(20 * 1024 * 1024));
        defer allocator.free(source);

        if (findNextTestBlock(source, 0) == null) continue; // no tests — nothing to aggregate

        if (aggregated.contains(import_path)) continue; // referenced in root.zig's test block

        // The exclusion comment names files as `src/<path>`; the walker yields
        // `<path>` relative to `src/`. Compare against the `src/`-prefixed form.
        const src_relative = try std.fmt.allocPrint(allocator, "src/{s}", .{import_path});
        defer allocator.free(src_relative);
        if (excluded.contains(src_relative)) continue; // deliberately excluded

        failures += 1;
        std.debug.print(
            "guard: src/{s} contains `test {{}}` block(s) but is NOT aggregated into src/root.zig's test block.\n" ++
                "       Fix: add `_ = @import(\"{s}\");` to that block, OR — if it is covered by a\n" ++
                "       dedicated build.zig test target — list it under DELIBERATE EXCLUSIONS in the\n" ++
                "       block's leading comment (as `src/{s}`).\n",
            .{ import_path, import_path, import_path },
        );
    }

    if (failures != 0) {
        std.debug.print("guard: {d} test-bearing src module(s) are not aggregated (see above)\n", .{failures});
        return GuardError.UnaggregatedTestModule;
    }
}

/// Collect every `@import("...")` path referenced inside `block_body` into
/// `set` (owns duplicated key strings). Quoted-string and comment-aware via the
/// shared scanner is unnecessary here: we match the literal `@import("` lead-in
/// and read to the closing quote, which is unambiguous in well-formed Zig.
fn collectImports(
    allocator: std.mem.Allocator,
    block_body: []const u8,
    set: *std.StringHashMap(void),
) !void {
    const needle = "@import(\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, block_body, cursor, needle)) |found| {
        const path_start = found + needle.len;
        const path_end = std.mem.indexOfScalarPos(u8, block_body, path_start, '"') orelse break;
        const raw = block_body[path_start..path_end];
        const normalized = try allocator.dupe(u8, raw);
        std.mem.replaceScalar(u8, normalized, std.fs.path.sep, '/');
        const gop = try set.getOrPut(normalized);
        if (gop.found_existing) allocator.free(normalized);
        cursor = path_end + 1;
    }
}

/// Collect the `DELIBERATE EXCLUSIONS` allow-list from `block_body` — every
/// backticked `` `src/<path>.zig` `` token found inside the block's comment
/// lines. Stored as the `src/`-prefixed form to match the walker comparison.
fn collectExclusions(
    allocator: std.mem.Allocator,
    block_body: []const u8,
    set: *std.StringHashMap(void),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, block_body, cursor, '`')) |open_tick| {
        const close_tick = std.mem.indexOfScalarPos(u8, block_body, open_tick + 1, '`') orelse break;
        const span = block_body[open_tick + 1 .. close_tick];
        cursor = close_tick + 1;
        // Accept only `src/....zig` tokens (a single path with no spaces).
        if (!std.mem.startsWith(u8, span, "src/")) continue;
        if (!std.mem.endsWith(u8, span, ".zig")) continue;
        if (std.mem.indexOfScalar(u8, span, ' ') != null) continue;
        if (std.mem.indexOfScalar(u8, span, ',') != null) continue;
        const key = try allocator.dupe(u8, span);
        const gop = try set.getOrPut(key);
        if (gop.found_existing) allocator.free(key);
    }
}

fn freeKeysAndDeinit(set: *std.StringHashMap(void), allocator: std.mem.Allocator) void {
    var it = set.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    set.deinit();
}

// ---------------------------------------------------------------------------
// Comment/string-aware `test {}` block scanner.
//
// Mirrors `tools/boundary_guard_test.zig`'s scanner so the two source-walking
// guards detect `test` blocks identically (correctly skipping `test` inside
// comments, `"..."` strings, `'.'` scalars, and `\\` multiline-string lines).
// ---------------------------------------------------------------------------

const TestBlock = struct {
    start: usize,
    end: usize,
};

fn findNextTestBlock(source: []const u8, start: usize) ?TestBlock {
    var cursor = start;
    while (cursor < source.len) {
        if (startsLineComment(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (startsMultilineStringLine(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (source[cursor] == '"') {
            cursor = skipQuotedString(source, cursor);
            continue;
        }
        if (source[cursor] == '\'') {
            cursor = skipQuotedScalar(source, cursor);
            continue;
        }
        if (startsToken(source, cursor, "test")) {
            const open_brace = findOpeningBrace(source, cursor + "test".len) orelse return null;
            const end = findMatchingBrace(source, open_brace) orelse return null;
            return .{ .start = cursor, .end = end };
        }
        cursor += 1;
    }

    return null;
}

fn findOpeningBrace(source: []const u8, start: usize) ?usize {
    var cursor = start;
    while (cursor < source.len) {
        if (startsLineComment(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (startsMultilineStringLine(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (source[cursor] == '"') {
            cursor = skipQuotedString(source, cursor);
            continue;
        }
        if (source[cursor] == '\'') {
            cursor = skipQuotedScalar(source, cursor);
            continue;
        }
        if (source[cursor] == '{') return cursor;
        cursor += 1;
    }

    return null;
}

fn findMatchingBrace(source: []const u8, open_brace: usize) ?usize {
    var depth: usize = 0;
    var cursor = open_brace;
    while (cursor < source.len) {
        if (startsLineComment(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (startsMultilineStringLine(source, cursor)) {
            cursor = skipLine(source, cursor);
            continue;
        }
        if (source[cursor] == '"') {
            cursor = skipQuotedString(source, cursor);
            continue;
        }
        if (source[cursor] == '\'') {
            cursor = skipQuotedScalar(source, cursor);
            continue;
        }

        if (source[cursor] == '{') {
            depth += 1;
        } else if (source[cursor] == '}') {
            depth -= 1;
            if (depth == 0) return cursor + 1;
        }

        cursor += 1;
    }

    return null;
}

fn startsToken(source: []const u8, index: usize, token: []const u8) bool {
    if (!std.mem.startsWith(u8, source[index..], token)) return false;

    const before_is_identifier = index > 0 and isIdentifierByte(source[index - 1]);
    const after_index = index + token.len;
    const after_is_identifier = after_index < source.len and isIdentifierByte(source[after_index]);
    return !before_is_identifier and !after_is_identifier;
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn startsLineComment(source: []const u8, index: usize) bool {
    return index + 1 < source.len and source[index] == '/' and source[index + 1] == '/';
}

fn startsMultilineStringLine(source: []const u8, index: usize) bool {
    return index + 1 < source.len and source[index] == '\\' and source[index + 1] == '\\';
}

fn skipLine(source: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {}
    return if (cursor < source.len) cursor + 1 else cursor;
}

fn skipQuotedString(source: []const u8, start: usize) usize {
    var cursor = start + 1;
    while (cursor < source.len) : (cursor += 1) {
        if (source[cursor] == '\\') {
            cursor += 1;
            continue;
        }
        if (source[cursor] == '"') return cursor + 1;
    }

    return source.len;
}

fn skipQuotedScalar(source: []const u8, start: usize) usize {
    var cursor = start + 1;
    while (cursor < source.len) : (cursor += 1) {
        if (source[cursor] == '\\') {
            cursor += 1;
            continue;
        }
        if (source[cursor] == '\'') return cursor + 1;
    }

    return source.len;
}
