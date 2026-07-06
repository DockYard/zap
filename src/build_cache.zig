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
const VERSION: u16 = 10;

const MAX_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;
const MAX_STABLE_SNAPSHOT_READ_ATTEMPTS: usize = 3;
const MAX_FINGERPRINT_FILE_BYTES: usize = 64 * 1024 * 1024;
const MAX_TOOLCHAIN_MANIFEST_BYTES: usize = 128 * 1024 * 1024;
const MAX_TOOLCHAIN_FILE_BYTES: usize = 1024 * 1024 * 1024;

const ZIG_LIB_MANIFEST_MAGIC: u64 = 0x4d_49_4c_5a_42_50_41_5a; // "ZAPBZLIM" little-endian
const ZIG_LIB_MANIFEST_VERSION: u16 = 1;
const ZIG_LIB_IDENTITY_MAGIC: u32 = 0x5a_5a_4c_34; // "ZZL4"
const ZIG_LIB_IDENTITY_VERSION: u16 = 4;
const COMPILER_MANIFEST_MAGIC: u64 = 0x4d_49_43_5a_42_50_41_5a; // "ZAPBZCIM" little-endian
const COMPILER_MANIFEST_VERSION: u16 = 1;
const COMPILER_IDENTITY_MAGIC: u32 = 0x5a_43_43_32; // "ZCC2"
const COMPILER_IDENTITY_VERSION: u16 = 2;

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
    /// P2-J1: `-Druntime-concurrency=` tri-state (null = manifest
    /// decides). A gate flip changes the emitted runtime and the link
    /// line, so the manifest-snapshot fast path must MISS on it rather
    /// than reinstalling an artifact built under the other gate value.
    runtime_concurrency: ?bool = null,
};

pub const Pipeline = struct {
    steps: []const PipelineStep = &.{},
};

pub const PipelineStep = union(enum) {
    compile,
    run: PipelineRunStep,
};

pub const PipelineRunStep = struct {
    args: []const []const u8 = &.{},
    forward_args: bool = true,
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
    zig_lib_identity_digest: CacheDigest,
    compiler_identity_digest: CacheDigest,
    host_arch: []const u8 = @tagName(builtin.cpu.arch),
    host_os: []const u8 = @tagName(builtin.os.tag),
};

pub const CacheDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
pub const FileDigest = CacheDigest;
pub const ToolchainDigest = CacheDigest;
pub const InvocationIdentity = CacheDigest;

pub const FileFingerprint = struct {
    path: []const u8,
    present: bool,
    content_digest: FileDigest,
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

/// Failure classes surfaced while computing build-cache toolchain identity.
///
/// These errors keep allocator pressure, canonicalization, manifest IO, live
/// file metadata, directory traversal, and content hashing distinguishable at
/// the caller boundary without changing the successful identity fast path.
pub const ToolchainIdentityError = std.mem.Allocator.Error || error{
    ZigLibCanonicalizationFailed,
    ZigLibIdentityManifestReadFailed,
    ZigLibIdentityManifestStatUnavailable,
    ZigLibIdentityManifestWriteFailed,
    ZigLibDirectoryOpenFailed,
    ZigLibDirectoryWalkFailed,
    ZigLibFileStatUnavailable,
    ZigLibFileOpenFailed,
    ZigLibFileHashUnavailable,
    CompilerExecutablePathUnavailable,
    CompilerExecutableCanonicalizationFailed,
    CompilerIdentityManifestReadFailed,
    CompilerIdentityManifestStatUnavailable,
    CompilerIdentityManifestWriteFailed,
    CompilerFileStatUnavailable,
    CompilerFileNotRegular,
    CompilerFileHashUnavailable,
    ToolchainIdentityFileTooLarge,
};

const ReadZigLibIdentityManifestError = std.mem.Allocator.Error || error{
    FileNotFound,
    InvalidZigLibIdentityManifest,
    ZigLibIdentityManifestReadFailed,
};

const ReadCompilerIdentityManifestError = std.mem.Allocator.Error || error{
    FileNotFound,
    InvalidCompilerIdentityManifest,
    CompilerIdentityManifestReadFailed,
};

pub const ValidationStats = struct {
    file_stats_checked: usize = 0,
    files_hashed: usize = 0,
    miss_reason: ?ValidationMissReason = null,
    /// Borrowed from the validated snapshot or current input path. Valid only
    /// while the caller-owned snapshot/inputs passed to `validateSnapshot`
    /// remain alive. Use `validationMissDetailAlloc` when the detail must
    /// outlive those inputs.
    miss_path: []const u8 = "",
};

pub const ValidationMissReason = enum {
    invocation_identity_changed,
    cached_artifact_path_mismatch,
    cached_artifact_missing,
    debug_symbols_missing,
    file_missing,
    file_unexpectedly_present,
    file_not_regular,
    file_unreadable,
    file_content_changed,
    directory_unreadable,
    directory_presence_changed,
    directory_listing_changed,
    env_unreadable,
    env_presence_changed,
    env_value_changed,
    glob_unreadable,
    glob_result_changed,
};

pub fn validationMissReasonLabel(reason: ?ValidationMissReason) []const u8 {
    return if (reason) |some| @tagName(some) else "unavailable";
}

pub fn validationMissDetailAlloc(allocator: std.mem.Allocator, stats: ValidationStats) ![]const u8 {
    const label = validationMissReasonLabel(stats.miss_reason);
    if (stats.miss_path.len == 0) return allocator.dupe(u8, label);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ label, stats.miss_path });
}

const ZigLibFileRecord = struct {
    path: []const u8,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    ctime_nanos: i128,
    content_digest: FileDigest,
};

const ZigLibIdentityManifest = struct {
    canonical_dir: []const u8,
    identity_digest: ToolchainDigest,
    files: []const ZigLibFileRecord,

    fn deinit(self: *ZigLibIdentityManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_dir);
        for (self.files) |record| allocator.free(record.path);
        allocator.free(self.files);
        self.* = .{
            .canonical_dir = "",
            .identity_digest = zeroCacheDigest(),
            .files = &.{},
        };
    }
};

const CompilerIdentityManifest = struct {
    canonical_path: []const u8,
    identity_digest: ToolchainDigest,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    ctime_nanos: i128,
    content_digest: FileDigest,

    fn deinit(self: *CompilerIdentityManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_path);
        self.* = .{
            .canonical_path = "",
            .identity_digest = zeroCacheDigest(),
            .size = 0,
            .inode = 0,
            .mtime_nanos = 0,
            .ctime_nanos = 0,
            .content_digest = zeroCacheDigest(),
        };
    }
};

pub const Snapshot = struct {
    invocation_identity: InvocationIdentity,
    cache_key_hex: []const u8,
    /// Content-addressed artifact path under the Zap cache, e.g.
    /// `.zap-cache/o/<digest>/<artifact>`. This is the durable artifact;
    /// `output_path` is the installed/user-facing copy.
    cached_artifact_path: []const u8,
    output_path: []const u8,
    kind: ArtifactKind,
    target: ?[]const u8 = null,
    debug_symbols_required: bool,
    pipeline: ?Pipeline = null,
    files: []const FileFingerprint = &.{},
    directories: []const DirectoryFingerprint = &.{},
    env_vars: []const EnvFingerprint = &.{},
    globs: []const GlobFingerprint = &.{},

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_key_hex);
        allocator.free(self.cached_artifact_path);
        allocator.free(self.output_path);
        if (self.target) |target| allocator.free(target);
        if (self.pipeline) |pipeline| freePipeline(allocator, pipeline);
        for (self.files) |fingerprint| allocator.free(fingerprint.path);
        allocator.free(self.files);
        for (self.directories) |fingerprint| allocator.free(fingerprint.path);
        allocator.free(self.directories);
        for (self.env_vars) |fingerprint| allocator.free(fingerprint.name);
        allocator.free(self.env_vars);
        for (self.globs) |fingerprint| allocator.free(fingerprint.pattern);
        allocator.free(self.globs);
        self.* = .{
            .invocation_identity = zeroCacheDigest(),
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
                .invocation_identity = zeroCacheDigest(),
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
    invocation_identity: InvocationIdentity,
    snapshot_mtime_nanos: i128,
    stats: ?*ValidationStats = null,
};

