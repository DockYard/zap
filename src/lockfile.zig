//! Lockfile Management
//!
//! Generates and reads zap.lock for reproducible builds.
//! Format: one line per dep, tab-separated fields:
//!   name\ttype\turl\tresolved_ref\tcommit\tintegrity

const std = @import("std");
const build_cache = @import("build_cache.zig");
const env = @import("env.zig");

const io = std.Options.debug_io;

pub const LockEntry = struct {
    name: []const u8,
    source_type: []const u8, // "git", "path", "zig", "system"
    url: []const u8, // url or path
    resolved_ref: []const u8, // tag, branch, or "–"
    commit: []const u8, // full commit hash or "–"
    integrity: []const u8, // "sha256-..." or "–"
};

/// Owned zap.lock contents and parsed entries.
///
/// Each `LockEntry` string slice points into `content`; callers must keep the
/// `OwnedLockfile` alive for as long as they use `entries`.
pub const OwnedLockfile = struct {
    allocator: std.mem.Allocator,
    content: []u8,
    entries: []const LockEntry,

    pub fn deinit(self: *OwnedLockfile) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

/// Result of reading zap.lock.
///
/// `absent` is returned only when `zap.lock` truly does not exist. Read,
/// parse, and allocation failures are returned as errors.
pub const ReadLockfileResult = union(enum) {
    absent,
    present: OwnedLockfile,

    pub fn deinit(self: *ReadLockfileResult) void {
        switch (self.*) {
            .absent => {},
            .present => |*lockfile| lockfile.deinit(),
        }
        self.* = undefined;
    }
};

pub const ReadLockfileError = std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || error{
    InvalidLockfile,
};

/// Read and parse zap.lock.
pub fn readLockfile(
    alloc: std.mem.Allocator,
    project_root: []const u8,
) ReadLockfileError!ReadLockfileResult {
    const lock_path = try std.fs.path.join(alloc, &.{ project_root, "zap.lock" });
    defer alloc.free(lock_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, lock_path, alloc, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => |read_err| return read_err,
    };
    errdefer alloc.free(content);

    var entries: std.ArrayListUnmanaged(LockEntry) = .empty;
    errdefer entries.deinit(alloc);

    var rest: []const u8 = content;
    while (rest.len > 0) {
        const raw_line, const remaining = std.mem.cutScalar(u8, rest, '\n') orelse .{ rest, "" };
        rest = remaining;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        // Skip comments and empty lines
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        try entries.append(alloc, try parseLockEntryLine(line));
    }

    const owned_entries = try entries.toOwnedSlice(alloc);
    return .{ .present = .{
        .allocator = alloc,
        .content = content,
        .entries = owned_entries,
    } };
}

fn parseLockEntryLine(line: []const u8) error{InvalidLockfile}!LockEntry {
    const name, const after_name = std.mem.cutScalar(u8, line, '\t') orelse return error.InvalidLockfile;
    const source_type, const after_type = std.mem.cutScalar(u8, after_name, '\t') orelse return error.InvalidLockfile;
    const url_field, const after_url = std.mem.cutScalar(u8, after_type, '\t') orelse return error.InvalidLockfile;
    const resolved_ref, const after_ref = std.mem.cutScalar(u8, after_url, '\t') orelse return error.InvalidLockfile;
    const commit_field, const integrity = std.mem.cutScalar(u8, after_ref, '\t') orelse return error.InvalidLockfile;
    if (name.len == 0 or
        source_type.len == 0 or
        url_field.len == 0 or
        resolved_ref.len == 0 or
        commit_field.len == 0 or
        integrity.len == 0 or
        std.mem.indexOfScalar(u8, integrity, '\t') != null)
    {
        return error.InvalidLockfile;
    }
    return .{
        .name = name,
        .source_type = source_type,
        .url = url_field,
        .resolved_ref = resolved_ref,
        .commit = commit_field,
        .integrity = integrity,
    };
}

/// Write zap.lock from a list of resolved deps.
pub fn writeLockfile(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    entries: []const LockEntry,
) !void {
    const lock_path = try std.fs.path.join(alloc, &.{ project_root, "zap.lock" });
    defer alloc.free(lock_path);

    // Build content in memory.
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(alloc);

    try content.appendSlice(alloc, "# zap.lock — auto-generated, do not edit\n");
    try content.appendSlice(alloc, "# name\ttype\turl\tresolved\tcommit\tintegrity\n");

    for (entries) |entry| {
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            entry.name,
            entry.source_type,
            entry.url,
            entry.resolved_ref,
            entry.commit,
            entry.integrity,
        });
        defer alloc.free(line);
        try content.appendSlice(alloc, line);
    }

    try build_cache.writeFileAtomic(alloc, lock_path, content.items);
}

