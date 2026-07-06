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
//!   3. For every `AGGREGATOR for` declaration in that comment (a whole
//!      subtree delegated to a nested aggregator file — e.g. the concurrency
//!      kernel tree, whose tests run through `zig build test-kernel` rooted at
//!      `src/runtime/concurrency/concurrency.zig`), it parses the aggregator's
//!      own `test {}` block(s) and computes the set of subtree modules whose
//!      tests actually run there. An excluded subtree is therefore NOT a
//!      blanket excuse: its modules are verified against the aggregator.
//!   4. It walks `src/` recursively and, for every `*.zig` file that contains a
//!      real `test {}` block (comment/string-aware detection), asserts the file
//!      is aggregated (1), verified inside its subtree aggregator (3), or
//!      explicitly excluded (2). Hand-listing a per-file exclusion under a
//!      declared aggregator subtree is itself a failure — the aggregator's
//!      test block is the single source of truth for its subtree.
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
    MalformedAggregatorDeclaration,
    AggregatorTestBlockNotFound,
    HandListedAggregatorSubtreeExclusion,
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

    // (3) Parse `AGGREGATOR for` declarations out of the same comment and
    // load each aggregator's aggregated-module set from its own source, so
    // subtree modules are verified instead of blanket-excused.
    var aggregators: std.ArrayList(AggregatorDecl) = .empty;
    defer freeAggregators(&aggregators, allocator);
    try collectAggregators(allocator, block_body, &aggregators);

    for (aggregators.items) |*aggregator| {
        const aggregator_source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            aggregator.root,
            allocator,
            .limited(8 * 1024 * 1024),
        );
        defer allocator.free(aggregator_source);
        if (findNextTestBlock(aggregator_source, 0) == null) {
            std.debug.print(
                "guard: declared aggregator {s} has no `test {{}}` block to aggregate its subtree's tests\n",
                .{aggregator.root},
            );
            return GuardError.AggregatorTestBlockNotFound;
        }
        try collectAggregatorTestedPaths(
            allocator,
            aggregator.root,
            aggregator_source,
            &aggregator.tested,
        );
    }

    // (3b) Reject hand-listed per-file exclusions under a declared aggregator
    // subtree. The aggregator's test block is the single source of truth for
    // its subtree — a per-file comment entry there could only mask a module
    // whose tests are silently dead.
    {
        var stale_exclusions: usize = 0;
        var exclusion_it = excluded.keyIterator();
        while (exclusion_it.next()) |entry| {
            const aggregator_index = subtreeAggregatorIndex(aggregators.items, entry.*) orelse continue;
            const aggregator = aggregators.items[aggregator_index];
            if (std.mem.eql(u8, entry.*, aggregator.root)) continue; // the aggregator root's own entry
            stale_exclusions += 1;
            std.debug.print(
                "guard: DELIBERATE EXCLUSIONS hand-lists {s}, which lies under {s}'s declared\n" ++
                    "       subtree `{s}`. Remove the entry — subtree modules are verified against\n" ++
                    "       the aggregator's own test block, never hand-listed.\n",
                .{ entry.*, aggregator.root, aggregator.subtree },
            );
        }
        if (stale_exclusions != 0) return GuardError.HandListedAggregatorSubtreeExclusion;
    }

    // (4) Walk src/ recursively for every test-bearing module.
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

        // The exclusion comment names files as `src/<path>`; the walker yields
        // `<path>` relative to `src/`. Compare against the `src/`-prefixed form.
        const src_relative = try std.fmt.allocPrint(allocator, "src/{s}", .{import_path});
        defer allocator.free(src_relative);

        // A file under a declared aggregator subtree answers to the
        // aggregator's own `test {}` block — root.zig aggregation and
        // per-file exclusions do not apply there.
        if (subtreeAggregatorIndex(aggregators.items, src_relative)) |aggregator_index| {
            const aggregator = aggregators.items[aggregator_index];
            // The aggregator root itself is the deliberate exclusion: its
            // tests run through the dedicated build.zig test target that the
            // exclusion comment names (e.g. `zig build test-kernel`).
            if (std.mem.eql(u8, src_relative, aggregator.root)) continue;
            if (aggregator.tested.contains(src_relative)) continue;

            const aggregator_dir = std.fs.path.dirnamePosix(aggregator.root) orelse ".";
            const import_hint = if (std.mem.startsWith(u8, src_relative, aggregator_dir) and
                src_relative.len > aggregator_dir.len + 1 and
                src_relative[aggregator_dir.len] == '/')
                src_relative[aggregator_dir.len + 1 ..]
            else
                src_relative;
            failures += 1;
            std.debug.print(
                "guard: {s} has tests but is not imported in {s}'s test block.\n" ++
                    "       Fix: add `_ = @import(\"{s}\");` (or a `_ = <name>;` reference to a\n" ++
                    "       top-level `const <name> = @import(\"{s}\");` binding) to that block.\n",
                .{ src_relative, aggregator.root, import_hint, import_hint },
            );
            continue;
        }

        if (aggregated.contains(import_path)) continue; // referenced in root.zig's test block

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
// Subtree-aggregator support.
//
// A DELIBERATE EXCLUSIONS entry may declare an entire subtree as delegated to
// a nested aggregator file instead of hand-listing every module:
//
//     `src/runtime/concurrency/concurrency.zig` — AGGREGATOR for
//     `src/runtime/concurrency/`
//
// Syntax contract: the literal marker `AGGREGATOR for`, with the nearest
// preceding backticked `src/<path>.zig` token naming the aggregator root and
// the nearest following backticked `src/<dir>/` token naming the subtree it
// aggregates. The guard then parses the aggregator root's own `test {}`
// block(s) and requires every test-bearing module under the subtree to be
// aggregated THERE — both `_ = @import("x.zig");` statements and
// `_ = name;` references resolved through the aggregator's top-level
// `const name = @import("x.zig");` declarations count (both forms pull the
// referenced file's tests into the aggregator's test binary).
// ---------------------------------------------------------------------------