pub const ValidationResult = enum {
    valid,
    miss,
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

fn toolchainIdentityError(err: anyerror, mapped_error: ToolchainIdentityError) ToolchainIdentityError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => mapped_error,
    };
}

fn toolchainIdentityHashError(err: anyerror, mapped_error: ToolchainIdentityError) ToolchainIdentityError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.ToolchainIdentityFileTooLarge,
        else => mapped_error,
    };
}

fn canonicalizeZigLibDir(
    allocator: std.mem.Allocator,
    zig_lib_dir: []const u8,
) ToolchainIdentityError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        std.Options.debug_io,
        zig_lib_dir,
        allocator,
    ) catch |err| return toolchainIdentityError(err, error.ZigLibCanonicalizationFailed);
}

fn resolveCompilerExecutablePath(allocator: std.mem.Allocator) ToolchainIdentityError![]u8 {
    return std.process.executablePathAlloc(std.Options.debug_io, allocator) catch |err|
        return toolchainIdentityError(err, error.CompilerExecutablePathUnavailable);
}

fn canonicalizeCompilerExecutablePath(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
) ToolchainIdentityError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(
        std.Options.debug_io,
        executable_path,
        allocator,
    ) catch |err| return toolchainIdentityError(err, error.CompilerExecutableCanonicalizationFailed);
}