/// Find a lock entry by dep name.
pub fn findEntry(entries: []const LockEntry, name: []const u8) ?LockEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub const FetchGitDepError = std.mem.Allocator.Error ||
    std.process.RunError ||
    std.Io.Dir.AccessError ||
    std.Io.Dir.CopyFileError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.DeleteTreeError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.ReadLinkError ||
    std.Io.Dir.RenamePreserveError ||
    std.Io.Dir.SymLinkError ||
    error{
        GitCloneFailed,
        GitRevParseFailed,
        FetchTaskFailed,
        HomeNotSet,
        IntegrityMismatch,
        InvalidCommitHash,
        LockfileCommitMismatch,
        LockfileIntegrityMismatch,
        LockfileSourceDrift,
        UnsupportedCacheEntry,
    };

/// Cached checkout for a git dependency.
///
/// `path`, `commit`, and `integrity` are owned by the caller.
pub const GitDepCheckout = struct {
    path: []const u8,
    commit: []const u8,
    integrity: []const u8,

    pub fn deinit(self: GitDepCheckout, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.commit);
        allocator.free(self.integrity);
    }
};

/// Fetch a git dep to the cache directory. Returns the path to the cached checkout.
///
/// Cache location: ~/.cache/zap/deps/<name>-<commit_prefix>/
/// If already cached, returns immediately after successfully hashing the cache.
pub fn fetchGitDep(
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
    locked: ?LockEntry,
) FetchGitDepError!GitDepCheckout {
    return fetchGitDepFromHome(alloc, env.getenv("HOME") orelse return error.HomeNotSet, name, url, ref, locked);
}

