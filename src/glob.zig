const std = @import("std");

pub const CollectOptions = struct {
    root: []const u8 = ".",
    include_files: bool = true,
    include_directories: bool = true,
};

pub fn match(pattern: []const u8, path: []const u8) bool {
    const clean_pattern = stripLeadingCurrentDir(pattern);
    const clean_path = stripLeadingCurrentDir(path);
    return matchSegments(clean_pattern, clean_path, 0, 0);
}

fn matchSegments(pattern: []const u8, path: []const u8, pattern_start: usize, path_start: usize) bool {
    if (pattern_start >= pattern.len) return path_start >= path.len;

    const pattern_segment = nextSegment(pattern, pattern_start);
    if (std.mem.eql(u8, pattern_segment.value, "**")) {
        if (pattern_segment.next >= pattern.len) return true;
        if (matchSegments(pattern, path, pattern_segment.next, path_start)) return true;

        var current_path_start = path_start;
        while (current_path_start < path.len) {
            const path_segment = nextSegment(path, current_path_start);
            if (matchSegments(pattern, path, pattern_segment.next, path_segment.next)) return true;
            current_path_start = path_segment.next;
        }
        return false;
    }

    if (path_start >= path.len) return false;
    const path_segment = nextSegment(path, path_start);
    if (!matchSegment(pattern_segment.value, path_segment.value)) return false;
    return matchSegments(pattern, path, pattern_segment.next, path_segment.next);
}

const Segment = struct {
    value: []const u8,
    next: usize,
};

fn nextSegment(value: []const u8, start: usize) Segment {
    var end = start;
    while (end < value.len and value[end] != '/') {
        end += 1;
    }
    return .{
        .value = value[start..end],
        .next = if (end < value.len) end + 1 else end,
    };
}

fn matchSegment(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_value_index: usize = 0;

    while (value_index < value.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern_index = pattern_index;
            star_value_index = value_index;
            pattern_index += 1;
            continue;
        }

        if (pattern_index < pattern.len and
            (pattern[pattern_index] == value[value_index] or pattern[pattern_index] == '?'))
        {
            pattern_index += 1;
            value_index += 1;
            continue;
        }

        if (star_pattern_index) |star_index| {
            pattern_index = star_index + 1;
            star_value_index += 1;
            value_index = star_value_index;
            continue;
        }

        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }

    return pattern_index == pattern.len;
}

pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    options: CollectOptions,
) ![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary_allocator = arena.allocator();

    const clean_pattern = stripLeadingCurrentDir(pattern);
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeMatches(allocator, results.items);

    if (!hasMagic(clean_pattern)) {
        const access_path = try pathForAccess(temporary_allocator, options.root, clean_pattern);
        if (std.Io.Dir.cwd().access(io, access_path, .{})) |_| {
            try results.append(allocator, try allocator.dupe(u8, clean_pattern));
        } else |_| {}
        return results.toOwnedSlice(allocator);
    }

    const base_prefix = basePrefix(clean_pattern);
    const search_path = try pathForAccess(
        temporary_allocator,
        options.root,
        if (base_prefix.len == 0) "." else base_prefix,
    );
    const initial_prefix = stripTrailingSlash(base_prefix);

    try walk(
        allocator,
        temporary_allocator,
        io,
        search_path,
        initial_prefix,
        clean_pattern,
        options,
        &results,
    );

    sort(results.items);
    return results.toOwnedSlice(allocator);
}

pub fn freeMatches(allocator: std.mem.Allocator, matches: []const []const u8) void {
    for (matches) |item| allocator.free(item);
    allocator.free(matches);
}

fn walk(
    result_allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    relative_prefix: []const u8,
    pattern: []const u8,
    options: CollectOptions,
    results: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        const full_path = try std.fs.path.join(temporary_allocator, &.{ dir_path, entry.name });
        const relative_path = if (relative_prefix.len == 0)
            try temporary_allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(temporary_allocator, "{s}/{s}", .{ relative_prefix, entry.name });

        if (entry.kind == .directory) {
            if (options.include_directories and match(pattern, relative_path)) {
                try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
            }
            try walk(
                result_allocator,
                temporary_allocator,
                io,
                full_path,
                relative_path,
                pattern,
                options,
                results,
            );
            continue;
        }

        if (entry.kind == .file and options.include_files and match(pattern, relative_path)) {
            try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
        }
    }
}

fn sort(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}

fn pathForAccess(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative_path) or std.mem.eql(u8, root, ".")) {
        return allocator.dupe(u8, relative_path);
    }
    return std.fs.path.join(allocator, &.{ root, relative_path });
}

fn basePrefix(pattern: []const u8) []const u8 {
    var prefix_end: usize = 0;
    for (pattern, 0..) |character, index| {
        if (character == '*' or character == '?') break;
        if (character == '/') prefix_end = index + 1;
    }
    return pattern[0..prefix_end];
}

fn hasMagic(pattern: []const u8) bool {
    for (pattern) |character| {
        if (character == '*' or character == '?') return true;
    }
    return false;
}

fn stripLeadingCurrentDir(path: []const u8) []const u8 {
    var result = path;
    while (std.mem.startsWith(u8, result, "./")) {
        result = result[2..];
    }
    return result;
}

fn stripTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 0 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

test "match supports literal star question and double star" {
    try std.testing.expect(match("foo.zap", "foo.zap"));
    try std.testing.expect(!match("foo.zap", "bar.zap"));
    try std.testing.expect(match("*.zap", "foo.zap"));
    try std.testing.expect(!match("*.zap", "lib/foo.zap"));
    try std.testing.expect(match("file-?.zap", "file-a.zap"));
    try std.testing.expect(match("**/*.zap", "foo.zap"));
    try std.testing.expect(match("**/*.zap", "lib/sub/foo.zap"));
    try std.testing.expect(match("lib/**/*.zap", "lib/foo.zap"));
    try std.testing.expect(!match("lib/**/*.zap", "test/foo.zap"));
}

test "collect returns sorted relative matches" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.createDirPath(std.Options.debug_io, "fixture/nested");
    {
        var file = try temporary_directory.dir.createFile(std.Options.debug_io, "fixture/b.zap", .{});
        file.close(std.Options.debug_io);
    }
    {
        var file = try temporary_directory.dir.createFile(std.Options.debug_io, "fixture/a.zap", .{});
        file.close(std.Options.debug_io);
    }
    {
        var file = try temporary_directory.dir.createFile(std.Options.debug_io, "fixture/nested/c.txt", .{});
        file.close(std.Options.debug_io);
    }

    const root = try temporary_directory.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);

    const matches = try collect(allocator, std.Options.debug_io, "fixture/*.zap", .{ .root = root });
    defer freeMatches(allocator, matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("fixture/a.zap", matches[0]);
    try std.testing.expectEqualStrings("fixture/b.zap", matches[1]);
}