pub fn zigLibIdentityDigest(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    zig_lib_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!ToolchainDigest {
    if (maybe_stats) |stats| stats.* = .{};

    const canonical_zig_lib_dir = try canonicalizeZigLibDir(allocator, zig_lib_dir);
    defer allocator.free(canonical_zig_lib_dir);

    const manifest_path = try zigLibIdentityManifestPath(allocator, cache_dir, canonical_zig_lib_dir);
    defer allocator.free(manifest_path);

    if (readZigLibIdentityManifest(allocator, manifest_path)) |manifest_value| {
        var manifest = manifest_value;
        defer manifest.deinit(allocator);
        const manifest_mtime_nanos = cwdFileMtimeNanos(manifest_path) catch |err|
            return toolchainIdentityError(err, error.ZigLibIdentityManifestStatUnavailable);
        if (try validateZigLibIdentityManifest(
            allocator,
            canonical_zig_lib_dir,
            manifest,
            manifest_mtime_nanos,
            maybe_stats,
        )) {
            if (maybe_stats) |stats| stats.manifest_hit = true;
            return manifest.identity_digest;
        }
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidZigLibIdentityManifest => {},
        error.OutOfMemory => return error.OutOfMemory,
        error.ZigLibIdentityManifestReadFailed => return error.ZigLibIdentityManifestReadFailed,
    }

    var rebuilt = try rebuildZigLibIdentityManifest(allocator, canonical_zig_lib_dir, maybe_stats);
    defer rebuilt.deinit(allocator);
    writeZigLibIdentityManifestAtomic(allocator, manifest_path, rebuilt) catch |err|
        return toolchainIdentityError(err, error.ZigLibIdentityManifestWriteFailed);
    return rebuilt.identity_digest;
}

pub fn compilerIdentityDigest(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!ToolchainDigest {
    if (maybe_stats) |stats| stats.* = .{};

    const exe_path = try resolveCompilerExecutablePath(allocator);
    defer allocator.free(exe_path);
    const canonical_exe_path = try canonicalizeCompilerExecutablePath(allocator, exe_path);
    defer allocator.free(canonical_exe_path);

    return compilerIdentityDigestForPath(allocator, cache_dir, canonical_exe_path, maybe_stats);
}

pub fn compilerIdentityDigestForPath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!ToolchainDigest {
    if (maybe_stats) |stats| stats.* = .{};

    const manifest_path = try compilerIdentityManifestPath(allocator, cache_dir, canonical_exe_path);
    defer allocator.free(manifest_path);

    if (readCompilerIdentityManifest(allocator, manifest_path)) |manifest_value| {
        var manifest = manifest_value;
        defer manifest.deinit(allocator);
        const manifest_mtime_nanos = cwdFileMtimeNanos(manifest_path) catch |err|
            return toolchainIdentityError(err, error.CompilerIdentityManifestStatUnavailable);
        if (try validateCompilerIdentityManifest(
            canonical_exe_path,
            manifest,
            manifest_mtime_nanos,
            maybe_stats,
        )) {
            if (maybe_stats) |stats| stats.manifest_hit = true;
            return manifest.identity_digest;
        }
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidCompilerIdentityManifest => {},
        error.OutOfMemory => return error.OutOfMemory,
        error.CompilerIdentityManifestReadFailed => return error.CompilerIdentityManifestReadFailed,
    }

    var rebuilt = try rebuildCompilerIdentityManifest(allocator, canonical_exe_path, maybe_stats);
    defer rebuilt.deinit(allocator);
    writeCompilerIdentityManifestAtomic(allocator, manifest_path, rebuilt) catch |err|
        return toolchainIdentityError(err, error.CompilerIdentityManifestWriteFailed);
    return rebuilt.identity_digest;
}

pub fn hashInvocationIdentity(allocator: std.mem.Allocator, inputs: InvocationInputs) !InvocationIdentity {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const identity_magic: u32 = 0x5a_49_44_32; // "ZID2"
    // v3 (P2-J1): the identity folds the `-Druntime-concurrency=`
    // override tri-state; the bump retires every pre-gate snapshot.
    const identity_version: u16 = 3;
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
    // P2-J1: tri-state gate override (0 = unset, 1 = off, 2 = on).
    hashOptionalByte(&hasher, if (inputs.overrides.runtime_concurrency) |gate|
        @as(u8, if (gate) 2 else 1)
    else
        null);
    hashBool(&hasher, inputs.collect_arc_stats);
    hashOptionalString(&hasher, inputs.zap_lib_dir);
    hashBytes(&hasher, inputs.zig_lib_dir);
    hashBytes(&hasher, &inputs.zig_lib_identity_digest);
    hashBytes(&hasher, inputs.host_arch);
    hashBytes(&hasher, inputs.host_os);
    hashBytes(&hasher, &inputs.compiler_identity_digest);

    return hasher.finalResult();
}

pub fn fileFingerprint(allocator: std.mem.Allocator, path: []const u8) !FileFingerprint {
    while (true) {
        const stat_before = cwdFileStat(path) catch |err| switch (err) {
            error.FileNotFound => return absentFileFingerprint(allocator, path),
            else => return err,
        };
        if (stat_before.kind != .file) return error.FileStatUnavailable;

        const content_digest = try hashFingerprintFileContents(path, null);

        const stat_after = cwdFileStat(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (!statIdentityMatches(stat_before, stat_after)) {
            continue;
        }

        return .{
            .path = try allocator.dupe(u8, path),
            .present = true,
            .content_digest = content_digest,
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
) !ValidationResult {
    if (inputs.stats) |stats| stats.* = .{};

    if (!std.mem.eql(u8, &snapshot.invocation_identity, &inputs.invocation_identity)) {
        recordValidationMiss(inputs.stats, .invocation_identity_changed, "");
        return .miss;
    }
    if (!cachedArtifactPathMatchesKey(snapshot)) {
        recordValidationMiss(inputs.stats, .cached_artifact_path_mismatch, snapshot.cached_artifact_path);
        return .miss;
    }

    switch (try validateCachedPathAccess(
        snapshot.cached_artifact_path,
        .cached_artifact_missing,
        snapshot.cached_artifact_path,
        inputs.stats,
    )) {
        .valid => {},
        .miss => return .miss,
    }
    if (snapshot.debug_symbols_required) {
        const debug_path = try std.fmt.allocPrint(allocator, "{s}.dSYM", .{snapshot.cached_artifact_path});
        defer allocator.free(debug_path);
        switch (try validateCachedPathAccess(
            debug_path,
            .debug_symbols_missing,
            snapshot.cached_artifact_path,
            inputs.stats,
        )) {
            .valid => {},
            .miss => return .miss,
        }
    }

    for (snapshot.files) |expected| {
        switch (try validateFileFingerprint(
            expected,
            inputs.snapshot_mtime_nanos,
            inputs.stats,
        )) {
            .valid => {},
            .miss => return .miss,
        }
    }
    for (snapshot.directories) |expected| {
        const current = try directoryFingerprint(allocator, expected.path, expected.recursive);
        defer allocator.free(current.path);
        if (current.present != expected.present) {
            recordValidationMiss(inputs.stats, .directory_presence_changed, expected.path);
            return .miss;
        }
        if (current.listing_hash != expected.listing_hash) {
            recordValidationMiss(inputs.stats, .directory_listing_changed, expected.path);
            return .miss;
        }
    }
    for (snapshot.env_vars) |expected| {
        const current = try envFingerprint(allocator, expected.name);
        defer allocator.free(current.name);
        if (current.present != expected.present) {
            recordValidationMiss(inputs.stats, .env_presence_changed, expected.name);
            return .miss;
        }
        if (current.value_hash != expected.value_hash) {
            recordValidationMiss(inputs.stats, .env_value_changed, expected.name);
            return .miss;
        }
    }
    for (snapshot.globs) |expected| {
        const current = try globFingerprint(allocator, expected.pattern);
        defer allocator.free(current.pattern);
        if (current.result_hash != expected.result_hash) {
            recordValidationMiss(inputs.stats, .glob_result_changed, expected.pattern);
            return .miss;
        }
    }
    return .valid;
}

fn validateCachedPathAccess(
    path: []const u8,
    missing_reason: ValidationMissReason,
    miss_path: []const u8,
    maybe_stats: ?*ValidationStats,
) !ValidationResult {
    std.Io.Dir.cwd().access(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            recordValidationMiss(maybe_stats, missing_reason, miss_path);
            return .miss;
        },
        else => return err,
    };
    return .valid;
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
    try bytes.appendSlice(allocator, &snapshot.invocation_identity);
    try appendString(allocator, bytes, snapshot.cache_key_hex);
    try appendString(allocator, bytes, snapshot.cached_artifact_path);
    try appendString(allocator, bytes, snapshot.output_path);
    try appendInt(allocator, u8, bytes, @intFromEnum(snapshot.kind));
    try appendOptionalString(allocator, bytes, snapshot.target);
    try appendBool(allocator, bytes, snapshot.debug_symbols_required);
    try appendOptionalPipeline(allocator, bytes, snapshot.pipeline);

    try appendInt(allocator, u32, bytes, @intCast(snapshot.files.len));
    for (snapshot.files) |fingerprint| {
        try appendString(allocator, bytes, fingerprint.path);
        try appendBool(allocator, bytes, fingerprint.present);
        try bytes.appendSlice(allocator, fingerprint.content_digest[0..]);
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

    const invocation_identity = try reader.readFixed(InvocationIdentity);
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
    const pipeline = readOptionalPipeline(allocator, &reader) catch |err| {
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
        .pipeline = pipeline,
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
            .content_digest = try reader.readFixed(FileDigest),
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

fn readPipeline(allocator: std.mem.Allocator, reader: *Reader) !Pipeline {
    var steps: std.ArrayListUnmanaged(PipelineStep) = .empty;
    errdefer {
        for (steps.items) |step| {
            switch (step) {
                .compile => {},
                .run => |run_step| {
                    for (run_step.args) |arg| allocator.free(arg);
                    allocator.free(run_step.args);
                },
            }
        }
        steps.deinit(allocator);
    }

    const step_count = try reader.readCount();
    var step_index: usize = 0;
    while (step_index < step_count) : (step_index += 1) {
        const tag = try reader.readInt(u8);
        switch (tag) {
            1 => try steps.append(allocator, .compile),
            2 => {
                const forward_args = try reader.readBool();
                var args: std.ArrayListUnmanaged([]const u8) = .empty;
                var args_transferred = false;
                errdefer {
                    if (!args_transferred) {
                        for (args.items) |arg| allocator.free(arg);
                        args.deinit(allocator);
                    }
                }
                const arg_count = try reader.readCount();
                var arg_index: usize = 0;
                while (arg_index < arg_count) : (arg_index += 1) {
                    const arg = try reader.readString(allocator);
                    var arg_transferred = false;
                    errdefer if (!arg_transferred) allocator.free(arg);
                    try args.append(allocator, arg);
                    arg_transferred = true;
                }
                const owned_args = try args.toOwnedSlice(allocator);
                args_transferred = true;
                errdefer {
                    for (owned_args) |arg| allocator.free(arg);
                    allocator.free(owned_args);
                }
                try steps.append(allocator, .{ .run = .{
                    .args = owned_args,
                    .forward_args = forward_args,
                } });
            },
            else => return error.InvalidSnapshot,
        }
    }

    return .{ .steps = try steps.toOwnedSlice(allocator) };
}

fn readOptionalPipeline(allocator: std.mem.Allocator, reader: *Reader) !?Pipeline {
    return if (try reader.readBool()) try readPipeline(allocator, reader) else null;
}

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

fn freePipeline(allocator: std.mem.Allocator, pipeline: Pipeline) void {
    for (pipeline.steps) |step| {
        switch (step) {
            .compile => {},
            .run => |run_step| {
                for (run_step.args) |arg| allocator.free(arg);
                allocator.free(run_step.args);
            },
        }
    }
    allocator.free(pipeline.steps);
}

fn appendPipeline(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), pipeline: Pipeline) !void {
    try appendInt(allocator, u32, bytes, @intCast(pipeline.steps.len));
    for (pipeline.steps) |step| {
        switch (step) {
            .compile => try appendInt(allocator, u8, bytes, 1),
            .run => |run_step| {
                try appendInt(allocator, u8, bytes, 2);
                try appendBool(allocator, bytes, run_step.forward_args);
                try appendInt(allocator, u32, bytes, @intCast(run_step.args.len));
                for (run_step.args) |arg| {
                    try appendString(allocator, bytes, arg);
                }
            },
        }
    }
}

fn appendOptionalPipeline(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayListUnmanaged(u8),
    pipeline: ?Pipeline,
) !void {
    try appendBool(allocator, bytes, pipeline != null);
    if (pipeline) |some| try appendPipeline(allocator, bytes, some);
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

fn readZigLibIdentityManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
) ReadZigLibIdentityManifestError!ZigLibIdentityManifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(MAX_TOOLCHAIN_MANIFEST_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ZigLibIdentityManifestReadFailed,
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
    const identity_digest = reader.readFixed(ToolchainDigest) catch return error.InvalidZigLibIdentityManifest;

    const files = parseZigLibFileRecords(allocator, &reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidZigLibIdentityManifest,
    };
    errdefer freeZigLibRecords(allocator, files);

    if (reader.pos != bytes.len) return error.InvalidZigLibIdentityManifest;
    if (!recordsAreStrictlySorted(files)) return error.InvalidZigLibIdentityManifest;
    const recomputed_identity = computeZigLibAggregateIdentityDigest(canonical_dir, files);
    if (!std.mem.eql(u8, recomputed_identity[0..], identity_digest[0..])) return error.InvalidZigLibIdentityManifest;

    return .{
        .canonical_dir = canonical_dir,
        .identity_digest = identity_digest,
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
            .ctime_nanos = try reader.readInt(i128),
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
    try bytes.appendSlice(allocator, &manifest.identity_digest);
    try appendInt(allocator, u32, &bytes, @intCast(manifest.files.len));
    for (manifest.files) |record| {
        try appendString(allocator, &bytes, record.path);
        try appendInt(allocator, u64, &bytes, record.size);
        try appendInt(allocator, u64, &bytes, record.inode);
        try appendInt(allocator, i128, &bytes, record.mtime_nanos);
        try appendInt(allocator, i128, &bytes, record.ctime_nanos);
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

fn readCompilerIdentityManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
) ReadCompilerIdentityManifestError!CompilerIdentityManifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(MAX_TOOLCHAIN_MANIFEST_BYTES),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompilerIdentityManifestReadFailed,
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
    const identity_digest = reader.readFixed(ToolchainDigest) catch return error.InvalidCompilerIdentityManifest;
    const size = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    const inode = reader.readInt(u64) catch return error.InvalidCompilerIdentityManifest;
    const mtime_nanos = reader.readInt(i128) catch return error.InvalidCompilerIdentityManifest;
    const ctime_nanos = reader.readInt(i128) catch return error.InvalidCompilerIdentityManifest;
    const content_digest = reader.readFixed(FileDigest) catch return error.InvalidCompilerIdentityManifest;
    if (reader.pos != bytes.len) return error.InvalidCompilerIdentityManifest;

    const recomputed_identity = computeCompilerAggregateIdentityDigest(canonical_path, content_digest);
    if (!std.mem.eql(u8, recomputed_identity[0..], identity_digest[0..])) return error.InvalidCompilerIdentityManifest;

    return .{
        .canonical_path = canonical_path,
        .identity_digest = identity_digest,
        .size = size,
        .inode = inode,
        .mtime_nanos = mtime_nanos,
        .ctime_nanos = ctime_nanos,
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
    try bytes.appendSlice(allocator, &manifest.identity_digest);
    try appendInt(allocator, u64, &bytes, manifest.size);
    try appendInt(allocator, u64, &bytes, manifest.inode);
    try appendInt(allocator, i128, &bytes, manifest.mtime_nanos);
    try appendInt(allocator, i128, &bytes, manifest.ctime_nanos);
    try bytes.appendSlice(allocator, &manifest.content_digest);

    try writeFileAtomic(allocator, path, bytes.items);
}

fn validateZigLibIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    manifest: ZigLibIdentityManifest,
    manifest_mtime_nanos: i128,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!bool {
    if (!std.mem.eql(u8, canonical_zig_lib_dir, manifest.canonical_dir)) return false;

    const current = try collectZigLibRecords(allocator, canonical_zig_lib_dir, false, maybe_stats);
    defer freeZigLibRecords(allocator, current);

    if (current.len != manifest.files.len) return false;
    for (manifest.files, current) |stored, live| {
        if (!std.mem.eql(u8, stored.path, live.path)) return false;
        if (stored.size != live.size) return false;
        if (stored.inode != live.inode) return false;
        if (stored.mtime_nanos != live.mtime_nanos) return false;
        if (stored.ctime_nanos != live.ctime_nanos) return false;
        if (live.mtime_nanos >= manifest_mtime_nanos or live.ctime_nanos >= manifest_mtime_nanos) return false;
    }
    return true;
}

fn validateCompilerIdentityManifest(
    canonical_exe_path: []const u8,
    manifest: CompilerIdentityManifest,
    manifest_mtime_nanos: i128,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!bool {
    if (!std.mem.eql(u8, canonical_exe_path, manifest.canonical_path)) return false;

    const stat = cwdFileStat(canonical_exe_path) catch |err|
        return toolchainIdentityError(err, error.CompilerFileStatUnavailable);
    if (maybe_stats) |stats| stats.files_discovered += 1;
    if (stat.kind != .file) return false;
    if (manifest.size != stat.size) return false;
    if (manifest.inode != @as(u64, @intCast(stat.inode))) return false;
    if (manifest.mtime_nanos != stat.mtime.nanoseconds) return false;
    if (manifest.ctime_nanos != stat.ctime.nanoseconds) return false;
    if (stat.mtime.nanoseconds >= manifest_mtime_nanos or stat.ctime.nanoseconds >= manifest_mtime_nanos) return false;
    return true;
}

fn rebuildZigLibIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!ZigLibIdentityManifest {
    const canonical_dir = try allocator.dupe(u8, canonical_zig_lib_dir);
    errdefer allocator.free(canonical_dir);

    const records = try collectZigLibRecords(allocator, canonical_zig_lib_dir, true, maybe_stats);
    errdefer freeZigLibRecords(allocator, records);

    return .{
        .canonical_dir = canonical_dir,
        .identity_digest = computeZigLibAggregateIdentityDigest(canonical_dir, records),
        .files = records,
    };
}

fn rebuildCompilerIdentityManifest(
    allocator: std.mem.Allocator,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!CompilerIdentityManifest {
    const canonical_path = try allocator.dupe(u8, canonical_exe_path);
    errdefer allocator.free(canonical_path);

    const stat = cwdFileStat(canonical_exe_path) catch |err|
        return toolchainIdentityError(err, error.CompilerFileStatUnavailable);
    if (stat.kind != .file) return error.CompilerFileNotRegular;
    if (maybe_stats) |stats| stats.files_discovered += 1;
    const content_digest = try hashCompilerFileContents(allocator, canonical_exe_path, maybe_stats);

    return .{
        .canonical_path = canonical_path,
        .identity_digest = computeCompilerAggregateIdentityDigest(canonical_path, content_digest),
        .size = stat.size,
        .inode = @intCast(stat.inode),
        .mtime_nanos = stat.mtime.nanoseconds,
        .ctime_nanos = stat.ctime.nanoseconds,
        .content_digest = content_digest,
    };
}

fn collectZigLibRecords(
    allocator: std.mem.Allocator,
    canonical_zig_lib_dir: []const u8,
    comptime hash_contents: bool,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError![]ZigLibFileRecord {
    var dir = std.Io.Dir.cwd().openDir(
        std.Options.debug_io,
        canonical_zig_lib_dir,
        .{ .iterate = true },
    ) catch |err| return toolchainIdentityError(err, error.ZigLibDirectoryOpenFailed);
    defer dir.close(std.Options.debug_io);

    var records: std.ArrayListUnmanaged(ZigLibFileRecord) = .empty;
    errdefer {
        for (records.items) |record| allocator.free(record.path);
        records.deinit(allocator);
    }

    var walker = std.Io.Dir.walk(dir, allocator) catch |err|
        return toolchainIdentityError(err, error.ZigLibDirectoryWalkFailed);
    defer walker.deinit();
    while (walker.next(std.Options.debug_io) catch |err|
        return toolchainIdentityError(err, error.ZigLibDirectoryWalkFailed)) |entry|
    {
        if (entry.kind != .file) continue;
        const stat = try zigLibFileStat(dir, entry.path);
        if (stat.kind != .file) continue;
        const digest: FileDigest = if (hash_contents)
            try hashZigLibFileContents(allocator, dir, entry.path, maybe_stats)
        else
            [_]u8{0} ** 32;
        if (maybe_stats) |stats| stats.files_discovered += 1;
        const record_path = try allocator.dupe(u8, entry.path);
        var path_transferred = false;
        errdefer if (!path_transferred) allocator.free(record_path);
        try records.append(allocator, .{
            .path = record_path,
            .size = stat.size,
            .inode = @intCast(stat.inode),
            .mtime_nanos = stat.mtime.nanoseconds,
            .ctime_nanos = stat.ctime.nanoseconds,
            .content_digest = digest,
        });
        path_transferred = true;
    }

    std.mem.sort(ZigLibFileRecord, records.items, {}, struct {
        fn lessThan(_: void, left: ZigLibFileRecord, right: ZigLibFileRecord) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);
    return try records.toOwnedSlice(allocator);
}

fn zigLibFileStat(dir: std.Io.Dir, relative_path: []const u8) ToolchainIdentityError!std.Io.File.Stat {
    var file = dir.openFile(std.Options.debug_io, relative_path, .{
        .allow_directory = false,
        .path_only = true,
    }) catch |err| return toolchainIdentityError(err, error.ZigLibFileStatUnavailable);
    defer file.close(std.Options.debug_io);
    return file.stat(std.Options.debug_io) catch |err|
        return toolchainIdentityError(err, error.ZigLibFileStatUnavailable);
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
        .content_digest = zeroFileDigest(),
        .size = 0,
        .inode = 0,
        .mtime_nanos = 0,
        .ctime_nanos = 0,
    };
}

fn zeroFileDigest() FileDigest {
    return zeroCacheDigest();
}

fn zeroCacheDigest() CacheDigest {
    return [_]u8{0} ** @sizeOf(CacheDigest);
}

pub fn fileContentDigest(contents: []const u8) FileDigest {
    return bytesDigest(contents);
}

pub fn bytesDigest(contents: []const u8) CacheDigest {
    var digest: CacheDigest = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    return digest;
}

fn hashFingerprintFileContents(
    path: []const u8,
    maybe_stats: ?*ValidationStats,
) !FileDigest {
    const digest = hashFileContentsFromCwd(path, MAX_FINGERPRINT_FILE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if (maybe_stats) |stats| stats.files_hashed += 1;
    return digest;
}

fn hashFileContentsFromCwd(path: []const u8, max_bytes: usize) !CacheDigest {
    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close(std.Options.debug_io);
    return hashOpenedFileContents(file, max_bytes);
}

fn hashOpenedFileContents(file: std.Io.File, max_bytes: usize) !CacheDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        const bytes_read = file.readStreaming(std.Options.debug_io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;
        total_bytes += bytes_read;
        if (total_bytes > max_bytes) return error.StreamTooLong;
        hasher.update(buffer[0..bytes_read]);
    }
    return hasher.finalResult();
}

fn statIdentityMatches(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == right.kind and
        left.size == right.size and
        left.inode == right.inode and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn validateFileFingerprint(
    expected: FileFingerprint,
    snapshot_mtime_nanos: i128,
    maybe_stats: ?*ValidationStats,
) !ValidationResult {
    const stat = cwdFileStat(expected.path) catch |err| switch (err) {
        error.FileNotFound => {
            if (!expected.present) return .valid;
            recordValidationMiss(maybe_stats, .file_missing, expected.path);
            return .miss;
        },
        else => return err,
    };
    if (maybe_stats) |stats| stats.file_stats_checked += 1;
    if (!expected.present) {
        recordValidationMiss(maybe_stats, .file_unexpectedly_present, expected.path);
        return .miss;
    }
    if (stat.kind != .file) {
        recordValidationMiss(maybe_stats, .file_not_regular, expected.path);
        return .miss;
    }

    if (fileStatMatchesFingerprint(stat, expected) and fileStatPredatesSnapshot(stat, snapshot_mtime_nanos)) {
        return .valid;
    }

    const current_digest = hashFingerprintFileContents(expected.path, maybe_stats) catch |err| switch (err) {
        error.FileNotFound => {
            recordValidationMiss(maybe_stats, .file_missing, expected.path);
            return .miss;
        },
        else => return err,
    };
    if (!std.mem.eql(u8, current_digest[0..], expected.content_digest[0..])) {
        recordValidationMiss(maybe_stats, .file_content_changed, expected.path);
        return .miss;
    }
    return .valid;
}

fn fileStatMatchesFingerprint(stat: std.Io.File.Stat, expected: FileFingerprint) bool {
    return expected.present and
        stat.kind == .file and
        stat.size == expected.size and
        @as(u64, @intCast(stat.inode)) == expected.inode and
        stat.mtime.nanoseconds == expected.mtime_nanos and
        stat.ctime.nanoseconds == expected.ctime_nanos;
}

fn fileStatPredatesSnapshot(stat: std.Io.File.Stat, snapshot_mtime_nanos: i128) bool {
    return stat.mtime.nanoseconds < snapshot_mtime_nanos and
        stat.ctime.nanoseconds < snapshot_mtime_nanos;
}

fn recordValidationMiss(
    maybe_stats: ?*ValidationStats,
    reason: ValidationMissReason,
    path: []const u8,
) void {
    if (maybe_stats) |stats| {
        if (stats.miss_reason == null) {
            stats.miss_reason = reason;
            stats.miss_path = path;
        }
    }
}

fn hashZigLibFileContents(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    relative_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!FileDigest {
    _ = allocator;
    var file = dir.openFile(std.Options.debug_io, relative_path, .{
        .allow_directory = false,
    }) catch |err| return toolchainIdentityError(err, error.ZigLibFileOpenFailed);
    defer file.close(std.Options.debug_io);
    const digest = hashOpenedFileContents(file, MAX_TOOLCHAIN_FILE_BYTES) catch |err|
        return toolchainIdentityHashError(err, error.ZigLibFileHashUnavailable);
    if (maybe_stats) |stats| stats.files_hashed += 1;
    return digest;
}

fn hashCompilerFileContents(
    allocator: std.mem.Allocator,
    canonical_exe_path: []const u8,
    maybe_stats: ?*ToolchainIdentityStats,
) ToolchainIdentityError!FileDigest {
    _ = allocator;
    const digest = hashFileContentsFromCwd(canonical_exe_path, MAX_TOOLCHAIN_FILE_BYTES) catch |err|
        return toolchainIdentityHashError(err, error.CompilerFileHashUnavailable);
    if (maybe_stats) |stats| stats.files_hashed += 1;
    return digest;
}

fn computeZigLibAggregateIdentityDigest(canonical_dir: []const u8, records: []const ZigLibFileRecord) ToolchainDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashIdentityInt(u32, &hasher, ZIG_LIB_IDENTITY_MAGIC);
    hashIdentityInt(u16, &hasher, ZIG_LIB_IDENTITY_VERSION);
    hashBytes(&hasher, canonical_dir);
    const file_count: u64 = records.len;
    hashIdentityInt(u64, &hasher, file_count);
    for (records) |record| {
        hashZigLibFileRecordIdentity(&hasher, record);
    }
    return hasher.finalResult();
}

fn hashZigLibFileRecordIdentity(hasher: *std.crypto.hash.sha2.Sha256, record: ZigLibFileRecord) void {
    hashBytes(hasher, record.path);
    hashIdentityInt(u64, hasher, record.size);
    hashIdentityInt(u64, hasher, record.inode);
    hashIdentityInt(i128, hasher, record.mtime_nanos);
    hashIdentityInt(i128, hasher, record.ctime_nanos);
    hasher.update(record.content_digest[0..]);
}

fn hashIdentityInt(comptime T: type, hasher: *std.crypto.hash.sha2.Sha256, value: T) void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    hasher.update(&buffer);
}

fn computeCompilerAggregateIdentityDigest(canonical_path: []const u8, content_digest: FileDigest) ToolchainDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const magic = COMPILER_IDENTITY_MAGIC;
    const version = COMPILER_IDENTITY_VERSION;
    hashBytes(&hasher, std.mem.asBytes(&magic));
    hashBytes(&hasher, std.mem.asBytes(&version));
    hashBytes(&hasher, canonical_path);
    hashBytes(&hasher, &content_digest);
    return hasher.finalResult();
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
            const entry_path = try allocator.dupe(u8, entry.path);
            var path_transferred = false;
            errdefer if (!path_transferred) allocator.free(entry_path);
            try entries.append(allocator, .{
                .path = entry_path,
                .size = stat.size,
                .inode = @intCast(stat.inode),
                .mtime_nanos = stat.mtime.nanoseconds,
                .ctime_nanos = stat.ctime.nanoseconds,
            });
            path_transferred = true;
        }
    } else {
        var iterator = dir.iterate();
        while (try iterator.next(std.Options.debug_io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zap")) continue;
            const stat = try directoryEntryStat(dir, entry.name);
            if (stat.kind != .file) continue;
            const entry_path = try allocator.dupe(u8, entry.name);
            var path_transferred = false;
            errdefer if (!path_transferred) allocator.free(entry_path);
            try entries.append(allocator, .{
                .path = entry_path,
                .size = stat.size,
                .inode = @intCast(stat.inode),
                .mtime_nanos = stat.mtime.nanoseconds,
                .ctime_nanos = stat.ctime.nanoseconds,
            });
            path_transferred = true;
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
    identity_digest: ToolchainDigest,
    records: []const ZigLibFileRecord,
) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, ZIG_LIB_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, ZIG_LIB_MANIFEST_VERSION);
    try appendString(allocator, &bytes, canonical_dir);
    try bytes.appendSlice(allocator, &identity_digest);
    try appendInt(allocator, u32, &bytes, @intCast(records.len));
    for (records) |record| {
        try appendString(allocator, &bytes, record.path);
        try appendInt(allocator, u64, &bytes, record.size);
        try appendInt(allocator, u64, &bytes, record.inode);
        try appendInt(allocator, i128, &bytes, record.mtime_nanos);
        try appendInt(allocator, i128, &bytes, record.ctime_nanos);
        try bytes.appendSlice(allocator, &record.content_digest);
    }
    return try bytes.toOwnedSlice(allocator);
}

fn serializeCompilerIdentityManifestForTest(
    allocator: std.mem.Allocator,
    canonical_path: []const u8,
    identity_digest: ToolchainDigest,
    size: u64,
    inode: u64,
    mtime_nanos: i128,
    ctime_nanos: i128,
    content_digest: FileDigest,
) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, COMPILER_MANIFEST_MAGIC);
    try appendInt(allocator, u16, &bytes, COMPILER_MANIFEST_VERSION);
    try appendString(allocator, &bytes, canonical_path);
    try bytes.appendSlice(allocator, &identity_digest);
    try appendInt(allocator, u64, &bytes, size);
    try appendInt(allocator, u64, &bytes, inode);
    try appendInt(allocator, i128, &bytes, mtime_nanos);
    try appendInt(allocator, i128, &bytes, ctime_nanos);
    try bytes.appendSlice(allocator, &content_digest);
    return try bytes.toOwnedSlice(allocator);
}

fn testDigest(byte: u8) CacheDigest {
    return [_]u8{byte} ** @sizeOf(CacheDigest);
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
        .zig_lib_identity_digest = testDigest(0x45),
        .compiler_identity_digest = testDigest(0x12),
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
        .zig_lib_identity_digest = testDigest(1),
        .compiler_identity_digest = testDigest(2),
    };
    const base_hash = try hashInvocationIdentity(allocator, base);

    var changed_compiler = base;
    changed_compiler.compiler_identity_digest = testDigest(3);
    const changed_compiler_hash = try hashInvocationIdentity(allocator, changed_compiler);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &changed_compiler_hash));

    var changed_zig_lib = base;
    changed_zig_lib.zig_lib_identity_digest = testDigest(4);
    const changed_zig_lib_hash = try hashInvocationIdentity(allocator, changed_zig_lib);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &changed_zig_lib_hash));

    var changed_zap_lib = base;
    changed_zap_lib.zap_lib_dir = "/tmp/other-zap/lib";
    const changed_zap_lib_hash = try hashInvocationIdentity(allocator, changed_zap_lib);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &changed_zap_lib_hash));

    var changed_overrides = base;
    changed_overrides.overrides.memory = "Memory.Tracking";
    const changed_overrides_hash = try hashInvocationIdentity(allocator, changed_overrides);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &changed_overrides_hash));

    var changed_arc_stats = base;
    changed_arc_stats.collect_arc_stats = true;
    const changed_arc_stats_hash = try hashInvocationIdentity(allocator, changed_arc_stats);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &changed_arc_stats_hash));
}