fn fetchGitDepFromHome(
    alloc: std.mem.Allocator,
    home: []const u8,
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
    locked: ?LockEntry,
) FetchGitDepError!GitDepCheckout {
    const cache_base = try dependencyCacheBase(alloc, home);
    defer alloc.free(cache_base);
    try std.Io.Dir.cwd().createDirPath(io, cache_base);

    if (locked) |lock_entry| {
        try validateLockedGitEntryForRequest(lock_entry, name, url, ref);
        if (try cachedCheckout(alloc, cache_base, name, lock_entry.commit, .{ .lockfile = lock_entry.integrity })) |checkout| return checkout;
    }

    const tmp_dir = try uniqueCacheTempPath(alloc, cache_base, name, "clone");
    defer alloc.free(tmp_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try cloneGitDependency(alloc, name, url, ref, tmp_dir);

    const commit_owned = try gitHeadCommit(alloc, tmp_dir);
    errdefer alloc.free(commit_owned);
    try validateCommitHash(commit_owned);

    if (locked) |lock_entry| {
        if (!std.mem.eql(u8, lock_entry.commit, commit_owned)) return error.LockfileCommitMismatch;
    }

    const clone_integrity = try computeDirectoryHash(alloc, tmp_dir);
    errdefer alloc.free(clone_integrity);

    if (locked) |lock_entry| {
        if (!std.mem.eql(u8, lock_entry.integrity, clone_integrity)) return error.LockfileIntegrityMismatch;
    }

    const cache_expectation: CacheIntegrityExpectation = if (locked) |lock_entry|
        .{ .lockfile = lock_entry.integrity }
    else
        .{ .fresh_clone = clone_integrity };

    if (try cachedCheckout(alloc, cache_base, name, commit_owned, cache_expectation)) |checkout| {
        errdefer checkout.deinit(alloc);
        try deleteTemporaryTree(tmp_dir);
        alloc.free(commit_owned);
        alloc.free(clone_integrity);
        return checkout;
    }

    const cache_dir = try cacheDirForCommit(alloc, cache_base, name, commit_owned);
    errdefer alloc.free(cache_dir);

    try installCachedDirectory(alloc, tmp_dir, cache_dir);
    try deleteTemporaryTree(tmp_dir);

    const installed_integrity = try computeDirectoryHash(alloc, cache_dir);
    defer alloc.free(installed_integrity);
    if (!std.mem.eql(u8, installed_integrity, clone_integrity)) return error.IntegrityMismatch;

    return .{
        .path = cache_dir,
        .commit = commit_owned,
        .integrity = clone_integrity,
    };
}

fn dependencyCacheBase(alloc: std.mem.Allocator, home: ?[]const u8) FetchGitDepError![]const u8 {
    const home_path = home orelse return error.HomeNotSet;
    if (home_path.len == 0) return error.HomeNotSet;
    return std.fs.path.join(alloc, &.{ home_path, ".cache", "zap", "deps" });
}

const CacheIntegrityExpectation = union(enum) {
    lockfile: []const u8,
    fresh_clone: []const u8,
};

fn cachedCheckout(
    alloc: std.mem.Allocator,
    cache_base: []const u8,
    name: []const u8,
    commit: []const u8,
    expectation: ?CacheIntegrityExpectation,
) FetchGitDepError!?GitDepCheckout {
    const cache_dir = try cacheDirForCommit(alloc, cache_base, name, commit);
    errdefer alloc.free(cache_dir);

    std.Io.Dir.cwd().access(io, cache_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            alloc.free(cache_dir);
            return null;
        },
        else => |access_err| return access_err,
    };

    const commit_owned = try alloc.dupe(u8, commit);
    errdefer alloc.free(commit_owned);
    const integrity = try computeDirectoryHash(alloc, cache_dir);
    errdefer alloc.free(integrity);
    if (expectation) |expected| {
        switch (expected) {
            .lockfile => |expected_integrity| {
                if (!std.mem.eql(u8, expected_integrity, integrity)) return error.LockfileIntegrityMismatch;
            },
            .fresh_clone => |expected_integrity| {
                if (!std.mem.eql(u8, expected_integrity, integrity)) return error.IntegrityMismatch;
            },
        }
    }

    return .{
        .path = cache_dir,
        .commit = commit_owned,
        .integrity = integrity,
    };
}

fn validateLockedGitEntryForRequest(
    lock_entry: LockEntry,
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
) FetchGitDepError!void {
    if (!std.mem.eql(u8, lock_entry.name, name) or
        !std.mem.eql(u8, lock_entry.source_type, "git") or
        !std.mem.eql(u8, lock_entry.url, url) or
        !std.mem.eql(u8, lock_entry.resolved_ref, lockedRefField(ref)))
    {
        return error.LockfileSourceDrift;
    }
    try validateCommitHash(lock_entry.commit);
    try validateIntegrityHash(lock_entry.integrity);
}

fn lockedRefField(ref: ?[]const u8) []const u8 {
    return ref orelse "-";
}

fn validateCommitHash(commit: []const u8) FetchGitDepError!void {
    if (commit.len < 8) return error.InvalidCommitHash;
    for (commit) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidCommitHash;
    }
}

fn validateIntegrityHash(integrity: []const u8) FetchGitDepError!void {
    const prefix = "sha256-";
    if (integrity.len != prefix.len + 64) return error.LockfileIntegrityMismatch;
    if (!std.mem.startsWith(u8, integrity, prefix)) return error.LockfileIntegrityMismatch;
    for (integrity[prefix.len..]) |byte| {
        if (!std.ascii.isHex(byte)) return error.LockfileIntegrityMismatch;
    }
}

