//! Persistent manifest artifact cache snapshots.
//!
//! The manifest build path uses this module for an early artifact-cache
//! hit before re-running build.zap CTFE and source discovery. The
//! snapshot is deliberately conservative: every stored dependency must
//! still validate, or the caller treats the snapshot as a cache miss.

const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");
const glob = @import("glob.zig");

const MAGIC: u64 = 0x4e_41_4c_50_42_50_41_5a; // "ZAPBPLAN" little-endian
const VERSION: u16 = 3;

const MAX_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;
const MAX_STABLE_SNAPSHOT_READ_ATTEMPTS: usize = 3;
const MAX_FINGERPRINT_FILE_BYTES: usize = 64 * 1024 * 1024;
const MAX_TOOLCHAIN_MANIFEST_BYTES: usize = 128 * 1024 * 1024;
const MAX_TOOLCHAIN_FILE_BYTES: usize = 1024 * 1024 * 1024;

const ZIG_LIB_MANIFEST_MAGIC: u64 = 0x4d_49_4c_5a_42_50_41_5a; // "ZAPBZLIM" little-endian
const ZIG_LIB_MANIFEST_VERSION: u16 = 1;
const ZIG_LIB_IDENTITY_MAGIC: u32 = 0x5a_5a_4c_32; // "ZZL2"
const ZIG_LIB_IDENTITY_VERSION: u16 = 1;
const COMPILER_MANIFEST_MAGIC: u64 = 0x4d_49_43_5a_42_50_41_5a; // "ZAPBZCIM" little-endian
const COMPILER_MANIFEST_VERSION: u16 = 1;
const COMPILER_IDENTITY_MAGIC: u32 = 0x5a_43_43_31; // "ZCC1"
const COMPILER_IDENTITY_VERSION: u16 = 1;

pub const ArtifactKind = enum(u8) {
    bin = 1,
    lib = 2,
    obj = 3,
};

pub const BuildOpt = struct {
    key: []const u8,
    value: []const u8,
};

pub const OverrideIdentity = struct {
    optimize: ?u8 = null,
    memory: ?[]const u8 = null,
    target: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
};

pub const InvocationInputs = struct {
    build_source: []const u8,
    project_root: []const u8,
    target_name: []const u8,
    build_opts: []const BuildOpt = &.{},
    overrides: OverrideIdentity = .{},
    collect_arc_stats: bool = false,
    zap_lib_dir: ?[]const u8 = null,
    zig_lib_dir: []const u8,
    zig_lib_identity_hash: u64,
    compiler_identity_hash: u64,
    host_arch: []const u8 = @tagName(builtin.cpu.arch),
    host_os: []const u8 = @tagName(builtin.os.tag),
};

pub const FileFingerprint = struct {
    path: []const u8,
    present: bool,
    content_hash: u64,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    ctime_nanos: i128,
};

pub const DirectoryFingerprint = struct {
    path: []const u8,
    recursive: bool,
    present: bool,
    listing_hash: u64,
};

pub const EnvFingerprint = struct {
    name: []const u8,
    present: bool,
    value_hash: u64,
};

pub const GlobFingerprint = struct {
    pattern: []const u8,
    result_hash: u64,
};

pub const ToolchainIdentityStats = struct {
    files_discovered: usize = 0,
    files_hashed: usize = 0,
    manifest_hit: bool = false,
};

pub const ValidationStats = struct {
    file_stats_checked: usize = 0,
    file_stat_fast_path_hits: usize = 0,
    files_hashed: usize = 0,
};

const FileDigest = [32]u8;

const ZigLibFileRecord = struct {
    path: []const u8,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    content_digest: FileDigest,
};

const ZigLibIdentityManifest = struct {
    canonical_dir: []const u8,
    identity_hash: u64,
    files: []const ZigLibFileRecord,

    fn deinit(self: *ZigLibIdentityManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_dir);
        for (self.files) |record| allocator.free(record.path);
        allocator.free(self.files);
        self.* = .{
            .canonical_dir = "",
            .identity_hash = 0,
            .files = &.{},
        };
    }
};

const CompilerIdentityManifest = struct {
    canonical_path: []const u8,
    identity_hash: u64,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    content_digest: FileDigest,

    fn deinit(self: *CompilerIdentityManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_path);
        self.* = .{
            .canonical_path = "",
            .identity_hash = 0,
            .size = 0,
            .inode = 0,
            .mtime_nanos = 0,
            .content_digest = [_]u8{0} ** 32,
        };
    }
};

pub const Snapshot = struct {
    invocation_identity: u64,
    cache_key_hex: []const u8,
    /// Content-addressed artifact path under the Zap cache, e.g.
    /// `.zap-cache/o/<digest>/<artifact>`. This is the durable artifact;
    /// `output_path` is the installed/user-facing copy.
    cached_artifact_path: []const u8,
    output_path: []const u8,
    kind: ArtifactKind,
    target: ?[]const u8 = null,
    debug_symbols_required: bool,
    files: []const FileFingerprint = &.{},
    directories: []const DirectoryFingerprint = &.{},
    env_vars: []const EnvFingerprint = &.{},
    globs: []const GlobFingerprint = &.{},

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_key_hex);
        allocator.free(self.cached_artifact_path);
        allocator.free(self.output_path);
        if (self.target) |target| allocator.free(target);
        for (self.files) |fingerprint| allocator.free(fingerprint.path);
        allocator.free(self.files);
        for (self.directories) |fingerprint| allocator.free(fingerprint.path);
        allocator.free(self.directories);
        for (self.env_vars) |fingerprint| allocator.free(fingerprint.name);
        allocator.free(self.env_vars);
        for (self.globs) |fingerprint| allocator.free(fingerprint.pattern);
        allocator.free(self.globs);
        self.* = .{
            .invocation_identity = 0,
            .cache_key_hex = "",
            .cached_artifact_path = "",
            .output_path = "",
            .kind = .bin,
            .debug_symbols_required = false,
        };
    }
};

pub const StableSnapshot = struct {
    snapshot: Snapshot,
    mtime_nanos: i128,

    pub fn deinit(self: *StableSnapshot, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.* = .{
            .snapshot = .{
                .invocation_identity = 0,
                .cache_key_hex = "",
                .cached_artifact_path = "",
                .output_path = "",
                .kind = .bin,
                .debug_symbols_required = false,
            },
            .mtime_nanos = 0,
        };
    }
};

pub const ValidationInputs = struct {
    invocation_identity: u64,
    snapshot_mtime_nanos: i128,
    stats: ?*ValidationStats = null,
};

pub fn snapshotPath(allocator: std.mem.Allocator, cache_dir: []const u8, target_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.build-plan", .{ cache_dir, target_name });
}

pub fn artifactPath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    cache_key_hex: []const u8,
    artifact_filename: []const u8,
) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cache_dir, "o", cache_key_hex, artifact_filename });
}

