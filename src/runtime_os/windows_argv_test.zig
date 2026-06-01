//! Native unit tests for the Windows command-line splitter
//! (`Backend.splitCommandLineWtf16` in `src/runtime_os/windows.zig`).
//!
//! The Windows `argv()` backend recovers the process argument vector by
//! reading the PEB `CommandLine` WTF-16 `UNICODE_STRING` and tokenizing it
//! with the documented `CommandLineToArgvW` quote/backslash rules, then
//! transcoding each argument WTF-16 → UTF-8 into a static cache. The PEB
//! read is the only Windows-specific step; the tokenizer + transcoder
//! (`splitCommandLineWtf16`) is PURE — it takes a `[]const u16` and output
//! buffers — so it can be exercised on the HOST with synthetic WTF-16 input
//! and asserted byte-for-byte, WITHOUT a Windows runtime or wine.
//!
//! This file is its own `zig build test` target (native host target), so the
//! parsing logic is proven correct on every `zig build test` run even though
//! the full `src/runtime_os/windows.zig` backend is only COMPILE-checked for
//! `x86_64-windows-gnu` (it cannot run on the host). Lazy analysis means
//! importing the backend here pulls in only the reachable pure splitter, not
//! the PEB/console/VEH code.
//!
//! The cases below cover the full tricky surface called out for the Windows
//! argv follow-up: simple separation, quoted-with-spaces, embedded quotes,
//! even/odd backslash runs before a quote, the `""`-in-quotes literal-quote
//! rule, leading/trailing/multiple separators, an empty command line, the
//! special argv[0] (program-name) quoting, a non-ASCII (BMP) transcode, and
//! an unpaired surrogate (the reason WTF-16, not strict UTF-16, is used).

const std = @import("std");
const Backend = @import("windows.zig").Backend;

/// Encode a UTF-8 test string to a heap-allocated WTF-16LE `[]u16` for
/// feeding the splitter. Caller frees. Test-only convenience.
fn wtf16(allocator: std.mem.Allocator, comptime utf8: []const u8) ![]u16 {
    return std.unicode.wtf8ToWtf16LeAlloc(allocator, utf8);
}

/// Run the splitter on `command_line` and return the parsed argv as a list of
/// owned UTF-8 `[]u8` slices (copied out of the splitter's caller-provided
/// scratch so assertions are independent of buffer reuse). Caller frees each
/// slice and the outer list.
fn splitToOwned(
    allocator: std.mem.Allocator,
    command_line: []const u16,
) ![][]u8 {
    var bytes: [4096]u8 = undefined;
    var ptrs: [64][*:0]const u8 = undefined;
    const argc = Backend.splitCommandLineWtf16(command_line, &bytes, &ptrs);

    var result = try allocator.alloc([]u8, argc);
    errdefer allocator.free(result);
    var filled: usize = 0;
    errdefer for (result[0..filled]) |s| allocator.free(s);
    while (filled < argc) : (filled += 1) {
        const arg = std.mem.span(ptrs[filled]);
        result[filled] = try allocator.dupe(u8, arg);
    }
    return result;
}

fn freeOwned(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |s| allocator.free(s);
    allocator.free(args);
}

test "splitCommandLineWtf16 - simple space-separated args" {
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "a b c");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("a", args[0]);
    try std.testing.expectEqualStrings("b", args[1]);
    try std.testing.expectEqualStrings("c", args[2]);
}

test "splitCommandLineWtf16 - quoted arg preserves spaces" {
    // argv[0] = `prog`, argv[1] = `a b` (quotes removed, inner space kept),
    // argv[2] = `c`.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog \"a b\" c");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("a b", args[1]);
    try std.testing.expectEqualStrings("c", args[2]);
}

test "splitCommandLineWtf16 - embedded quote toggles mid-token" {
    // `a"b c"d` is ONE argument: the quote toggles quoting in place, so the
    // space inside the quoted region is kept and the token is `ab cd`.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog a\"b c\"d");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("ab cd", args[1]);
}