const aggregator_marker = "AGGREGATOR for";

const AggregatorDecl = struct {
    /// `src/`-prefixed path of the aggregator root file (itself a deliberate
    /// exclusion — its tests run through a dedicated build.zig test target).
    root: []const u8,
    /// `src/`-prefixed directory prefix (trailing `/` included) of the
    /// subtree whose test-bearing modules the root aggregates.
    subtree: []const u8,
    /// `src/`-prefixed paths of every module referenced by the aggregator's
    /// `test {}` block(s). Populated by `collectAggregatorTestedPaths`.
    tested: std.StringHashMap(void),
};

fn freeAggregators(list: *std.ArrayList(AggregatorDecl), allocator: std.mem.Allocator) void {
    for (list.items) |*aggregator| {
        allocator.free(aggregator.root);
        allocator.free(aggregator.subtree);
        freeKeysAndDeinit(&aggregator.tested, allocator);
    }
    list.deinit(allocator);
}

fn freeBindingsAndDeinit(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Parse every `AGGREGATOR for` declaration out of the exclusions comment in
/// `block_body`. Each declaration contributes one `AggregatorDecl` (with an
/// empty `tested` set — the caller fills it from the aggregator's source).
/// A marker whose root or subtree token is missing or malformed is a hard
/// error: a silently ignored declaration would resurrect the exact
/// dead-tests failure mode this guard exists to prevent.
fn collectAggregators(
    allocator: std.mem.Allocator,
    block_body: []const u8,
    list: *std.ArrayList(AggregatorDecl),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, block_body, cursor, aggregator_marker)) |marker| {
        cursor = marker + aggregator_marker.len;

        // Root token: the nearest backtick span BEFORE the marker.
        const root = nearestBacktickSpanBefore(block_body, marker) orelse {
            std.debug.print(
                "guard: `{s}` declaration has no backticked `src/<path>.zig` root token before it\n",
                .{aggregator_marker},
            );
            return GuardError.MalformedAggregatorDeclaration;
        };
        if (!std.mem.startsWith(u8, root, "src/") or !std.mem.endsWith(u8, root, ".zig")) {
            std.debug.print(
                "guard: `{s}` declaration root token `{s}` is not a `src/<path>.zig` path\n",
                .{ aggregator_marker, root },
            );
            return GuardError.MalformedAggregatorDeclaration;
        }

        // Subtree token: the nearest backtick span AFTER the marker.
        const subtree = nearestBacktickSpanAfter(block_body, cursor) orelse {
            std.debug.print(
                "guard: `{s}` declaration for `{s}` has no backticked `src/<dir>/` subtree token after it\n",
                .{ aggregator_marker, root },
            );
            return GuardError.MalformedAggregatorDeclaration;
        };
        if (!std.mem.startsWith(u8, subtree, "src/") or !std.mem.endsWith(u8, subtree, "/")) {
            std.debug.print(
                "guard: `{s}` declaration for `{s}` names subtree token `{s}`, which is not a `src/<dir>/` prefix\n",
                .{ aggregator_marker, root, subtree },
            );
            return GuardError.MalformedAggregatorDeclaration;
        }
        if (!std.mem.startsWith(u8, root, subtree)) {
            std.debug.print(
                "guard: aggregator root `{s}` does not live under its declared subtree `{s}`\n",
                .{ root, subtree },
            );
            return GuardError.MalformedAggregatorDeclaration;
        }

        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const owned_subtree = try allocator.dupe(u8, subtree);
        errdefer allocator.free(owned_subtree);
        try list.append(allocator, .{
            .root = owned_root,
            .subtree = owned_subtree,
            .tested = std.StringHashMap(void).init(allocator),
        });
    }
}