pub fn zigLibIdentityHash(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    zig_lib_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !u64 {
    if (maybe_stats) |stats| stats.* = .{};

    const canonical_zig_lib_dir_z = std.Io.Dir.cwd().realPathFileAlloc(
        std.Options.debug_io,
        zig_lib_dir,
        allocator,
    ) catch return error.ZigLibUnreadable;
    defer allocator.free(canonical_zig_lib_dir_z);
    const canonical_zig_lib_dir: []const u8 = canonical_zig_lib_dir_z;

    const manifest_path = try zigLibIdentityManifestPath(allocator, cache_dir, canonical_zig_lib_dir);
    defer allocator.free(manifest_path);

    if (readZigLibIdentityManifest(allocator, manifest_path)) |manifest_value| {
        var manifest = manifest_value;
        defer manifest.deinit(allocator);
        const manifest_mtime_nanos = cwdFileMtimeNanos(manifest_path) catch return error.ZigLibUnreadable;
        if (validateZigLibIdentityManifest(
            allocator,
            canonical_zig_lib_dir,
            manifest,
            manifest_mtime_nanos,
            maybe_stats,
        ) catch return error.ZigLibUnreadable) {
            if (maybe_stats) |stats| stats.manifest_hit = true;
            return manifest.identity_hash;
        }
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidZigLibIdentityManifest => {},
        else => return err,
    }

    var rebuilt = try rebuildZigLibIdentityManifest(allocator, canonical_zig_lib_dir, maybe_stats);
    defer rebuilt.deinit(allocator);
    try writeZigLibIdentityManifestAtomic(allocator, manifest_path, rebuilt);
    return rebuilt.identity_hash;
}

pub fn compilerIdentityHash(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !u64 {
    if (maybe_stats) |stats| stats.* = .{};

    const exe_path = std.process.executablePathAlloc(std.Options.debug_io, allocator) catch
        return error.CompilerIdentityUnavailable;
    defer allocator.free(exe_path);
    const canonical_exe_path_z = std.Io.Dir.cwd().realPathFileAlloc(
        std.Options.debug_io,
        exe_path,
        allocator,
    ) catch return error.CompilerIdentityUnavailable;
    defer allocator.free(canonical_exe_path_z);
    const canonical_exe_path: []const u8 = canonical_exe_path_z;

    return compilerIdentityHashForPath(allocator, cache_dir, canonical_exe_path, maybe_stats);
}

pub fn compilerIdentityHashForPath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !u64 {
    if (maybe_stats) |stats| stats.* = .{};

    const manifest_path = try compilerIdentityManifestPath(allocator, cache_dir, canonical_exe_path);
    defer allocator.free(manifest_path);

    if (readCompilerIdentityManifest(allocator, manifest_path)) |manifest_value| {
        var manifest = manifest_value;
        defer manifest.deinit(allocator);
        const manifest_mtime_nanos = cwdFileMtimeNanos(manifest_path) catch return error.CompilerIdentityUnavailable;
        if (validateCompilerIdentityManifest(
            canonical_exe_path,
            manifest,
            manifest_mtime_nanos,
            maybe_stats,
        ) catch return error.CompilerIdentityUnavailable) {
            if (maybe_stats) |stats| stats.manifest_hit = true;
            return manifest.identity_hash;
        }
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidCompilerIdentityManifest => {},
        else => return err,
    }

    var rebuilt = try rebuildCompilerIdentityManifest(allocator, canonical_exe_path, maybe_stats);
    defer rebuilt.deinit(allocator);
    try writeCompilerIdentityManifestAtomic(allocator, manifest_path, rebuilt);
    return rebuilt.identity_hash;
}

pub fn hashInvocationIdentity(allocator: std.mem.Allocator, inputs: InvocationInputs) !u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const identity_magic: u32 = 0x5a_49_44_32; // "ZID2"
    const identity_version: u16 = 1;
    hashBytes(&hasher, std.mem.asBytes(&identity_magic));
    hashBytes(&hasher, std.mem.asBytes(&identity_version));
    hashBytes(&hasher, inputs.build_source);
    hashBytes(&hasher, inputs.project_root);
    hashBytes(&hasher, inputs.target_name);

    const sorted_opts = try allocator.dupe(BuildOpt, inputs.build_opts);
    defer allocator.free(sorted_opts);
    std.mem.sort(BuildOpt, sorted_opts, {}, struct {
        fn lessThan(_: void, left: BuildOpt, right: BuildOpt) bool {
            const key_order = std.mem.order(u8, left.key, right.key);
            if (key_order != .eq) return key_order == .lt;
            return std.mem.lessThan(u8, left.value, right.value);
        }
    }.lessThan);
    const opt_count: u64 = sorted_opts.len;
    hashBytes(&hasher, std.mem.asBytes(&opt_count));
    for (sorted_opts) |build_opt| {
        hashBytes(&hasher, build_opt.key);
        hashBytes(&hasher, build_opt.value);
    }

    hashOptionalByte(&hasher, inputs.overrides.optimize);
    hashOptionalString(&hasher, inputs.overrides.memory);
    hashOptionalString(&hasher, inputs.overrides.target);
    hashOptionalString(&hasher, inputs.overrides.cpu);
    hashBool(&hasher, inputs.collect_arc_stats);
    hashOptionalString(&hasher, inputs.zap_lib_dir);
    hashBytes(&hasher, inputs.zig_lib_dir);
    hashBytes(&hasher, std.mem.asBytes(&inputs.zig_lib_identity_hash));
    hashBytes(&hasher, inputs.host_arch);
    hashBytes(&hasher, inputs.host_os);
    hashBytes(&hasher, std.mem.asBytes(&inputs.compiler_identity_hash));

    const digest = hasher.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

pub fn fileFingerprint(allocator: std.mem.Allocator, path: []const u8) !FileFingerprint {
    while (true) {
        const stat_before = cwdFileStat(path) catch |err| switch (err) {
            error.FileNotFound => return absentFileFingerprint(allocator, path),
            else => return err,
        };
        if (stat_before.kind != .file) return error.FileStatUnavailable;

        const contents = try readFingerprintFileContents(allocator, path, null);

        const stat_after = cwdFileStat(path) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(contents);
                continue;
            },
            else => {
                allocator.free(contents);
                return err;
            },
        };
        if (!statIdentityMatches(stat_before, stat_after)) {
            allocator.free(contents);
            continue;
        }
        defer allocator.free(contents);

        return .{
            .path = try allocator.dupe(u8, path),
            .present = true,
            .content_hash = std.hash.Wyhash.hash(0, contents),
            .size = stat_after.size,
            .inode = @intCast(stat_after.inode),
            .mtime_nanos = stat_after.mtime.nanoseconds,
            .ctime_nanos = stat_after.ctime.nanoseconds,
        };
    }
}

pub fn directoryFingerprint(
    allocator: std.mem.Allocator,
    path: []const u8,
    recursive: bool,
) !DirectoryFingerprint {
    const maybe_hash = hashDirectoryListing(allocator, path, recursive) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = try allocator.dupe(u8, path),
            .recursive = recursive,
            .present = false,
            .listing_hash = 0,
        },
        else => return err,
    };
    return .{
        .path = try allocator.dupe(u8, path),
        .recursive = recursive,
        .present = true,
        .listing_hash = maybe_hash,
    };
}

pub fn envFingerprint(allocator: std.mem.Allocator, name: []const u8) !EnvFingerprint {
    if (env.getenvRuntime(name)) |value| {
        return .{
            .name = try allocator.dupe(u8, name),
            .present = true,
            .value_hash = std.hash.Wyhash.hash(0, value),
        };
    }
    return .{
        .name = try allocator.dupe(u8, name),
        .present = false,
        .value_hash = 0,
    };
}

pub fn globFingerprint(allocator: std.mem.Allocator, pattern: []const u8) !GlobFingerprint {
    const matches = try glob.collect(allocator, std.Options.debug_io, pattern, .{});
    defer glob.freeMatches(allocator, matches);
    return .{
        .pattern = try allocator.dupe(u8, pattern),
        .result_hash = hashGlobMatches(matches),
    };
}

pub fn writeSnapshotAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    snapshot: Snapshot,
) !void {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try serializeInto(allocator, &bytes, snapshot);

    try writeFileAtomic(allocator, path, bytes.items);
}

pub fn writeFileAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
) !void {
    _ = allocator;
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    }

    var atomic = try std.Io.Dir.cwd().createFileAtomic(std.Options.debug_io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic.deinit(std.Options.debug_io);
    atomic.file.writeStreamingAll(std.Options.debug_io, contents) catch |err| {
        atomic.file.close(std.Options.debug_io);
        atomic.file_open = false;
        return err;
    };
    try atomic.replace(std.Options.debug_io);
}

pub fn readStableSnapshot(allocator: std.mem.Allocator, path: []const u8) !StableSnapshot {
    var attempts: usize = 0;
    while (attempts < MAX_STABLE_SNAPSHOT_READ_ATTEMPTS) : (attempts += 1) {
        var file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{
            .allow_directory = false,
        });
        defer file.close(std.Options.debug_io);

        const stat_before = try file.stat(std.Options.debug_io);
        if (stat_before.kind != .file) return error.FileStatUnavailable;

        const bytes = try readOpenedFileAlloc(allocator, file, MAX_SNAPSHOT_BYTES);
        defer allocator.free(bytes);

        const stat_after = try file.stat(std.Options.debug_io);
        if (!statIdentityMatches(stat_before, stat_after)) continue;

        return .{
            .snapshot = try deserialize(allocator, bytes),
            .mtime_nanos = stat_after.mtime.nanoseconds,
        };
    }
    return error.UnstableSnapshot;
}

pub fn validateSnapshot(
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    inputs: ValidationInputs,
) bool {
    if (inputs.stats) |stats| stats.* = .{};

    if (snapshot.invocation_identity != inputs.invocation_identity) return false;
    if (!cachedArtifactPathMatchesKey(snapshot)) return false;

    std.Io.Dir.cwd().access(std.Options.debug_io, snapshot.cached_artifact_path, .{}) catch return false;
    if (snapshot.debug_symbols_required) {
        const debug_path = std.fmt.allocPrint(allocator, "{s}.dSYM", .{snapshot.cached_artifact_path}) catch return false;
        defer allocator.free(debug_path);
        std.Io.Dir.cwd().access(std.Options.debug_io, debug_path, .{}) catch return false;
    }

    for (snapshot.files) |expected| {
        if (!validateFileFingerprint(
            allocator,
            expected,
            inputs.snapshot_mtime_nanos,
            inputs.stats,
        )) return false;
    }
    for (snapshot.directories) |expected| {
        const current = directoryFingerprint(allocator, expected.path, expected.recursive) catch return false;
        defer allocator.free(current.path);
        if (current.present != expected.present) return false;
        if (current.listing_hash != expected.listing_hash) return false;
    }
    for (snapshot.env_vars) |expected| {
        const current = envFingerprint(allocator, expected.name) catch return false;
        defer allocator.free(current.name);
        if (current.present != expected.present) return false;
        if (current.value_hash != expected.value_hash) return false;
    }
    for (snapshot.globs) |expected| {
        const current = globFingerprint(allocator, expected.pattern) catch return false;
        defer allocator.free(current.pattern);
        if (current.result_hash != expected.result_hash) return false;
    }
    return true;
}