fn cacheDirForCommit(
    alloc: std.mem.Allocator,
    cache_base: []const u8,
    name: []const u8,
    commit: []const u8,
) FetchGitDepError![]const u8 {
    try validateCommitHash(commit);
    return std.fmt.allocPrint(alloc, "{s}/{s}-{s}", .{ cache_base, name, commit[0..8] });
}

fn uniqueCacheTempPath(
    alloc: std.mem.Allocator,
    cache_base: []const u8,
    name: []const u8,
    label: []const u8,
) FetchGitDepError![]const u8 {
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);

    var random_hex: [32]u8 = undefined;
    for (random_bytes, 0..) |byte, index| {
        random_hex[index * 2] = std.fmt.digitToChar(byte >> 4, .lower);
        random_hex[index * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
    }

    return std.fmt.allocPrint(alloc, "{s}/.tmp-{s}-{s}-{s}", .{
        cache_base,
        label,
        name,
        random_hex[0..],
    });
}

fn deleteTemporaryTree(path: []const u8) FetchGitDepError!void {
    try std.Io.Dir.cwd().deleteTree(io, path);
}

fn cloneGitDependency(
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
    tmp_dir: []const u8,
) FetchGitDepError!void {
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

    const clone_result = try std.process.run(alloc, io, .{
        .argv = clone_args.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer deinitRunResult(alloc, clone_result);

    if (clone_result.term != .exited or clone_result.term.exited != 0) {
        std.debug.print("Error: git clone failed for dep `{s}` from {s}\n", .{ name, url });
        return error.GitCloneFailed;
    }
}

fn gitHeadCommit(alloc: std.mem.Allocator, tmp_dir: []const u8) FetchGitDepError![]const u8 {
    const rev_result = try std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", tmp_dir, "rev-parse", "HEAD" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer deinitRunResult(alloc, rev_result);

    if (rev_result.term != .exited or rev_result.term.exited != 0) return error.GitRevParseFailed;

    const commit = std.mem.trimEnd(u8, rev_result.stdout, "\n\r ");
    try validateCommitHash(commit);
    return try alloc.dupe(u8, commit);
}

fn deinitRunResult(alloc: std.mem.Allocator, result: std.process.RunResult) void {
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

fn installCachedDirectory(
    alloc: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) FetchGitDepError!void {
    std.Io.Dir.cwd().renamePreserve(source_path, std.Io.Dir.cwd(), destination_path, io) catch |err| switch (err) {
        error.CrossDevice => return installCachedDirectoryByCopy(alloc, source_path, destination_path),
        error.PathAlreadyExists => return,
        else => |install_err| return install_err,
    };
}

fn installCachedDirectoryByCopy(
    alloc: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) FetchGitDepError!void {
    const destination_parent = std.fs.path.dirname(destination_path) orelse ".";
    const staging_path = try uniqueCacheTempPath(alloc, destination_parent, std.fs.path.basename(destination_path), "install");
    defer alloc.free(staging_path);
    errdefer std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};

    try copyDirectoryTree(alloc, source_path, staging_path);

    const source_integrity = try computeDirectoryHash(alloc, source_path);
    defer alloc.free(source_integrity);
    const staging_integrity = try computeDirectoryHash(alloc, staging_path);
    defer alloc.free(staging_integrity);
    if (!std.mem.eql(u8, source_integrity, staging_integrity)) return error.IntegrityMismatch;

    std.Io.Dir.cwd().renamePreserve(staging_path, std.Io.Dir.cwd(), destination_path, io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try deleteTemporaryTree(staging_path);
            return;
        },
        else => |install_err| return install_err,
    };
}

fn copyDirectoryTree(
    alloc: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) FetchGitDepError!void {
    try std.Io.Dir.cwd().createDirPath(io, destination_path);

    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var destination_dir = try std.Io.Dir.cwd().openDir(io, destination_path, .{});
    defer destination_dir.close(io);

    var walker = try std.Io.Dir.walk(source_dir, alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try destination_dir.createDirPath(io, entry.path),
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    try destination_dir.createDirPath(io, parent);
                }
                try source_dir.copyFile(entry.path, destination_dir, entry.path, io, .{ .replace = false, .make_path = true });
            },
            .sym_link => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    try destination_dir.createDirPath(io, parent);
                }
                var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_length = try source_dir.readLink(io, entry.path, &target_buffer);
                try destination_dir.symLink(io, target_buffer[0..target_length], entry.path, .{});
            },
            else => return error.UnsupportedCacheEntry,
        }
    }
}