test "snapshot serialization round trip preserves fields" {
    const allocator = std.testing.allocator;
    const invocation_identity = testDigest(99);
    const content_digest = [_]u8{0x11} ** @sizeOf(FileDigest);
    const files = [_]FileFingerprint{.{
        .path = "lib/app.zap",
        .present = true,
        .content_digest = content_digest,
        .size = 12,
        .inode = 13,
        .mtime_nanos = 14,
        .ctime_nanos = 15,
    }};
    const directories = [_]DirectoryFingerprint{.{ .path = "lib", .recursive = true, .present = true, .listing_hash = 22 }};
    const env_vars = [_]EnvFingerprint{.{ .name = "PATH", .present = true, .value_hash = 33 }};
    const globs = [_]GlobFingerprint{.{ .pattern = "lib/**/*.zap", .result_hash = 44 }};
    const snapshot: Snapshot = .{
        .invocation_identity = invocation_identity,
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

    try std.testing.expectEqualSlices(u8, &invocation_identity, &restored.invocation_identity);
    try std.testing.expectEqualStrings("abcd", restored.cache_key_hex);
    try std.testing.expectEqualStrings(".zap-cache/o/abcd/app", restored.cached_artifact_path);
    try std.testing.expectEqualStrings("zap-out/bin/app", restored.output_path);
    try std.testing.expectEqual(ArtifactKind.bin, restored.kind);
    try std.testing.expectEqualStrings("aarch64-macos-none", restored.target.?);
    try std.testing.expect(restored.debug_symbols_required);
    try std.testing.expectEqual(@as(usize, 1), restored.files.len);
    try std.testing.expectEqualStrings("lib/app.zap", restored.files[0].path);
    try std.testing.expect(std.mem.eql(u8, content_digest[0..], restored.files[0].content_digest[0..]));
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
    const invocation_identity = testDigest(99);
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);

    const snapshot: Snapshot = .{
        .invocation_identity = invocation_identity,
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
    try std.testing.expectEqualSlices(u8, &invocation_identity, &stable_snapshot.snapshot.invocation_identity);
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

test "stable snapshot read preserves allocation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/target.build-plan" });
    defer allocator.free(snapshot_path);

    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(99),
        .cache_key_hex = "abcd",
        .cached_artifact_path = ".zap-cache/o/abcd/app",
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .debug_symbols_required = false,
    };
    try writeSnapshotAtomic(allocator, snapshot_path, snapshot);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        readStableSnapshot(failing_allocator.allocator(), snapshot_path),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
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