fn cachedArtifactPathMatchesKey(snapshot: Snapshot) bool {
    if (snapshot.cache_key_hex.len == 0) return false;
    const artifact_parent = std.fs.path.dirname(snapshot.cached_artifact_path) orelse return false;
    const key_component = std.fs.path.basename(artifact_parent);
    return std.mem.eql(u8, key_component, snapshot.cache_key_hex);
}

fn serializeInto(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayListUnmanaged(u8),
    snapshot: Snapshot,
) !void {
    try appendInt(allocator, u64, bytes, MAGIC);
    try appendInt(allocator, u16, bytes, VERSION);
    try appendInt(allocator, u64, bytes, snapshot.invocation_identity);
    try appendString(allocator, bytes, snapshot.cache_key_hex);
    try appendString(allocator, bytes, snapshot.cached_artifact_path);
    try appendString(allocator, bytes, snapshot.output_path);
    try appendInt(allocator, u8, bytes, @intFromEnum(snapshot.kind));
    try appendOptionalString(allocator, bytes, snapshot.target);
    try appendBool(allocator, bytes, snapshot.debug_symbols_required);

    try appendInt(allocator, u32, bytes, @intCast(snapshot.files.len));
    for (snapshot.files) |fingerprint| {
        try appendString(allocator, bytes, fingerprint.path);
        try appendBool(allocator, bytes, fingerprint.present);
        try appendInt(allocator, u64, bytes, fingerprint.content_hash);
        try appendInt(allocator, u64, bytes, fingerprint.size);
        try appendInt(allocator, u64, bytes, fingerprint.inode);
        try appendInt(allocator, i128, bytes, fingerprint.mtime_nanos);
        try appendInt(allocator, i128, bytes, fingerprint.ctime_nanos);
    }
    try appendInt(allocator, u32, bytes, @intCast(snapshot.directories.len));
    for (snapshot.directories) |fingerprint| {
        try appendString(allocator, bytes, fingerprint.path);
        try appendBool(allocator, bytes, fingerprint.recursive);
        try appendBool(allocator, bytes, fingerprint.present);
        try appendInt(allocator, u64, bytes, fingerprint.listing_hash);
    }
    try appendInt(allocator, u32, bytes, @intCast(snapshot.env_vars.len));
    for (snapshot.env_vars) |fingerprint| {
        try appendString(allocator, bytes, fingerprint.name);
        try appendBool(allocator, bytes, fingerprint.present);
        try appendInt(allocator, u64, bytes, fingerprint.value_hash);
    }
    try appendInt(allocator, u32, bytes, @intCast(snapshot.globs.len));
    for (snapshot.globs) |fingerprint| {
        try appendString(allocator, bytes, fingerprint.pattern);
        try appendInt(allocator, u64, bytes, fingerprint.result_hash);
    }
}

fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var reader: Reader = .{ .bytes = bytes };
    if (try reader.readInt(u64) != MAGIC) return error.InvalidSnapshot;
    if (try reader.readInt(u16) != VERSION) return error.InvalidSnapshot;

    const invocation_identity = try reader.readInt(u64);
    const cache_key_hex = try reader.readString(allocator);
    const cached_artifact_path = reader.readString(allocator) catch |err| {
        allocator.free(cache_key_hex);
        return err;
    };
    const output_path = reader.readString(allocator) catch |err| {
        allocator.free(cache_key_hex);
        allocator.free(cached_artifact_path);
        return err;
    };
    const kind_tag = reader.readInt(u8) catch |err| {
        allocator.free(cache_key_hex);
        allocator.free(cached_artifact_path);
        allocator.free(output_path);
        return err;
    };
    const kind: ArtifactKind = switch (kind_tag) {
        1 => .bin,
        2 => .lib,
        3 => .obj,
        else => {
            allocator.free(cache_key_hex);
            allocator.free(cached_artifact_path);
            allocator.free(output_path);
            return error.InvalidSnapshot;
        },
    };
    const target = reader.readOptionalString(allocator) catch |err| {
        allocator.free(cache_key_hex);
        allocator.free(cached_artifact_path);
        allocator.free(output_path);
        return err;
    };
    const debug_symbols_required = reader.readBool() catch |err| {
        allocator.free(cache_key_hex);
        allocator.free(cached_artifact_path);
        allocator.free(output_path);
        if (target) |target_path| allocator.free(target_path);
        return err;
    };

    var snapshot: Snapshot = .{
        .invocation_identity = invocation_identity,
        .cache_key_hex = cache_key_hex,
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = kind,
        .target = target,
        .debug_symbols_required = debug_symbols_required,
    };
    errdefer snapshot.deinit(allocator);

    var file_list: std.ArrayListUnmanaged(FileFingerprint) = .empty;
    errdefer {
        for (file_list.items) |fingerprint| allocator.free(fingerprint.path);
        file_list.deinit(allocator);
    }
    const file_count = try reader.readCount();
    var file_index: usize = 0;
    while (file_index < file_count) : (file_index += 1) {
        const path = try reader.readString(allocator);
        errdefer allocator.free(path);
        try file_list.append(allocator, .{
            .path = path,
            .present = try reader.readBool(),
            .content_hash = try reader.readInt(u64),
            .size = try reader.readInt(u64),
            .inode = try reader.readInt(u64),
            .mtime_nanos = try reader.readInt(i128),
            .ctime_nanos = try reader.readInt(i128),
        });
    }
    snapshot.files = try file_list.toOwnedSlice(allocator);

    var directory_list: std.ArrayListUnmanaged(DirectoryFingerprint) = .empty;
    errdefer {
        for (directory_list.items) |fingerprint| allocator.free(fingerprint.path);
        directory_list.deinit(allocator);
    }
    const directory_count = try reader.readCount();
    var directory_index: usize = 0;
    while (directory_index < directory_count) : (directory_index += 1) {
        const path = try reader.readString(allocator);
        errdefer allocator.free(path);
        try directory_list.append(allocator, .{
            .path = path,
            .recursive = try reader.readBool(),
            .present = try reader.readBool(),
            .listing_hash = try reader.readInt(u64),
        });
    }
    snapshot.directories = try directory_list.toOwnedSlice(allocator);

    var env_list: std.ArrayListUnmanaged(EnvFingerprint) = .empty;
    errdefer {
        for (env_list.items) |fingerprint| allocator.free(fingerprint.name);
        env_list.deinit(allocator);
    }
    const env_count = try reader.readCount();
    var env_index: usize = 0;
    while (env_index < env_count) : (env_index += 1) {
        const name = try reader.readString(allocator);
        errdefer allocator.free(name);
        try env_list.append(allocator, .{
            .name = name,
            .present = try reader.readBool(),
            .value_hash = try reader.readInt(u64),
        });
    }
    snapshot.env_vars = try env_list.toOwnedSlice(allocator);

    var glob_list: std.ArrayListUnmanaged(GlobFingerprint) = .empty;
    errdefer {
        for (glob_list.items) |fingerprint| allocator.free(fingerprint.pattern);
        glob_list.deinit(allocator);
    }
    const glob_count = try reader.readCount();
    var glob_index: usize = 0;
    while (glob_index < glob_count) : (glob_index += 1) {
        const pattern = try reader.readString(allocator);
        errdefer allocator.free(pattern);
        try glob_list.append(allocator, .{
            .pattern = pattern,
            .result_hash = try reader.readInt(u64),
        });
    }
    snapshot.globs = try glob_list.toOwnedSlice(allocator);

    if (reader.pos != bytes.len) return error.InvalidSnapshot;
    return snapshot;
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readInt(self: *Reader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.pos > self.bytes.len or size > self.bytes.len - self.pos) return error.InvalidSnapshot;
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..size], .little);
        self.pos += size;
        return value;
    }

    fn readBool(self: *Reader) !bool {
        return switch (try self.readInt(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidSnapshot,
        };
    }

    fn readCount(self: *Reader) !usize {
        return @intCast(try self.readInt(u32));
    }

    fn readString(self: *Reader, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.readCount();
        if (self.pos > self.bytes.len or len > self.bytes.len - self.pos) return error.InvalidSnapshot;
        const out = try allocator.dupe(u8, self.bytes[self.pos..][0..len]);
        self.pos += len;
        return out;
    }

    fn readOptionalString(self: *Reader, allocator: std.mem.Allocator) !?[]const u8 {
        return if (try self.readBool()) try self.readString(allocator) else null;
    }

    fn readFixed(self: *Reader, comptime T: type) !T {
        const len = @sizeOf(T);
        if (self.pos > self.bytes.len or len > self.bytes.len - self.pos) return error.InvalidSnapshot;
        var out: T = undefined;
        @memcpy(std.mem.asBytes(&out), self.bytes[self.pos..][0..len]);
        self.pos += len;
        return out;
    }
};

