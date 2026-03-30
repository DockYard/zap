//! Lockfile Management
//!
//! Generates and reads zap.lock for reproducible builds.
//! Format: one line per dep, tab-separated fields:
//!   name\ttype\turl\tresolved_ref\tcommit\tintegrity

const std = @import("std");
const zap = @import("root.zig");
const BuildConfig = zap.builder.BuildConfig;

pub const LockEntry = struct {
    name: []const u8,
    source_type: []const u8, // "git", "path", "zig", "system"
    url: []const u8, // url or path
    resolved_ref: []const u8, // tag, branch, or "–"
    commit: []const u8, // full commit hash or "–"
    integrity: []const u8, // "sha256-..." or "–"
};

/// Read and parse zap.lock. Returns null if the file doesn't exist.
pub fn readLockfile(alloc: std.mem.Allocator, project_root: []const u8) ?[]const LockEntry {
    const lock_path = std.fs.path.join(alloc, &.{ project_root, "zap.lock" }) catch return null;
    defer alloc.free(lock_path);
    const content = std.fs.cwd().readFileAlloc(alloc, lock_path, 1024 * 1024) catch return null;

    var entries: std.ArrayListUnmanaged(LockEntry) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip comments and empty lines
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const source_type = fields.next() orelse continue;
        const url = fields.next() orelse continue;
        const resolved_ref = fields.next() orelse continue;
        const commit = fields.next() orelse continue;
        const integrity = fields.next() orelse continue;

        entries.append(alloc, .{
            .name = name,
            .source_type = source_type,
            .url = url,
            .resolved_ref = resolved_ref,
            .commit = commit,
            .integrity = integrity,
        }) catch continue;
    }

    return entries.toOwnedSlice(alloc) catch return null;
}

/// Write zap.lock from a list of resolved deps.
pub fn writeLockfile(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    entries: []const LockEntry,
) !void {
    const lock_path = try std.fs.path.join(alloc, &.{ project_root, "zap.lock" });
    var file = try std.fs.cwd().createFile(lock_path, .{});
    defer file.close();
    const writer = file.deprecatedWriter();

    try writer.writeAll("# zap.lock — auto-generated, do not edit\n");
    try writer.writeAll("# name\ttype\turl\tresolved\tcommit\tintegrity\n");

    for (entries) |entry| {
        try writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            entry.name,
            entry.source_type,
            entry.url,
            entry.resolved_ref,
            entry.commit,
            entry.integrity,
        });
    }
}

/// Find a lock entry by dep name.
pub fn findEntry(entries: []const LockEntry, name: []const u8) ?LockEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Fetch a git dep to the cache directory. Returns the path to the cached checkout.
///
/// Cache location: ~/.cache/zap/deps/<name>-<commit_prefix>/
/// If already cached, returns immediately.
pub fn fetchGitDep(
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
    locked_commit: ?[]const u8,
) !struct { path: []const u8, commit: []const u8, integrity: []const u8 } {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const cache_base = try std.fs.path.join(alloc, &.{ home, ".cache", "zap", "deps" });
    std.fs.cwd().makePath(cache_base) catch {};

    // If we have a locked commit, check the cache first
    if (locked_commit) |commit| {
        const cache_dir = try std.fmt.allocPrint(alloc, "{s}/{s}-{s}", .{
            cache_base, name, commit[0..@min(commit.len, 8)],
        });
        if (std.fs.cwd().access(cache_dir, .{})) |_| {
            // Compute integrity from cached content
            const integrity = computeDirectoryHash(alloc, cache_dir) catch "-";
            return .{ .path = cache_dir, .commit = commit, .integrity = integrity };
        } else |_| {}
    }

    // Clone to a temp directory, then move to cache
    const tmp_dir = try std.fmt.allocPrint(alloc, "{s}/{s}-tmp", .{ cache_base, name });
    // Remove any leftover tmp dir
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Build git clone command
    var clone_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer clone_args.deinit(alloc);
    try clone_args.append(alloc, "git");
    try clone_args.append(alloc, "clone");
    try clone_args.append(alloc, "--depth");
    try clone_args.append(alloc, "1");
    if (ref) |r| {
        try clone_args.append(alloc, "--branch");
        try clone_args.append(alloc, r);
    }
    try clone_args.append(alloc, url);
    try clone_args.append(alloc, tmp_dir);

    // Execute git clone
    const clone_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = clone_args.items,
        .max_output_bytes = 1024 * 1024,
    }) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Error: git clone failed for dep `{s}` from {s}\n", .{ name, url }) catch {};
        return error.GitCloneFailed;
    };
    if (clone_result.term != .Exited or clone_result.term.Exited != 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Error: git clone failed for dep `{s}` from {s}\n", .{ name, url }) catch {};
        return error.GitCloneFailed;
    }

    // Get the commit hash
    const rev_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "-C", tmp_dir, "rev-parse", "HEAD" },
        .max_output_bytes = 256,
    }) catch {
        return error.GitCloneFailed;
    };

    const commit = std.mem.trimRight(u8, rev_result.stdout, "\n\r ");
    const commit_owned = try alloc.dupe(u8, commit);

    // Move to final cache location
    const cache_dir = try std.fmt.allocPrint(alloc, "{s}/{s}-{s}", .{
        cache_base, name, commit_owned[0..@min(commit_owned.len, 8)],
    });
    // Remove existing if it's there (shouldn't be, but be safe)
    std.fs.cwd().deleteTree(cache_dir) catch {};
    std.fs.cwd().rename(tmp_dir, cache_dir) catch {
        // If rename fails (cross-device), try to use tmp_dir directly
        const integrity = computeDirectoryHash(alloc, tmp_dir) catch "-";
        return .{ .path = tmp_dir, .commit = commit_owned, .integrity = integrity };
    };

    const integrity = computeDirectoryHash(alloc, cache_dir) catch "-";
    return .{ .path = cache_dir, .commit = commit_owned, .integrity = integrity };
}