test "snapshot deserialization rejects truncated file content digest" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    try appendInt(allocator, u64, &bytes, MAGIC);
    try appendInt(allocator, u16, &bytes, VERSION);
    try appendInt(allocator, u64, &bytes, 1);
    try appendString(allocator, &bytes, "cache-key");
    try appendString(allocator, &bytes, ".zap-cache/o/cache-key/app");
    try appendString(allocator, &bytes, "zap-out/bin/app");
    try appendInt(allocator, u8, &bytes, @intFromEnum(ArtifactKind.bin));
    try appendOptionalString(allocator, &bytes, null);
    try appendBool(allocator, &bytes, false);
    try appendOptionalPipeline(allocator, &bytes, null);
    try appendInt(allocator, u32, &bytes, 1);
    try appendString(allocator, &bytes, "lib/app.zap");
    try appendBool(allocator, &bytes, true);
    const partial_digest = [_]u8{0x42} ** (std.crypto.hash.sha2.Sha256.digest_length - 1);
    try bytes.appendSlice(allocator, &partial_digest);

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

test "snapshot validation reuses content digest when stat tuple predates snapshot" {
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
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
    };
    var stats: ValidationStats = .{};
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
        .stats = &stats,
    };

    try std.testing.expectEqual(ValidationResult.valid, try validateSnapshot(allocator, snapshot, inputs));
    try std.testing.expectEqual(@as(usize, 1), stats.file_stats_checked);
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
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
    };
    var stats: ValidationStats = .{};
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
        .stats = &stats,
    };

    try std.testing.expectEqual(ValidationResult.valid, try validateSnapshot(allocator, snapshot, inputs));
    try std.testing.expectEqual(@as(usize, 1), stats.file_stats_checked);
    try std.testing.expectEqual(@as(usize, 1), stats.files_hashed);
}