/// Compute a SHA-256 hash over all .zap files in a directory, sorted by relative path.
/// Returns "sha256-<hex>" or an error from a complete walk/read failure.
fn computeDirectoryHash(alloc: std.mem.Allocator, dir_path: []const u8) FetchGitDepError![]const u8 {
    var temp_arena = std.heap.ArenaAllocator.init(alloc);
    defer temp_arena.deinit();
    const temp_alloc = temp_arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var zap_file_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try std.Io.Dir.walk(dir, temp_alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zap")) {
            try zap_file_paths.append(temp_alloc, try temp_alloc.dupe(u8, entry.path));
        }
    }

    std.mem.sort([]const u8, zap_file_paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (zap_file_paths.items) |relative_path| {
        updateDirectoryHash(&hasher, relative_path);
        const content = try dir.readFileAlloc(io, relative_path, temp_alloc, .limited(10 * 1024 * 1024));
        updateDirectoryHash(&hasher, content);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex_buf[index * 2] = std.fmt.digitToChar(byte >> 4, .lower);
        hex_buf[index * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
    }
    return try std.fmt.allocPrint(alloc, "sha256-{s}", .{hex_buf[0..]});
}

fn updateDirectoryHash(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_bytes, @intCast(bytes.len), .little);
    hasher.update(&length_bytes);
    hasher.update(bytes);
}

/// Description of a git dependency to fetch.
pub const GitDepRequest = struct {
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8,
    locked: ?LockEntry,
};

/// Result of a parallel fetch operation.
pub const GitDepResult = struct {
    name: []const u8,
    path: []const u8,
    commit: []const u8,
    integrity: []const u8,

    pub fn deinit(self: GitDepResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.commit);
        allocator.free(self.integrity);
    }
};

/// Fetch multiple git dependencies in parallel using Io.Group.
///
/// Uses Zig 0.16's structured concurrency via Io.Group for bounded
/// parallel git clone operations. Returns results in the same order as the
/// input requests, or propagates the first dependency infrastructure failure.
pub fn fetchGitDepsParallel(
    alloc: std.mem.Allocator,
    requests: []const GitDepRequest,
) FetchGitDepError![]GitDepResult {
    return fetchGitDepsParallelFromHome(alloc, env.getenv("HOME") orelse return error.HomeNotSet, requests);
}

fn fetchGitDepsParallelFromHome(
    alloc: std.mem.Allocator,
    home: []const u8,
    requests: []const GitDepRequest,
) FetchGitDepError![]GitDepResult {
    if (requests.len == 0) return &.{};

    const results = try alloc.alloc(GitDepResult, requests.len);
    errdefer alloc.free(results);

    // For a single dep, just fetch directly (no concurrency overhead)
    if (requests.len == 1) {
        const req = requests[0];
        const fetch_result = try fetchGitDepFromHome(alloc, home, req.name, req.url, req.ref, req.locked);
        results[0] = .{
            .name = req.name,
            .path = fetch_result.path,
            .commit = fetch_result.commit,
            .integrity = fetch_result.integrity,
        };
        return results;
    }

    const task_states = try alloc.alloc(GitDepTaskState, requests.len);
    defer alloc.free(task_states);
    for (task_states) |*task_state| {
        task_state.* = .pending;
    }

    var locked_allocator = LockedAllocator.init(alloc);
    const task_allocator = locked_allocator.allocator();

    // Parallel fetch using Io.Group (structured concurrency)
    var group: std.Io.Group = .init;
    for (requests, 0..) |req, i| {
        group.async(io, fetchGitDepTask, .{ task_allocator, home, req, &task_states[i] });
    }
    try group.await(io);

    for (task_states) |task_state| {
        switch (task_state) {
            .pending => {
                deinitSuccessfulTaskStates(alloc, task_states);
                return error.FetchTaskFailed;
            },
            .failure => |fetch_error| {
                deinitSuccessfulTaskStates(alloc, task_states);
                return fetch_error;
            },
            .success => {},
        }
    }

    for (requests, task_states, 0..) |req, task_state, index| {
        switch (task_state) {
            .pending, .failure => unreachable,
            .success => |fetch_result| {
                results[index] = .{
                    .name = req.name,
                    .path = fetch_result.path,
                    .commit = fetch_result.commit,
                    .integrity = fetch_result.integrity,
                };
            },
        }
    }

    return results;
}

