const std = @import("std");

// ============================================================
// String similarity for "Did you mean?" suggestions
//
// Implements Jaro-Winkler distance (preferred for short identifiers)
// and Levenshtein distance (fallback for longer names).
// ============================================================

/// Jaro-Winkler similarity between two strings.
/// Returns 0.0 (completely different) to 1.0 (identical).
/// Jaro-Winkler gives extra weight to common prefixes, making it
/// ideal for short identifiers (variable/function names).
pub fn jaroWinkler(a: []const u8, b: []const u8) f64 {
    const jaro_sim = jaro(a, b);
    if (jaro_sim == 0.0) return 0.0;

    // Count common prefix (up to 4 characters)
    const prefix_len: f64 = blk: {
        const max_prefix = @min(@min(a.len, b.len), 4);
        var i: usize = 0;
        while (i < max_prefix and a[i] == b[i]) : (i += 1) {}
        break :blk @floatFromInt(i);
    };

    // Winkler modification: boost for common prefix
    const p = 0.1; // standard scaling factor
    return jaro_sim + (prefix_len * p * (1.0 - jaro_sim));
}

/// Jaro similarity between two strings.
/// Returns 0.0 to 1.0.
fn jaro(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 and b.len == 0) return 1.0;
    if (a.len == 0 or b.len == 0) return 0.0;

    const max_len = @max(a.len, b.len);
    const match_window: usize = if (max_len > 1) max_len / 2 - 1 else 0;

    // Track which characters have been matched
    var a_matched = [_]bool{false} ** 256;
    var b_matched = [_]bool{false} ** 256;

    // Clamp to buffer size
    const a_len = @min(a.len, 256);
    const b_len = @min(b.len, 256);

    // Count matches
    var matches: f64 = 0;
    for (0..a_len) |i| {
        const start = if (i > match_window) i - match_window else 0;
        const end = @min(i + match_window + 1, b_len);

        if (start >= end) continue;
        for (start..end) |j| {
            if (!b_matched[j] and a[i] == b[j]) {
                a_matched[i] = true;
                b_matched[j] = true;
                matches += 1;
                break;
            }
        }
    }

    if (matches == 0) return 0.0;

    // Count transpositions
    var transpositions: f64 = 0;
    var k: usize = 0;
    for (0..a_len) |i| {
        if (!a_matched[i]) continue;
        while (k < b_len and !b_matched[k]) : (k += 1) {}
        if (k < b_len and a[i] != b[k]) {
            transpositions += 1;
        }
        k += 1;
    }

    const a_f: f64 = @floatFromInt(a_len);
    const b_f: f64 = @floatFromInt(b_len);

    return (matches / a_f + matches / b_f + (matches - transpositions / 2.0) / matches) / 3.0;
}

/// Levenshtein edit distance between two strings.
/// Returns the minimum number of single-character edits needed.
pub fn levenshtein(a: []const u8, b: []const u8) u32 {
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);

    // Use single-row optimization (O(min(m,n)) space)
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;

    // Static buffer to avoid allocation; fall back for very long strings
    var static_buf: [512]u32 = undefined;
    const row = if (short.len + 1 <= static_buf.len)
        static_buf[0 .. short.len + 1]
    else
        return @intCast(@max(a.len, b.len)); // degenerate fallback

    // Initialize row
    for (row, 0..) |*cell, i| {
        cell.* = @intCast(i);
    }

    for (long, 0..) |lc, i| {
        var prev = row[0];
        row[0] = @intCast(i + 1);

        for (short, 0..) |sc, j| {
            const cost: u32 = if (lc == sc) 0 else 1;
            const insert = row[j + 1] + 1;
            const delete = row[j] + 1;
            const replace = prev + cost;
            prev = row[j + 1];
            row[j + 1] = @min(insert, @min(delete, replace));
        }
    }

    return row[short.len];
}

/// Find the best match for `name` among `candidates`.
/// Returns the best candidate if similarity >= threshold, else null.
pub fn findBestMatch(name: []const u8, candidates: []const []const u8, threshold: f64) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_score: f64 = 0;

    for (candidates) |candidate| {
        // Skip identical matches
        if (std.mem.eql(u8, name, candidate)) continue;

        const score = jaroWinkler(name, candidate);
        if (score >= threshold and score > best_score) {
            best_score = score;
            best = candidate;
        }
    }

    return best;
}

// Default suggestion threshold
pub const SUGGESTION_THRESHOLD: f64 = 0.8;

// ============================================================
// Tests
// ============================================================

test "jaro-winkler identical strings" {
    try std.testing.expectEqual(@as(f64, 1.0), jaroWinkler("hello", "hello"));
}

test "jaro-winkler empty strings" {
    try std.testing.expectEqual(@as(f64, 1.0), jaroWinkler("", ""));
    try std.testing.expectEqual(@as(f64, 0.0), jaroWinkler("", "hello"));
    try std.testing.expectEqual(@as(f64, 0.0), jaroWinkler("hello", ""));
}

test "jaro-winkler similar short names" {
    // "name" vs "naem" — common typo, should be high similarity
    const score = jaroWinkler("name", "naem");
    try std.testing.expect(score >= 0.9);
}

test "jaro-winkler dissimilar strings" {
    const score = jaroWinkler("hello", "world");
    try std.testing.expect(score < 0.7);
}

test "jaro-winkler prefix boost" {
    // Strings with common prefix should score higher
    const with_prefix = jaroWinkler("defmodule", "defmodul");
    const without = jaroWinkler("xefmodule", "defmodul");
    try std.testing.expect(with_prefix > without);
}

test "levenshtein basic" {
    try std.testing.expectEqual(@as(u32, 0), levenshtein("hello", "hello"));
    try std.testing.expectEqual(@as(u32, 1), levenshtein("hello", "helo"));
    try std.testing.expectEqual(@as(u32, 1), levenshtein("hello", "hellox"));
    try std.testing.expectEqual(@as(u32, 5), levenshtein("hello", ""));
    try std.testing.expectEqual(@as(u32, 5), levenshtein("", "hello"));
}

test "levenshtein transposition" {
    // "name" -> "naem" requires 2 operations (or 1 transposition, counted as 2 edits)
    const dist = levenshtein("name", "naem");
    try std.testing.expect(dist <= 2);
}

test "findBestMatch" {
    const candidates = [_][]const u8{ "name", "game", "fame", "xyz" };
    const result = findBestMatch("naem", &candidates, 0.8);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("name", result.?);
}

test "findBestMatch no match" {
    const candidates = [_][]const u8{ "alpha", "beta", "gamma" };
    const result = findBestMatch("xyz", &candidates, 0.8);
    try std.testing.expect(result == null);
}