test "snapshot validation rejects same-size file content edits" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "zap-out/bin") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "app.zap", .data = "aaaa" }) catch return error.Unexpected;

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
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .files = &files,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };

    try std.testing.expectEqual(ValidationResult.valid, try validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "app.zap", .data = "bbbb" }) catch return error.Unexpected;
    var changed_stats: ValidationStats = .{};
    const changed_inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
        .stats = &changed_stats,
    };
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, snapshot, changed_inputs));
    try std.testing.expectEqual(ValidationMissReason.file_content_changed, changed_stats.miss_reason.?);
    try std.testing.expectEqualStrings(file_path, changed_stats.miss_path);
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
    const first_hash = try zigLibIdentityDigest(allocator, cache_dir, zig_lib_dir, &first_stats);
    try std.testing.expect(!first_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 2), first_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 2), first_stats.files_hashed);

    var second_stats: ToolchainIdentityStats = .{};
    const second_hash = try zigLibIdentityDigest(allocator, cache_dir, zig_lib_dir, &second_stats);
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

    const hash_a = try zigLibIdentityDigest(allocator, cache_dir, path_a, null);
    const hash_b = try zigLibIdentityDigest(allocator, cache_dir, path_b, null);
    try std.testing.expect(!std.mem.eql(u8, hash_a[0..], hash_b[0..]));

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zig-a/std/start.zig", .data = "pub const value = 1000;" }) catch return error.Unexpected;
    const changed_hash_a = try zigLibIdentityDigest(allocator, cache_dir, path_a, null);
    try std.testing.expect(!std.mem.eql(u8, hash_a[0..], changed_hash_a[0..]));
}