const LockedAllocator = struct {
    backing_allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    fn init(backing_allocator: std.mem.Allocator) LockedAllocator {
        return .{ .backing_allocator = backing_allocator };
    }

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn lock(self: *LockedAllocator) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        self.backing_allocator.rawFree(memory, alignment, return_address);
    }
};

const GitDepTaskState = union(enum) {
    pending,
    success: GitDepCheckout,
    failure: FetchGitDepError,
};

fn deinitSuccessfulTaskStates(allocator: std.mem.Allocator, task_states: []GitDepTaskState) void {
    for (task_states) |task_state| {
        switch (task_state) {
            .success => |checkout| checkout.deinit(allocator),
            .pending, .failure => {},
        }
    }
}

fn fetchGitDepTask(
    alloc: std.mem.Allocator,
    home: []const u8,
    req: GitDepRequest,
    task_state: *GitDepTaskState,
) void {
    const fetch_result = fetchGitDepFromHome(alloc, home, req.name, req.url, req.ref, req.locked) catch |err| {
        task_state.* = .{ .failure = err };
        return;
    };
    task_state.* = .{ .success = fetch_result };
}

pub const FetchError = FetchGitDepError;

test "readLockfile: distinguishes absent lockfile from malformed lockfile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

    const absent = try readLockfile(alloc, tmp_path);
    try std.testing.expectEqual(std.meta.Tag(ReadLockfileResult).absent, std.meta.activeTag(absent));

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "zap.lock",
        .data = "missing\tfields\n",
    });
    try std.testing.expectError(error.InvalidLockfile, readLockfile(alloc, tmp_path));
}

test "readLockfile: propagates infrastructure read failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "zap.lock", .default_dir);
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

    var result = readLockfile(alloc, tmp_path) catch |err| {
        try std.testing.expect(err != error.FileNotFound);
        try std.testing.expect(err != error.InvalidLockfile);
        return;
    };
    defer result.deinit();
    try std.testing.expect(std.meta.activeTag(result) != .absent);
}

test "writeLockfile and readLockfile round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

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
    var read_result = try readLockfile(alloc, tmp_path);
    defer read_result.deinit();
    const read_entries = switch (read_result) {
        .absent => return error.TestExpectedNonNull,
        .present => |lockfile| lockfile.entries,
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
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

    // Write initial lockfile
    try writeLockfile(alloc, tmp_path, &.{
        .{ .name = "old_dep", .source_type = "path", .url = ".", .resolved_ref = "-", .commit = "-", .integrity = "-" },
    });

    // Overwrite with new deps (simulates adding a dep)
    try writeLockfile(alloc, tmp_path, &.{
        .{ .name = "old_dep", .source_type = "path", .url = ".", .resolved_ref = "-", .commit = "-", .integrity = "-" },
        .{ .name = "new_dep", .source_type = "git", .url = "url", .resolved_ref = "v2", .commit = "def456", .integrity = "sha256-y" },
    });

    var read_result = try readLockfile(alloc, tmp_path);
    defer read_result.deinit();
    const entries = switch (read_result) {
        .absent => return error.TestExpectedNonNull,
        .present => |lockfile| lockfile.entries,
    };
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("new_dep", entries[1].name);
}

