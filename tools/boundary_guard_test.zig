const std = @import("std");

const ForbiddenDispatchString = struct {
    value: []const u8,
    reason: []const u8,
};

const forbidden_dispatch_strings = [_]ForbiddenDispatchString{
    .{ .value = "Path.glob", .reason = "glob dispatch must use the raw :zig.Prim.glob intrinsic" },
    .{ .value = ":zig.Path.glob", .reason = "glob dispatch must use the raw :zig.Prim.glob intrinsic" },
    .{ .value = "__Path__glob", .reason = "glob dispatch must not use a Zap public API name" },
    .{ .value = "SourceGraph.structs", .reason = "source graph reflection must use raw reflection intrinsics" },
    .{ .value = "Struct.functions", .reason = "struct reflection must use raw reflection intrinsics" },
    .{ .value = "__SourceGraph__structs", .reason = "source graph reflection must not use a Zap public API name" },
    .{ .value = "__Struct__functions", .reason = "struct reflection must not use a Zap public API name" },
};

const GuardFailure = error{
    ForbiddenPublicZapApiDispatchString,
};

test "compiler/runtime dispatch does not depend on public Zap runner API names" {
    const allocator = std.testing.allocator;

    var src_dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, "src", .{ .iterate = true });
    defer src_dir.close(std.Options.debug_io);

    var iterator = src_dir.iterate();
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const source = try src_dir.readFileAlloc(std.Options.debug_io, entry.name, allocator, .limited(20 * 1024 * 1024));
        defer allocator.free(source);

        try expectNoForbiddenDispatchStrings(entry.name, source);
    }
}

fn expectNoForbiddenDispatchStrings(file_name: []const u8, source: []const u8) !void {
    var allowed_start: usize = 0;
    var cursor: usize = 0;

    while (findNextTestBlock(source, cursor)) |test_block| {
        try expectNoForbiddenDispatchStringsInRange(file_name, source, allowed_start, test_block.start);
        allowed_start = test_block.end;
        cursor = test_block.end;
    }

    try expectNoForbiddenDispatchStringsInRange(file_name, source, allowed_start, source.len);
}

fn expectNoForbiddenDispatchStringsInRange(
    file_name: []const u8,
    source: []const u8,
    range_start: usize,
    range_end: usize,
) !void {
    const haystack = source[range_start..range_end];
    for (forbidden_dispatch_strings) |forbidden| {
        if (std.mem.indexOf(u8, haystack, forbidden.value)) |relative_index| {
            const source_index = range_start + relative_index;
            const location = lineAndColumn(source, source_index);
            std.debug.print(
                "forbidden public Zap API dispatch string in src/{s}:{d}:{d}: \"{s}\" ({s})\n",
                .{ file_name, location.line, location.column, forbidden.value, forbidden.reason },
            );
            return GuardFailure.ForbiddenPublicZapApiDispatchString;
        }
    }
}

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

const SourceLocation = struct {
    line: usize,
    column: usize,
};

fn lineAndColumn(source: []const u8, index: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..index]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    return .{ .line = line, .column = column };
}