test "Zig lib aggregate identity includes record stat identity" {
    const base_records = [_]ZigLibFileRecord{
        .{
            .path = "std/start.zig",
            .size = 100,
            .inode = 200,
            .mtime_nanos = 300,
            .ctime_nanos = 400,
            .content_digest = testDigest(0x42),
        },
    };
    const base_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &base_records);

    var changed_size = base_records;
    changed_size[0].size += 1;
    const size_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &changed_size);
    try std.testing.expect(!std.mem.eql(u8, base_identity[0..], size_identity[0..]));

    var changed_inode = base_records;
    changed_inode[0].inode += 1;
    const inode_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &changed_inode);
    try std.testing.expect(!std.mem.eql(u8, base_identity[0..], inode_identity[0..]));

    var changed_mtime = base_records;
    changed_mtime[0].mtime_nanos += 1;
    const mtime_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &changed_mtime);
    try std.testing.expect(!std.mem.eql(u8, base_identity[0..], mtime_identity[0..]));

    var changed_ctime = base_records;
    changed_ctime[0].ctime_nanos += 1;
    const ctime_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &changed_ctime);
    try std.testing.expect(!std.mem.eql(u8, base_identity[0..], ctime_identity[0..]));

    var changed_content = base_records;
    changed_content[0].content_digest = testDigest(0x43);
    const content_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &changed_content);
    try std.testing.expect(!std.mem.eql(u8, base_identity[0..], content_identity[0..]));
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

    const first_hash = try zigLibIdentityDigest(allocator, cache_dir, zig_lib_dir, null);
    const canonical_dir_z = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, zig_lib_dir, allocator) catch return error.Unexpected;
    defer allocator.free(canonical_dir_z);
    const manifest_path = try zigLibIdentityManifestPath(allocator, cache_dir, canonical_dir_z);
    defer allocator.free(manifest_path);

    try writeFileAtomic(allocator, manifest_path, "not a valid manifest");
    var corrupt_stats: ToolchainIdentityStats = .{};
    const corrupt_recomputed = try zigLibIdentityDigest(allocator, cache_dir, zig_lib_dir, &corrupt_stats);
    try std.testing.expectEqual(first_hash, corrupt_recomputed);
    try std.testing.expect(!corrupt_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), corrupt_stats.files_hashed);

    try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, manifest_path);
    var missing_stats: ToolchainIdentityStats = .{};
    const missing_recomputed = try zigLibIdentityDigest(allocator, cache_dir, zig_lib_dir, &missing_stats);
    try std.testing.expectEqual(first_hash, missing_recomputed);
    try std.testing.expect(!missing_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), missing_stats.files_hashed);
}

test "Zig lib identity manifest malformed allocated records clean up safely" {
    const allocator = std.testing.allocator;
    const digest_a = [_]u8{1} ** 32;
    const digest_b = [_]u8{2} ** 32;

    const unsorted_records = [_]ZigLibFileRecord{
        .{ .path = "b.zig", .size = 1, .inode = 10, .mtime_nanos = 20, .ctime_nanos = 30, .content_digest = digest_b },
        .{ .path = "a.zig", .size = 1, .inode = 11, .mtime_nanos = 21, .ctime_nanos = 31, .content_digest = digest_a },
    };
    const unsorted_identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &unsorted_records);
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
        .{ .path = "a.zig", .size = 1, .inode = 11, .mtime_nanos = 21, .ctime_nanos = 31, .content_digest = digest_a },
        .{ .path = "b.zig", .size = 1, .inode = 10, .mtime_nanos = 20, .ctime_nanos = 30, .content_digest = digest_b },
    };
    const mismatched_bytes = try serializeZigLibIdentityManifestForTest(
        allocator,
        "/tmp/zig-lib",
        testDigest(0xaa),
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
    const identity = computeZigLibAggregateIdentityDigest("/tmp/zig-lib", &records);
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

test "Zig lib identity digest preserves OOM during canonicalization" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-lib") catch return error.Unexpected;
    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const zig_lib_dir = try std.fs.path.join(allocator, &.{ root, "zig-lib" });
    defer allocator.free(zig_lib_dir);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache" });
    defer allocator.free(cache_dir);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        zigLibIdentityDigest(failing_allocator.allocator(), cache_dir, zig_lib_dir, null),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "Zig lib identity digest reports canonicalization failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const missing_zig_lib_dir = try std.fs.path.join(allocator, &.{ root, "missing-zig-lib" });
    defer allocator.free(missing_zig_lib_dir);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache" });
    defer allocator.free(cache_dir);

    try std.testing.expectError(
        error.ZigLibCanonicalizationFailed,
        zigLibIdentityDigest(allocator, cache_dir, missing_zig_lib_dir, null),
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
    const first_hash = try compilerIdentityDigestForPath(allocator, cache_dir, compiler_path, &first_stats);
    try std.testing.expect(!first_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), first_stats.files_discovered);
    try std.testing.expectEqual(@as(usize, 1), first_stats.files_hashed);

    var second_stats: ToolchainIdentityStats = .{};
    const second_hash = try compilerIdentityDigestForPath(allocator, cache_dir, compiler_path, &second_stats);
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

    const hash_a = try compilerIdentityDigestForPath(allocator, cache_dir, path_a, null);
    const hash_b = try compilerIdentityDigestForPath(allocator, cache_dir, path_b, null);
    try std.testing.expect(!std.mem.eql(u8, hash_a[0..], hash_b[0..]));

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-a", .data = "changed compiler bytes are longer" }) catch return error.Unexpected;
    const changed_hash_a = try compilerIdentityDigestForPath(allocator, cache_dir, path_a, null);
    try std.testing.expect(!std.mem.eql(u8, hash_a[0..], changed_hash_a[0..]));
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

    const first_hash = try compilerIdentityDigestForPath(allocator, cache_dir, compiler_path, null);
    const manifest_path = try compilerIdentityManifestPath(allocator, cache_dir, compiler_path);
    defer allocator.free(manifest_path);

    try writeFileAtomic(allocator, manifest_path, "not a valid manifest");
    var corrupt_stats: ToolchainIdentityStats = .{};
    const corrupt_recomputed = try compilerIdentityDigestForPath(allocator, cache_dir, compiler_path, &corrupt_stats);
    try std.testing.expectEqual(first_hash, corrupt_recomputed);
    try std.testing.expect(!corrupt_stats.manifest_hit);
    try std.testing.expectEqual(@as(usize, 1), corrupt_stats.files_hashed);

    const digest = [_]u8{9} ** 32;
    const malformed_bytes = try serializeCompilerIdentityManifestForTest(
        allocator,
        compiler_path,
        testDigest(0xbb),
        1,
        2,
        3,
        4,
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
    const identity = computeCompilerAggregateIdentityDigest("/tmp/zap", digest);
    const bytes = try serializeCompilerIdentityManifestForTest(
        allocator,
        "/tmp/zap",
        identity,
        1,
        2,
        3,
        4,
        digest,
    );
    defer allocator.free(bytes);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        deserializeCompilerIdentityManifest(failing_allocator.allocator(), bytes),
    );
}

test "compiler identity digest preserves OOM while resolving executable path" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        compilerIdentityDigest(failing_allocator.allocator(), ".zap-cache/toolchain", null),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "compiler identity canonicalization preserves OOM" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap", .data = "compiler bytes" }) catch return error.Unexpected;
    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const compiler_path = try std.fs.path.join(allocator, &.{ root, "zap" });
    defer allocator.free(compiler_path);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        canonicalizeCompilerExecutablePath(failing_allocator.allocator(), compiler_path),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "compiler identity digest reports executable stat failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const missing_compiler_path = try std.fs.path.join(allocator, &.{ root, "missing-zap" });
    defer allocator.free(missing_compiler_path);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zap-cache/toolchain" });
    defer allocator.free(cache_dir);

    try std.testing.expectError(
        error.CompilerFileStatUnavailable,
        compilerIdentityDigestForPath(allocator, cache_dir, missing_compiler_path, null),
    );
}