test "computeDirectoryHash: produces consistent hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

    const file = try tmp_dir.dir.createFile(io, "test.zap", .{});
    try file.writeStreamingAll(io, "pub struct Test {}\n");
    file.close(io);

    const hash1 = try computeDirectoryHash(alloc, tmp_path);
    const hash2 = try computeDirectoryHash(alloc, tmp_path);

    // Same content produces same hash
    try std.testing.expectEqualStrings(hash1, hash2);
    try std.testing.expect(std.mem.startsWith(u8, hash1, "sha256-"));
}

test "dependency cache base: rejects absent HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(error.HomeNotSet, dependencyCacheBase(alloc, null));
}

test "fetchGitDep: propagates cache directory creation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "home-file", .data = "" });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const home_file = try std.fs.path.join(alloc, &.{ tmp_path, "home-file" });

    try std.testing.expectError(error.NotDir, fetchGitDepFromHome(
        alloc,
        home_file,
        "dep",
        "/not-used",
        null,
        null,
    ));
}

test "fetchGitDep: cached integrity read failure is not placeholder success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    try tmp_dir.dir.createDirPath(io, ".cache/zap/deps/dep-12345678");

    const oversized_path = try std.fs.path.join(alloc, &.{ home_path, ".cache", "zap", "deps", "dep-12345678", "oversized.zap" });
    var oversized_file = try std.Io.Dir.cwd().createFile(io, oversized_path, .{});
    defer oversized_file.close(io);
    try oversized_file.writeStreamingAll(io, "pub struct Oversized {}\n");
    var chunk: [1024]u8 = @splat('x');
    var remaining: usize = 10 * 1024 * 1024;
    while (remaining > 0) {
        const count = @min(remaining, chunk.len);
        try oversized_file.writeStreamingAll(io, chunk[0..count]);
        remaining -= count;
    }

    try std.testing.expectError(error.StreamTooLong, fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/dep.git",
        null,
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/dep.git",
            .resolved_ref = "-",
            .commit = "1234567890abcdef",
            .integrity = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    ));
}

test "fetchGitDepsParallel: propagates task fetch failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);

    if (fetchGitDepsParallelFromHome(alloc, home_path, &.{
        .{ .name = "missing-a", .url = "/definitely/not/a/git/repo/a", .ref = null, .locked = null },
        .{ .name = "missing-b", .url = "/definitely/not/a/git/repo/b", .ref = null, .locked = null },
    })) |results| {
        for (results) |result| result.deinit(alloc);
        alloc.free(results);
        return error.TestExpectedError;
    } else |_| {}
}

test "installCachedDirectory: propagates install failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "source");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "source/lib.zap", .data = "pub struct Lib {}\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "blocked-parent", .data = "" });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const source_path = try std.fs.path.join(alloc, &.{ tmp_path, "source" });
    const blocked_destination = try std.fs.path.join(alloc, &.{ tmp_path, "blocked-parent", "cache" });

    if (installCachedDirectory(alloc, source_path, blocked_destination)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "deleteTemporaryTree: propagates cleanup failures" {
    if (comptime std.posix.mode_t == u0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "temp/blocked");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "temp/blocked/lib.zap",
        .data = "pub struct Lib {}\n",
    });
    try tmp_dir.dir.setFilePermissions(io, "temp/blocked", std.Io.File.Permissions.fromMode(0o500), .{});
    defer tmp_dir.dir.setFilePermissions(io, "temp/blocked", .default_dir, .{}) catch {};

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const temp_path = try std.fs.path.join(alloc, &.{ tmp_path, "temp" });

    if (deleteTemporaryTree(temp_path)) |_| {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {},
        else => return err,
    }
}

test "deleteTemporaryTree: treats an already missing path as clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    const missing_path = try std.fs.path.join(alloc, &.{ tmp_path, "missing-temp" });

    try deleteTemporaryTree(missing_path);
}