fn nearestBacktickSpanBefore(text: []const u8, index: usize) ?[]const u8 {
    const close_tick = std.mem.lastIndexOfScalar(u8, text[0..index], '`') orelse return null;
    const open_tick = std.mem.lastIndexOfScalar(u8, text[0..close_tick], '`') orelse return null;
    return text[open_tick + 1 .. close_tick];
}

fn nearestBacktickSpanAfter(text: []const u8, index: usize) ?[]const u8 {
    const open_tick = std.mem.indexOfScalarPos(u8, text, index, '`') orelse return null;
    const close_tick = std.mem.indexOfScalarPos(u8, text, open_tick + 1, '`') orelse return null;
    return text[open_tick + 1 .. close_tick];
}

/// Map every top-level `const <name> = @import("<path>.zig");` declaration in
/// `source` (with or without `pub`) to its import path. Line-based and
/// comment-aware: `//` comment lines and `\\` multiline-string lines are
/// skipped, and only whole-container imports count — a projection such as
/// `const X = @import("x.zig").X;` does not bind (the guard deliberately
/// credits only whole-container references, the established aggregation
/// pattern).
fn collectConstImportBindings(
    allocator: std.mem.Allocator,
    source: []const u8,
    map: *std.StringHashMap([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "\\\\")) continue;

        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub ")) {
            rest = std.mem.trimStart(u8, rest["pub ".len..], " ");
        }
        if (!std.mem.startsWith(u8, rest, "const ")) continue;
        rest = std.mem.trimStart(u8, rest["const ".len..], " ");

        var name_len: usize = 0;
        while (name_len < rest.len and isIdentifierByte(rest[name_len])) : (name_len += 1) {}
        if (name_len == 0) continue;
        const name = rest[0..name_len];
        rest = std.mem.trimStart(u8, rest[name_len..], " ");

        if (!std.mem.startsWith(u8, rest, "=")) continue;
        rest = std.mem.trimStart(u8, rest[1..], " ");

        const needle = "@import(\"";
        if (!std.mem.startsWith(u8, rest, needle)) continue;
        const path_start = needle.len;
        const path_end = std.mem.indexOfScalarPos(u8, rest, path_start, '"') orelse continue;
        const import_path = rest[path_start..path_end];
        if (!std.mem.endsWith(u8, import_path, ".zig")) continue;
        // Whole-container binding only: after the closing quote the statement
        // must be `);` — a `.decl` projection does not aggregate tests.
        const after_quote = std.mem.trimStart(u8, rest[path_end + 1 ..], " ");
        if (!std.mem.startsWith(u8, after_quote, ");")) continue;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_path = try allocator.dupe(u8, import_path);
        const gop = try map.getOrPut(owned_name);
        if (gop.found_existing) {
            allocator.free(owned_name);
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_path;
    }
}