fn appendInt(allocator: std.mem.Allocator, comptime T: type, bytes: *std.ArrayListUnmanaged(u8), value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try bytes.appendSlice(allocator, &buf);
}

fn appendBool(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: bool) !void {
    try bytes.append(allocator, if (value) 1 else 0);
}

fn appendString(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try appendInt(allocator, u32, bytes, @intCast(value.len));
    try bytes.appendSlice(allocator, value);
}

fn appendOptionalString(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: ?[]const u8) !void {
    try appendBool(allocator, bytes, value != null);
    if (value) |some| try appendString(allocator, bytes, some);
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    const len: u64 = bytes.len;
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn hashBool(hasher: *std.crypto.hash.sha2.Sha256, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(&.{byte});
}

fn hashOptionalByte(hasher: *std.crypto.hash.sha2.Sha256, value: ?u8) void {
    hashBool(hasher, value != null);
    if (value) |some| hasher.update(&.{some});
}

fn hashOptionalString(hasher: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    hashBool(hasher, value != null);
    if (value) |some| hashBytes(hasher, some);
}

fn zigLibIdentityManifestPath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    canonical_zig_lib_dir: []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashBytes(&hasher, canonical_zig_lib_dir);
    const digest = hasher.finalResult();
    const path_key = std.mem.readInt(u64, digest[0..8], .little);
    return std.fmt.allocPrint(
        allocator,
        "{s}/zig-lib-{x:0>16}.identity",
        .{ cache_dir, path_key },
    );
}

fn readZigLibIdentityManifest(allocator: std.mem.Allocator, path: []const u8) !ZigLibIdentityManifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(MAX_TOOLCHAIN_MANIFEST_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(bytes);
    return deserializeZigLibIdentityManifest(allocator, bytes);
}

fn deserializeZigLibIdentityManifest(allocator: std.mem.Allocator, bytes: []const u8) !ZigLibIdentityManifest {
    var reader: Reader = .{ .bytes = bytes };
    const magic = reader.readInt(u64) catch return error.InvalidZigLibIdentityManifest;
    if (magic != ZIG_LIB_MANIFEST_MAGIC) return error.InvalidZigLibIdentityManifest;
    const version = reader.readInt(u16) catch return error.InvalidZigLibIdentityManifest;
    if (version != ZIG_LIB_MANIFEST_VERSION) return error.InvalidZigLibIdentityManifest;

    const canonical_dir = reader.readString(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidZigLibIdentityManifest,
    };
    errdefer allocator.free(canonical_dir);
    const identity_hash = reader.readInt(u64) catch return error.InvalidZigLibIdentityManifest;

    const files = parseZigLibFileRecords(allocator, &reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidZigLibIdentityManifest,
    };
    errdefer freeZigLibRecords(allocator, files);

    if (reader.pos != bytes.len) return error.InvalidZigLibIdentityManifest;
    if (!recordsAreStrictlySorted(files)) return error.InvalidZigLibIdentityManifest;
    const recomputed_identity = computeZigLibAggregateIdentityHash(canonical_dir, files);
    if (recomputed_identity != identity_hash) return error.InvalidZigLibIdentityManifest;

    return .{
        .canonical_dir = canonical_dir,
        .identity_hash = identity_hash,
        .files = files,
    };
}

fn parseZigLibFileRecords(
    allocator: std.mem.Allocator,
    reader: *Reader,
) ![]const ZigLibFileRecord {
    var records: std.ArrayListUnmanaged(ZigLibFileRecord) = .empty;
    errdefer {
        for (records.items) |record| allocator.free(record.path);
        records.deinit(allocator);
    }

    const record_count = try reader.readCount();
    var index: usize = 0;
    while (index < record_count) : (index += 1) {
        const path = try reader.readString(allocator);
        errdefer allocator.free(path);
        try records.append(allocator, .{
            .path = path,
            .size = try reader.readInt(u64),
            .inode = try reader.readInt(u64),
            .mtime_nanos = try reader.readInt(i128),
            .content_digest = try reader.readFixed(FileDigest),
        });
    }
    return try records.toOwnedSlice(allocator);
}

fn writeZigLibIdentityManifestAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: ZigLibIdentityManifest,
) !void {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, ZIG_LIB_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, ZIG_LIB_MANIFEST_VERSION);
    try appendString(allocator, &bytes, manifest.canonical_dir);
    try appendInt(allocator, u64, &bytes, manifest.identity_hash);
    try appendInt(allocator, u32, &bytes, @intCast(manifest.files.len));
    for (manifest.files) |record| {
        try appendString(allocator, &bytes, record.path);
        try appendInt(allocator, u64, &bytes, record.size);
        try appendInt(allocator, u64, &bytes, record.inode);
        try appendInt(allocator, i128, &bytes, record.mtime_nanos);
        try bytes.appendSlice(allocator, &record.content_digest);
    }

    try writeFileAtomic(allocator, path, bytes.items);
}

fn compilerIdentityManifestPath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    canonical_exe_path: []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashBytes(&hasher, canonical_exe_path);
    const digest = hasher.finalResult();
    const path_key = std.mem.readInt(u64, digest[0..8], .little);
    return std.fmt.allocPrint(
        allocator,
        "{s}/compiler-{x:0>16}.identity",
        .{ cache_dir, path_key },
    );
}

fn readCompilerIdentityManifest(allocator: std.mem.Allocator, path: []const u8) !CompilerIdentityManifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(MAX_TOOLCHAIN_MANIFEST_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(bytes);
    return deserializeCompilerIdentityManifest(allocator, bytes);
}

fn deserializeCompilerIdentityManifest(allocator: std.mem.Allocator, bytes: []const u8) !CompilerIdentityManifest {
    var reader: Reader = .{ .bytes = bytes };
    const magic = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    if (magic != COMPILER_MANIFEST_MAGIC) return error.InvalidCompilerIdentityManifest;
    const version = reader.readInt(u16) catch return error.InvalidCompilerIdentityManifest;
    if (version != COMPILER_MANIFEST_VERSION) return error.InvalidCompilerIdentityManifest;

    const canonical_path = reader.readString(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCompilerIdentityManifest,
    };
    errdefer allocator.free(canonical_path);
    const identity_hash = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    const size = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    const inode = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    const mtime_nanos = reader.readInt(i128) catch return error.InvalidCompilerIdentityManifest;
    const content_digest = reader.readFixed(FileDigest) catch return error.InvalidCompilerIdentityManifest;
    if (reader.pos != bytes.len) return error.InvalidCompilerIdentityManifest;

    const recomputed_identity = computeCompilerAggregateIdentityHash(canonical_path, content_digest);
    if (recomputed_identity != identity_hash) return error.InvalidCompilerIdentityManifest;

    return .{
        .canonical_path = canonical_path,
        .identity_hash = identity_hash,
        .size = size,
        .inode = inode,
        .mtime_nanos = mtime_nanos,
        .content_digest = content_digest,
    };
}

fn writeCompilerIdentityManifestAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: CompilerIdentityManifest,
) !void {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, COMPILER_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, COMPILER_MANIFEST_VERSION);
    try appendString(allocator, &bytes, manifest.canonical_path);
    try appendInt(allocator, u64, &bytes, manifest.identity_hash);
    try appendInt(allocator, u64, &bytes, manifest.size);
    try appendInt(allocator, u64, &bytes, manifest.inode);
    try appendInt(allocator, i128, &bytes, manifest.mtime_nanos);
    try bytes.appendSlice(allocator, &manifest.content_digest);

    try writeFileAtomic(allocator, path, bytes.items);
}

fn validateZigLibIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    manifest: ZigLibIdentityManifest,
    manifest_mtime_nanos: i128,
    maybe_stats: ?*ToolchainIdentityStats,
) !bool {
    if (!std.mem.eql(u8, canonical_zig_lib_dir, manifest.canonical_dir)) return false;

    const current = try collectZigLibRecords(allocator, canonical_zig_lib_dir, false, maybe_stats);
    defer freeZigLibRecords(allocator, current);

    if (current.len != manifest.files.len) return false;
    for (manifest.files, current) |stored, live| {
        if (!std.mem.eql(u8, stored.path, live.path)) return false;
        if (stored.size != live.size) return false;
        if (stored.inode != live.inode) return false;
        if (stored.mtime_nanos != live.mtime_nanos) return false;
        if (live.mtime_nanos >= manifest_mtime_nanos) return false;
    }
    return true;
}

fn validateCompilerIdentityManifest(
    canonical_exe_path: []const u8,
    manifest: CompilerIdentityManifest,
    manifest_mtime_nanos: i128,
    maybe_stats: ?*ToolchainIdentityStats,
) !bool {
    if (!std.mem.eql(u8, canonical_exe_path, manifest.canonical_path)) return false;

    const stat = cwdFileStat(canonical_exe_path) catch return error.CompilerIdentityUnavailable;
    if (maybe_stats) |stats| stats.files_discovered += 1;
    if (stat.kind != .file) return false;
    if (manifest.size != stat.size) return false;
    if (manifest.inode != @as(u64, @intCast(stat.inode))) return false;
    if (manifest.mtime_nanos != stat.mtime.nanoseconds) return false;
    if (stat.mtime.nanoseconds >= manifest_mtime_nanos) return false;
    return true;
}