test "fetchGitDep: successful cached integrity is never placeholder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    try tmp_dir.dir.createDirPath(io, ".cache/zap/deps/dep-12345678");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = ".cache/zap/deps/dep-12345678/lib.zap",
        .data = "pub struct Lib {}\n",
    });

    const cache_base = try dependencyCacheBase(alloc, home_path);
    const cache_dir = try cacheDirForCommit(alloc, cache_base, "dep", "1234567890abcdef");
    const integrity = try computeDirectoryHash(alloc, cache_dir);

    const checkout = try fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/dep.git",
        null,
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/dep.git",
            .resolved_ref = "-",
            .commit = "1234567890abcdef",
            .integrity = integrity,
        },
    );

    try std.testing.expect(!std.mem.eql(u8, checkout.integrity, "-"));
    try std.testing.expect(std.mem.startsWith(u8, checkout.integrity, "sha256-"));
}

test "fetchGitDep: valid locked cached checkout reuses full lock metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    try tmp_dir.dir.createDirPath(io, ".cache/zap/deps/dep-12345678");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = ".cache/zap/deps/dep-12345678/lib.zap",
        .data = "pub struct Lib {}\n",
    });

    const cache_base = try dependencyCacheBase(alloc, home_path);
    const cache_dir = try cacheDirForCommit(alloc, cache_base, "dep", "1234567890abcdef");
    const integrity = try computeDirectoryHash(alloc, cache_dir);

    const checkout = try fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/dep.git",
        "v1.0.0",
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/dep.git",
            .resolved_ref = "v1.0.0",
            .commit = "1234567890abcdef",
            .integrity = integrity,
        },
    );

    try std.testing.expectEqualStrings(cache_dir, checkout.path);
    try std.testing.expectEqualStrings("1234567890abcdef", checkout.commit);
    try std.testing.expectEqualStrings(integrity, checkout.integrity);
}

test "fetchGitDep: corrupt locked cached checkout fails integrity validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    try tmp_dir.dir.createDirPath(io, ".cache/zap/deps/dep-12345678");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = ".cache/zap/deps/dep-12345678/lib.zap",
        .data = "pub struct Lib {}\n",
    });

    const cache_base = try dependencyCacheBase(alloc, home_path);
    const cache_dir = try cacheDirForCommit(alloc, cache_base, "dep", "1234567890abcdef");
    const original_integrity = try computeDirectoryHash(alloc, cache_dir);

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = ".cache/zap/deps/dep-12345678/lib.zap",
        .data = "pub struct Corrupted {}\n",
    });

    try std.testing.expectError(error.LockfileIntegrityMismatch, fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/dep.git",
        "v1.0.0",
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/dep.git",
            .resolved_ref = "v1.0.0",
            .commit = "1234567890abcdef",
            .integrity = original_integrity,
        },
    ));
}

test "fetchGitDep: source drift rejects commit-only locked cache reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const home_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    try tmp_dir.dir.createDirPath(io, ".cache/zap/deps/dep-12345678");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = ".cache/zap/deps/dep-12345678/lib.zap",
        .data = "pub struct Lib {}\n",
    });

    const cache_base = try dependencyCacheBase(alloc, home_path);
    const cache_dir = try cacheDirForCommit(alloc, cache_base, "dep", "1234567890abcdef");
    const integrity = try computeDirectoryHash(alloc, cache_dir);

    try std.testing.expectError(error.LockfileSourceDrift, fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/new.git",
        "v1.0.0",
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/old.git",
            .resolved_ref = "v1.0.0",
            .commit = "1234567890abcdef",
            .integrity = integrity,
        },
    ));

    try std.testing.expectError(error.LockfileSourceDrift, fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/old.git",
        "v2.0.0",
        .{
            .name = "dep",
            .source_type = "git",
            .url = "https://example.invalid/old.git",
            .resolved_ref = "v1.0.0",
            .commit = "1234567890abcdef",
            .integrity = integrity,
        },
    ));

    try std.testing.expectError(error.LockfileSourceDrift, fetchGitDepFromHome(
        alloc,
        home_path,
        "dep",
        "https://example.invalid/old.git",
        "v1.0.0",
        .{
            .name = "dep",
            .source_type = "path",
            .url = "deps/dep",
            .resolved_ref = "-",
            .commit = "1234567890abcdef",
            .integrity = integrity,
        },
    ));
}