test "compiler identity hash helper reports hash failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const missing_compiler_path = try std.fs.path.join(allocator, &.{ root, "missing-zap" });
    defer allocator.free(missing_compiler_path);

    try std.testing.expectError(
        error.CompilerFileHashUnavailable,
        hashCompilerFileContents(allocator, missing_compiler_path, null),
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
        .invocation_identity = testDigest(1),
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
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };
    try std.testing.expectEqual(ValidationResult.valid, try validateSnapshot(allocator, snapshot, inputs));

    var wrong_cache_key = snapshot;
    wrong_cache_key.cache_key_hex = "different";
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, wrong_cache_key, inputs));

    tmp_dir.dir.deleteFile(std.Options.debug_io, "zap-out/bin/app") catch return error.Unexpected;
    try std.testing.expectEqual(ValidationResult.valid, try validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zap-out/bin/app", .data = "binary" }) catch return error.Unexpected;

    tmp_dir.dir.deleteFile(std.Options.debug_io, ".zap-cache/o/abcd/app") catch return error.Unexpected;
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct Changed {}" }) catch return error.Unexpected;
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;

    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/extra.zap", .data = "pub struct Extra {}" }) catch return error.Unexpected;
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, snapshot, inputs));
    tmp_dir.dir.deleteFile(std.Options.debug_io, "lib/extra.zap") catch return error.Unexpected;

    var missing_dsym = snapshot;
    missing_dsym.debug_symbols_required = true;
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, missing_dsym, inputs));

    var env_mismatch = snapshot;
    env_mismatch.env_vars = &bad_env;
    try std.testing.expectEqual(ValidationResult.miss, try validateSnapshot(allocator, env_mismatch, inputs));
}

test "snapshot validation propagates cached artifact access failures" {
    const allocator = std.testing.allocator;

    const too_long_prefix = try allocator.alloc(u8, std.fs.max_path_bytes + 1);
    defer allocator.free(too_long_prefix);
    @memset(too_long_prefix, 'a');
    const cached_artifact_path = try std.fmt.allocPrint(allocator, "{s}/abcd/app", .{too_long_prefix});
    defer allocator.free(cached_artifact_path);

    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .debug_symbols_required = false,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };

    try std.testing.expectError(error.NameTooLong, validateSnapshot(allocator, snapshot, inputs));
}

test "snapshot validation propagates directory fingerprint allocation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);
    const dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "lib" });
    defer allocator.free(dir_path);

    const directories = [_]DirectoryFingerprint{.{
        .path = dir_path,
        .recursive = false,
        .present = true,
        .listing_hash = 0,
    }};
    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .directories = &directories,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        validateSnapshot(failing_allocator.allocator(), snapshot, inputs),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "snapshot validation propagates env fingerprint allocation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);

    const env_vars = [_]EnvFingerprint{.{
        .name = "ZAP_SNAPSHOT_VALIDATION_OOM_TEST",
        .present = false,
        .value_hash = 0,
    }};
    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .env_vars = &env_vars,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        validateSnapshot(failing_allocator.allocator(), snapshot, inputs),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "snapshot validation propagates glob fingerprint allocation failures" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, ".zap-cache/o/abcd") catch return error.Unexpected;
    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = ".zap-cache/o/abcd/app", .data = "binary" }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "lib/app.zap", .data = "pub struct App {}" }) catch return error.Unexpected;

    const tmp_path = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(tmp_path);
    const cached_artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, ".zap-cache/o/abcd/app" });
    defer allocator.free(cached_artifact_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "zap-out/bin/app" });
    defer allocator.free(output_path);
    const glob_pattern = try std.fs.path.join(allocator, &.{ tmp_path, "lib/*.zap" });
    defer allocator.free(glob_pattern);

    const globs = [_]GlobFingerprint{.{
        .pattern = glob_pattern,
        .result_hash = 0,
    }};
    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(1),
        .cache_key_hex = "abcd",
        .cached_artifact_path = cached_artifact_path,
        .output_path = output_path,
        .kind = .bin,
        .debug_symbols_required = false,
        .globs = &globs,
    };
    const inputs: ValidationInputs = .{
        .invocation_identity = testDigest(1),
        .snapshot_mtime_nanos = std.math.maxInt(i128),
    };

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        validateSnapshot(failing_allocator.allocator(), snapshot, inputs),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "snapshot serialization preserves an opt-in build pipeline" {
    const allocator = std.testing.allocator;

    const run_args = [_][]const u8{ "--only", "math" };
    const steps = [_]PipelineStep{
        .compile,
        .{ .run = .{
            .args = &run_args,
            .forward_args = true,
        } },
    };
    const snapshot: Snapshot = .{
        .invocation_identity = testDigest(99),
        .cache_key_hex = "abcd",
        .cached_artifact_path = ".zap-cache/o/abcd/app",
        .output_path = "zap-out/bin/app",
        .kind = .bin,
        .debug_symbols_required = false,
        .pipeline = .{ .steps = &steps },
    };

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try serializeInto(allocator, &bytes, snapshot);

    var restored = try deserialize(allocator, bytes.items);
    defer restored.deinit(allocator);

    const pipeline = restored.pipeline orelse return error.ExpectedPipeline;
    try std.testing.expectEqual(@as(usize, 2), pipeline.steps.len);
    try std.testing.expect(pipeline.steps[0] == .compile);
    try std.testing.expect(pipeline.steps[1] == .run);
    try std.testing.expectEqualStrings("--only", pipeline.steps[1].run.args[0]);
    try std.testing.expectEqualStrings("math", pipeline.steps[1].run.args[1]);
    try std.testing.expect(pipeline.steps[1].run.forward_args);
}

fn exerciseReadPipelineAllocationFailures(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var reader: Reader = .{ .bytes = bytes };
    const pipeline = try readPipeline(allocator, &reader);
    defer freePipeline(allocator, pipeline);

    try std.testing.expectEqual(@as(usize, 1), pipeline.steps.len);
    try std.testing.expect(pipeline.steps[0] == .run);
    try std.testing.expectEqualStrings("--only", pipeline.steps[0].run.args[0]);
}

test "P4J2: readPipeline frees read arg when args append fails" {
    const allocator = std.testing.allocator;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try appendInt(allocator, u32, &bytes, 1);
    try appendInt(allocator, u8, &bytes, 2);
    try appendBool(allocator, &bytes, false);
    try appendInt(allocator, u32, &bytes, 1);
    try appendString(allocator, &bytes, "--only");

    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseReadPipelineAllocationFailures,
        .{bytes.items},
    );
}

fn exerciseCollectZigLibRecordsAllocationFailures(
    allocator: std.mem.Allocator,
    zig_lib_dir: []const u8,
) !void {
    const records = try collectZigLibRecords(allocator, zig_lib_dir, false, null);
    defer freeZigLibRecords(allocator, records);

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expect(recordsAreStrictlySorted(records));
}

test "P4J2: collectZigLibRecords frees duplicated record paths when append fails" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "zig-lib/std") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "zig-lib/std/start.zig",
        .data = "pub const start = true;",
    }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "zig-lib/build_runner.zig",
        .data = "pub fn main() void {}",
    }) catch return error.Unexpected;

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const zig_lib_dir = try std.fs.path.join(allocator, &.{ root, "zig-lib" });
    defer allocator.free(zig_lib_dir);

    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseCollectZigLibRecordsAllocationFailures,
        .{zig_lib_dir},
    );
}

fn exerciseHashDirectoryListingAllocationFailures(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !void {
    const shallow_hash = try hashDirectoryListing(allocator, dir_path, false);
    const recursive_hash = try hashDirectoryListing(allocator, dir_path, true);

    try std.testing.expect(shallow_hash != recursive_hash);
}

test "P4J2: hashDirectoryListing frees duplicated entry paths when append fails" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.createDirPath(std.Options.debug_io, "lib/nested") catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "lib/app.zap",
        .data = "pub struct App {}",
    }) catch return error.Unexpected;
    tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "lib/nested/extra.zap",
        .data = "pub struct Extra {}",
    }) catch return error.Unexpected;

    const root = tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator) catch return error.Unexpected;
    defer allocator.free(root);
    const dir_path = try std.fs.path.join(allocator, &.{ root, "lib" });
    defer allocator.free(dir_path);

    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseHashDirectoryListingAllocationFailures,
        .{dir_path},
    );
}