fn rebuildZigLibIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !ZigLibIdentityManifest {
    const canonical_dir = try allocator.dupe(u8, canonical_zig_lib_dir);
    errdefer allocator.free(canonical_dir);

    const records = try collectZigLibRecords(allocator, canonical_zig_lib_dir, true, maybe_stats);
    errdefer freeZigLibRecords(allocator, records);

    return .{
        .canonical_dir = canonical_dir,
        .identity_hash = computeZigLibAggregateIdentityHash(canonical_dir, records),
        .files = records,
    };
}

fn rebuildCompilerIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !CompilerIdentityManifest {
    const canonical_path = try allocator.dupe(u8, canonical_exe_path);
    errdefer allocator.free(canonical_path);

    const stat = cwdFileStat(canonical_exe_path) catch return error.CompilerIdentityUnavailable;
    if (stat.kind != .file) return error.CompilerIdentityUnavailable;
    if (maybe_stats) |stats| stats.files_discovered += 1;
    const content_digest = try hashCompilerFileContents(allocator, canonical_exe_path, maybe_stats);

    return .{
        .canonical_path = canonical_path,
        .identity_hash = computeCompilerAggregateIdentityHash(canonical_path, content_digest),
        .size = stat.size,
        .inode = @intCast(stat.inode),
        .mtime_nanos = stat.mtime.nanoseconds,
        .content_digest = content_digest,
    };
}

fn collectZigLibRecords(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    comptime hash_contents: bool,
    maybe_stats: ?*ToolchainIdentityStats,
) ![]ZigLibFileRecord {
    var dir = std.Io.Dir.cwd().openDir(
        std.Options.debug_io,
        canonical_zig_lib_dir,
        .{ .iterate = true },
    ) catch return error.ZigLibUnreadable;
    defer dir.close(std.Options.debug_io);

    var records: std.ArrayListUnmanaged(ZigLibFileRecord) = .empty;
    errdefer {
        for (records.items) |record| allocator.free(record.path);
        records.deinit(allocator);
    }

    var walker = std.Io.Dir.walk(dir, allocator) catch return error.ZigLibUnreadable;
    defer walker.deinit();
    while (walker.next(std.Options.debug_io) catch return error.ZigLibUnreadable) |entry| {
        if (entry.kind != .file) continue;
        const stat = zigLibFileStat(dir, entry.path) catch return error.ZigLibUnreadable;
        if (stat.kind != .file) continue;
        const digest: FileDigest = if (hash_contents)
            try hashZigLibFileContents(allocator, dir, entry.path, maybe_stats)
        else
            [_]u8{0} ** 32;
        if (maybe_stats) |stats| stats.files_discovered += 1;
        try records.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .size = stat.size,
            .inode = @intCast(stat.inode),
            .mtime_nanos = stat.mtime.nanoseconds,
            .content_digest = digest,
        });
    }

    std.mem.sort(ZigLibFileRecord, records.items, {}, struct {
        fn lessThan(_: void, left: ZigLibFileRecord, right: ZigLibFileRecord) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);
    return try records.toOwnedSlice(allocator);
}

fn zigLibFileStat(dir: std.Io.Dir, relative_path: []const u8) !std.Io.File.Stat {
    var file = dir.openFile(std.Options.debug_io, relative_path, .{
        .allow_directory = false,
        .path_only = true,
    }) catch return error.ZigLibUnreadable;
    defer file.close(std.Options.debug_io);
    return file.stat(std.Options.debug_io) catch return error.ZigLibUnreadable;
}

fn cwdFileStat(path: []const u8) !std.Io.File.Stat {
    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{
        .allow_directory = false,
        .path_only = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.FileStatUnavailable,
    };
    defer file.close(std.Options.debug_io);
    return file.stat(std.Options.debug_io) catch return error.FileStatUnavailable;
}

fn readOpenedFileAlloc(allocator: std.mem.Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    var reader = file.reader(std.Options.debug_io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |read_err| return read_err,
    };
}

fn cwdFileMtimeNanos(path: []const u8) !i128 {
    const stat = try cwdFileStat(path);
    return stat.mtime.nanoseconds;
}

fn absentFileFingerprint(allocator: std.mem.Allocator, path: []const u8) !FileFingerprint {
    return .{
        .path = try allocator.dupe(u8, path),
        .present = false,
        .content_hash = 0,
        .size = 0,
        .inode = 0,
        .mtime_nanos = 0,
        .ctime_nanos = 0,
    };
}

fn readFingerprintFileContents(
    allocator: std.mem.Allocator,
    path: []const u8,
    maybe_stats: ?*ValidationStats,
) ![]u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(MAX_FINGERPRINT_FILE_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if (maybe_stats) |stats| stats.files_hashed += 1;
    return contents;
}

fn statIdentityMatches(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == right.kind and
        left.size == right.size and
        left.inode == right.inode and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn fingerprintStatIdentityMatches(fingerprint: FileFingerprint, stat: std.Io.File.Stat) bool {
    return stat.kind == .file and
        fingerprint.size == stat.size and
        fingerprint.inode == @as(u64, @intCast(stat.inode)) and
        fingerprint.mtime_nanos == stat.mtime.nanoseconds and
        fingerprint.ctime_nanos == stat.ctime.nanoseconds;
}

fn statIdentityIsOlderThanSnapshot(stat: std.Io.File.Stat, snapshot_mtime_nanos: i128) bool {
    return stat.mtime.nanoseconds < snapshot_mtime_nanos and
        stat.ctime.nanoseconds < snapshot_mtime_nanos;
}

fn validateFileFingerprint(
    allocator: std.mem.Allocator,
    expected: FileFingerprint,
    snapshot_mtime_nanos: i128,
    maybe_stats: ?*ValidationStats,
) bool {
    const stat = cwdFileStat(expected.path) catch |err| switch (err) {
        error.FileNotFound => return !expected.present,
        else => return false,
    };
    if (maybe_stats) |stats| stats.file_stats_checked += 1;
    if (!expected.present) return false;
    if (stat.kind != .file) return false;

    if (fingerprintStatIdentityMatches(expected, stat) and
        statIdentityIsOlderThanSnapshot(stat, snapshot_mtime_nanos))
    {
        if (maybe_stats) |stats| stats.file_stat_fast_path_hits += 1;
        return true;
    }

    const contents = readFingerprintFileContents(allocator, expected.path, maybe_stats) catch return false;
    defer allocator.free(contents);
    return std.hash.Wyhash.hash(0, contents) == expected.content_hash;
}

fn hashZigLibFileContents(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    relative_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !FileDigest {
    const contents = dir.readFileAlloc(
        std.Options.debug_io,
        relative_path,
        allocator,
        .limited(MAX_TOOLCHAIN_FILE_BYTES),
    ) catch return error.ZigLibUnreadable;
    defer allocator.free(contents);
    if (maybe_stats) |stats| stats.files_hashed += 1;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(contents);
    return hasher.finalResult();
}

fn hashCompilerFileContents(
    allocator: std.mem.Allocator,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) !FileDigest {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        canonical_exe_path,
        allocator,
        .limited(MAX_TOOLCHAIN_FILE_BYTES),
    ) catch return error.CompilerIdentityUnavailable;
    defer allocator.free(contents);
    if (maybe_stats) |stats| stats.files_hashed += 1;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(contents);
    return hasher.finalResult();
}

fn computeZigLibAggregateIdentityHash(canonical_dir: []const u8, records: []const ZigLibFileRecord) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const magic = ZIG_LIB_IDENTITY_MAGIC;
    const version = ZIG_LIB_IDENTITY_VERSION;
    hashBytes(&hasher, std.mem.asBytes(&magic));
    hashBytes(&hasher, std.mem.asBytes(&version));
    hashBytes(&hasher, canonical_dir);
    const file_count: u64 = records.len;
    hashBytes(&hasher, std.mem.asBytes(&file_count));
    for (records) |record| {
        hashBytes(&hasher, record.path);
        hashBytes(&hasher, &record.content_digest);
    }
    const digest = hasher.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn computeCompilerAggregateIdentityHash(canonical_path: []const u8, content_digest: FileDigest) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const magic = COMPILER_IDENTITY_MAGIC;
    const version = COMPILER_IDENTITY_VERSION;
    hashBytes(&hasher, std.mem.asBytes(&magic));
    hashBytes(&hasher, std.mem.asBytes(&version));
    hashBytes(&hasher, canonical_path);
    hashBytes(&hasher, &content_digest);
    const digest = hasher.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn freeZigLibRecords(allocator: std.mem.Allocator, records: []const ZigLibFileRecord) void {
    for (records) |record| allocator.free(record.path);
    allocator.free(records);
}

fn recordsAreStrictlySorted(records: []const ZigLibFileRecord) bool {
    if (records.len == 0) return true;
    var index: usize = 1;
    while (index < records.len) : (index += 1) {
        if (!std.mem.lessThan(u8, records[index - 1].path, records[index].path)) return false;
    }
    return true;
}

const DirectoryEntryFingerprint = struct {
    path: []const u8,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    ctime_nanos: i128,
};

fn hashDirectoryListing(allocator: std.mem.Allocator, path: []const u8, recursive: bool) !u64 {
    var dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var entries: std.ArrayListUnmanaged(DirectoryEntryFingerprint) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    if (recursive) {
        var walker = try std.Io.Dir.walk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.Options.debug_io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zap")) continue;
            const stat = try directoryEntryStat(dir, entry.path);
            if (stat.kind != .file) continue;
            try entries.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .size = stat.size,
                .inode = @intCast(stat.inode),
                .mtime_nanos = stat.mtime.nanoseconds,
                .ctime_nanos = stat.ctime.nanoseconds,
            });
        }
    } else {
        var iterator = dir.iterate();
        while (try iterator.next(std.Options.debug_io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
            const stat = try directoryEntryStat(dir, entry.name);
            if (stat.kind != .file) continue;
            try entries.append(allocator, .{
                .path = try allocator.dupe(u8, entry.name),
                .size = stat.size,
                .inode = @intCast(stat.inode),
                .mtime_nanos = stat.mtime.nanoseconds,
                .ctime_nanos = stat.ctime.nanoseconds,
            });
        }
    }

    std.mem.sort(DirectoryEntryFingerprint, entries.items, {}, struct {
        fn lessThan(_: void, left: DirectoryEntryFingerprint, right: DirectoryEntryFingerprint) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);

    var hasher = std.hash.Wyhash.init(0);
    const count: u64 = entries.items.len;
    hasher.update(std.mem.asBytes(&count));
    for (entries.items) |entry| {
        const len: u64 = entry.path.len;
        hasher.update(std.mem.asBytes(&len));
        hasher.update(entry.path);
        hasher.update(std.mem.asBytes(&entry.size));
        hasher.update(std.mem.asBytes(&entry.inode));
        hasher.update(std.mem.asBytes(&entry.mtime_nanos));
        hasher.update(std.mem.asBytes(&entry.ctime_nanos));
    }
    return hasher.final();
}

fn directoryEntryStat(dir: std.Io.Dir, relative_path: []const u8) !std.Io.File.Stat {
    var file = try dir.openFile(std.Options.debug_io, relative_path, .{
        .allow_directory = false,
        .path_only = true,
    });
    defer file.close(std.Options.debug_io);
    return try file.stat(std.Options.debug_io);
}

fn hashGlobMatches(matches: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (matches) |matched_path| {
        const path_len: u64 = @intCast(matched_path.len);
        hasher.update(std.mem.asBytes(&path_len));
        hasher.update(matched_path);
    }
    return hasher.final();
}

fn serializeZigLibIdentityManifestForTest(
    allocator: std.mem.Allocator,
    canonical_dir: []const u8,
    identity_hash: u64,
    records: []const ZigLibFileRecord,
) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, ZIG_LIB_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, ZIG_LIB_MANIFEST_VERSION);
    try appendString(allocator, &bytes, canonical_dir);
    try appendInt(allocator, u64, &bytes, identity_hash);
    try appendInt(allocator, u32, &bytes, @intCast(records.len));
    for (records) |record| {
        try appendString(allocator, &bytes, record.path);
        try appendInt(allocator, u64, &bytes, record.size);
        try appendInt(allocator, u64, &bytes, record.inode);
        try appendInt(allocator, i128, &bytes, record.mtime_nanos);
        try bytes.appendSlice(allocator, &record.content_digest);
    }
    return try bytes.toOwnedSlice(allocator);
}