test "splitCommandLineWtf16 - even backslashes before quote (2n -> n backslashes + toggle)" {
    // Program name then `a\\"b`: two backslashes (2n, n=1) before a quote →
    // one literal backslash and the quote TOGGLES (is consumed, not emitted).
    // `b` follows inside quotes → argument is `a\b`.
    const allocator = std.testing.allocator;
    // u16 literal: 'p' 'r' 'o' 'g' ' ' 'a' '\' '\' '"' 'b'
    const cl = [_]u16{ 'p', 'r', 'o', 'g', ' ', 'a', '\\', '\\', '"', 'b' };

    const args = try splitToOwned(allocator, &cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("a\\b", args[1]); // a, backslash, b
}

test "splitCommandLineWtf16 - odd backslashes before quote (2n+1 -> n backslashes + literal quote)" {
    // `a\\\"b`: three backslashes (2n+1, n=1) before a quote → one literal
    // backslash and a LITERAL quote (escaped; quoting state unchanged). `b`
    // follows → argument is `a\"b`.
    const allocator = std.testing.allocator;
    // 'p' 'r' 'o' 'g' ' ' 'a' '\' '\' '\' '"' 'b'
    const cl = [_]u16{ 'p', 'r', 'o', 'g', ' ', 'a', '\\', '\\', '\\', '"', 'b' };

    const args = try splitToOwned(allocator, &cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("a\\\"b", args[1]); // a, backslash, quote, b
}

test "splitCommandLineWtf16 - trailing backslashes (no quote) are literal" {
    // A run of backslashes NOT followed by a quote is emitted verbatim.
    const allocator = std.testing.allocator;
    // 'p' 'r' 'o' 'g' ' ' 'a' '\' '\' '\'
    const cl = [_]u16{ 'p', 'r', 'o', 'g', ' ', 'a', '\\', '\\', '\\' };

    const args = try splitToOwned(allocator, &cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("a\\\\\\", args[1]); // a + three backslashes
}

test "splitCommandLineWtf16 - double-quote inside quotes is a literal quote" {
    // The post-2005 CRT rule: inside a quoted region, `""` emits ONE literal
    // `"` and stays in-quotes. `prog "a""b"` → argv[1] = `a"b`.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog \"a\"\"b\"");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("a\"b", args[1]); // a, quote, b
}

test "splitCommandLineWtf16 - leading, trailing, and repeated separators collapse" {
    // Leading/trailing spaces and tabs and runs of them produce no empty
    // arguments. (Tab is a separator too.)
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "   a\t\t b   c \t");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("a", args[0]);
    try std.testing.expectEqualStrings("b", args[1]);
    try std.testing.expectEqualStrings("c", args[2]);
}

test "splitCommandLineWtf16 - empty command line yields no args" {
    const allocator = std.testing.allocator;
    const cl = [_]u16{};

    const args = try splitToOwned(allocator, &cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 0), args.len);
}

test "splitCommandLineWtf16 - all-whitespace command line yields no args" {
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "   \t  ");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 0), args.len);
}

test "splitCommandLineWtf16 - argv[0] program name uses special quoting (backslashes literal)" {
    // For argv[0] ONLY, backslashes are literal and a quote merely toggles a
    // quoted region. A quoted program path with spaces is one token; its
    // backslashes are preserved without escape interpretation.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "\"C:\\Program Files\\app.exe\" arg1");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\app.exe", args[0]);
    try std.testing.expectEqualStrings("arg1", args[1]);
}

test "splitCommandLineWtf16 - argv[0] unquoted ends at first space" {
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "C:\\app.exe hello world");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("C:\\app.exe", args[0]);
    try std.testing.expectEqualStrings("hello", args[1]);
    try std.testing.expectEqualStrings("world", args[2]);
}

test "splitCommandLineWtf16 - non-ASCII BMP arg transcodes WTF-16 to UTF-8" {
    // `café` (é = U+00E9, 2 UTF-8 bytes) and `日本語` (each U+65E5/U+672C/
    // U+8A9E, 3 UTF-8 bytes) round-trip through the WTF-16 → UTF-8 transcode.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog café 日本語");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("café", args[1]);
    try std.testing.expectEqualStrings("日本語", args[2]);
}

test "splitCommandLineWtf16 - supplementary-plane arg (surrogate pair) transcodes" {
    // U+1F600 (😀) is a surrogate PAIR in WTF-16 (D83D DE00) and 4 UTF-8
    // bytes. A correct WTF-16 → UTF-8 step recombines the pair.
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog 😀");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("😀", args[1]);
}

test "splitCommandLineWtf16 - unpaired surrogate is preserved (WTF-16, not strict UTF-16)" {
    // A lone high surrogate (U+D83D with no following low surrogate) is
    // INVALID UTF-16 but a valid WTF-16 sequence — Windows paths/args can
    // contain such. The WTF-8 transcode preserves it as the 3-byte WTF-8
    // encoding of the surrogate code point (ED A0 BD), rather than rejecting
    // or replacing it. This is exactly why the backend uses the WTF variant.
    const allocator = std.testing.allocator;
    // 'a' then a lone high surrogate 0xD83D.
    const cl = [_]u16{ 'a', 0xD83D };

    const args = try splitToOwned(allocator, &cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 1), args.len);
    // WTF-8 of U+D83D = 0xED 0xA0 0xBD, preceded by 'a'.
    const expected = [_]u8{ 'a', 0xED, 0xA0, 0xBD };
    try std.testing.expectEqualStrings(&expected, args[0]);
}

test "splitCommandLineWtf16 - empty quoted arg is a present empty string" {
    // A standalone `""` argument is a real, empty argument (argc counts it).
    const allocator = std.testing.allocator;
    const cl = try wtf16(allocator, "prog \"\" tail");
    defer allocator.free(cl);

    const args = try splitToOwned(allocator, cl);
    defer freeOwned(allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("prog", args[0]);
    try std.testing.expectEqualStrings("", args[1]);
    try std.testing.expectEqualStrings("tail", args[2]);
}