/// Collect every module path aggregated by `source`'s `test {}` block(s) into
/// `set`, as `src/`-prefixed repo-relative paths. Two aggregation forms
/// count, matching Zig's test-collection semantics:
///
///   * `_ = @import("x.zig");` directly inside a test block, and
///   * `_ = name;` inside a test block where `name` is a top-level
///     `const name = @import("x.zig");` binding.
///
/// Import paths are subtree-relative, so each is joined with the directory of
/// `aggregator_root` (a `src/`-prefixed path) before insertion.
fn collectAggregatorTestedPaths(
    allocator: std.mem.Allocator,
    aggregator_root: []const u8,
    source: []const u8,
    set: *std.StringHashMap(void),
) !void {
    const aggregator_dir = std.fs.path.dirnamePosix(aggregator_root) orelse ".";

    var bindings = std.StringHashMap([]const u8).init(allocator);
    defer freeBindingsAndDeinit(&bindings, allocator);
    try collectConstImportBindings(allocator, source, &bindings);

    var relative_paths = std.StringHashMap(void).init(allocator);
    defer freeKeysAndDeinit(&relative_paths, allocator);

    var cursor: usize = 0;
    while (findNextTestBlock(source, cursor)) |block| {
        cursor = block.end;
        const block_body = source[block.start..block.end];

        // Form 1: direct `@import("...")` references.
        try collectImports(allocator, block_body, &relative_paths);

        // Form 2: `_ = name;` references resolved through the bindings.
        var lines = std.mem.splitScalar(u8, block_body, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (!std.mem.startsWith(u8, line, "_")) continue;
            var rest = std.mem.trimStart(u8, line[1..], " ");
            if (!std.mem.startsWith(u8, rest, "=")) continue;
            rest = std.mem.trimStart(u8, rest[1..], " ");
            const semicolon = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
            const referenced = std.mem.trim(u8, rest[0..semicolon], " ");
            if (referenced.len == 0) continue;
            var all_identifier_bytes = true;
            for (referenced) |byte| {
                if (!isIdentifierByte(byte)) {
                    all_identifier_bytes = false;
                    break;
                }
            }
            if (!all_identifier_bytes) continue;
            const bound_path = bindings.get(referenced) orelse continue;
            const owned = try allocator.dupe(u8, bound_path);
            const gop = try relative_paths.getOrPut(owned);
            if (gop.found_existing) allocator.free(owned);
        }
    }

    var it = relative_paths.keyIterator();
    while (it.next()) |relative_path| {
        const joined = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ aggregator_dir, relative_path.* },
        );
        const gop = try set.getOrPut(joined);
        if (gop.found_existing) allocator.free(joined);
    }
}