fn serializeCompilerIdentityManifestForTest(
    allocator: std.mem.Allocator,
    canonical_path: []const u8,
    identity_hash: u64,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    content_digest: FileDigest,
) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, COMPILER_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, COMPILER_MANIFEST_VERSION);
    try appendString(allocator, &bytes, canonical_path);
    try appendInt(allocator, u64, &bytes, identity_hash);
    try appendInt(allocator, u64, &bytes, size);
    try appendInt(allocator, u64, &bytes, inode);
    try appendInt(allocator, i128, &bytes, mtime_nanos);
    try bytes.appendSlice(allocator, &content_digest);
    return try bytes.toOwnedSlice(allocator);
}

test "manifest invocation identity sorts build opts deterministically" {
    const allocator = std.testing.allocator;
    const left_opts = [_]BuildOpt{
        .{ .key = "beta", .value = "2" },
        .{ .key = "alpha", .value = "1" },
    };
    const right_opts = [_]BuildOpt{
        .{ .key = "alpha", .value = "1" },
        .{ .key = "beta", .value = "2" },
    };
    const base: InvocationInputs = .{
        .build_source = "pub struct App.Builder {}",
        .project_root = "/tmp/project",
        .target_name = "test",
        .build_opts = &left_opts,
        .zig_lib_dir = "/tmp/zig/lib",
        .zig_lib_identity_hash = 456,
        .compiler_identity_hash = 123,
    };
    var other = base;
    other.build_opts = &right_opts;
    try std.testing.expectEqual(
        try hashInvocationIdentity(allocator, base),
        try hashInvocationIdentity(allocator, other),
    );
}

test "manifest invocation identity includes required build controls and tool identities" {
    const allocator = std.testing.allocator;
    const base: InvocationInputs = .{
        .build_source = "pub struct App.Builder {}",
        .project_root = "/tmp/project",
        .target_name = "test",
        .overrides = .{
            .memory = "Memory.ARC",
            .target = "aarch64-macos-none",
        },
        .collect_arc_stats = false,
        .zap_lib_dir = "/tmp/zap/lib",
        .zig_lib_dir = "/tmp/zig/lib",
        .zig_lib_identity_hash = 1,
        .compiler_identity_hash = 2,
    };
    const base_hash = try hashInvocationIdentity(allocator, base);

    var changed_compiler = base;
    changed_compiler.compiler_identity_hash = 3;
    try std.testing.expect(base_hash != try hashInvocationIdentity(allocator, changed_compiler));

    var changed_zig_lib = base;
    changed_zig_lib.zig_lib_identity_hash = 4;
    try std.testing.expect(base_hash != try hashInvocationIdentity(allocator, changed_zig_lib));

    var changed_zap_lib = base;
    changed_zap_lib.zap_lib_dir = "/tmp/other-zap/lib";
    try std.testing.expect(base_hash != try hashInvocationIdentity(allocator, changed_zap_lib));

    var changed_overrides = base;
    changed_overrides.overrides.memory = "Memory.Tracking";
    try std.testing.expect(base_hash != try hashInvocationIdentity(allocator, changed_overrides));

    var changed_arc_stats = base;
    changed_arc_stats.collect_arc_stats = true;
    try std.testing.expect(base_hash != try hashInvocationIdentity(allocator, changed_arc_stats));
}

test "snapshot serialization round trip preserves fields" {
    const allocator = std.testing.allocator;
    const files = [_]FileFingerprint{.{
        .path = "lib/app.zap",
        .present = true,
        .content_hash = 11,
        .size = 12,
        .inode = 13,
        .mtime_nanos = 14,
        .ctime_nanos = 15,
    }};
    const directories = [_]DirectoryFingerprint{.{ .path = "lib", .recursive = true, .present = true, .listing_hash = 22 }};
    const env_vars = [_]EnvFingerprint{.{ .name = "PATH", .present = true, .value_hash = 33 }};
    const globs = [_]GlobFingerprint{.{ .pattern = "lib/**/*.zap", .result_hash = 44 }};
    const snapshot: Snapshot = .{
        .invocation_identity = 99,
        .cache_key_hex = "abcd",
        .cached_artifact_path = ".zap-cache/o/abcd/app",
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .target = "aarch64-macos-none",
        .debug_symbols_required = true,
        .files = &files,
        .directories = &directories,
        .env_vars = &env_vars,
        .globs = &globs,
    };

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try serializeInto(allocator, &bytes, snapshot);
    var restored = try deserialize(allocator, bytes.items);
    defer restored.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 99), restored.invocation_identity);
    try std.testing.expectEqualStrings("abcd", restored.cache_key_hex);
    try std.testing.expectEqualStrings(".zap-cache/o/abcd/app", restored.cached_artifact_path);
    try std.testing.expectEqualStrings("zap-out/bin/app", restored.output_path);
    try std.testing.expectEqual(ArtifactKind.bin, restored.kind);
    try std.testing.expectEqualStrings("aarch64-macos-none", restored.target.?);
    try std.testing.expect(restored.debug_symbols_required);
    try std.testing.expectEqual(@as(usize, 1), restored.files.len);
    try std.testing.expectEqualStrings("lib/app.zap", restored.files[0].path);
    try std.testing.expectEqual(@as(u64, 11), restored.files[0].content_hash);
    try std.testing.expectEqual(@as(u64, 12), restored.files[0].size);
    try std.testing.expectEqual(@as(u64, 13), restored.files[0].inode);
    try std.testing.expectEqual(@as(i128, 14), restored.files[0].mtime_nanos);
    try std.testing.expectEqual(@as(i128, 15), restored.files[0].ctime_nanos);
    try std.testing.expectEqual(@as(usize, 1), restored.directories.len);
    try std.testing.expectEqual(@as(usize, 1), restored.env_vars.len);
    try std.testing.expectEqual(@as(usize, 1), restored.globs.len);
}