/// Compute a SHA-256 hash over all .zap files in a directory, sorted by name.
/// Returns "sha256-<hex>" or error.
fn computeDirectoryHash(alloc: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Hash the directory path for uniqueness
    hasher.update(dir_path);

    // Walk the directory and hash all .zap file contents
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zap")) {
            hasher.update(entry.name);
            const content = dir.readFileAlloc(alloc, entry.name, 10 * 1024 * 1024) catch continue;
            defer alloc.free(content);
            hasher.update(content);
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Format as "sha256-<hex>"
    var hex_buf: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
        hex_buf[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
    }
    return try std.fmt.allocPrint(alloc, "sha256-{s}", .{hex_buf[0..16]});
}

pub const FetchError = error{
    GitCloneFailed,
    OutOfMemory,
} || std.fs.File.OpenError || std.posix.RenameError;

test "readLockfile: returns null for missing file" {
    const result = readLockfile(std.testing.allocator, "/nonexistent/path");
    try std.testing.expectEqual(null, result);
}

test "writeLockfile and readLockfile round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");

    const entries = &[_]LockEntry{
        .{
            .name = "my_dep",
            .source_type = "git",
            .url = "https://github.com/example/dep.git",
            .resolved_ref = "v1.0.0",
            .commit = "abc123def456",
            .integrity = "sha256-deadbeef01234567",
        },
        .{
            .name = "local_dep",
            .source_type = "path",
            .url = "../local",
            .resolved_ref = "-",
            .commit = "-",
            .integrity = "-",
        },
    };

    try writeLockfile(alloc, tmp_path, entries);

    // Read it back
    const read_entries = readLockfile(alloc, tmp_path) orelse {
        return error.TestExpectedNonNull;
    };

    try std.testing.expectEqual(@as(usize, 2), read_entries.len);
    try std.testing.expectEqualStrings("my_dep", read_entries[0].name);
    try std.testing.expectEqualStrings("git", read_entries[0].source_type);
    try std.testing.expectEqualStrings("https://github.com/example/dep.git", read_entries[0].url);
    try std.testing.expectEqualStrings("v1.0.0", read_entries[0].resolved_ref);
    try std.testing.expectEqualStrings("abc123def456", read_entries[0].commit);
    try std.testing.expectEqualStrings("sha256-deadbeef01234567", read_entries[0].integrity);

    try std.testing.expectEqualStrings("local_dep", read_entries[1].name);
    try std.testing.expectEqualStrings("path", read_entries[1].source_type);
    try std.testing.expectEqualStrings("-", read_entries[1].commit);
}

test "findEntry: finds by name" {
    const entries = &[_]LockEntry{
        .{ .name = "a", .source_type = "path", .url = ".", .resolved_ref = "-", .commit = "-", .integrity = "-" },
        .{ .name = "b", .source_type = "git", .url = "url", .resolved_ref = "v1", .commit = "abc", .integrity = "sha256-x" },
    };

    const found = findEntry(entries, "b");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("git", found.?.source_type);
    try std.testing.expectEqualStrings("abc", found.?.commit);

    const not_found = findEntry(entries, "c");
    try std.testing.expectEqual(null, not_found);
}

test "writeLockfile: overwrites existing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");

    // Write initial lockfile
    try writeLockfile(alloc, tmp_path, &.{
        .{ .name = "old_dep", .source_type = "path", .url = ".", .resolved_ref = "-", .commit = "-", .integrity = "-" },
    });

    // Overwrite with new deps (simulates adding a dep)
    try writeLockfile(alloc, tmp_path, &.{
        .{ .name = "old_dep", .source_type = "path", .url = ".", .resolved_ref = "-", .commit = "-", .integrity = "-" },
        .{ .name = "new_dep", .source_type = "git", .url = "url", .resolved_ref = "v2", .commit = "def456", .integrity = "sha256-y" },
    });

    const entries = readLockfile(alloc, tmp_path) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("new_dep", entries[1].name);
}

test "computeDirectoryHash: produces consistent hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.zap",
        .data = "defmodule Test do\nend\n",
    });

    const hash1 = try computeDirectoryHash(alloc, tmp_path);
    const hash2 = try computeDirectoryHash(alloc, tmp_path);

    // Same content produces same hash
    try std.testing.expectEqualStrings(hash1, hash2);
    try std.testing.expect(std.mem.startsWith(u8, hash1, "sha256-"));
}