/// Index of the aggregator whose declared subtree contains `src_relative`
/// (`src/`-prefixed), or null. Longest-prefix match, so a nested aggregator
/// wins over an enclosing one.
fn subtreeAggregatorIndex(aggregators: []const AggregatorDecl, src_relative: []const u8) ?usize {
    var best: ?usize = null;
    var best_len: usize = 0;
    for (aggregators, 0..) |aggregator, index| {
        if (!std.mem.startsWith(u8, src_relative, aggregator.subtree)) continue;
        if (aggregator.subtree.len > best_len) {
            best = index;
            best_len = aggregator.subtree.len;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Unit tests for the subtree-aggregator parsing helpers.
// ---------------------------------------------------------------------------

test "collectAggregators parses the AGGREGATOR annotation from the exclusions comment" {
    const allocator = std.testing.allocator;
    const block_body =
        \\    // DELIBERATE EXCLUSIONS (each covered elsewhere):
        \\    //   * `src/root.zig` — this file (the aggregator itself).
        \\    //   * `src/main.zig` — the CLI executable root.
        \\    //   * `src/runtime/concurrency/concurrency.zig` — AGGREGATOR for
        \\    //     `src/runtime/concurrency/`: the kernel tree, run by
        \\    //     `zig build test-kernel`.
        \\    _ = @import("token.zig");
    ;

    var aggregators: std.ArrayList(AggregatorDecl) = .empty;
    defer freeAggregators(&aggregators, allocator);
    try collectAggregators(allocator, block_body, &aggregators);

    try std.testing.expectEqual(@as(usize, 1), aggregators.items.len);
    try std.testing.expectEqualStrings(
        "src/runtime/concurrency/concurrency.zig",
        aggregators.items[0].root,
    );
    try std.testing.expectEqualStrings(
        "src/runtime/concurrency/",
        aggregators.items[0].subtree,
    );
}

test "collectAggregators rejects a marker with no subtree token after it" {
    const allocator = std.testing.allocator;
    const block_body =
        \\    //   * `src/runtime/concurrency/concurrency.zig` — AGGREGATOR for
        \\    //     the kernel tree (subtree token missing).
    ;

    var aggregators: std.ArrayList(AggregatorDecl) = .empty;
    defer freeAggregators(&aggregators, allocator);
    try std.testing.expectError(
        GuardError.MalformedAggregatorDeclaration,
        collectAggregators(allocator, block_body, &aggregators),
    );
}

test "collectAggregators rejects a marker with no aggregator-root token before it" {
    const allocator = std.testing.allocator;
    const block_body =
        \\    //   * the kernel tree — AGGREGATOR for `src/runtime/concurrency/`.
    ;

    var aggregators: std.ArrayList(AggregatorDecl) = .empty;
    defer freeAggregators(&aggregators, allocator);
    try std.testing.expectError(
        GuardError.MalformedAggregatorDeclaration,
        collectAggregators(allocator, block_body, &aggregators),
    );
}

test "collectConstImportBindings maps top-level const names to import paths" {
    const allocator = std.testing.allocator;
    const source =
        \\pub const stack_pool = @import("stack_pool.zig");
        \\const helper = @import("nested/helper.zig");
        \\pub const StackPool = stack_pool.StackPool;
        \\// const commented_out = @import("commented.zig");
        \\pub const std_dep = @import("std");
    ;

    var bindings = std.StringHashMap([]const u8).init(allocator);
    defer freeBindingsAndDeinit(&bindings, allocator);
    try collectConstImportBindings(allocator, source, &bindings);

    try std.testing.expectEqual(@as(u32, 2), bindings.count());
    try std.testing.expectEqualStrings("stack_pool.zig", bindings.get("stack_pool").?);
    try std.testing.expectEqualStrings("nested/helper.zig", bindings.get("helper").?);
    try std.testing.expect(bindings.get("commented_out") == null);
    try std.testing.expect(bindings.get("std_dep") == null);
    try std.testing.expect(bindings.get("StackPool") == null);
}

test "collectAggregatorTestedPaths resolves direct imports and identifier references" {
    const allocator = std.testing.allocator;
    const source =
        \\pub const alpha = @import("alpha.zig");
        \\pub const beta = @import("nested/beta.zig");
        \\pub const Unrelated = alpha.SomeType;
        \\
        \\test {
        \\    _ = @import("gamma.zig");
        \\    _ = alpha;
        \\    _ = beta; // trailing comment on the reference line
        \\    _ = Unrelated;
        \\}
    ;

    var tested = std.StringHashMap(void).init(allocator);
    defer freeKeysAndDeinit(&tested, allocator);
    try collectAggregatorTestedPaths(
        allocator,
        "src/runtime/concurrency/concurrency.zig",
        source,
        &tested,
    );

    try std.testing.expectEqual(@as(u32, 3), tested.count());
    try std.testing.expect(tested.contains("src/runtime/concurrency/gamma.zig"));
    try std.testing.expect(tested.contains("src/runtime/concurrency/alpha.zig"));
    try std.testing.expect(tested.contains("src/runtime/concurrency/nested/beta.zig"));
}

test "collectAggregatorTestedPaths unions every test block in the aggregator" {
    const allocator = std.testing.allocator;
    const source =
        \\test "named early test" {
        \\    _ = @import("early.zig");
        \\}
        \\
        \\test {
        \\    _ = @import("late.zig");
        \\}
    ;

    var tested = std.StringHashMap(void).init(allocator);
    defer freeKeysAndDeinit(&tested, allocator);
    try collectAggregatorTestedPaths(allocator, "src/tree/root.zig", source, &tested);

    try std.testing.expectEqual(@as(u32, 2), tested.count());
    try std.testing.expect(tested.contains("src/tree/early.zig"));
    try std.testing.expect(tested.contains("src/tree/late.zig"));
}

test "subtreeAggregatorIndex picks the longest matching subtree and skips non-members" {
    const allocator = std.testing.allocator;
    var aggregators: std.ArrayList(AggregatorDecl) = .empty;
    defer freeAggregators(&aggregators, allocator);
    try aggregators.append(allocator, .{
        .root = try allocator.dupe(u8, "src/runtime/root.zig"),
        .subtree = try allocator.dupe(u8, "src/runtime/"),
        .tested = std.StringHashMap(void).init(allocator),
    });
    try aggregators.append(allocator, .{
        .root = try allocator.dupe(u8, "src/runtime/concurrency/concurrency.zig"),
        .subtree = try allocator.dupe(u8, "src/runtime/concurrency/"),
        .tested = std.StringHashMap(void).init(allocator),
    });

    try std.testing.expectEqual(
        @as(?usize, 1),
        subtreeAggregatorIndex(aggregators.items, "src/runtime/concurrency/mailbox.zig"),
    );
    try std.testing.expectEqual(
        @as(?usize, 0),
        subtreeAggregatorIndex(aggregators.items, "src/runtime/other.zig"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        subtreeAggregatorIndex(aggregators.items, "src/lexer.zig"),
    );
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