test "artifact path is content addressed under cache object directory" {
    const allocator = std.testing.allocator;
    const digest_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const path = try artifactPath(allocator, ".zap-cache", digest_hex, "zap_test");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(".zap-cache/o/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/zap_test", path);
}

test "stable snapshot read returns parsed snapshot and file mtime" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);

    const snapshot: Snapshot = .{
        .invocation_identity = 99,
        .cache_key_hex = "abcd",
        .cached_artifact_path = ".zap-cache/o/abcd/app",
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .target = "aarch64-macos-none",
        .debug_symbols_required = true,
    };
    try writeSnapshotAtomic(allocator, snapshot_path, snapshot);

    var stable_snapshot = try readStableSnapshot(allocator, snapshot_path);
    defer stable_snapshot.deinit(allocator);
    const snapshot_stat = try cwdFileStat(snapshot_path);

    try std.testing.expectEqual(snapshot_stat.mtime.nanoseconds, stable_snapshot.mtime_nanos);
    try std.testing.expectEqual(@as(u64, 99), stable_snapshot.snapshot.invocation_identity);
    try std.testing.expectEqualStrings("abcd", stable_snapshot.snapshot.cache_key_hex);
    try std.testing.expectEqualStrings(".zap-cache/o/abcd/app", stable_snapshot.snapshot.cached_artifact_path);
    try std.testing.expectEqualStrings("zap-out/bin/app", stable_snapshot.snapshot.output_path);
    try std.testing.expectEqual(ArtifactKind.bin, stable_snapshot.snapshot.kind);
    try std.testing.expectEqualStrings("aarch64-macos-none", stable_snapshot.snapshot.target.?);
    try std.testing.expect(stable_snapshot.snapshot.debug_symbols_required);
}

test "stable snapshot read rejects invalid snapshot bytes" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);

    try writeFileAtomic(allocator, snapshot_path, "not a valid snapshot");
    try std.testing.expectError(error.InvalidSnapshot, readStableSnapshot(allocator, snapshot_path));
}

test "snapshot deserialization frees owned strings on malformed data" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, MAGIC);
    try appendInt(allocator, u16, &bytes, VERSION);
    try appendInt(allocator, u64, &bytes, 1);
    try appendString(allocator, &bytes, "cache-key");
    try appendString(allocator, &bytes, ".zap-cache/o/cache-key/app");
    try appendString(allocator, &bytes, "zap-out/bin/app");
    try appendInt(allocator, u8, &bytes, 99);

    try std.testing.expectError(error.InvalidSnapshot, deserialize(allocator, bytes.items));
}

test "atomic writes replace final file without fixed temp artifact" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "cache/target.hash" });
    defer allocator.free(path);
    const fixed_tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(fixed_tmp_path);

    try writeFileAtomic(allocator, path, "first");
    try writeFileAtomic(allocator, path, "second");

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("second", contents);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.Options.debug_io, fixed_tmp_path, .{}));
}

test "snapshot validation trusts unchanged file stat identity without hashing" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "zap-out/bin") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "app.zap" });
    defer allocator.free(file_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);

    const file_fp = try fileFingerprint(allocator, file_path);
    defer allocator.free(file_fp.path);
    var files = [_]FileFingerprint{file_fp};
    const snapshot: Snapshot = .{
        .invocation_identity = 1,
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
    };
    var stats: ValidationStats = .{};
    const inputs: ValidationInputs = .{
        .invocation_identity = 1,
        .snapshot_mtime_nanos = std.math.maxInt(i128),
        .stats = &stats,
    };

    try std.testing.expect(validateSnapshot(allocator, snapshot, inputs));
    try std.testing.expectEqual(@as(usize, 1), stats.file_stats_checked);
    try std.testing.expectEqual(@as(usize, 1), stats.file_stat_fast_path_hits);
    try std.testing.expectEqual(@as(usize, 0), stats.files_hashed);
}

test "snapshot validation falls back to content hash on file stat mismatch" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "zap-out/bin") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "app.zap" });
    defer allocator.free(file_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);

    var file_fp = try fileFingerprint(allocator, file_path);
    defer allocator.free(file_fp.path);
    file_fp.size += 1;
    var files = [_]FileFingerprint{file_fp};
    const snapshot: Snapshot = .{
        .invocation_identity = 1,
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
    };
    var stats: ValidationStats = .{};
    const inputs: ValidationInputs = .{
        .invocation_identity = 1,
        .snapshot_mtime_nanos = std.math.maxInt(i128),
        .stats = &stats,
    };

    try std.testing.expect(validateSnapshot(allocator, snapshot, inputs));
    try std.testing.expectEqual(@as(usize, 1), stats.file_stats_checked);
    try std.testing.expectEqual(@as(usize, 0), stats.file_stat_fast_path_hits);
    try std.testing.expectEqual(@as(usize, 1), stats.files_hashed);
}

test "Zig lib identity manifest reuses file hashes on unchanged second call" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-lib/std") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-lib/std/start.zig", .data = "pub const start = true;" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-lib/build_runner.zig", .data = "pub fn main() void {}" }) catch return error.Unexpected;

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const zig_lib_dir = try std.fs.path.join(allocator, &.{ root, "zig-lib" });
    defer allocator.free(zig_lib_dir);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache" });
    defer allocator.free(cache_dir);

    var first_stats: ToolchainIdentityStats = .{};
    const first_hash = try zigLibIdentityHash(allocator, cache_dir, zig_lib_dir, &first_stats);
    try std.testing.expect(!first_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 2), first_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 2), first_stats.files_hashed);

    var second_stats: ToolchainIdentityStats = .{};
    const second_hash = try zigLibIdentityHash(allocator, cache_dir, zig_lib_dir, &second_stats);
    try std.testing.expectEqual(first_hash, second_hash);
    try std.testing.expect(second_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 2), second_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 0), second_stats.files_hashed);
}

test "Zig lib identity manifest invalidates on content and path changes" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-a/std") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-b/std") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-a/std/start.zig", .data = "pub const value = 1;" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-b/std/start.zig", .data = "pub const value = 1;" }) catch return error.Unexpected;

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache" });
    defer allocator.free(cache_dir);
    const path_a = try std.fs.path.join(allocator, &.{ root, "zig-a" });
    defer allocator.free(path_a);
    const path_b = try std.fs.path.join(allocator, &.{ root, "zig-b" });
    defer allocator.free(path_b);

    const hash_a = try zigLibIdentityHash(allocator, cache_dir, path_a, null);
    const hash_b = try zigLibIdentityHash(allocator, cache_dir, path_b, null);
    try std.testing.expect(hash_a != hash_b);

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-a/std/start.zig", .data = "pub const value = 1000;" }) catch return error.Unexpected;
    const changed_hash_a = try zigLibIdentityHash(allocator, cache_dir, path_a, null);
    try std.testing.expect(hash_a != changed_hash_a);
}

test "Zig lib identity manifest corrupt or missing file recomputes safely" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-lib/std") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-lib/std/start.zig", .data = "pub const start = true;" }) catch return error.Unexpected;

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const zig_lib_dir = try std.fs.path.join(allocator, &.{ root, "zig-lib" });
    defer allocator.free(zig_lib_dir);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache" });
    defer allocator.free(cache_dir);

    const first_hash = try zigLibIdentityHash(allocator, cache_dir, zig_lib_dir, null);
    const canonical_dir_z = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, zig_lib_dir, allocator) catch return error.Unexpected;
    defer allocator.free(canonical_dir_z);
    const manifest_path = try zigLibIdentityManifestPath(allocator, cache_dir, canonical_dir_z);
    defer allocator.free(manifest_path);

    try writeFileAtomic(allocator, manifest_path, "not a valid manifest");
    var corrupt_stats: ToolchainIdentityStats = .{};
    const corrupt_recomputed = try zigLibIdentityHash(allocator, cache_dir, zig_lib_dir, &corrupt_stats);
    try std.testing.expectEqual(first_hash, corrupt_recomputed);
    try std.testing.expect(!corrupt_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), corrupt_stats.files_hashed);

    try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, manifest_path);
    var missing_stats: ToolchainIdentityStats = .{};
    const missing_recomputed = try zigLibIdentityHash(allocator, cache_dir, zig_lib_dir, &missing_stats);
    try std.testing.expectEqual(first_hash, missing_recomputed);
    try std.testing.expect(!missing_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), missing_stats.files_hashed);
}

test "Zig lib identity manifest malformed allocated records clean up safely" {
    const allocator = std.testing.allocator;
    const digest_a = [_]u8{1} ** 32;
    const digest_b = [_]u8{2} ** 32;

    const unsorted_records = [_]ZigLibFileRecord{
        .{ .path = "b.zig", .size = 1, .inode = 10, .mtime_nanos = 20, .content_digest = digest_b },
        .{ .path = "a.zig", .size = 1, .inode = 11, .mtime_nanos = 21, .content_digest = digest_a },
    };
    const unsorted_identity = computeZigLibAggregateIdentityHash("/tmp/zig-lib", &unsorted_records);
    const unsorted_bytes = try serializeZigLibIdentityManifestForTest(
        allocator,
        "/tmp/zig-lib",
        unsorted_identity,
        &unsorted_records,
    );
    defer allocator.free(unsorted_bytes);
    try std.testing.expectError(
        error.InvalidZigLibIdentityManifest,
        deserializeZigLibIdentityManifest(allocator, unsorted_bytes),
    );

    const sorted_records = [_]ZigLibFileRecord{
        .{ .path = "a.zig", .size = 1, .inode = 11, .mtime_nanos = 21, .content_digest = digest_a },
        .{ .path = "b.zig", .size = 1, .inode = 10, .mtime_nanos = 20, .content_digest = digest_b },
    };
    const mismatched_bytes = try serializeZigLibIdentityManifestForTest(
        allocator,
        "/tmp/zig-lib",
        12345,
        &sorted_records,
    );
    defer allocator.free(mismatched_bytes);
    try std.testing.expectError(
        error.InvalidZigLibIdentityManifest,
        deserializeZigLibIdentityManifest(allocator, mismatched_bytes),
    );
}

test "Zig lib identity manifest preserves OOM while reading canonical dir" {
    const allocator = std.testing.allocator;
    const records = [_]ZigLibFileRecord{};
    const identity = computeZigLibAggregateIdentityHash("/tmp/zig-lib", &records);
    const bytes = try serializeZigLibIdentityManifestForTest(
        allocator,
        "/tmp/zig-lib",
        identity,
        &records,
    );
    defer allocator.free(bytes);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        deserializeZigLibIdentityManifest(failing_allocator.allocator(), bytes),
    );
}

test "Zig lib identity manifest read errors are not treated as corrupt bytes" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "not-a-file.identity" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, manifest_path);

    if (readZigLibIdentityManifest(allocator, manifest_path)) |manifest| {
        var owned = manifest;
        owned.deinit(allocator);
        return error.ExpectedReadError;
    } else |err| {
        try std.testing.expect(err != error.InvalidZigLibIdentityManifest);
        try std.testing.expect(err != error.FileNotFound);
    }
}

test "compiler identity manifest reuses executable hash on unchanged second call" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap", .data = "compiler bytes" }) catch return error.Unexpected;
    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const compiler_path = try std.fs.path.join(allocator, &.{ root, "zap" });
    defer allocator.free(compiler_path);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache/toolchain" });
    defer allocator.free(cache_dir);

    var first_stats: ToolchainIdentityStats = .{};
    const first_hash = try compilerIdentityHashForPath(allocator, cache_dir, compiler_path, &first_stats);
    try std.testing.expect(!first_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), first_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 1), first_stats.files_hashed);

    var second_stats: ToolchainIdentityStats = .{};
    const second_hash = try compilerIdentityHashForPath(allocator, cache_dir, compiler_path, &second_stats);
    try std.testing.expectEqual(first_hash, second_hash);
    try std.testing.expect(second_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), second_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 0), second_stats.files_hashed);
}

test "compiler identity manifest invalidates on content and path changes" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-a", .data = "same compiler bytes" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-b", .data = "same compiler bytes" }) catch return error.Unexpected;
    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache/toolchain" });
    defer allocator.free(cache_dir);
    const path_a = try std.fs.path.join(allocator, &.{ root, "zap-a" });
    defer allocator.free(path_a);
    const path_b = try std.fs.path.join(allocator, &.{ root, "zap-b" });
    defer allocator.free(path_b);

    const hash_a = try compilerIdentityHashForPath(allocator, cache_dir, path_a, null);
    const hash_b = try compilerIdentityHashForPath(allocator, cache_dir, path_b, null);
    try std.testing.expect(hash_a != hash_b);

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-a", .data = "changed compiler bytes are longer" }) catch return error.Unexpected;
    const changed_hash_a = try compilerIdentityHashForPath(allocator, cache_dir, path_a, null);
    try std.testing.expect(hash_a != changed_hash_a);
}

test "compiler identity manifest corrupt or malformed data recomputes safely" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap", .data = "compiler bytes" }) catch return error.Unexpected;
    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const compiler_path = try std.fs.path.join(allocator, &.{ root, "zap" });
    defer allocator.free(compiler_path);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache/toolchain" });
    defer allocator.free(cache_dir);

    const first_hash = try compilerIdentityHashForPath(allocator, cache_dir, compiler_path, null);
    const manifest_path = try compilerIdentityManifestPath(allocator, cache_dir, compiler_path);
    defer allocator.free(manifest_path);

    try writeFileAtomic(allocator, manifest_path, "not a valid manifest");
    var corrupt_stats: ToolchainIdentityStats = .{};
    const corrupt_recomputed = try compilerIdentityHashForPath(allocator, cache_dir, compiler_path, &corrupt_stats);
    try std.testing.expectEqual(first_hash, corrupt_recomputed);
    try std.testing.expect(!corrupt_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), corrupt_stats.files_hashed);

    const digest = [_]u8{9} ** 32;
    const malformed_bytes = try serializeCompilerIdentityManifestForTest(
        allocator,
        compiler_path,
        999,
        1,
        2,
        3,
        digest,
    );
    defer allocator.free(malformed_bytes);
    try std.testing.expectError(
        error.InvalidCompilerIdentityManifest,
        deserializeCompilerIdentityManifest(allocator, malformed_bytes),
    );
}

test "compiler identity manifest preserves OOM while reading canonical path" {
    const allocator = std.testing.allocator;
    const digest = [_]u8{7} ** 32;
    const identity = computeCompilerAggregateIdentityHash("/tmp/zap", digest);
    const bytes = try serializeCompilerIdentityManifestForTest(
        allocator,
        "/tmp/zap",
        identity,
        1,
        2,
        3,
        digest,
    );
    defer allocator.free(bytes);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        deserializeCompilerIdentityManifest(failing_allocator.allocator(), bytes),
    );
}

test "snapshot validation rejects changed file cached artifact glob env and missing dSYM" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "zap-out/bin") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "lib/app.zap" });
    defer allocator.free(file_path);
    const dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "lib" });
    defer allocator.free(dir_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);
    const glob_pattern = try std.fs.path.join(allocator, &.{ tmp_path, "lib/*.zap" });
    defer allocator.free(glob_pattern);

    const file_fp = try fileFingerprint(allocator, file_path);
    defer allocator.free(file_fp.path);
    const dir_fp = try directoryFingerprint(allocator, dir_path, true);
    defer allocator.free(dir_fp.path);
    const glob_fp = try globFingerprint(allocator, glob_pattern);
    defer allocator.free(glob_fp.pattern);

    var files = [_]FileFingerprint{file_fp};
    var dirs = [_]DirectoryFingerprint{dir_fp};
    var globs = [_]GlobFingerprint{glob_fp};
    const bad_env = [_]EnvFingerprint{.{ .name = "PATH", .present = true, .value_hash = 0 }};
    const snapshot: Snapshot = .{
        .invocation_identity = 1,
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
        .directories = &dirs,
        .globs = &globs,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = 1,
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };
    try std.testing.expect(validateSnapshot(allocator, snapshot, inputs));

    var wrong_cache_key = snapshot;
    wrong_cache_key.cache_key_hex = "different";
    try std.testing.expect(!validateSnapshot(allocator, wrong_cache_key, inputs));

    tmp_dir.dir.deleteFile(std.Options.debug_io, "zap-out/bin/app") catch return error.Unexpected;
    try std.testing.expect(validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;

    tmp_dir.dir.deleteFile(std.Options.debug_io, ".zap-cache/o/abcd/app") catch return error.Unexpected;
    try std.testing.expect(!validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct Changed {}" }) catch return error.Unexpected;
    try std.testing.expect(!validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/extra.zap", .data = "pub struct Extra {}" }) catch return error.Unexpected;
    try std.testing.expect(!validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.deleteFile(std.Options.debug_io, "lib/extra.zap") catch return error.Unexpected;

    var missing_dsym = snapshot;
    missing_dsym.debug_symbols_required = true;
    try std.testing.expect(!validateSnapshot(allocator, missing_dsym, inputs));

    var env_mismatch = snapshot;
    env_mismatch.env_vars = &bad_env;
    try std.testing.expect(!validateSnapshot(allocator, env_mismatch, inputs));
}
