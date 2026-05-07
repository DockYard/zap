const std = @import("std");
const builtin = @import("builtin");

/// Read an environment variable for a runtime-known name. The runtime
/// can't `@import("env.zig")` because runtime.zig is injected into Zap
/// binaries as standalone source — it has no sibling files in the
/// emission cache. Mirrors `src/env.zig`'s helper for the runtime side.
fn envGetRuntime(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z: [*:0]const u8 = buf[0..name.len :0];
    const ptr = std.c.getenv(name_z) orelse return null;
    return std.mem.span(ptr);
}

const STDOUT_FD = std.posix.STDOUT_FILENO;
const STDERR_FD = std.posix.STDERR_FILENO;
const STDIN_FD = std.posix.STDIN_FILENO;

// Well-known atom IDs — must match the registration order in initGlobalAtomTable
// and AtomTable.init: nil=0, true=1, false=2, ok=3, error=4, cont=5, halt=6, done=7
pub const ATOM_CONT: u32 = 5;
pub const ATOM_HALT: u32 = 6;
pub const ATOM_DONE: u32 = 7;

fn posixWrite(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes[written..].len);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

fn posixRead(fd: std.posix.fd_t, buf: []u8) usize {
    return std.posix.read(fd, buf) catch 0;
}

// ============================================================
// Buffered stdout
//
// Every "write a single byte / small chunk to stdout" path used to
// hit `std.c.write(1, …)` directly; for byte-streamed output (e.g.
// the `mandelbrot` benchmark, which writes ~64 M bytes at N=8000)
// that's one syscall per byte. Adding a 64 KiB user-space buffer
// turns it into one syscall per ~64 KiB, matching the cost shape
// of libc's FILE buffer for stdout in C / Rust / Go / OCaml.
//
// Single-threaded by design — the buffer is a process-global byte
// array. Zap programs are single-threaded today; if that changes,
// guarding `stdout_buf_pos` with a mutex is the only addition
// needed (the buffer body has no aliasing concerns).
//
// `flushStdoutBuf()` is invoked:
//   * automatically at process exit via `atexit` (registered
//     lazily on first write);
//   * before every `gets()` so prompts ship before the read blocks;
//   * before every stderr write so error messages don't appear
//     out of order with respect to in-flight stdout content.
// All stderr writes still bypass the buffer — errors must be
// observable even if the program crashes mid-buffer.
const STDOUT_BUF_SIZE: usize = 64 * 1024;
var stdout_buf: [STDOUT_BUF_SIZE]u8 = undefined;
var stdout_buf_pos: usize = 0;
var stdout_atexit_registered: bool = false;

fn flushStdoutBuf() void {
    if (stdout_buf_pos == 0) return;
    var written: usize = 0;
    while (written < stdout_buf_pos) {
        const remaining = stdout_buf_pos - written;
        const rc = std.c.write(STDOUT_FD, stdout_buf[written..].ptr, remaining);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
    stdout_buf_pos = 0;
}

fn stdoutAtexitFlush() callconv(.c) void {
    flushStdoutBuf();
}

// `std.c.atexit` isn't part of the public `std.c` surface in Zig
// 0.16; declare the libc symbol directly. Zap binaries link libc
// unconditionally (`main.zig` builds with `link_libc = true`).
extern "c" fn atexit(handler: *const fn () callconv(.c) void) c_int;

fn ensureStdoutAtexit() void {
    if (stdout_atexit_registered) return;
    stdout_atexit_registered = true;
    _ = atexit(stdoutAtexitFlush);
}

/// Write a slice of bytes to the buffered stdout, flushing once when
/// the slice is larger than the remaining buffer space. Slices
/// larger than the whole buffer bypass the buffer entirely (one
/// syscall) after flushing what was already pending — matches libc's
/// behaviour for over-buffer writes and avoids splitting a single
/// large user request across multiple syscalls when the buffer
/// wouldn't add value.
fn stdoutBufferedWrite(bytes: []const u8) void {
    ensureStdoutAtexit();
    if (bytes.len >= STDOUT_BUF_SIZE) {
        flushStdoutBuf();
        posixWrite(STDOUT_FD, bytes);
        return;
    }
    if (bytes.len > STDOUT_BUF_SIZE - stdout_buf_pos) {
        flushStdoutBuf();
    }
    @memcpy(stdout_buf[stdout_buf_pos..][0..bytes.len], bytes);
    stdout_buf_pos += bytes.len;
}

fn stdoutBufferedWriteByte(byte: u8) void {
    ensureStdoutAtexit();
    if (stdout_buf_pos == STDOUT_BUF_SIZE) flushStdoutBuf();
    stdout_buf[stdout_buf_pos] = byte;
    stdout_buf_pos += 1;
}

/// Flush stdout, then write to stderr unbuffered. Use this for any
/// runtime panic / halt / error path so an error message doesn't
/// race ahead of buffered stdout output the user already produced —
/// particularly important when the program is about to abort and
/// `atexit` may not run.
fn stderrWriteFlushed(bytes: []const u8) void {
    flushStdoutBuf();
    posixWrite(STDERR_FD, bytes);
}

/// Platform-portable access to process argv (replacement for removed getArgv() in 0.16).
pub fn getArgv() []const [*:0]const u8 {
    if (comptime builtin.os.tag == .macos) {
        const c = struct {
            extern "c" fn _NSGetArgc() *c_int;
            extern "c" fn _NSGetArgv() *[*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c._NSGetArgc().*);
        const argv = c._NSGetArgv().*;
        return argv[0..argc];
    } else if (comptime builtin.os.tag == .linux) {
        // On Linux, use /proc/self/cmdline as fallback or linker-provided __libc_argv.
        const c = struct {
            extern "c" var __libc_argc: c_int;
            extern "c" var __libc_argv: [*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c.__libc_argc);
        return c.__libc_argv[0..argc];
    } else {
        return &.{};
    }
}

/// Write formatted output to stdout through the buffered writer.
fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdoutBufferedWrite(msg);
}

/// Write raw bytes to stdout through the buffered writer.
fn stdoutWrite(bytes: []const u8) void {
    stdoutBufferedWrite(bytes);
}

// ============================================================
// Arena Allocator
// Uses std.heap.ArenaAllocator backed by page_allocator.
// Thread-safe and lock-free in Zig 0.16. Init is cheap (no
// allocation until first use), so no lazy initialization needed.
// ============================================================

var runtime_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Terminal mode state for raw/normal switching
var original_termios: std.posix.termios = undefined;
var raw_mode_saved: bool = false;

fn bumpAlloc(len: usize) []u8 {
    // Use alignedAlloc with pointer alignment (8 on 64-bit) so that bump-allocated
    // memory can safely be cast to pointer types via @ptrCast(@alignCast(...)).
    const aligned = runtime_arena.allocator().alignedAlloc(u8, .@"8", len) catch return &.{};
    return @alignCast(aligned);
}

fn bumpAllocSlice(comptime T: type, len: usize) []T {
    return runtime_arena.allocator().alloc(T, len) catch return &.{};
}

pub fn resetAllocator() void {
    runtime_arena.reset(.retain_capacity);
}

// ============================================================
// Zap Runtime Support Struct (spec §21, §31.7)
//
// Provides runtime types for generated Zig code:
//   - Arc(T)       — generic ARC wrapper with atomic refcount
//   - Atom         — interned atom representation
//   - Closure      — fat pointer for function values
//   - ZapAllocator — allocator plumbing
//   - List(T)      — persistent list
//   - Map(K, V)    — persistent map (HAMT-based)
//   - String       — owned string with length
// ============================================================

// ============================================================
// Map workload instrumentation comptime flag
//
// `instrument_map` is a comptime-known boolean that gates the entire
// Map(K, V) instrumentation overlay (see `docs/map-workload-
// instrumentation-plan.md`). When false, every hook compiles to nothing
// and the runtime is bit-identical to the un-instrumented build. When
// true, allocMap/retain/release/put/delete/merge/get hooks emit per-
// instance and per-lineage records, and an `atexit` handler writes a
// JSON summary to `$ZAP_INSTRUMENT_OUT` (default
// `./map-instrumentation.json`).
//
// Resolution order:
//   1. The build-system root (the compiler binary built by `zig build`)
//      can override the flag by declaring
//      `pub const zap_runtime_instrument_map_override: bool = ...;`.
//      `src/root.zig` re-exports the `-Dinstrument-map` build option
//      under that name, so a `zig build -Dinstrument-map=true` flips
//      the flag on for the host test suite.
//   2. The embedded-runtime root (a Zap user binary) does not declare
//      that override, so the flag falls back to the source-level
//      `INSTRUMENT_MAP_DEFAULT` constant. `compiler.zig` rewrites that
//      default at source-registration time when the host compiler was
//      itself built with `-Dinstrument-map=true`, so user binaries
//      inherit the flag from the toolchain build.
// ============================================================

const INSTRUMENT_MAP_DEFAULT: bool = false;

pub const instrument_map: bool = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zap_runtime_instrument_map_override")) {
        break :blk @as(bool, root.zap_runtime_instrument_map_override);
    }
    break :blk INSTRUMENT_MAP_DEFAULT;
};

// ============================================================
// ARC — Atomic Reference Counting (spec §31.4)
// ============================================================

pub const ArcHeader = struct {
    ref_count: std.atomic.Value(u32),

    pub fn init() ArcHeader {
        return .{ .ref_count = std.atomic.Value(u32).init(1) };
    }

    pub fn retain(self: *ArcHeader) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *ArcHeader) bool {
        const prev = self.ref_count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            return true; // caller should free
        }
        return false;
    }

    pub fn count(self: *const ArcHeader) u32 {
        return self.ref_count.load(.acquire);
    }

    /// Non-generic retain for use from ZIR — takes an opaque pointer to an ArcHeader.
    pub fn retainOpaque(ptr: *anyopaque) void {
        const header: *ArcHeader = @ptrCast(@alignCast(ptr));
        header.retain();
    }

    /// Non-generic release for use from ZIR — returns true if the caller should free.
    pub fn releaseOpaque(ptr: *anyopaque) bool {
        const header: *ArcHeader = @ptrCast(@alignCast(ptr));
        return header.release();
    }
};

pub fn Arc(comptime T: type) type {
    return struct {
        const Self = @This();

        const Inner = struct {
            header: ArcHeader,
            value: T,
        };

        ptr: *Inner,

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .header = ArcHeader.init(),
                .value = value,
            };
            return .{ .ptr = inner };
        }

        pub fn retain(self: Self) Self {
            self.ptr.header.retain();
            return self;
        }

        pub fn release(self: Self, allocator: std.mem.Allocator) void {
            if (self.ptr.header.release()) {
                allocator.destroy(self.ptr);
            }
        }

        pub fn get(self: Self) *T {
            return &self.ptr.value;
        }

        pub fn getConst(self: Self) *const T {
            return &self.ptr.value;
        }

        pub fn refCount(self: Self) u32 {
            return self.ptr.header.count();
        }
    };
}

// ============================================================
// ARC instrumentation counters (Phase 1 of the k-nucleotide RSS
// roadmap — see `docs/k-nucleotide-rss-gap-implementation-plan.md`).
//
// Pure measurement infrastructure: every ARC retain / release path
// in the runtime increments one of these counters, and every pool
// tracks its own per-thread high-water-mark of simultaneously-live
// cells. The Phase 4-5 ownership pass will later populate
// `arc_consumes_total` and `arc_return_elisions_total`; for now they
// stay zero so callers (tests, stat dumps, future passes) have stable
// hooks to drop into.
//
// Setting `ZAP_ARC_STATS=1` in the environment causes the program to
// dump these counters on exit through an `atexit` hook. The dump
// reports global counters, then per-pool registered stats — pool name
// (Zig type name) and per-pool live high-water-mark. Pool HWM is the
// load-bearing signal for the RSS gap: peak resident set ≈ Σ pool HWM,
// regardless of total alloc count, so a bounded HWM under tail
// recursion proves the leak has been closed.
//
// Threading: counters are plain `u64` — Zap is single-threaded today.
// If concurrency lands, swap each `u64` for `std.atomic.Value(u64)`.
// ============================================================

pub var arc_retains_total: u64 = 0;
pub var arc_releases_total: u64 = 0;
pub var arc_consumes_total: u64 = 0;
pub var arc_return_elisions_total: u64 = 0;
/// Number of dense-Map mutating calls (put/delete) that took the
/// rc-1 fast path (mutated the receiver in place).
pub var dense_map_rc1_fast_path_total: u64 = 0;
/// Total dense-Map mutating calls.
pub var dense_map_mut_calls_total: u64 = 0;

/// Per-pool live-cell statistics. Each pool wrapper (e.g.
/// `ArcRuntime.ArcPool(T)`, `MArrayOf(T).InnerPool`, `Map(K,V).SelfPool`)
/// owns one of these and registers it with `pool_stats_head` on first
/// allocation. The registration is idempotent: a `registered` flag
/// guarantees a pool is linked exactly once even though `note*`
/// helpers run on every allocation/deallocation.
pub const PoolStats = struct {
    name: []const u8,
    live: u64 = 0,
    high_water: u64 = 0,
    registered: bool = false,
    next: ?*PoolStats = null,

    pub fn noteAllocation(self: *PoolStats) void {
        registerIfNeeded(self);
        self.live += 1;
        if (self.live > self.high_water) self.high_water = self.live;
    }

    pub fn noteDeallocation(self: *PoolStats) void {
        // The decrement is unconditional; pool destroy is invoked
        // exactly once per cell by the runtime, mirroring `create`.
        if (self.live > 0) self.live -= 1;
    }
};

var pool_stats_head: ?*PoolStats = null;

fn registerIfNeeded(stats: *PoolStats) void {
    if (stats.registered) return;
    stats.registered = true;
    stats.next = pool_stats_head;
    pool_stats_head = stats;
}

/// Snapshot a single pool's stats line. Tests / external callers can
/// walk `pool_stats_head` directly to assert HWM bounds without
/// stringifying the whole dump. The accessor is deliberately a free
/// function so future locking can be added in one place.
pub fn iteratePoolStats() ?*PoolStats {
    return pool_stats_head;
}

/// Print the global ARC counters and every registered pool's
/// high-water-mark through `write_line`. The callback indirection lets
/// the same dump routine target stderr (the atexit hook) and arbitrary
/// future sinks (test capture buffers, log files) without depending on
/// the std.Io writer interface — this file is shared between the
/// compiler-host process and the Zap-binary runtime, and the latter
/// must avoid pulling in any std.Io infrastructure that the embedded
/// build doesn't link.
pub fn dumpArcStats(write_line: *const fn ([]const u8) void) void {
    var line_buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] retains_total={d} releases_total={d} consumes_total={d} return_elisions_total={d}\n", .{
        arc_retains_total,
        arc_releases_total,
        arc_consumes_total,
        arc_return_elisions_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] dense_map_mut_calls_total={d} dense_map_rc1_fast_path_total={d}\n", .{
        dense_map_mut_calls_total,
        dense_map_rc1_fast_path_total,
    })) |line| {
        write_line(line);
    } else |_| {}
    var cursor = pool_stats_head;
    while (cursor) |stats| : (cursor = stats.next) {
        if (std.fmt.bufPrint(&line_buf, "[zap-arc-stats] pool={s} live={d} high_water={d}\n", .{
            stats.name, stats.live, stats.high_water,
        })) |line| {
            write_line(line);
        } else |_| {}
    }
}

fn writeLineToStderr(bytes: []const u8) void {
    posixWrite(STDERR_FD, bytes);
}

/// Convenience wrapper that writes the dump to stderr. Used by the
/// `atexit` hook so stats survive even if stdout was redirected to a
/// pipe that closed early.
pub fn dumpArcStatsToStderr() void {
    flushStdoutBuf();
    dumpArcStats(writeLineToStderr);
}

fn arcStatsAtexit() callconv(.c) void {
    dumpArcStatsToStderr();
}

var arc_stats_atexit_registered: bool = false;

/// Register the `ZAP_ARC_STATS=1` exit hook on first pool registration.
/// Cheap to call repeatedly — the boolean guard short-circuits after
/// the first invocation. The env-var check is done once and cached
/// implicitly through the registered flag.
fn ensureArcStatsAtexit() void {
    if (arc_stats_atexit_registered) return;
    arc_stats_atexit_registered = true;
    const value = envGetRuntime("ZAP_ARC_STATS") orelse return;
    if (value.len == 0 or value[0] == '0') return;
    _ = atexit(arcStatsAtexit);
}

// ============================================================
// Map workload instrumentation runtime state
//
// The instrumentation state lives in this module rather than inside
// `Map(K, V)` so it is shared across every `(K, V)` instantiation. All
// records are keyed by Map cell pointer (cast to `usize`) and are
// independent of the key/value type — the analyzer only cares about
// allocation lifetimes, refcount transitions, and operation counts.
//
// The state must NOT use `runtime.zig::Map` itself (that would recurse
// infinitely through the very hooks we're emitting). It uses
// `std.AutoHashMap` backed by `std.heap.page_allocator` directly.
//
// All public entry points are no-ops at the call site when
// `instrument_map == false` because the call sites are themselves
// gated by `comptime if (instrument_map)`. The functions still exist
// in both build modes so call sites compile, but the bodies short-
// circuit immediately when the flag is false.
// ============================================================

/// Per-Map-instance lifetime record. Populated incrementally as the
/// cell is allocated, retained, mutated, queried, and finally released.
/// At release time the record is finalised, classified into S/W/V, and
/// either appended to the in-memory finalised list or streamed to the
/// optional JSONL detail file.
pub const MapInstanceRecord = struct {
    instance_id: u64,
    lineage_id: u64,
    parent_instance_id: u64,
    alloc_size: u32,
    creation_callsite: u64,
    puts: u32,
    deletes: u32,
    merges: u32,
    gets: u32,
    peak_strong_count: u32,
    had_share_event: bool,
    had_post_share_mutation: bool,
    alloc_time_ns: u64,
    release_time_ns: u64,
    size_at_release: u32,
    /// Class assigned at release time. 'S' (single — never shared),
    /// 'W' (working-dict — shared at some point but never mutated
    /// post-share), or 'V' (versioned — shared and post-share-mutated).
    class: u8,
};

/// Per-lineage running aggregate. A lineage groups every Map instance
/// that derived from one another via `put`/`delete`/`merge`. The
/// `live_count` rises on alloc within the lineage and falls on
/// release; `peak_concurrent_versions` records the historical maximum
/// of `live_count`.
pub const MapLineageState = struct {
    lineage_id: u64,
    live_count: u32,
    peak_concurrent_versions: u32,
    instance_count: u32,
    total_node_clones: u64,
};

const InstrumentationState = struct {
    initialised: bool = false,
    program_start_ns: u64 = 0,
    next_instance_id: u64 = 1,
    next_lineage_id: u64 = 1,
    /// Active per-instance records — one entry while the cell is alive,
    /// removed at release-zero.
    active: std.AutoHashMap(usize, MapInstanceRecord) = undefined,
    /// Finalised per-instance records (released cells). The summary
    /// emitter walks this list at exit; the optional detail-file
    /// emitter streams each record as it is added.
    finalised: std.ArrayListUnmanaged(MapInstanceRecord) = .empty,
    /// Per-lineage state. Lineages persist for the lifetime of the
    /// process so the lineage_id assigned in `allocMap` remains valid
    /// for every derived instance.
    lineages: std.AutoHashMap(u64, MapLineageState) = undefined,
    /// Thread-local "current parent" used to plumb lineage and parent
    /// instance ids from a mutation entry point (`put`/`delete`/
    /// `merge`) down to the fresh `allocMap` call without threading a
    /// new parameter through every internal helper. The mutation entry
    /// stashes the input map's id pair before invoking allocMap-bound
    /// code paths and clears it on return. Single-threaded today; if
    /// Zap goes multi-threaded the field becomes per-thread.
    parent_lineage_id: u64 = 0,
    parent_instance_id: u64 = 0,
    parent_active: bool = false,
    /// Counts release records where the input had `had_share_event`
    /// AND a post-share mutation was observed. Sum of per-instance
    /// `had_post_share_mutation` flags, materialised eagerly so the
    /// summary emitter does not re-walk every record.
    post_share_mutation_count: u64 = 0,
    /// Aggregate node-clone count across every lineage; mirrors the
    /// per-lineage `total_node_clones` so the summary can report a
    /// single workload-level number.
    total_node_clones: u64 = 0,
    /// Top-N callsite tally. Allocated lazily during the first record
    /// finalisation; key is the return-address fingerprint captured at
    /// `allocMap`, value is the total count of instances created at
    /// that site.
    callsite_counts: std.AutoHashMap(u64, u64) = undefined,
    atexit_registered: bool = false,
    /// Posix file descriptor for the optional `map-instrumentation.jsonl`
    /// detail file, or `-1` when no detail file is open. We use a raw
    /// fd rather than `std.fs.File` because the embedded user-binary
    /// runtime context exposes only a restricted std surface (the rest
    /// of `runtime.zig` follows the same pattern — see `File.write` at
    /// the bottom of this file).
    detail_fd: i32 = -1,
    detail_attempted: bool = false,
};

var instrumentation_state: InstrumentationState = .{};

fn instrumentationAllocator() std.mem.Allocator {
    // Page allocator avoids any chance of recursive instrumentation if
    // a future allocator integration goes through Map(K, V). Maps used
    // here are small (one entry per live cell), so the per-allocation
    // overhead is acceptable for measurement infrastructure.
    return std.heap.page_allocator;
}

fn instrumentationNowNs() u64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const total: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    if (total < 0) return 0;
    return @intCast(total);
}

fn ensureInstrumentationInit() void {
    if (!instrument_map) return;
    if (instrumentation_state.initialised) return;
    const alloc = instrumentationAllocator();
    instrumentation_state.active = std.AutoHashMap(usize, MapInstanceRecord).init(alloc);
    instrumentation_state.lineages = std.AutoHashMap(u64, MapLineageState).init(alloc);
    instrumentation_state.callsite_counts = std.AutoHashMap(u64, u64).init(alloc);
    instrumentation_state.program_start_ns = instrumentationNowNs();
    instrumentation_state.initialised = true;
    if (!instrumentation_state.atexit_registered) {
        instrumentation_state.atexit_registered = true;
        _ = atexit(mapInstrumentationAtexit);
    }
    if (!instrumentation_state.detail_attempted) {
        instrumentation_state.detail_attempted = true;
        const detail_var = envGetRuntime("ZAP_INSTRUMENT_DETAIL");
        if (detail_var) |v| {
            if (v.len != 0 and v[0] != '0') {
                const path_z = std.posix.toPosixPath("map-instrumentation.jsonl") catch null;
                if (path_z) |pz| {
                    const fd = std.c.open(&pz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
                    if (fd >= 0) {
                        instrumentation_state.detail_fd = fd;
                    }
                }
            }
        }
    }
}

fn mapInstrumentationStartLineage() u64 {
    const id = instrumentation_state.next_lineage_id;
    instrumentation_state.next_lineage_id += 1;
    const entry = instrumentation_state.lineages.getOrPut(id) catch return id;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .lineage_id = id,
            .live_count = 0,
            .peak_concurrent_versions = 0,
            .instance_count = 0,
            .total_node_clones = 0,
        };
    }
    return id;
}

fn mapInstrumentationLineageBumpLive(lineage_id: u64) void {
    const entry = instrumentation_state.lineages.getOrPut(lineage_id) catch return;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .lineage_id = lineage_id,
            .live_count = 0,
            .peak_concurrent_versions = 0,
            .instance_count = 0,
            .total_node_clones = 0,
        };
    }
    entry.value_ptr.live_count += 1;
    entry.value_ptr.instance_count += 1;
    if (entry.value_ptr.live_count > entry.value_ptr.peak_concurrent_versions) {
        entry.value_ptr.peak_concurrent_versions = entry.value_ptr.live_count;
    }
}

fn mapInstrumentationLineageDropLive(lineage_id: u64) void {
    if (instrumentation_state.lineages.getPtr(lineage_id)) |state| {
        if (state.live_count > 0) state.live_count -= 1;
    }
}

fn mapInstrumentationLineageBumpClones(lineage_id: u64, n: u64) void {
    if (instrumentation_state.lineages.getPtr(lineage_id)) |state| {
        state.total_node_clones += n;
    }
    instrumentation_state.total_node_clones += n;
}

/// Record a fresh Map cell allocation. Returns the new instance_id so
/// the caller (the per-(K,V) `allocMap` wrapper) can stamp it on the
/// cell record, but the record itself is keyed by cell pointer.
pub fn mapInstrumentationOnAlloc(
    cell_ptr: usize,
    alloc_size: u32,
    creation_callsite: u64,
) void {
    if (!instrument_map) return;
    ensureInstrumentationInit();
    const instance_id = instrumentation_state.next_instance_id;
    instrumentation_state.next_instance_id += 1;

    const lineage_id = if (instrumentation_state.parent_active)
        instrumentation_state.parent_lineage_id
    else
        mapInstrumentationStartLineage();
    const parent_instance_id = if (instrumentation_state.parent_active)
        instrumentation_state.parent_instance_id
    else
        0;

    mapInstrumentationLineageBumpLive(lineage_id);

    const record: MapInstanceRecord = .{
        .instance_id = instance_id,
        .lineage_id = lineage_id,
        .parent_instance_id = parent_instance_id,
        .alloc_size = alloc_size,
        .creation_callsite = creation_callsite,
        .puts = 0,
        .deletes = 0,
        .merges = 0,
        .gets = 0,
        .peak_strong_count = 1,
        .had_share_event = false,
        .had_post_share_mutation = false,
        .alloc_time_ns = instrumentationNowNs(),
        .release_time_ns = 0,
        .size_at_release = 0,
        .class = 'S',
    };
    instrumentation_state.active.put(cell_ptr, record) catch {};
}

/// Hook invoked from `Map(K, V).retain` after the refcount bump. The
/// caller passes the post-bump strong count so the hook does not have
/// to re-read the atomic.
///
/// `Map.retain` is reached through two paths. Container-style
/// retains (List cons head retain, Map entry storage, struct field
/// assignment) route through `ArcRuntime.retainAnyPersistent`, which
/// dispatches to the type's `retain` method and therefore reaches
/// this hook. Transient borrow-pass retains emitted by the IR
/// verifier (the `share_value mode=retain` lowering paired with a
/// matching post-call release) route through `ArcRuntime.retainAny`,
/// which performs a direct header bump and never reaches this hook.
/// That split is what lets the Map workload classifier distinguish a
/// genuine concurrent owner (true sharing event) from temporary
/// borrow plumbing that resolves before the next mutation.
pub fn mapInstrumentationOnRetain(cell_ptr: usize, new_strong_count: u32) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        if (new_strong_count > record.peak_strong_count) {
            record.peak_strong_count = new_strong_count;
        }
        if (new_strong_count >= 2 and !record.had_share_event) {
            record.had_share_event = true;
        }
    }
}

/// Hook invoked from `Map(K, V).release` immediately before the cell
/// is destroyed (after the zero-transition has been confirmed). The
/// caller passes the final size so the hook does not re-walk the
/// trie. Classifies the record into S/W/V and moves it to the
/// finalised list (and the optional detail file).
pub fn mapInstrumentationOnRelease(cell_ptr: usize, size_at_release: u32) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    const removed = instrumentation_state.active.fetchRemove(cell_ptr) orelse return;
    var record = removed.value;
    record.size_at_release = size_at_release;
    record.release_time_ns = instrumentationNowNs();
    record.class = if (!record.had_share_event)
        @as(u8, 'S')
    else if (record.had_post_share_mutation)
        @as(u8, 'V')
    else
        @as(u8, 'W');
    if (record.had_post_share_mutation) {
        instrumentation_state.post_share_mutation_count += 1;
    }
    mapInstrumentationLineageDropLive(record.lineage_id);

    // Tally callsite count.
    const callsite_entry = instrumentation_state.callsite_counts.getOrPut(record.creation_callsite) catch null;
    if (callsite_entry) |entry| {
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    instrumentation_state.finalised.append(instrumentationAllocator(), record) catch {};
    if (instrumentation_state.detail_fd >= 0) {
        writeRecordJsonLine(instrumentation_state.detail_fd, record) catch {};
    }
}

/// Hook invoked from `put`/`delete`/`merge`. Bumps the appropriate
/// per-instance counter on the *input* map. Returns the input
/// instance_id so the caller can plumb it as `parent_instance_id`
/// into the impending allocMap call via the thread-local context.
pub fn mapInstrumentationBumpMutation(
    cell_ptr: usize,
    op: enum { put, delete, merge },
) struct { instance_id: u64, lineage_id: u64, had_share_event: bool } {
    if (!instrument_map) return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
    if (!instrumentation_state.initialised) return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        switch (op) {
            .put => record.puts += 1,
            .delete => record.deletes += 1,
            .merge => record.merges += 1,
        }
        return .{
            .instance_id = record.instance_id,
            .lineage_id = record.lineage_id,
            .had_share_event = record.had_share_event,
        };
    }
    return .{ .instance_id = 0, .lineage_id = 0, .had_share_event = false };
}

/// After a mutation produces a fresh derived map at `result_ptr`,
/// mark the *input* map as having had a post-share mutation iff the
/// input was already classified as having had a share event and the
/// result is a distinct cell. Called from `put`/`delete`/`merge`
/// after the new cell pointer is known. The share-event flag is set
/// only by `mapInstrumentationOnRetain` for retains that route
/// through `retainAnyPersistent` — transient borrow-pass retains
/// (`retainAny`) never flip the flag, so a "post-share mutation"
/// here means a genuine concurrent owner observed the older
/// version.
pub fn mapInstrumentationNotePostShareMutation(input_cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(input_cell_ptr)) |record| {
        if (record.had_share_event and !record.had_post_share_mutation) {
            record.had_post_share_mutation = true;
        }
    }
}

/// Bump the `gets` counter on the receiver map. Called from `get`,
/// `getStr`, `hasKey`, and `size`.
pub fn mapInstrumentationOnGet(cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(cell_ptr)) |record| {
        record.gets += 1;
    }
}

/// Set the thread-local parent context before invoking allocMap from
/// inside a `put`/`delete`/`merge`. Pair with
/// `mapInstrumentationClearParent` after allocMap returns. The pair is
/// not nested — the outer mutation is the only owner of the slot.
pub fn mapInstrumentationSetParent(lineage_id: u64, instance_id: u64) void {
    if (!instrument_map) return;
    instrumentation_state.parent_lineage_id = lineage_id;
    instrumentation_state.parent_instance_id = instance_id;
    instrumentation_state.parent_active = true;
}

pub fn mapInstrumentationClearParent() void {
    if (!instrument_map) return;
    instrumentation_state.parent_active = false;
    instrumentation_state.parent_lineage_id = 0;
    instrumentation_state.parent_instance_id = 0;
}

/// Bump the per-lineage clone count. Historical name — invoked by the
/// HAMT path-copy code; kept as a stable instrumentation surface for
/// future allocators that want to flag every internal clone. The dense
/// Map does not call this hook in its current form (cloning is whole-
/// buffer, already counted via `mapInstrumentationOnAlloc`'s lineage
/// `instance_count`); the function stays a no-op-friendly surface for
/// callers that detect a buffer clone.
pub fn mapInstrumentationNoteNodeClone(input_cell_ptr: usize) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    if (instrumentation_state.active.getPtr(input_cell_ptr)) |record| {
        mapInstrumentationLineageBumpClones(record.lineage_id, 1);
    }
}

fn writeRecordJsonLine(fd: i32, record: MapInstanceRecord) !void {
    var buf: [768]u8 = undefined;
    const class_str: []const u8 = switch (record.class) {
        'S' => "S",
        'W' => "W",
        'V' => "V",
        else => "?",
    };
    const formatted = try std.fmt.bufPrint(&buf,
        "{{\"instance_id\":{d},\"lineage_id\":{d},\"parent_instance_id\":{d}," ++
        "\"alloc_size\":{d},\"creation_callsite\":{d},\"puts\":{d},\"deletes\":{d}," ++
        "\"merges\":{d},\"gets\":{d},\"peak_strong_count\":{d},\"had_share_event\":{},\"had_post_share_mutation\":{}," ++
        "\"alloc_time_ns\":{d},\"release_time_ns\":{d},\"size_at_release\":{d},\"class\":\"{s}\"}}\n",
        .{
            record.instance_id,        record.lineage_id,
            record.parent_instance_id, record.alloc_size,
            record.creation_callsite,  record.puts,
            record.deletes,            record.merges,
            record.gets,               record.peak_strong_count,
            record.had_share_event,    record.had_post_share_mutation,
            record.alloc_time_ns,      record.release_time_ns,
            record.size_at_release,    class_str,
        });
    _ = std.c.write(fd, formatted.ptr, formatted.len);
}

fn classifyHistogramSize(s: u32) usize {
    if (s == 0) return 0;
    if (s <= 7) return 1;
    if (s <= 31) return 2;
    if (s <= 127) return 3;
    if (s <= 1023) return 4;
    return 5;
}

fn classifyConcurrentVersions(p: u32) usize {
    if (p <= 1) return 0;
    if (p == 2) return 1;
    if (p <= 5) return 2;
    if (p <= 20) return 3;
    return 4;
}

fn workloadNameFromArgv0() []const u8 {
    const argv = getArgv();
    if (argv.len == 0) return "unknown";
    const path = std.mem.span(argv[0]);
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex_buf: [8]u8 = undefined;
                    const slc = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{@as(u16, c)}) catch continue;
                    try buf.appendSlice(alloc, slc);
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    try buf.append(alloc, '"');
}

fn renderInstrumentationSummaryJson(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
    const state = &instrumentation_state;
    const records = state.finalised.items;

    var class_counts: [3]u64 = .{ 0, 0, 0 }; // S, W, V
    var size_hist: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
    var versions_hist: [5]u64 = .{ 0, 0, 0, 0, 0 };

    for (records) |rec| {
        const idx: usize = switch (rec.class) {
            'S' => 0,
            'W' => 1,
            'V' => 2,
            else => continue,
        };
        class_counts[idx] += 1;
        size_hist[classifyHistogramSize(rec.size_at_release)] += 1;
    }

    var lineage_class_S: u64 = 0;
    var lineage_class_W: u64 = 0;
    var lineage_class_V: u64 = 0;
    var lin_it = state.lineages.iterator();
    while (lin_it.next()) |entry| {
        versions_hist[classifyConcurrentVersions(entry.value_ptr.peak_concurrent_versions)] += 1;
        // Lineage class — derived from member-instance distribution.
        // S iff exactly one instance and it was class S.
        // V iff any instance class is V.
        // Otherwise W.
        var has_v = false;
        var has_w = false;
        var instance_total: u64 = 0;
        for (records) |rec| {
            if (rec.lineage_id != entry.value_ptr.lineage_id) continue;
            instance_total += 1;
            if (rec.class == 'V') has_v = true;
            if (rec.class == 'W') has_w = true;
        }
        if (instance_total == 0) continue;
        if (has_v) {
            lineage_class_V += 1;
        } else if (has_w or entry.value_ptr.peak_concurrent_versions >= 2) {
            lineage_class_W += 1;
        } else {
            lineage_class_S += 1;
        }
    }

    const total_records: u64 = @intCast(records.len);
    const total_lineages: u64 = state.lineages.count();

    // Sort callsites by count descending.
    const CallsiteEntry = struct { site: u64, count: u64 };
    var callsites: std.ArrayListUnmanaged(CallsiteEntry) = .empty;
    defer callsites.deinit(alloc);
    var cs_it = state.callsite_counts.iterator();
    while (cs_it.next()) |entry| {
        try callsites.append(alloc, .{ .site = entry.key_ptr.*, .count = entry.value_ptr.* });
    }
    std.mem.sort(CallsiteEntry, callsites.items, {}, struct {
        fn lessThan(_: void, a: CallsiteEntry, b: CallsiteEntry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const duration_ns = instrumentationNowNs() - state.program_start_ns;
    const workload = workloadNameFromArgv0();

    try buf.appendSlice(alloc, "{\n  \"workload\": ");
    try writeJsonString(buf, alloc, workload);
    try buf.appendSlice(alloc, ",\n  \"binary\": ");
    {
        const argv = getArgv();
        if (argv.len > 0) {
            try writeJsonString(buf, alloc, std.mem.span(argv[0]));
        } else {
            try buf.appendSlice(alloc, "\"\"");
        }
    }
    var line_buf: [256]u8 = undefined;
    {
        const slc = try std.fmt.bufPrint(&line_buf, ",\n  \"duration_ns\": {d},\n", .{duration_ns});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "  \"summary\": {\n");
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_instances\": {d},\n", .{total_records});
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_lineages\": {d},\n", .{total_lineages});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    \"by_class\": {\n");
    const denom: f64 = if (total_records == 0) 1.0 else @floatFromInt(total_records);
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"S\": {{\"count\": {d}, \"frac\": {d:.4}}},\n", .{ class_counts[0], @as(f64, @floatFromInt(class_counts[0])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"W\": {{\"count\": {d}, \"frac\": {d:.4}}},\n", .{ class_counts[1], @as(f64, @floatFromInt(class_counts[1])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"V\": {{\"count\": {d}, \"frac\": {d:.4}}}\n", .{ class_counts[2], @as(f64, @floatFromInt(class_counts[2])) / denom });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");
    try buf.appendSlice(alloc, "    \"by_lineage_class\": {\n");
    {
        const slc = try std.fmt.bufPrint(&line_buf, "      \"S\": {d},\n      \"W\": {d},\n      \"V\": {d}\n", .{ lineage_class_S, lineage_class_W, lineage_class_V });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    const size_labels = [_][]const u8{ "0", "1-7", "8-31", "32-127", "128-1023", "1024+" };
    try buf.appendSlice(alloc, "    \"size_histogram\": {\n");
    inline for (size_labels, 0..) |label, i| {
        const sep: []const u8 = if (i + 1 < size_labels.len) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      \"{s}\": {d}{s}\n", .{ label, size_hist[i], sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    const ver_labels = [_][]const u8{ "1", "2", "3-5", "6-20", "21+" };
    try buf.appendSlice(alloc, "    \"peak_concurrent_versions_histogram\": {\n");
    inline for (ver_labels, 0..) |label, i| {
        const sep: []const u8 = if (i + 1 < ver_labels.len) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      \"{s}\": {d}{s}\n", .{ label, versions_hist[i], sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    },\n");

    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"post_share_mutation_count\": {d},\n", .{state.post_share_mutation_count});
        try buf.appendSlice(alloc, slc);
    }
    {
        const slc = try std.fmt.bufPrint(&line_buf, "    \"total_node_clones\": {d},\n", .{state.total_node_clones});
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    \"top_callsites_by_instance_count\": [\n");
    const top_n = @min(@as(usize, 20), callsites.items.len);
    for (callsites.items[0..top_n], 0..) |entry, idx| {
        const sep: []const u8 = if (idx + 1 < top_n) "," else "";
        const slc = try std.fmt.bufPrint(&line_buf, "      {{\"site\": \"0x{x}\", \"count\": {d}}}{s}\n", .{ entry.site, entry.count, sep });
        try buf.appendSlice(alloc, slc);
    }
    try buf.appendSlice(alloc, "    ]\n");
    try buf.appendSlice(alloc, "  }\n}\n");
}

fn flushPendingActiveRecords() void {
    // Records still in `active` represent maps whose owners didn't run
    // a release before the program exited (e.g. globals, leaked refs).
    // Finalise them as-is so the summary reflects every observed
    // allocation. Class is computed from the bools as if release just
    // ran, with size_at_release left at 0 (we don't have a Self typed
    // pointer to read total_count from at this layer).
    var it = instrumentation_state.active.iterator();
    while (it.next()) |entry| {
        var record = entry.value_ptr.*;
        record.release_time_ns = instrumentationNowNs();
        record.class = if (!record.had_share_event)
            @as(u8, 'S')
        else if (record.had_post_share_mutation)
            @as(u8, 'V')
        else
            @as(u8, 'W');
        if (record.had_post_share_mutation) {
            instrumentation_state.post_share_mutation_count += 1;
        }
        instrumentation_state.finalised.append(instrumentationAllocator(), record) catch {};
        if (instrumentation_state.detail_fd >= 0) {
            writeRecordJsonLine(instrumentation_state.detail_fd, record) catch {};
        }
    }
    instrumentation_state.active.clearRetainingCapacity();
}

fn mapInstrumentationAtexit() callconv(.c) void {
    if (!instrument_map) return;
    if (!instrumentation_state.initialised) return;
    flushStdoutBuf();
    flushPendingActiveRecords();
    if (instrumentation_state.detail_fd >= 0) {
        _ = std.c.close(instrumentation_state.detail_fd);
        instrumentation_state.detail_fd = -1;
    }
    const out_path = envGetRuntime("ZAP_INSTRUMENT_OUT") orelse "map-instrumentation.json";
    const out_path_z = std.posix.toPosixPath(out_path) catch return;

    const alloc = instrumentationAllocator();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    renderInstrumentationSummaryJson(&buf, alloc) catch return;

    const fd = std.c.open(&out_path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < buf.items.len) {
        const n = std.c.write(fd, buf.items[written..].ptr, buf.items[written..].len);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

/// Test-only helper: returns a copy of the finalised record matching
/// `cell_ptr`, or null. Walks the finalised list linearly (O(n)) — only
/// the unit tests use this, and they exit immediately after asserting.
pub fn mapInstrumentationFindFinalised(cell_ptr_used_at_alloc: usize, instance_id: u64) ?MapInstanceRecord {
    _ = cell_ptr_used_at_alloc;
    if (!instrument_map) return null;
    if (!instrumentation_state.initialised) return null;
    for (instrumentation_state.finalised.items) |rec| {
        if (rec.instance_id == instance_id) return rec;
    }
    return null;
}

/// Test-only helper: returns the active record's instance_id for the
/// most recently allocated cell.
pub fn mapInstrumentationLastInstanceId() u64 {
    if (!instrument_map) return 0;
    if (!instrumentation_state.initialised) return 0;
    return instrumentation_state.next_instance_id - 1;
}

// ============================================================
// ArcRuntime — Non-generic ARC helpers for ZIR (spec §31.4)
//
// ZIR cannot express generic instantiation, so ArcRuntime
// provides concrete helper functions that take comptime T via
// @TypeOf, making them callable from generated ZIR code.
// ============================================================

pub const ArcRuntime = struct {
    /// Increment the runtime `arc_consumes_total` counter. Emitted as a
    /// ZIR call from each `share_value(.consume)` lowering so the
    /// observable counter reflects every consume site that fired during
    /// program execution, mirroring how `retainAny` / `releaseAny` bump
    /// their respective counters from the hot path. The cost is one
    /// extern function call per consume; consume mode still saves the
    /// far more expensive retain/release pair, so net effect is a
    /// reduction in ARC traffic.
    ///
    /// Also ensures the `ZAP_ARC_STATS=1` atexit hook is registered so
    /// programs whose ARC-managed types use bump allocation (e.g.
    /// `List`) — and therefore never run the per-pool atexit-registration
    /// path — still emit the counter dump on exit when the env var is
    /// set. The `ensureArcStatsAtexit` guard is idempotent so the cost
    /// is one boolean compare-branch on every consume after the first.
    pub fn noteConsume() void {
        ensureArcStatsAtexit();
        arc_consumes_total += 1;
    }

    /// Increment the runtime `arc_return_elisions_total` counter.
    /// Emitted from the function-epilogue drop emission when a local's
    /// release is suppressed because it is the source of the function's
    /// `ret` instruction (Phase 5 wires the emission). Defined here in
    /// Phase 3 alongside `noteConsume` so phase 5 only has to emit the
    /// call site, not introduce the runtime symbol.
    ///
    /// Also ensures the `ZAP_ARC_STATS=1` atexit hook is registered so
    /// programs whose ARC-managed types use bump allocation — and
    /// therefore never run the per-pool atexit-registration path — still
    /// emit the counter dump on exit when the env var is set. The
    /// `ensureArcStatsAtexit` guard is idempotent so the cost is one
    /// boolean compare-branch on every elision after the first; mirrors
    /// the `noteConsume` symmetry so a return-elision-only workload
    /// (one that never fires a consume site) still dumps stats.
    pub fn noteReturnElision() void {
        ensureArcStatsAtexit();
        arc_return_elisions_total += 1;
    }

    /// Per-type sized allocator pool. Each `Arc(T).Inner` size class gets
    /// its own `std.heap.MemoryPool` so allocation becomes a free-list pop
    /// and free becomes a free-list push — no malloc/free traffic in the
    /// hot path. The pool grows in page-sized chunks from `page_allocator`
    /// and never shrinks within process lifetime, so small-object
    /// workloads (binarytrees ~600 M nodes) pay the cost of the OS page
    /// commits exactly once instead of per-allocation.
    ///
    /// `threadlocal` because `MemoryPool` itself is single-threaded.
    /// Multi-threaded Zap programs get one pool per thread, with no
    /// shared free list and no contention. Functions that never
    /// allocate values of `T` pay nothing — the pool starts in
    /// `.empty` state (no allocation, no syscall).
    fn ArcPool(comptime T: type) type {
        return struct {
            const Pool = std.heap.MemoryPool(Arc(T).Inner);
            threadlocal var pool: Pool = .empty;
            threadlocal var stats: PoolStats = .{ .name = "Arc(" ++ @typeName(T) ++ ")" };

            fn create() *Arc(T).Inner {
                ensureArcStatsAtexit();
                stats.noteAllocation();
                return pool.create(std.heap.page_allocator) catch
                    @panic("ArcRuntime: ArcPool out of memory");
            }

            fn destroy(inner: *Arc(T).Inner) void {
                stats.noteDeallocation();
                pool.destroy(inner);
            }
        };
    }

    /// Allocate and wrap a value in an Arc. Returns a pointer to the
    /// value field inside the Arc inner struct.
    ///
    /// The `allocator` parameter is preserved for ABI stability with
    /// existing ZIR call sites (`allocAny(@TypeOf(value), allocator,
    /// value)`) but is no longer the source of storage — `Arc(T).Inner`
    /// allocations come from a per-type `MemoryPool`. Routing through
    /// the pool removes one libc-allocator round-trip per Arc node, which
    /// dominates Arc-heavy workloads (e.g., binarytrees `make`/`check`
    /// at ~600 M nodes per N=21 run).
    pub fn allocAny(comptime T: type, allocator: std.mem.Allocator, value: T) *T {
        _ = allocator;
        const inner = ArcPool(T).create();
        inner.* = .{
            .header = ArcHeader.init(),
            .value = value,
        };
        return &inner.value;
    }

    /// Element type of an Arc value pointer. The ZIR backend calls every
    /// public release helper with `(allocator, ptr)` — Zig's call-site
    /// inference cannot recover a `comptime T` slot from runtime arguments,
    /// so each helper receives `ptr: anytype` and asks `@typeInfo` for the
    /// element type instead. Centralised here so every helper agrees on
    /// "argument is a single-item pointer to T".
    fn arcPtrChild(comptime PtrT: type) type {
        const info = @typeInfo(PtrT);
        if (info == .optional) {
            const inner = @typeInfo(info.optional.child);
            if (inner == .pointer and inner.pointer.size == .one) {
                return inner.pointer.child;
            }
        }
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("ArcRuntime helper expects a single-item pointer; got " ++ @typeName(PtrT));
        }
        return info.pointer.child;
    }

    fn arcPtrIsOptional(comptime PtrT: type) bool {
        return @typeInfo(PtrT) == .optional;
    }

    /// Returns true when `T` carries its own ARC header inline as the first
    /// field rather than relying on the generic `Arc(T).Inner` wrapper.
    /// Such types are responsible for their own allocation pool and
    /// destruction (via a `release` or `arcReleaseDeep` method) — typically
    /// because they own variable-length payload buffers (`Map(K, V)`,
    /// `MArrayOf(T)`).
    fn hasInlineArcHeader(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (info.@"struct".fields.len == 0) return false;
        const first = info.@"struct".fields[0];
        if (first.type != ArcHeader) return false;
        if (!std.mem.eql(u8, first.name, "header")) return false;
        return true;
    }

    /// Free an Arc-managed value given a pointer to the value field.
    /// Decrements the refcount and frees the inner allocation when it reaches zero.
    /// The `allocator` argument is vestigial — the inner allocation is owned
    /// by the per-type `ArcPool` and returns there on destruction.
    pub fn freeAny(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return freeAny(allocator, unwrapped);
        }
        @setEvalBranchQuota(2000);
        // `allocator` retained for ABI; pool-owned allocations don't use it.
        _ = &allocator;
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            // Self-managed: T owns its own pool. Release routes through
            // T's release method, which performs deep teardown including
            // any heap-allocated payload arrays.
            if (@hasDecl(T, "release")) {
                T.release(@as(?*const T, ptr));
            } else if (@hasDecl(T, "arcReleaseDeep")) {
                T.arcReleaseDeep(std.heap.page_allocator, ptr);
            } else {
                @compileError("inline-header Arc type missing release/arcReleaseDeep: " ++ @typeName(T));
            }
            return;
        }
        const inner: *Arc(T).Inner = @constCast(@fieldParentPtr("value", ptr));
        if (inner.header.release()) {
            ArcPool(T).destroy(inner);
        }
    }

    /// Release (decrement refcount) an Arc-managed value given a pointer to the
    /// value field. On the zero-transition, recursively releases any indirect-
    /// storage Arc'd children before destroying the inner allocation; for types
    /// without such fields the comptime walk degenerates to a shallow free.
    ///
    /// Accepts the pointer as `anytype` so the ZIR backend's two-argument
    /// call site (`releaseAny(allocator, ptr)`) compiles — Zig cannot infer
    /// a leading `comptime T: type` parameter from the runtime ptr argument.
    /// The element type is recovered via `@typeInfo`.
    pub fn releaseAny(allocator: std.mem.Allocator, ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return releaseAny(allocator, unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        // Inline-header types (`Map(K, V)`, `MArrayOf(T)`, ...) own
        // their own pool and bump `arc_releases_total` inside their
        // dedicated `release` method; if the generic wrapper also
        // bumped, every release routed through `releaseAny` would
        // double-count. Skip the bump here when `T` is self-managed —
        // the inner `T.release(...)` call inside `releaseArcAny`
        // accounts for this release. For Arc(T)-wrapped values the
        // wrapper is the only counter site, so the bump stays.
        if (comptime !hasInlineArcHeader(T)) {
            arc_releases_total += 1;
        }
        releaseArcAny(T, allocator, ptr);
    }

    /// Phase 1 of split-phase release: atomically decrement the refcount and
    /// report whether the caller is now the last owner.
    ///
    /// Returns the mutable parent value pointer on the zero-transition (the
    /// caller is the final owner and must finish destruction) and `null`
    /// otherwise. Does NOT destroy the inner allocation — `destroyPreparedAny`
    /// does that. The split exists so a compiler-generated deep-release helper
    /// can read indirect-storage child pointers from the parent struct *before*
    /// the parent's backing allocation is destroyed.
    pub fn prepareReleaseAny(comptime T: type, ptr: *const T) ?*T {
        const Inner = Arc(T).Inner;
        const inner: *Inner = @constCast(@fieldParentPtr("value", ptr));
        if (inner.header.release()) return &inner.value;
        return null;
    }

    /// Phase 2 of split-phase release: destroy an Arc-wrapped allocation
    /// whose refcount has already been brought to zero by
    /// `prepareReleaseAny`. The deep-release helper uses this between
    /// the children walk and returning to the caller. The `allocator`
    /// argument is vestigial — see `allocAny` and `ArcPool`.
    pub fn destroyPreparedAny(comptime T: type, allocator: std.mem.Allocator, ptr: *T) void {
        _ = allocator;
        const inner: *Arc(T).Inner = @fieldParentPtr("value", ptr);
        ArcPool(T).destroy(inner);
    }

    /// Deep-release an Arc-managed value. Walks the value's struct fields
    /// at comptime: every indirect-storage Arc'd field — encoded by the
    /// Zap codegen as a single-item const pointer (`?*const ChildT`) — is
    /// released recursively before the parent allocation is destroyed.
    ///
    /// For types without any indirect-storage fields, the comptime walk
    /// expands to nothing and behavior is identical to `releaseAny`.
    ///
    /// Recursion at the type level (e.g. `Tree` → `?*const Tree` → `Tree`)
    /// terminates because Zig memoizes generic instantiations by their
    /// comptime parameter values; the recursive reference reuses the same
    /// in-progress instance rather than expanding indefinitely.
    pub fn releaseArcAny(comptime T: type, allocator: std.mem.Allocator, ptr: *const T) void {
        if (comptime hasInlineArcHeader(T)) {
            if (@hasDecl(T, "release")) {
                T.release(@as(?*const T, ptr));
            } else if (@hasDecl(T, "arcReleaseDeep")) {
                T.arcReleaseDeep(allocator, ptr);
            } else {
                @compileError("inline-header Arc type missing release/arcReleaseDeep: " ++ @typeName(T));
            }
            return;
        }
        if (prepareReleaseAny(T, ptr)) |owned| {
            releaseChildrenAny(T, allocator, owned.*);
            destroyPreparedAny(T, allocator, owned);
        }
    }

    /// Walk every field of an aggregate value at comptime and deep-release
    /// any indirect-storage Arc'd children encountered. Non-aggregates are
    /// a no-op; flat aggregates compile to nothing.
    pub fn releaseChildrenAny(comptime T: type, allocator: std.mem.Allocator, value: T) void {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    releaseFieldChildAny(field.type, allocator, @field(value, field.name));
                }
            },
            else => {},
        }
    }

    fn releaseFieldChildAny(comptime FieldType: type, allocator: std.mem.Allocator, value: FieldType) void {
        switch (@typeInfo(FieldType)) {
            .optional => |opt| {
                if (value) |inner| releaseFieldChildAny(opt.child, allocator, inner);
            },
            .pointer => |p| {
                if (p.size == .one) {
                    releaseArcAny(p.child, allocator, @constCast(value));
                }
            },
            else => {},
        }
    }

    /// Walk every field of an aggregate value at comptime and deep-retain
    /// any indirect-storage Arc'd children encountered. Mirrors
    /// `releaseChildrenAny` exactly — every field shape that the release
    /// walker would decrement, this walker increments. Used at sites
    /// that hand a borrowed-by-pointer aggregate to a caller that will
    /// later own and release it (e.g. `List.next` returning `cell.head`
    /// when the cell still owns the same value).
    pub fn retainChildrenAny(comptime T: type, value: T) void {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    retainFieldChildAny(field.type, @field(value, field.name));
                }
            },
            else => {},
        }
    }

    fn retainFieldChildAny(comptime FieldType: type, value: FieldType) void {
        switch (@typeInfo(FieldType)) {
            .optional => |opt| {
                if (value) |inner| retainFieldChildAny(opt.child, inner);
            },
            .pointer => |p| {
                if (p.size == .one) {
                    // Struct/aggregate field deep-retain represents a
                    // genuine new persistent owner of the inner ARC
                    // value (the parent aggregate). Route through the
                    // persistent path so type-specific instrumentation
                    // (Map share-event tracking) observes the share.
                    retainAnyPersistent(@as(*const p.child, value));
                }
            },
            else => {},
        }
    }

    /// Generic ARC retain used for *transient* borrow-pass plumbing —
    /// the IR `share_value mode=retain` lowering. This pairs with a
    /// matching post-call `releaseAny` so the retain represents
    /// temporary ownership that resolves before the next user-visible
    /// mutation. Type-specific instrumentation hooks (Map workload
    /// share-event classifier in particular) deliberately do *not*
    /// fire on this path. Use `retainAnyPersistent` instead when the
    /// retain represents a new long-lived owner — for example a List
    /// cons cell stashing the value in its head, a Map entry's
    /// retained value, or a struct field assignment.
    pub fn retainAny(ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return retainAny(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            const mut: *T = @constCast(ptr);
            mut.header.retain();
            arc_retains_total += 1;
            return;
        }
        const Inner = Arc(T).Inner;
        const inner: *Inner = @constCast(@fieldParentPtr("value", ptr));
        inner.header.retain();
        arc_retains_total += 1;
    }

    /// Retain for *persistent* container ownership: the caller is
    /// stashing the ARC value inside another long-lived owner — a
    /// List cons cell, a Map entry's value, a struct field. Routes
    /// through the type's public `retain` method when one exists so
    /// type-specific bookkeeping fires; in particular this is the
    /// retain path the Map workload instrumentation classifies as a
    /// real concurrent-owner share event. `retainAny` (above) covers
    /// the symmetric transient case.
    pub fn retainAnyPersistent(ptr: anytype) void {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return;
            return retainAnyPersistent(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            if (comptime @hasDecl(T, "retain")) {
                _ = T.retain(@as(?*const T, ptr));
                return;
            }
            const mut: *T = @constCast(ptr);
            mut.header.retain();
            arc_retains_total += 1;
            return;
        }
        const Inner = Arc(T).Inner;
        const inner: *Inner = @constCast(@fieldParentPtr("value", ptr));
        inner.header.retain();
        arc_retains_total += 1;
    }

    /// Retain through an optional Arc pointer: `?*const T` becomes a no-op
    /// when null, otherwise unwraps and increments the refcount. Field-get
    /// on an indirect-storage recursive field (`?*const T`) emits this so
    /// the extracted reference and the parent both own the child Arc — a
    /// later deep release of either owner decrements once and only the
    /// final decrement frees the allocation.
    pub fn retainAnyOpt(ptr: anytype) void {
        const PtrT = @TypeOf(ptr);
        switch (@typeInfo(PtrT)) {
            .optional => if (ptr) |p| retainAny(p),
            .pointer => retainAny(ptr),
            else => @compileError("retainAnyOpt expects pointer or optional pointer; got " ++ @typeName(PtrT)),
        }
    }

    /// Get the refcount of an Arc-managed value.
    pub fn refCountAny(ptr: anytype) u32 {
        if (comptime arcPtrIsOptional(@TypeOf(ptr))) {
            const unwrapped = ptr orelse return 0;
            return refCountAny(unwrapped);
        }
        const T = arcPtrChild(@TypeOf(ptr));
        if (comptime hasInlineArcHeader(T)) {
            return ptr.header.count();
        }
        const Inner = Arc(T).Inner;
        const inner: *Inner = @constCast(@fieldParentPtr("value", ptr));
        return inner.header.count();
    }

    /// Reset a value for Perceus-style reuse. If the reference count is 1,
    /// return an opaque reuse token for the existing allocation. Otherwise,
    /// release the current value and return null.
    pub fn resetAny(allocator: std.mem.Allocator, ptr: anytype) ?*anyopaque {
        if (refCountAny(ptr) == 1) {
            return @ptrCast(@constCast(ptr));
        }
        releaseAny(allocator, ptr);
        return null;
    }

    /// Convert a Perceus reuse token back into a typed allocation. If the token
    /// is present, reuse that storage; otherwise allocate a fresh value.
    pub fn reuseAllocByType(comptime T: type, allocator: std.mem.Allocator, token: ?*anyopaque) *T {
        if (token) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return allocator.create(T) catch @panic("ArcRuntime.reuseAllocByType: out of memory");
    }
};

// ============================================================
// MArray — Mutable, ARC-managed, pool-backed contiguous arrays.
//
// `MArrayOf(T)` is the generic Zig template; user-visible Zap
// types are concrete instantiations (`MArrayI64`, `MArrayF64`).
// Each `MArrayOf(T)` carries:
//
//   * an `ArcHeader` — atomic refcount, identical to `Arc(T)`
//     so retain/release lower through the same opaque helpers;
//   * a `len` field — number of elements;
//   * an `items` raw pointer — heap allocation of `len` `T`s.
//
// The `Inner` allocations come from a thread-local
// `std.heap.MemoryPool(Inner)` (one pool per element type), and
// the backing element storage comes from `std.heap.page_allocator`
// directly. Two independent allocations are intentional: the
// `Inner` is a small, cache-friendly fixed-size payload that
// fits the pool's free-list shape; the `items` buffer is
// variable-length and must round-trip through the page
// allocator anyway.
//
// Mutation through `*const Self` mirrors `Arc(T).Inner` —
// the source-Arc ABI exposes `?*const T` everywhere; the
// runtime `@constCast`s once at the boundary to write through
// the `items` pointer or the refcount header.
// ============================================================

pub fn MArrayOf(comptime T: type) type {
    return struct {
        const Self = @This();

        /// `Inner` carries the ARC header, the element count, and the
        /// raw element-storage pointer. The Zap source representation
        /// is `?*const Self`; recovering `Inner` from a `Self`
        /// pointer is a single `@ptrCast`.
        pub const Inner = struct {
            header: ArcHeader,
            len: usize,
            items: [*]T,
        };

        const InnerPool = struct {
            const PoolT = std.heap.MemoryPool(Inner);
            threadlocal var pool: PoolT = .empty;
            threadlocal var stats: PoolStats = .{ .name = "MArrayOf(" ++ @typeName(T) ++ ").Inner" };

            fn create() *Inner {
                ensureArcStatsAtexit();
                stats.noteAllocation();
                return pool.create(std.heap.page_allocator) catch
                    @panic("MArray inner pool: out of memory");
            }

            fn destroy(inner: *Inner) void {
                stats.noteDeallocation();
                pool.destroy(inner);
            }
        };

        /// Allocate an array of `requested_len` elements, each
        /// initialised to `init_value`. Returns the
        /// `?*const Self`-shaped pointer the Zap-side source
        /// representation expects. Panics on OOM (consistent with
        /// `ArcRuntime.allocAny` — Zap programs cannot recover from
        /// allocation failure today).
        pub fn new(requested_len: i64, init_value: T) ?*const Self {
            if (requested_len < 0) @panic("MArray.new: negative length");
            const slot_count: usize = @intCast(requested_len);
            const items_slice = std.heap.page_allocator.alloc(T, slot_count) catch
                @panic("MArray.new: items out of memory");
            for (items_slice) |*element_slot| element_slot.* = init_value;

            const inner = InnerPool.create();
            inner.* = .{
                .header = ArcHeader.init(),
                .len = slot_count,
                .items = items_slice.ptr,
            };
            return @ptrCast(inner);
        }

        /// Read the element at `index`. Panics on null array (matches
        /// the ArcRuntime convention — null is a programmer error,
        /// not a runtime-recoverable state).
        pub fn get(array: ?*const Self, index: i64) T {
            const inner = innerOf(array orelse @panic("MArray.get: null array"));
            const slot: usize = @intCast(index);
            if (slot >= inner.len) @panic("MArray.get: index out of bounds");
            return inner.items[slot];
        }

        /// Write `value` to position `index` and return `value`. The
        /// returned value matches `List.set`-style "value out" so
        /// callers can chain (e.g. `total = total + MArray.set(arr, i, x)`).
        pub fn set(array: ?*const Self, index: i64, value: T) T {
            const inner: *Inner = @constCast(innerOf(array orelse @panic("MArray.set: null array")));
            const slot: usize = @intCast(index);
            if (slot >= inner.len) @panic("MArray.set: index out of bounds");
            inner.items[slot] = value;
            return value;
        }

        /// Number of elements. Panics on null array.
        pub fn length(array: ?*const Self) i64 {
            const inner = innerOf(array orelse @panic("MArray.length: null array"));
            return @intCast(inner.len);
        }

        /// Increment the refcount and return the same handle. Mirrors
        /// `ArcRuntime.retainAny`'s shape so the comptime field-walker
        /// in `releaseChildrenAny` (or its successor) can pick up
        /// `?*const MArrayOf(T)` fields automatically when an `MArray`
        /// is stored inside a user struct.
        pub fn retain(array: ?*const Self) ?*const Self {
            const handle = array orelse return null;
            const inner: *Inner = @constCast(innerOf(handle));
            inner.header.retain();
            arc_retains_total += 1;
            return handle;
        }

        /// Decrement the refcount; on the zero-transition free both
        /// the element-storage buffer and the `Inner` allocation.
        /// Element types that need their own destruction (future
        /// `MArrayString`, `MArrayList`) can extend the zero-branch
        /// with a per-element walk; the present integer/float
        /// instantiations leave `T` trivially destructible.
        pub fn release(array: ?*const Self) void {
            const handle = array orelse return;
            const inner: *Inner = @constCast(innerOf(handle));
            arc_releases_total += 1;
            if (inner.header.release()) {
                std.heap.page_allocator.free(inner.items[0..inner.len]);
                InnerPool.destroy(inner);
            }
        }

        fn innerOf(array: *const Self) *const Inner {
            return @ptrCast(@alignCast(array));
        }
    };
}

/// Concrete instantiation backing `pub struct MArrayI64` in
/// `lib/marray.zap`. Used by fannkuch-redux's permutation buffer.
pub const MArrayI64 = MArrayOf(i64);

/// Concrete instantiation backing `pub struct MArrayF64` in
/// `lib/marray.zap`. Used by spectral-norm's `u`/`v` vectors.
pub const MArrayF64 = MArrayOf(f64);

// ============================================================
// Atom — Interned atom values (spec §5.6)
// ============================================================

pub const Atom = struct {
    id: u32,

    pub const nil_id: u32 = 0;
    pub const true_id: u32 = 1;
    pub const false_id: u32 = 2;
    pub const ok_id: u32 = 3;
    pub const error_id: u32 = 4;

    pub const nil: Atom = .{ .id = nil_id };
    pub const @"true": Atom = .{ .id = true_id };
    pub const @"false": Atom = .{ .id = false_id };
    pub const ok: Atom = .{ .id = ok_id };
    pub const @"error": Atom = .{ .id = error_id };

    pub fn eql(a: Atom, b: Atom) bool {
        return a.id == b.id;
    }

    pub fn to_string(id: anytype) []const u8 {
        const T = @TypeOf(id);
        if (T == u32) return atomToString(id);
        if (@typeInfo(T) == .int) return atomToString(@intCast(id));
        return "<not_an_atom>";
    }
};

pub const AtomTable = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
    lookup: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) AtomTable {
        var table = AtomTable{
            .allocator = allocator,
            .strings = .empty,
            .lookup = std.StringHashMap(u32).init(allocator),
        };
        // Register well-known atoms
        const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
        for (builtins) |name| {
            table.strings.append(allocator, name) catch {};
            table.lookup.put(name, @intCast(table.strings.items.len - 1)) catch {};
        }
        return table;
    }

    pub fn deinit(self: *AtomTable) void {
        self.strings.deinit(self.allocator);
        self.lookup.deinit();
    }

    pub fn intern(self: *AtomTable, name: []const u8) !Atom {
        if (self.lookup.get(name)) |id| {
            return .{ .id = id };
        }
        const id: u32 = @intCast(self.strings.items.len);
        const duped = try self.allocator.dupe(u8, name);
        try self.strings.append(self.allocator, duped);
        try self.lookup.put(duped, id);
        return .{ .id = id };
    }

    pub fn getName(self: *const AtomTable, atom: Atom) []const u8 {
        if (atom.id < self.strings.items.len) {
            return self.strings.items[atom.id];
        }
        return "<unknown_atom>";
    }
};

// ============================================================
// Global Atom Table — process-wide interned atom registry
// ============================================================

// Simple atom table using fixed-size arrays to avoid std.HashMap/ArrayList
// which require operations not yet implemented in the Zig self-hosted backend.
const MAX_ATOMS = 256;
const MAX_ATOM_NAME_LEN = 64;

var atom_names: [MAX_ATOMS][MAX_ATOM_NAME_LEN]u8 = undefined;
var atom_lengths: [MAX_ATOMS]u32 = [_]u32{0} ** MAX_ATOMS;
var atom_count: u32 = 0;
var atom_table_initialized: bool = false;

fn initAtomTable() void {
    if (atom_table_initialized) return;
    // Register well-known atoms
    const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
    for (builtins) |name| {
        const id = atom_count;
        const len: u32 = @intCast(name.len);
        @memcpy(atom_names[id][0..len], name);
        atom_lengths[id] = len;
        atom_count += 1;
    }
    atom_table_initialized = true;
}

/// Intern a string as an atom. Returns the atom's u32 ID.
pub fn atomIntern(name: [*]const u8, len: u32) u32 {
    initAtomTable();
    const name_slice = name[0..len];
    // Search existing atoms
    var i: u32 = 0;
    while (i < atom_count) : (i += 1) {
        if (atom_lengths[i] == len) {
            if (std.mem.eql(u8, atom_names[i][0..len], name_slice)) {
                return i;
            }
        }
    }
    // New atom
    if (atom_count >= MAX_ATOMS) return 0;
    const id = atom_count;
    @memcpy(atom_names[id][0..len], name_slice);
    atom_lengths[id] = len;
    atom_count += 1;
    return id;
}

/// Get the string name of an atom by its u32 ID.
pub fn atomToString(id: u32) []const u8 {
    initAtomTable();
    if (id < atom_count) {
        return atom_names[id][0..atom_lengths[id]];
    }
    return "<unknown_atom>";
}

/// Compare two atom IDs for equality.
pub fn atomEq(a: u32, b: u32) bool {
    return a == b;
}

// ============================================================
// Builder Runtime — entry point plumbing for build.zap builders
// ============================================================

pub const BuilderRuntime = struct {
    /// Construct Zap.Env from getArgv().
    /// argv[0] = binary, argv[1] = target, argv[2] = os, argv[3] = arch
    pub fn buildEnvFromArgv() struct { target: u32, os: u32, arch: u32 } {
        const argv = getArgv();
        return .{
            .target = if (argv.len > 1) atomIntern(argv[1], @intCast(std.mem.len(argv[1]))) else 0,
            .os = if (argv.len > 2) atomIntern(argv[2], @intCast(std.mem.len(argv[2]))) else 0,
            .arch = if (argv.len > 3) atomIntern(argv[3], @intCast(std.mem.len(argv[3]))) else 0,
        };
    }

    /// Serialize a manifest struct to stdout as key=value lines.
    pub fn serializeManifest(manifest: anytype) void {
        const T = @TypeOf(manifest);
        const info = @typeInfo(T);
        if (info != .@"struct") return; // void or non-struct — nothing to serialize
        inline for (info.@"struct".fields) |field| {
            const value = @field(manifest, field.name);
            const FT = @TypeOf(value);
            if (FT == []const u8) {
                stdoutPrint("{s}={s}\n", .{ field.name, value });
            } else if (FT == u32) {
                stdoutPrint("{s}={s}\n", .{ field.name, atomToString(value) });
            } else if (@typeInfo(FT) == .int) {
                stdoutPrint("{s}={d}\n", .{ field.name, value });
            } else if (FT == bool) {
                stdoutPrint("{s}={}\n", .{ field.name, value });
            }
        }
    }
};

// ============================================================
// Closure — Fat pointer for function values (spec §20.2, §31.3)
// ============================================================

pub fn Closure(comptime Args: type, comptime Ret: type) type {
    return struct {
        const Self = @This();

        call_fn: *const fn (*anyopaque, Args) Ret,
        env: *anyopaque,

        pub fn invoke(self: Self, args: Args) Ret {
            return self.call_fn(self.env, args);
        }
    };
}

/// Type-erased closure for dynamic dispatch
pub const DynClosure = struct {
    call_fn: *const anyopaque,
    env: ?*anyopaque,
    env_release: ?*const fn (*anyopaque) void,

    pub fn release(self: DynClosure) void {
        if (self.env_release) |rel| {
            if (self.env) |e| {
                rel(e);
            }
        }
    }
};

pub fn invokeDynClosure(comptime Ret: type, closure: DynClosure, args: anytype) Ret {
    const Fn = *const fn (?*anyopaque, @TypeOf(args)) Ret;
    const fn_ptr: Fn = @ptrCast(@alignCast(closure.call_fn));
    return fn_ptr(closure.env, args);
}

const testing = std.testing;

test "ArcRuntime.resetAny returns token for unique value" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 42);
    const token = ArcRuntime.resetAny(allocator, ptr);
    try testing.expect(token != null);
    const reused = ArcRuntime.reuseAllocByType(i64, allocator, token);
    reused.* = 7;
    try testing.expectEqual(@as(i64, 7), reused.*);
    ArcRuntime.releaseAny(allocator, reused);
}

test "ArcRuntime.resetAny releases shared value and yields null token" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 10);
    ArcRuntime.retainAny(ptr);
    const token = ArcRuntime.resetAny(allocator, ptr);
    try testing.expect(token == null);
    ArcRuntime.releaseAny(allocator, ptr);
}

test "String.compare orders bytes lexicographically" {
    try testing.expectEqual(@as(i64, 0), String.compare("abc", "abc"));
    try testing.expectEqual(@as(i64, -1), String.compare("abc", "abd"));
    try testing.expectEqual(@as(i64, 1), String.compare("abd", "abc"));
    // shorter string compares less than its prefix-equal longer counterpart
    try testing.expectEqual(@as(i64, -1), String.compare("ab", "abc"));
    try testing.expectEqual(@as(i64, 1), String.compare("abc", "ab"));
    // empty boundary
    try testing.expectEqual(@as(i64, 0), String.compare("", ""));
    try testing.expectEqual(@as(i64, -1), String.compare("", "x"));
    try testing.expectEqual(@as(i64, 1), String.compare("x", ""));
}

// ============================================================
// String — String utilities
// ============================================================

pub const String = struct {
    /// Convert a string to an atom, creating it if it doesn't exist.
    pub fn to_atom(name: []const u8) u32 {
        return atomIntern(name.ptr, @intCast(name.len));
    }

    /// Convert a string to an existing atom. Returns null (0xFFFFFFFF)
    /// if the atom has not been previously interned.
    pub fn to_existing_atom(name: []const u8) u32 {
        initAtomTable();
        var i: u32 = 0;
        while (i < atom_count) : (i += 1) {
            if (atom_lengths[i] == name.len) {
                if (std.mem.eql(u8, atom_names[i][0..name.len], name)) {
                    return i;
                }
            }
        }
        return 0xFFFFFFFF;
    }

    /// Concatenate two strings into a fresh allocation backed by the
    /// runtime arena. Zap-emitted code calls this directly because Zap
    /// has no notion of allocators at the call site.
    pub fn concat(a: []const u8, b: []const u8) []const u8 {
        const result = bumpAlloc(a.len + b.len);
        if (result.len == 0) return a; // fallback: return first string
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    pub fn length(s: []const u8) i64 {
        return @intCast(s.len);
    }

    pub fn slice(s: []const u8, start: i64, end: i64) []const u8 {
        const safe_start: usize = if (start >= 0) @intCast(start) else 0;
        const safe_end: usize = if (end >= 0) @intCast(end) else 0;
        const s_end = @min(safe_end, s.len);
        const s_start = @min(safe_start, s_end);
        return s[s_start..s_end];
    }

    pub fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.find(u8, haystack, needle) != null;
    }

    pub fn startsWith(s: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, s, prefix);
    }

    pub fn endsWith(s: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, s, suffix);
    }

    pub fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, " \t\n\r");
    }

    /// Get byte at index as a single-character string.
    pub fn byte_at(s: []const u8, index: i64) []const u8 {
        const i: usize = if (index >= 0) @intCast(index) else return "";
        if (i >= s.len) return "";
        const result = bumpAlloc(1);
        if (result.len == 0) return "";
        result[0] = s[i];
        return result;
    }

    /// Construct a one-byte string from an integer 0..255. The inverse
    /// of `byte_at`. Higher bits of the input are masked off, so the
    /// result is always exactly one byte and never panics on out-of-
    /// range input. Lets Zap code emit raw binary (e.g., PBM image
    /// data) without needing a Zig primitive at the call site.
    pub fn from_byte(byte: i64) []const u8 {
        const result = bumpAlloc(1);
        if (result.len == 0) return "";
        result[0] = @intCast(@as(u64, @bitCast(byte)) & 0xFF);
        return result;
    }

    /// Lexicographic byte-wise comparison. Returns a negative integer
    /// when `left` precedes `right`, zero when they are byte-identical,
    /// and a positive integer when `left` follows `right`. Equivalent
    /// in shape to C's `strcmp` and OCaml's `String.compare`. Useful
    /// as a comparator for `Enum.sort` over `String` keys when the
    /// protocol-based `<=` is too generic for the call-site to
    /// resolve cleanly.
    pub fn compare(left: []const u8, right: []const u8) i64 {
        return switch (std.mem.order(u8, left, right)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// Iterator protocol for strings. The slice itself is the iteration
    /// state — each call returns the first byte (as a single-character
    /// string) and the remaining slice. This lets `for ch <- "hello"`
    /// dispatch through `Enumerable.next/1` like every other container.
    pub fn next(s: []const u8) struct { u32, []const u8, []const u8 } {
        if (s.len == 0) return .{ ATOM_DONE, "", s };
        const head = bumpAlloc(1);
        if (head.len == 0) return .{ ATOM_DONE, "", s };
        head[0] = s[0];
        return .{ ATOM_CONT, head, s[1..] };
    }

    pub fn upcase(s: []const u8) []const u8 {
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        return result;
    }

    pub fn downcase(s: []const u8) []const u8 {
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn reverse_string(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[s.len - 1 - i] = c;
        }
        return result;
    }

    pub fn replace_string(s: []const u8, pattern: []const u8, replacement: []const u8) []const u8 {
        if (pattern.len == 0) return s;
        var count: usize = 0;
        var pos: usize = 0;
        while (pos + pattern.len <= s.len) {
            if (std.mem.eql(u8, s[pos .. pos + pattern.len], pattern)) {
                count += 1;
                pos += pattern.len;
            } else {
                pos += 1;
            }
        }
        if (count == 0) return s;
        const new_len = s.len - (count * pattern.len) + (count * replacement.len);
        const result = bumpAlloc(new_len);
        if (result.len == 0) return s;
        var src: usize = 0;
        var dst: usize = 0;
        while (src < s.len) {
            if (src + pattern.len <= s.len and std.mem.eql(u8, s[src .. src + pattern.len], pattern)) {
                @memcpy(result[dst .. dst + replacement.len], replacement);
                dst += replacement.len;
                src += pattern.len;
            } else {
                result[dst] = s[src];
                dst += 1;
                src += 1;
            }
        }
        return result;
    }

    pub fn index_of(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        if (needle.len > haystack.len) return -1;
        if (std.mem.find(u8, haystack, needle)) |idx| {
            return @intCast(idx);
        }
        return -1;
    }

    pub fn pad_leading(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const pad_count = target - s.len;
        const result = bumpAlloc(target);
        if (result.len == 0) return s;
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[0..pad_count], fill);
        @memcpy(result[pad_count..target], s);
        return result;
    }

    pub fn pad_trailing(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const result = bumpAlloc(target);
        if (result.len == 0) return s;
        @memcpy(result[0..s.len], s);
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[s.len..target], fill);
        return result;
    }

    pub fn repeat_string(s: []const u8, count: i64) []const u8 {
        if (count <= 0 or s.len == 0) return "";
        const n: usize = @intCast(count);
        const result = bumpAlloc(s.len * n);
        if (result.len == 0) return s;
        for (0..n) |i| {
            @memcpy(result[i * s.len .. (i + 1) * s.len], s);
        }
        return result;
    }

    pub fn capitalize(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        result[0] = if (s[0] >= 'a' and s[0] <= 'z') s[0] - 32 else s[0];
        for (s[1..], 0..) |c, i| {
            result[i + 1] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn trim_leading(s: []const u8) []const u8 {
        return std.mem.trimStart(u8, s, " \t\n\r");
    }

    pub fn trim_trailing(s: []const u8) []const u8 {
        return std.mem.trimEnd(u8, s, " \t\n\r");
    }

    pub fn string_count(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        var count: i64 = 0;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                count += 1;
                i += needle.len;
            } else {
                i += 1;
            }
        }
        return count;
    }

    pub fn split_to_list(s: []const u8, delimiter: []const u8) ?*const List([]const u8) {
        if (delimiter.len == 0) {
            return List([]const u8).cons(s, null);
        }
        var result: ?*const List([]const u8) = null;
        var pos: usize = 0;
        var seg_start: usize = 0;
        while (pos < s.len) {
            if (pos + delimiter.len <= s.len and std.mem.eql(u8, s[pos .. pos + delimiter.len], delimiter)) {
                const seg = s[seg_start..pos];
                const seg_copy = bumpAlloc(seg.len);
                if (seg_copy.len > 0) @memcpy(seg_copy, seg);
                result = List([]const u8).cons(seg_copy, result);
                pos += delimiter.len;
                seg_start = pos;
            } else {
                pos += 1;
            }
        }
        const last_seg = s[seg_start..];
        const last_copy = bumpAlloc(last_seg.len);
        if (last_copy.len > 0) @memcpy(last_copy, last_seg);
        result = List([]const u8).cons(last_copy, result);
        return List([]const u8).reverse(result);
    }

    pub fn string_join(list: ?*const List([]const u8), separator: []const u8) []const u8 {
        if (list == null) return "";
        var total: usize = 0;
        var count: usize = 0;
        var current = list;
        while (current) |cell| {
            total += cell.head.len;
            count += 1;
            current = cell.tail;
        }
        if (count == 0) return "";
        total += separator.len * (count - 1);
        const result = bumpAlloc(total);
        if (result.len == 0) return "";
        var dst: usize = 0;
        var first = true;
        current = list;
        while (current) |cell| {
            if (!first and separator.len > 0) {
                @memcpy(result[dst..][0..separator.len], separator);
                dst += separator.len;
            }
            @memcpy(result[dst..][0..cell.head.len], cell.head);
            dst += cell.head.len;
            first = false;
            current = cell.tail;
        }
        return result[0..dst];
    }
};

// ============================================================
// Kernel functions (spec §30.2)
// ============================================================

pub fn panic(message: []const u8) noreturn {
    stderrWriteFlushed("** (NilError) ");
    posixWrite(STDERR_FD, message);
    posixWrite(STDERR_FD, "\n");
    std.process.exit(1);
}

pub const Range = struct {
    /// Iterator protocol for ranges.
    /// Uses the range struct as its own state — `start` is the current position.
    /// Returns {:cont, current, next_range} or {:done, 0, nil_range}.
    pub fn next(range: anytype) std.meta.Tuple(&.{ u32, i64, @TypeOf(range) }) {
        const start = range.start;
        const end_val = range.end;
        const step_mag = if (range.step < 0) -range.step else range.step;
        const direction: i64 = if (@hasField(@TypeOf(range), "direction") and range.direction != 0)
            range.direction
        else if (start <= end_val)
            1
        else
            -1;

        // Check if done
        const done = if (direction > 0) start > end_val else start < end_val;
        if (done) {
            return .{ ATOM_DONE, 0, range };
        }

        // Advance: create next range with updated start
        const step = direction * step_mag;
        var next_range = range;
        next_range.start = start + step;
        if (@hasField(@TypeOf(next_range), "direction")) {
            next_range.direction = direction;
        }
        return .{ ATOM_CONT, start, next_range };
    }

    /// Flip a range's direction by swapping `start` and `end`. The
    /// `step` magnitude is preserved; the implicit direction (derived
    /// from `start` vs `end` when `direction == 0`) flips because the
    /// endpoints swapped. Returns a fresh range value — the input is
    /// not mutated.
    pub fn reverse(range: anytype) @TypeOf(range) {
        var flipped = range;
        flipped.start = range.end;
        flipped.end = range.start;
        if (@hasField(@TypeOf(flipped), "direction")) {
            flipped.direction = 0;
        }
        return flipped;
    }
};

pub const Kernel = struct {
    /// Generic string conversion used by string interpolation. Strings
    /// pass through untouched; numbers/bools/enums are formatted via the
    /// runtime arena.
    pub fn to_string(value: anytype) []const u8 {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            return value;
        } else if (T == bool) {
            return if (value) "true" else "false";
        } else if (info == .int or info == .comptime_int) {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAlloc(slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .float or info == .comptime_float) {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAlloc(slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .@"enum") {
            return @tagName(value);
        } else {
            return "<value>";
        }
    }

    pub fn panic(message: []const u8) noreturn {
        stderrWriteFlushed("panic: ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    pub fn halt(message: []const u8) noreturn {
        stderrWriteFlushed("halt: ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    /// Call a callable value — either a bare function pointer or a
    /// closure struct with `{call_fn, env, env_release}` fields.
    pub inline fn callCallable0(callable: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare0(callable);
        }
        return callable();
    }

    pub inline fn callCallable1(callable: anytype, arg0: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare1(callable, arg0);
        }
        return callable(arg0);
    }

    pub inline fn callCallable2(callable: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0, arg1);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare2(callable, arg0, arg1);
        }
        return callable(arg0, arg1);
    }

    pub inline fn callCallable3(callable: anytype, arg0: anytype, arg1: anytype, arg2: anytype) CallableReturn(@TypeOf(callable)) {
        if (comptime isZapClosure(@TypeOf(callable))) {
            return callable.call_fn(callable.env, arg0, arg1, arg2);
        }
        if (comptime isBareFunction(@TypeOf(callable))) {
            return callBare3(callable, arg0, arg1, arg2);
        }
        return callable(arg0, arg1, arg2);
    }

    pub fn is_integer(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .int or info == .comptime_int;
    }

    pub fn is_float(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .float or info == .comptime_float;
    }

    pub fn is_number(value: anytype) bool {
        return is_integer(value) or is_float(value);
    }

    pub fn is_boolean(value: anytype) bool {
        return @TypeOf(value) == bool;
    }

    pub fn is_string(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == []const u8) return true;
        const info = @typeInfo(T);
        if (info == .pointer) {
            const child = std.meta.Child(T);
            return @typeInfo(child) == .array and std.meta.Elem(child) == u8;
        }
        return false;
    }

    pub fn is_atom(value: anytype) bool {
        // Atoms are represented as u32 at runtime
        return @TypeOf(value) == u32;
    }

    pub fn is_nil(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return true;
        const info = @typeInfo(T);
        if (info == .optional) {
            return value == null;
        }
        return false;
    }

    pub fn is_list(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "head") and @hasField(child.pointer.child, "tail");
            }
        }
        return false;
    }

    pub fn is_tuple(value: anytype) bool {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        return info == .@"struct" and info.@"struct".is_tuple;
    }

    pub fn is_map(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "entries") and @hasField(child.pointer.child, "size");
            }
        }
        return false;
    }

    pub fn is_struct(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .@"struct" and !info.@"struct".is_tuple) return true;
        if (info == .pointer) {
            const child = @typeInfo(std.meta.Child(@TypeOf(value)));
            if (child == .@"struct" and !child.@"struct".is_tuple) return true;
        }
        return false;
    }

    pub fn raise(message: []const u8) noreturn {
        stderrWriteFlushed("** (RuntimeError) ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    // Operator primitives backing the generic `pub fn ==`/`!=`/`<`/`>`/
    // `<=`/`>=` in lib/kernel.zap. The Zap monomorphizer specializes the
    // Kernel operator per concrete type pair, so each instantiation here
    // sees a concrete `T` and Zig's comptime dispatch picks the right
    // operation (`std.mem.eql` for slices, `==` for value types, etc.).

    pub fn eq(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.eql(u8, a, b);
        return a == b;
    }

    pub fn neq(a: anytype, b: anytype) bool {
        return !eq(a, b);
    }

    pub fn lt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, a, b);
        return a < b;
    }

    pub fn gt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, b, a);
        return a > b;
    }

    pub fn lte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, b, a);
        return a <= b;
    }

    pub fn gte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, a, b);
        return a >= b;
    }

    pub fn add(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a +% b;
        return a + b;
    }

    pub fn sub(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a -% b;
        return a - b;
    }

    pub fn mul(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a *% b;
        return a * b;
    }

    pub fn divide(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return @divTrunc(a, b);
        return a / b;
    }

    pub fn remainder(a: anytype, b: anytype) @TypeOf(a) {
        return @rem(a, b);
    }

    pub fn eq_i8(a: i8, b: i8) bool {
        return a == b;
    }
    pub fn eq_i16(a: i16, b: i16) bool {
        return a == b;
    }
    pub fn eq_i32(a: i32, b: i32) bool {
        return a == b;
    }
    pub fn eq_i64(a: i64, b: i64) bool {
        return a == b;
    }
    pub fn eq_i128(a: i128, b: i128) bool {
        return a == b;
    }
    pub fn eq_u8(a: u8, b: u8) bool {
        return a == b;
    }
    pub fn eq_u16(a: u16, b: u16) bool {
        return a == b;
    }
    pub fn eq_u32(a: u32, b: u32) bool {
        return a == b;
    }
    pub fn eq_u64(a: u64, b: u64) bool {
        return a == b;
    }
    pub fn eq_u128(a: u128, b: u128) bool {
        return a == b;
    }
    pub fn eq_f16(a: f16, b: f16) bool {
        return a == b;
    }
    pub fn eq_f32(a: f32, b: f32) bool {
        return a == b;
    }
    pub fn eq_f64(a: f64, b: f64) bool {
        return a == b;
    }
    pub fn eq_f80(a: f80, b: f80) bool {
        return a == b;
    }
    pub fn eq_f128(a: f128, b: f128) bool {
        return a == b;
    }

    pub fn neq_i8(a: i8, b: i8) bool {
        return a != b;
    }
    pub fn neq_i16(a: i16, b: i16) bool {
        return a != b;
    }
    pub fn neq_i32(a: i32, b: i32) bool {
        return a != b;
    }
    pub fn neq_i64(a: i64, b: i64) bool {
        return a != b;
    }
    pub fn neq_i128(a: i128, b: i128) bool {
        return a != b;
    }
    pub fn neq_u8(a: u8, b: u8) bool {
        return a != b;
    }
    pub fn neq_u16(a: u16, b: u16) bool {
        return a != b;
    }
    pub fn neq_u32(a: u32, b: u32) bool {
        return a != b;
    }
    pub fn neq_u64(a: u64, b: u64) bool {
        return a != b;
    }
    pub fn neq_u128(a: u128, b: u128) bool {
        return a != b;
    }
    pub fn neq_f16(a: f16, b: f16) bool {
        return a != b;
    }
    pub fn neq_f32(a: f32, b: f32) bool {
        return a != b;
    }
    pub fn neq_f64(a: f64, b: f64) bool {
        return a != b;
    }
    pub fn neq_f80(a: f80, b: f80) bool {
        return a != b;
    }
    pub fn neq_f128(a: f128, b: f128) bool {
        return a != b;
    }

    pub fn lt_i8(a: i8, b: i8) bool {
        return a < b;
    }
    pub fn lt_i16(a: i16, b: i16) bool {
        return a < b;
    }
    pub fn lt_i32(a: i32, b: i32) bool {
        return a < b;
    }
    pub fn lt_i64(a: i64, b: i64) bool {
        return a < b;
    }
    pub fn lt_i128(a: i128, b: i128) bool {
        return a < b;
    }
    pub fn lt_u8(a: u8, b: u8) bool {
        return a < b;
    }
    pub fn lt_u16(a: u16, b: u16) bool {
        return a < b;
    }
    pub fn lt_u32(a: u32, b: u32) bool {
        return a < b;
    }
    pub fn lt_u64(a: u64, b: u64) bool {
        return a < b;
    }
    pub fn lt_u128(a: u128, b: u128) bool {
        return a < b;
    }
    pub fn lt_f16(a: f16, b: f16) bool {
        return a < b;
    }
    pub fn lt_f32(a: f32, b: f32) bool {
        return a < b;
    }
    pub fn lt_f64(a: f64, b: f64) bool {
        return a < b;
    }
    pub fn lt_f80(a: f80, b: f80) bool {
        return a < b;
    }
    pub fn lt_f128(a: f128, b: f128) bool {
        return a < b;
    }

    pub fn gt_i8(a: i8, b: i8) bool {
        return a > b;
    }
    pub fn gt_i16(a: i16, b: i16) bool {
        return a > b;
    }
    pub fn gt_i32(a: i32, b: i32) bool {
        return a > b;
    }
    pub fn gt_i64(a: i64, b: i64) bool {
        return a > b;
    }
    pub fn gt_i128(a: i128, b: i128) bool {
        return a > b;
    }
    pub fn gt_u8(a: u8, b: u8) bool {
        return a > b;
    }
    pub fn gt_u16(a: u16, b: u16) bool {
        return a > b;
    }
    pub fn gt_u32(a: u32, b: u32) bool {
        return a > b;
    }
    pub fn gt_u64(a: u64, b: u64) bool {
        return a > b;
    }
    pub fn gt_u128(a: u128, b: u128) bool {
        return a > b;
    }
    pub fn gt_f16(a: f16, b: f16) bool {
        return a > b;
    }
    pub fn gt_f32(a: f32, b: f32) bool {
        return a > b;
    }
    pub fn gt_f64(a: f64, b: f64) bool {
        return a > b;
    }
    pub fn gt_f80(a: f80, b: f80) bool {
        return a > b;
    }
    pub fn gt_f128(a: f128, b: f128) bool {
        return a > b;
    }

    pub fn lte_i8(a: i8, b: i8) bool {
        return a <= b;
    }
    pub fn lte_i16(a: i16, b: i16) bool {
        return a <= b;
    }
    pub fn lte_i32(a: i32, b: i32) bool {
        return a <= b;
    }
    pub fn lte_i64(a: i64, b: i64) bool {
        return a <= b;
    }
    pub fn lte_i128(a: i128, b: i128) bool {
        return a <= b;
    }
    pub fn lte_u8(a: u8, b: u8) bool {
        return a <= b;
    }
    pub fn lte_u16(a: u16, b: u16) bool {
        return a <= b;
    }
    pub fn lte_u32(a: u32, b: u32) bool {
        return a <= b;
    }
    pub fn lte_u64(a: u64, b: u64) bool {
        return a <= b;
    }
    pub fn lte_u128(a: u128, b: u128) bool {
        return a <= b;
    }
    pub fn lte_f16(a: f16, b: f16) bool {
        return a <= b;
    }
    pub fn lte_f32(a: f32, b: f32) bool {
        return a <= b;
    }
    pub fn lte_f64(a: f64, b: f64) bool {
        return a <= b;
    }
    pub fn lte_f80(a: f80, b: f80) bool {
        return a <= b;
    }
    pub fn lte_f128(a: f128, b: f128) bool {
        return a <= b;
    }

    pub fn gte_i8(a: i8, b: i8) bool {
        return a >= b;
    }
    pub fn gte_i16(a: i16, b: i16) bool {
        return a >= b;
    }
    pub fn gte_i32(a: i32, b: i32) bool {
        return a >= b;
    }
    pub fn gte_i64(a: i64, b: i64) bool {
        return a >= b;
    }
    pub fn gte_i128(a: i128, b: i128) bool {
        return a >= b;
    }
    pub fn gte_u8(a: u8, b: u8) bool {
        return a >= b;
    }
    pub fn gte_u16(a: u16, b: u16) bool {
        return a >= b;
    }
    pub fn gte_u32(a: u32, b: u32) bool {
        return a >= b;
    }
    pub fn gte_u64(a: u64, b: u64) bool {
        return a >= b;
    }
    pub fn gte_u128(a: u128, b: u128) bool {
        return a >= b;
    }
    pub fn gte_f16(a: f16, b: f16) bool {
        return a >= b;
    }
    pub fn gte_f32(a: f32, b: f32) bool {
        return a >= b;
    }
    pub fn gte_f64(a: f64, b: f64) bool {
        return a >= b;
    }
    pub fn gte_f80(a: f80, b: f80) bool {
        return a >= b;
    }
    pub fn gte_f128(a: f128, b: f128) bool {
        return a >= b;
    }

    pub fn add_i8(a: i8, b: i8) i8 {
        return a +% b;
    }
    pub fn add_i16(a: i16, b: i16) i16 {
        return a +% b;
    }
    pub fn add_i32(a: i32, b: i32) i32 {
        return a +% b;
    }
    pub fn add_i64(a: i64, b: i64) i64 {
        return a +% b;
    }
    pub fn add_i128(a: i128, b: i128) i128 {
        return a +% b;
    }
    pub fn add_u8(a: u8, b: u8) u8 {
        return a +% b;
    }
    pub fn add_u16(a: u16, b: u16) u16 {
        return a +% b;
    }
    pub fn add_u32(a: u32, b: u32) u32 {
        return a +% b;
    }
    pub fn add_u64(a: u64, b: u64) u64 {
        return a +% b;
    }
    pub fn add_u128(a: u128, b: u128) u128 {
        return a +% b;
    }
    pub fn add_f16(a: f16, b: f16) f16 {
        return a + b;
    }
    pub fn add_f32(a: f32, b: f32) f32 {
        return a + b;
    }
    pub fn add_f64(a: f64, b: f64) f64 {
        return a + b;
    }
    pub fn add_f80(a: f80, b: f80) f80 {
        return a + b;
    }
    pub fn add_f128(a: f128, b: f128) f128 {
        return a + b;
    }

    pub fn sub_i8(a: i8, b: i8) i8 {
        return a -% b;
    }
    pub fn sub_i16(a: i16, b: i16) i16 {
        return a -% b;
    }
    pub fn sub_i32(a: i32, b: i32) i32 {
        return a -% b;
    }
    pub fn sub_i64(a: i64, b: i64) i64 {
        return a -% b;
    }
    pub fn sub_i128(a: i128, b: i128) i128 {
        return a -% b;
    }
    pub fn sub_u8(a: u8, b: u8) u8 {
        return a -% b;
    }
    pub fn sub_u16(a: u16, b: u16) u16 {
        return a -% b;
    }
    pub fn sub_u32(a: u32, b: u32) u32 {
        return a -% b;
    }
    pub fn sub_u64(a: u64, b: u64) u64 {
        return a -% b;
    }
    pub fn sub_u128(a: u128, b: u128) u128 {
        return a -% b;
    }
    pub fn sub_f16(a: f16, b: f16) f16 {
        return a - b;
    }
    pub fn sub_f32(a: f32, b: f32) f32 {
        return a - b;
    }
    pub fn sub_f64(a: f64, b: f64) f64 {
        return a - b;
    }
    pub fn sub_f80(a: f80, b: f80) f80 {
        return a - b;
    }
    pub fn sub_f128(a: f128, b: f128) f128 {
        return a - b;
    }

    pub fn mul_i8(a: i8, b: i8) i8 {
        return a *% b;
    }
    pub fn mul_i16(a: i16, b: i16) i16 {
        return a *% b;
    }
    pub fn mul_i32(a: i32, b: i32) i32 {
        return a *% b;
    }
    pub fn mul_i64(a: i64, b: i64) i64 {
        return a *% b;
    }
    pub fn mul_i128(a: i128, b: i128) i128 {
        return a *% b;
    }
    pub fn mul_u8(a: u8, b: u8) u8 {
        return a *% b;
    }
    pub fn mul_u16(a: u16, b: u16) u16 {
        return a *% b;
    }
    pub fn mul_u32(a: u32, b: u32) u32 {
        return a *% b;
    }
    pub fn mul_u64(a: u64, b: u64) u64 {
        return a *% b;
    }
    pub fn mul_u128(a: u128, b: u128) u128 {
        return a *% b;
    }
    pub fn mul_f16(a: f16, b: f16) f16 {
        return a * b;
    }
    pub fn mul_f32(a: f32, b: f32) f32 {
        return a * b;
    }
    pub fn mul_f64(a: f64, b: f64) f64 {
        return a * b;
    }
    pub fn mul_f80(a: f80, b: f80) f80 {
        return a * b;
    }
    pub fn mul_f128(a: f128, b: f128) f128 {
        return a * b;
    }

    pub fn divide_i8(a: i8, b: i8) i8 {
        return @divTrunc(a, b);
    }
    pub fn divide_i16(a: i16, b: i16) i16 {
        return @divTrunc(a, b);
    }
    pub fn divide_i32(a: i32, b: i32) i32 {
        return @divTrunc(a, b);
    }
    pub fn divide_i64(a: i64, b: i64) i64 {
        return @divTrunc(a, b);
    }
    pub fn divide_i128(a: i128, b: i128) i128 {
        return @divTrunc(a, b);
    }
    pub fn divide_u8(a: u8, b: u8) u8 {
        return @divTrunc(a, b);
    }
    pub fn divide_u16(a: u16, b: u16) u16 {
        return @divTrunc(a, b);
    }
    pub fn divide_u32(a: u32, b: u32) u32 {
        return @divTrunc(a, b);
    }
    pub fn divide_u64(a: u64, b: u64) u64 {
        return @divTrunc(a, b);
    }
    pub fn divide_u128(a: u128, b: u128) u128 {
        return @divTrunc(a, b);
    }
    pub fn divide_f16(a: f16, b: f16) f16 {
        return a / b;
    }
    pub fn divide_f32(a: f32, b: f32) f32 {
        return a / b;
    }
    pub fn divide_f64(a: f64, b: f64) f64 {
        return a / b;
    }
    pub fn divide_f80(a: f80, b: f80) f80 {
        return a / b;
    }
    pub fn divide_f128(a: f128, b: f128) f128 {
        return a / b;
    }

    pub fn remainder_i8(a: i8, b: i8) i8 {
        return @rem(a, b);
    }
    pub fn remainder_i16(a: i16, b: i16) i16 {
        return @rem(a, b);
    }
    pub fn remainder_i32(a: i32, b: i32) i32 {
        return @rem(a, b);
    }
    pub fn remainder_i64(a: i64, b: i64) i64 {
        return @rem(a, b);
    }
    pub fn remainder_i128(a: i128, b: i128) i128 {
        return @rem(a, b);
    }
    pub fn remainder_u8(a: u8, b: u8) u8 {
        return @rem(a, b);
    }
    pub fn remainder_u16(a: u16, b: u16) u16 {
        return @rem(a, b);
    }
    pub fn remainder_u32(a: u32, b: u32) u32 {
        return @rem(a, b);
    }
    pub fn remainder_u64(a: u64, b: u64) u64 {
        return @rem(a, b);
    }
    pub fn remainder_u128(a: u128, b: u128) u128 {
        return @rem(a, b);
    }
    pub fn remainder_f16(a: f16, b: f16) f16 {
        return @rem(a, b);
    }
    pub fn remainder_f32(a: f32, b: f32) f32 {
        return @rem(a, b);
    }
    pub fn remainder_f64(a: f64, b: f64) f64 {
        return @rem(a, b);
    }
    pub fn remainder_f80(a: f80, b: f80) f80 {
        return @rem(a, b);
    }
    pub fn remainder_f128(a: f128, b: f128) f128 {
        return @rem(a, b);
    }

    pub fn sleep(milliseconds: i64) i64 {
        if (milliseconds <= 0) return milliseconds;
        const ms: u64 = @intCast(milliseconds);
        var ts = std.posix.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        while (true) {
            const rc = std.c.nanosleep(&ts, &ts);
            if (rc == 0) break;
            if (std.posix.errno(rc) != .INTR) break;
        }
        return milliseconds;
    }
};

/// Simple fixed-buffer writer for inspect formatting.
/// Replaces the std.Io.File writer with direct buffer writes.
const BufWriter = struct {
    buf: []u8,
    pos: usize,

    pub fn print(self: *BufWriter, comptime fmt: []const u8, args: anytype) !void {
        const remaining = self.buf[self.pos..];
        const result = std.fmt.bufPrint(remaining, fmt, args) catch return;
        self.pos += result.len;
    }
};

// ============================================================
// TestTracker — mutable counters for test/assertion reporting
// ============================================================

pub const Zest = struct {
    var test_count: i64 = 0;
    var test_failures: i64 = 0;
    var assertion_count: i64 = 0;
    var assertion_failures: i64 = 0;
    var current_test_failed: bool = false;
    var seed: i64 = 0;
    var seed_set: bool = false;
    var timeout_ms: i64 = 0; // per-test timeout in milliseconds (0 = no timeout)
    var test_start_ns: i96 = 0; // timestamp when current test started
    var timeout_count: i64 = 0; // number of tests that timed out

    pub fn set_seed(s: i64) void {
        seed = s;
        seed_set = true;
    }

    pub fn get_seed() i64 {
        if (!seed_set) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const abs_nanos: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
            const positive = if (abs_nanos < 0) -abs_nanos else abs_nanos;
            seed = @intCast(positive & 0x7FFFFFFFFFFFFFFF);
            seed_set = true;
        }
        return seed;
    }

    pub fn set_timeout(ms: i64) void {
        timeout_ms = ms;
    }

    pub fn get_timeout() i64 {
        return timeout_ms;
    }

    pub fn begin_test() void {
        current_test_failed = false;
        test_count += 1;
        if (timeout_ms > 0) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            test_start_ns = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        }
    }

    pub fn check_timeout() bool {
        if (timeout_ms <= 0) return false;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        const elapsed_ns = now_ns - test_start_ns;
        const timeout_ns: i96 = @as(i96, timeout_ms) * 1_000_000;
        if (elapsed_ns > timeout_ns) {
            current_test_failed = true;
            timeout_count += 1;
            stdoutPrint("\x1b[1;33mT\x1b[0m", .{}); // yellow T for timeout
            return true;
        }
        return false;
    }

    pub fn end_test() void {
        if (current_test_failed) {
            test_failures += 1;
        }
    }

    pub fn print_result() void {
        if (current_test_failed) {
            print_fail();
        } else {
            print_dot();
        }
    }

    pub fn pass_assertion() void {
        assertion_count += 1;
    }

    pub fn fail_assertion() void {
        assertion_count += 1;
        assertion_failures += 1;
        current_test_failed = true;
    }

    pub fn print_dot() void {
        stdoutPrint("\x1b[1;32m.\x1b[0m", .{});
    }

    pub fn print_fail() void {
        stdoutPrint("\x1b[1;31mF\x1b[0m", .{});
    }

    pub fn summary() i64 {
        stdoutPrint("\n\nSeed: ", .{});
        writeI64(get_seed());
        if (timeout_ms > 0) {
            stdoutPrint("\nTimeout: ", .{});
            writeI64(timeout_ms);
            stdoutPrint("ms", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(test_count);
        stdoutPrint(" tests, ", .{});
        writeI64(test_failures);
        stdoutPrint(" failures", .{});
        if (timeout_count > 0) {
            stdoutPrint(" (", .{});
            writeI64(timeout_count);
            stdoutPrint(" timed out)", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(assertion_count);
        stdoutPrint(" assertions, ", .{});
        writeI64(assertion_failures);
        stdoutPrint(" failures\n", .{});
        return test_failures;
    }

    fn writeI64(val: i64) void {
        if (val < 0) {
            stdoutPrint("-", .{});
            writeI64(-val);
            return;
        }
        if (val >= 10) {
            writeI64(@divTrunc(val, 10));
        }
        const digit: u8 = @intCast(@mod(val, 10));
        const buf = [1]u8{'0' + digit};
        stdoutWrite(&buf);
    }
};

// ============================================================
// BinaryHelpers — concrete binary pattern matching operations
// for ZIR builder (no generics, no comptime type params)
// ============================================================

pub const BinaryHelpers = struct {
    // --- Integer reads (byte-aligned) ---
    // Each function reads N bytes from data at the given byte offset
    // using big-endian byte order, returning a u64/i64.
    // The ZIR builder calls these because ZIR cannot express generic
    // std.mem.readInt calls with comptime type parameters.

    pub fn readIntU8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(data[offset]);
    }

    pub fn readIntU16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .big));
    }

    pub fn readIntU16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .little));
    }

    pub fn readIntU32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .big));
    }

    pub fn readIntU32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .little));
    }

    pub fn readIntU64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .big));
    }

    pub fn readIntU64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .little));
    }

    pub fn readIntI8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(@as(i8, @bitCast(data[offset])));
    }

    pub fn readIntI16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .big));
    }

    pub fn readIntI16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .little));
    }

    pub fn readIntI32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .big));
    }

    pub fn readIntI32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .little));
    }

    pub fn readIntI64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .big);
    }

    pub fn readIntI64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .little);
    }

    // Sub-byte read: extract `bits` bits from data[offset] >> bit_offset
    pub fn readBitsU(data: []const u8, offset: usize, bit_offset: u3, bits: u8) i64 {
        if (offset >= data.len) return 0;
        const shifted: u8 = data[offset] >> bit_offset;
        if (bits == 0 or bits >= 8) return @intCast(shifted);
        const mask: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
        return @intCast(shifted & mask);
    }

    // --- Float reads ---
    pub fn readF32Big(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .big);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF32Little(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .little);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF64Big(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .big);
        return @bitCast(int_val);
    }

    pub fn readF64Little(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .little);
        return @bitCast(int_val);
    }

    // --- Slice ---
    // Returns data[offset..offset+length], or data[offset..] if length == 0 (sentinel for "rest")
    pub fn slice(data: []const u8, offset: usize, length: usize) []const u8 {
        const start = @min(offset, data.len);
        if (length == 0) return data[start..];
        const end = @min(std.math.add(usize, start, length) catch data.len, data.len);
        return data[start..end];
    }

    // --- UTF-8 reads ---
    // Returns the byte sequence length for the UTF-8 character at data[offset]
    pub fn utf8ByteLen(data: []const u8, offset: usize) u64 {
        if (offset >= data.len) return 1;
        return @intCast(std.unicode.utf8ByteSequenceLength(data[offset]) catch 1);
    }

    // Returns the decoded codepoint for the UTF-8 character at data[offset..offset+len]
    pub fn utf8Decode(data: []const u8, offset: usize, len: usize) u64 {
        if (offset + len > data.len or len == 0 or len > 4) return 0xFFFD;
        const end = offset + len;
        const byte_slice = data[offset..end];
        // utf8Decode expects a fixed-size array per length
        return switch (len) {
            1 => @intCast(byte_slice[0]),
            2 => @intCast(std.unicode.utf8Decode(byte_slice[0..2].*) catch 0xFFFD),
            3 => @intCast(std.unicode.utf8Decode(byte_slice[0..3].*) catch 0xFFFD),
            4 => @intCast(std.unicode.utf8Decode(byte_slice[0..4].*) catch 0xFFFD),
            else => 0xFFFD,
        };
    }

    // --- Prefix matching ---
    // Returns true if data starts with the expected prefix
    pub fn matchPrefix(data: []const u8, expected: []const u8) bool {
        if (data.len < expected.len) return false;
        return std.mem.eql(u8, data[0..expected.len], expected);
    }
};

// ============================================================
// List — Concrete cons-cell for pointer-based lists.
//
// Lists use nullable pointers: null = empty, non-null = cons cell.
// This allows runtime empty/non-empty checks that survive ZIR.
// ============================================================

// ---- Callable dispatch helpers ----
// Handle both bare function pointers and Zap closure structs transparently.
// Used by List and Map higher-order helpers.

fn isZapClosure(comptime Callback: type) bool {
    return switch (@typeInfo(Callback)) {
        .@"struct" => @hasField(Callback, "call_fn") and @hasField(Callback, "env"),
        else => false,
    };
}

fn isBareFunction(comptime Callback: type) bool {
    return switch (@typeInfo(Callback)) {
        .@"fn" => true,
        .pointer => |pointer| @typeInfo(pointer.child) == .@"fn",
        else => false,
    };
}

inline fn callBare0(callable: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{});
    return @call(.auto, &callable, .{});
}

inline fn callBare1(callable: anytype, arg0: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{arg0});
    return @call(.auto, &callable, .{arg0});
}

inline fn callBare2(callable: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{ arg0, arg1 });
    return @call(.auto, &callable, .{ arg0, arg1 });
}

inline fn callBare3(callable: anytype, arg0: anytype, arg1: anytype, arg2: anytype) CallableReturn(@TypeOf(callable)) {
    if (comptime @typeInfo(@TypeOf(callable)) == .pointer) return @call(.auto, callable, .{ arg0, arg1, arg2 });
    return @call(.auto, &callable, .{ arg0, arg1, arg2 });
}

fn CallableReturn(comptime Callback: type) type {
    return switch (@typeInfo(Callback)) {
        .@"struct" => if (@hasField(Callback, "call_fn") and @hasField(Callback, "env"))
            FunctionReturn(@FieldType(Callback, "call_fn"))
        else
            FunctionReturn(Callback),
        else => FunctionReturn(Callback),
    };
}

fn FunctionReturn(comptime Function: type) type {
    return switch (@typeInfo(Function)) {
        .pointer => |pointer| FunctionReturn(pointer.child),
        .@"fn" => |function| function.return_type orelse void,
        else => @compileError("callable value must be a function pointer or Zap closure, got " ++ @typeName(Function)),
    };
}

inline fn call1(callback: anytype, arg0: anytype) CallableReturn(@TypeOf(callback)) {
    if (comptime isZapClosure(@TypeOf(callback))) {
        return callback.call_fn(callback.env, arg0);
    }
    if (comptime isBareFunction(@TypeOf(callback))) {
        return callBare1(callback, arg0);
    }
    return callback(arg0);
}

inline fn call2(callback: anytype, arg0: anytype, arg1: anytype) CallableReturn(@TypeOf(callback)) {
    if (comptime isZapClosure(@TypeOf(callback))) {
        return callback.call_fn(callback.env, arg0, arg1);
    }
    if (comptime isBareFunction(@TypeOf(callback))) {
        return callBare2(callback, arg0, arg1);
    }
    return callback(arg0, arg1);
}

// ============================================================
// Type-derived Map/List dispatch helpers.
//
// These free functions accept `anytype` for the collection ref and
// reconstruct the underlying `Map(K, V)` / `List(T)` type at compile
// time via `@TypeOf` introspection. The Zap-side `:zig.Map.get(...)`
// and similar bridges route through these helpers so the call site's
// runtime type — including `Map(u32, Term)` — is preserved without
// the bridge needing to encode K/V into the call name.
// ============================================================

/// Extract the underlying `Map(K, V)` type from a `?*const Map(K, V)`
/// (or `*const Map(K, V)`) operand. Used by the dispatch helpers to
/// look up the right monomorph.
fn MapTypeOf(comptime MapPtr: type) type {
    const ti = @typeInfo(MapPtr);
    const ptr_inner = switch (ti) {
        .optional => |o| @typeInfo(o.child),
        .pointer => ti,
        else => @compileError("MapTypeOf: expected ?*const Map or *const Map, got " ++ @typeName(MapPtr)),
    };
    return switch (ptr_inner) {
        .pointer => |p| p.child,
        else => @compileError("MapTypeOf: expected ?*const Map, got " ++ @typeName(MapPtr)),
    };
}

fn ListTypeOf(comptime ListPtr: type) type {
    const ti = @typeInfo(ListPtr);
    const ptr_inner = switch (ti) {
        .optional => |o| @typeInfo(o.child),
        .pointer => ti,
        else => @compileError("ListTypeOf: expected ?*const List or *const List, got " ++ @typeName(ListPtr)),
    };
    return switch (ptr_inner) {
        .pointer => |p| p.child,
        else => @compileError("ListTypeOf: expected ?*const List, got " ++ @typeName(ListPtr)),
    };
}

/// Wrap a heterogeneous-friendly `Map.get` over an `anytype` default.
/// When the underlying Map's value type is `Term`, this wraps the
/// default into a Term, calls `Map.get`, then unwraps the resulting
/// Term back into the default's static type. When the value type is
/// already a concrete (homogeneous) type, the default is forwarded
/// unchanged. The return type matches whichever the caller passed —
/// string literals (`*const [N:0]u8`) are surfaced as `[]const u8`.
pub fn mapGet(map: anytype, key: anytype, default: anytype) MapGetReturnType(@TypeOf(map), @TypeOf(default)) {
    const M = MapTypeOf(@TypeOf(map));
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        const wrapped = Term.from(default);
        const result = M.get(map, key, wrapped);
        return Term.toCoerced(result, default);
    }
    return M.get(map, key, default);
}

fn MapGetReturnType(comptime MapPtr: type, comptime DefaultT: type) type {
    const M = MapTypeOf(MapPtr);
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        // String literals are returned as `[]const u8` slices.
        const dti = @typeInfo(DefaultT);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                return []const u8;
            }
        }
        return DefaultT;
    }
    return V;
}

pub fn mapHasKey(map: anytype, key: anytype) bool {
    const M = MapTypeOf(@TypeOf(map));
    return M.hasKey(map, key);
}

pub fn mapPut(map: anytype, key: anytype, value: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    const V = @FieldType(M.MapEntry, "value");
    if (V == Term) {
        return M.put(map, key, Term.from(value));
    }
    return M.put(map, key, value);
}

pub fn mapDelete(map: anytype, key: anytype) ?*const MapTypeOf(@TypeOf(map)) {
    const M = MapTypeOf(@TypeOf(map));
    return M.delete(map, key);
}

pub fn mapMerge(a: anytype, b: anytype) ?*const MapTypeOf(@TypeOf(a)) {
    const M = MapTypeOf(@TypeOf(a));
    return M.merge(a, b);
}

pub fn mapSize(map: anytype) i64 {
    const M = MapTypeOf(@TypeOf(map));
    return M.size(map);
}

pub fn mapIsEmpty(map: anytype) bool {
    const M = MapTypeOf(@TypeOf(map));
    return M.isEmpty(map);
}

pub fn mapNext(map: anytype) std.meta.Tuple(&.{
    u32,
    std.meta.Tuple(&.{ MapKeyOf(@TypeOf(map)), MapValueOf(@TypeOf(map)) }),
    ?*const MapTypeOf(@TypeOf(map)),
}) {
    const M = MapTypeOf(@TypeOf(map));
    return M.next(map);
}

pub fn mapKeys(map: anytype) ?*const List(MapKeyOf(@TypeOf(map))) {
    const M = MapTypeOf(@TypeOf(map));
    return M.keys(map);
}

pub fn mapValues(map: anytype) ?*const List(MapValueOf(@TypeOf(map))) {
    const M = MapTypeOf(@TypeOf(map));
    return M.values(map);
}

pub fn mapEnumReduceValues(map: anytype, initial: i64, callback: anytype) i64 {
    const M = MapTypeOf(@TypeOf(map));
    return M.enumReduceValues(map, initial, callback);
}

fn MapValueOf(comptime MapPtr: type) type {
    const M = MapTypeOf(MapPtr);
    return @FieldType(M.MapEntry, "value");
}

fn MapKeyOf(comptime MapPtr: type) type {
    const M = MapTypeOf(MapPtr);
    return @FieldType(M.MapEntry, "key");
}

pub fn listGetHead(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.getHead(list);
}

pub fn listGetTail(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.getTail(list);
}

pub fn listIsEmpty(list: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.isEmpty(list);
}

pub fn listLength(list: anytype) i64 {
    const L = ListTypeOf(@TypeOf(list));
    return L.length(list);
}

pub fn listGet(list: anytype, index: i64) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.get(list, index);
}

pub fn listLast(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.last(list);
}

pub fn listReverse(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.reverse(list);
}

pub fn listConcat(a: anytype, b: anytype) @TypeOf(a) {
    const L = ListTypeOf(@TypeOf(a));
    return L.concat(a, b);
}

pub fn listAppend(list: anytype, value: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.append(list, value);
}

pub fn listContains(list: anytype, value: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.contains(list, value);
}

pub fn listTake(list: anytype, count: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.take(list, count);
}

pub fn listNext(list: anytype) std.meta.Tuple(&.{ u32, ListElementOf(@TypeOf(list)), @TypeOf(list) }) {
    const L = ListTypeOf(@TypeOf(list));
    return L.next(list);
}

pub fn listCons(head: anytype, tail: anytype) @TypeOf(tail) {
    const L = ListTypeOf(@TypeOf(tail));
    return L.cons(head, tail);
}

pub fn listDrop(list: anytype, count: i64) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.drop(list, count);
}

pub fn listUniq(list: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.uniq(list);
}

pub fn listMapFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.mapFn(list, callback);
}

pub fn listFilterFn(list: anytype, predicate: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.filterFn(list, predicate);
}

pub fn listRejectFn(list: anytype, predicate: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.rejectFn(list, predicate);
}

pub fn listEnumReduceSimple(list: anytype, initial: ListElementOf(@TypeOf(list)), callback: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.enumReduceSimple(list, initial, callback);
}

pub fn listEachFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.eachFn(list, callback);
}

pub fn listFindFn(list: anytype, default: anytype, predicate: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.findFn(list, default, predicate);
}

pub fn listAnyFn(list: anytype, predicate: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.anyFn(list, predicate);
}

pub fn listAllFn(list: anytype, predicate: anytype) bool {
    const L = ListTypeOf(@TypeOf(list));
    return L.allFn(list, predicate);
}

pub fn listCountFn(list: anytype, predicate: anytype) i64 {
    const L = ListTypeOf(@TypeOf(list));
    return L.countFn(list, predicate);
}

pub fn listSortFn(list: anytype, comparator: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.sortFn(list, comparator);
}

pub fn listFlatMapFn(list: anytype, callback: anytype) @TypeOf(list) {
    const L = ListTypeOf(@TypeOf(list));
    return L.flatMapFn(list, callback);
}

pub fn listMaxVal(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.maxVal(list);
}

pub fn listMinVal(list: anytype) ListElementOf(@TypeOf(list)) {
    const L = ListTypeOf(@TypeOf(list));
    return L.minVal(list);
}

fn ListElementOf(comptime ListPtr: type) type {
    const L = ListTypeOf(ListPtr);
    return @FieldType(L, "head");
}

// ============================================================
// Term — heterogeneous value wrapper.
//
// Used as the storage type for collections whose elements are not
// homogeneously typed (e.g. `%{name: "Alice", age: 30}` where the
// values are `String` and `i64`). The compiler picks `Term` as the
// element type whenever the static element types disagree, then
// inserts wrapping (`Term.from(x)`) at construction sites and
// unwrapping (`Term.to(T, t, default)`) at consumption sites so the
// caller still sees a concrete value of the expected type.
//
// Homogeneous collections continue to instantiate the underlying
// `List(T)` / `Map(K, V)` directly with their concrete element
// types; `Term` is engaged only for the heterogeneous case.
// ============================================================

pub const Term = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    bool_val: bool,
    atom: u32,
    nil: void,
    /// Erased ?*const List(Term). Stored as opaque pointer to avoid
    /// the recursive type definition; callers reinterpret via the
    /// helpers below.
    list: ?*const anyopaque,
    /// Erased ?*const Map(K, Term). The key type is irrelevant to
    /// `Term` itself — collection-specific code knows the key type.
    map: ?*const anyopaque,
    /// Owned slice of child terms (small fixed-size aggregates).
    tuple: []const Term,

    /// Wrap a Zig value of any supported type as a `Term`. Comptime
    /// dispatch keeps the call sites at the wrap point allocation-free
    /// for scalars and slices.
    pub fn from(value: anytype) Term {
        const T = @TypeOf(value);
        const ti = @typeInfo(T);
        return switch (ti) {
            .bool => .{ .bool_val = value },
            .int => |int_info| blk: {
                if (int_info.signedness == .signed) {
                    break :blk .{ .int = @intCast(value) };
                } else {
                    // u32 atoms — emitted Zap atoms are u32. Map them
                    // to the atom variant so equality and printing can
                    // round-trip correctly.
                    if (T == u32) break :blk .{ .atom = value };
                    break :blk .{ .int = @intCast(value) };
                }
            },
            .comptime_int => .{ .int = @intCast(value) },
            .float => .{ .float = @floatCast(value) },
            .comptime_float => .{ .float = @floatCast(value) },
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk .{ .str = value };
                }
                if (ptr_info.size == .one) {
                    const child_info = @typeInfo(ptr_info.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        break :blk .{ .str = value[0..] };
                    }
                }
                break :blk .{ .nil = {} };
            },
            .optional => |opt_info| blk: {
                if (value) |v| {
                    // Re-enter `from` with the unwrapped value.
                    break :blk Term.from(v);
                }
                _ = opt_info;
                break :blk .{ .nil = {} };
            },
            .void => .{ .nil = {} },
            .null => .{ .nil = {} },
            else => blk: {
                if (T == Term) break :blk value;
                break :blk .{ .nil = {} };
            },
        };
    }

    /// Unwrap a `Term` into a concrete Zig value of type `T`. If the
    /// runtime variant does not match, returns the supplied default.
    /// Accepts `[]const u8` slices and `*const [N:0]u8` string-literal
    /// pointers transparently — both fan in to the `.str` variant.
    pub fn to(comptime T: type, t: Term, default: T) T {
        if (T == Term) return t;
        const ti = @typeInfo(T);
        return switch (ti) {
            .bool => if (t == .bool_val) t.bool_val else default,
            .int => |int_info| blk: {
                if (int_info.signedness == .unsigned and T == u32) {
                    break :blk if (t == .atom) t.atom else default;
                }
                if (t == .int) {
                    break :blk @intCast(t.int);
                }
                break :blk default;
            },
            .float => if (t == .float) @floatCast(t.float) else default,
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk if (t == .str) t.str else default;
                }
                break :blk default;
            },
            .optional => blk: {
                if (t == .nil) break :blk null;
                break :blk default;
            },
            .void => {},
            else => default,
        };
    }

    /// Unwrap a `Term` to a value compatible with `default`'s static
    /// type, but always materialise the result as a `[]const u8` slice
    /// whenever the default is a string (slice or string-literal
    /// pointer). This sidesteps a Zig codegen quirk where parameters
    /// declared `anytype` keep their argument's literal pointer-to-
    /// array type instead of coercing to `[]const u8`, which would
    /// otherwise force `Term.to` to compare incompatible target types.
    pub fn toCoerced(t: Term, default: anytype) ToCoercedResult(@TypeOf(default)) {
        const D = @TypeOf(default);
        const dti = @typeInfo(D);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                // String literal — return as []const u8.
                return if (t == .str) t.str else @as([]const u8, default);
            }
        }
        return Term.to(D, t, default);
    }

    pub fn ToCoercedResult(comptime D: type) type {
        const dti = @typeInfo(D);
        if (dti == .pointer and dti.pointer.size == .one) {
            const child_info = @typeInfo(dti.pointer.child);
            if (child_info == .array and child_info.array.child == u8) {
                return []const u8;
            }
        }
        return D;
    }

    pub fn eql(a: Term, b: Term) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .int => a.int == b.int,
            .float => a.float == b.float,
            .str => std.mem.eql(u8, a.str, b.str),
            .bool_val => a.bool_val == b.bool_val,
            .atom => a.atom == b.atom,
            .nil => true,
            .list => a.list == b.list,
            .map => a.map == b.map,
            .tuple => blk: {
                if (a.tuple.len != b.tuple.len) break :blk false;
                for (a.tuple, b.tuple) |ea, eb| {
                    if (!eql(ea, eb)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// FNV-1a hash seed for Term values. Used by `Map(K, Term)` to
    /// hash heterogeneous values when atoms-as-keys still need stable
    /// hashing of the value type for collision resolution diagnostics.
    pub fn hash(self: Term) u32 {
        return switch (self) {
            .int => |v| @truncate(@as(u64, @bitCast(v))),
            .float => |v| @truncate(@as(u64, @bitCast(v))),
            .str => |v| blk: {
                var h: u32 = 2166136261;
                for (v) |byte| {
                    h ^= byte;
                    h *%= 16777619;
                }
                break :blk h;
            },
            .bool_val => |v| if (v) @as(u32, 1) else @as(u32, 0),
            .atom => |v| v,
            .nil => 0,
            .list => 0,
            .map => 0,
            .tuple => |elems| blk: {
                var h: u32 = 2166136261;
                for (elems) |elem| {
                    h ^= hash(elem);
                    h *%= 16777619;
                }
                break :blk h;
            },
        };
    }
};

/// Coerce a value of any type back to the type produced by
/// `Term.ToCoercedResult(@TypeOf(default))`. When the value is itself a
/// `Term`, unwraps via `Term.toCoerced`. When the value is already
/// compatible with `default` (the homogeneous case where the runtime
/// collection's element type matches the declared type), returns it
/// as-is. Used by pattern lowering for heterogeneous keyword lists:
/// the function param's declared tuple slot may be `i64`, but the actual
/// runtime tuple may carry `Term` values (when the caller passed a
/// heterogeneous keyword list). One helper handles both shapes via a
/// comptime branch on `@TypeOf(value)`.
pub fn coerceFromMaybeTerm(value: anytype, default: anytype) Term.ToCoercedResult(@TypeOf(default)) {
    const V = @TypeOf(value);
    if (V == Term) {
        return Term.toCoerced(value, default);
    }
    return value;
}

// ============================================================
// wyhash — embedded hash function for the dense Map.
//
// Wraps Zig's stdlib production wyhash (the same `final v3` used by
// `ankerl::unordered_dense` by default) and adds a per-process random
// seed source. Inlined into runtime.zig (rather than imported from
// `wyhash.zig`) because runtime.zig is the single registered runtime
// source for every user binary — additional sibling files cannot be
// imported. The host build retains `src/wyhash.zig` for unit tests.
// ============================================================

const Wyhash = struct {
    const StdWyhash = std.hash.Wyhash;

    /// Strictly-monotonic counter bumped on every seed materialization.
    /// Combined with ASLR-derived entropy via SplitMix64 to produce a
    /// per-instance seed unpredictable to an attacker without process
    /// introspection.
    var seed_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    threadlocal var thread_seed_state: ?u64 = null;

    inline fn splitMix64(state: u64) u64 {
        var z = state +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn osEntropy() u64 {
        var buf: [8]u8 = undefined;
        switch (builtin.os.tag) {
            .linux => {
                const rc = std.os.linux.getrandom(&buf, buf.len, 0);
                if (rc == buf.len) {
                    return std.mem.readInt(u64, &buf, .little);
                }
            },
            else => {},
        }
        return 0;
    }

    pub fn nextSeed() u64 {
        const counter = seed_counter.fetchAdd(1, .monotonic);
        if (thread_seed_state == null) {
            const ra: u64 = @intCast(@returnAddress());
            thread_seed_state = splitMix64(ra ^ osEntropy() ^ 0xD1B54A32D192ED03);
        }
        thread_seed_state = splitMix64(thread_seed_state.? +% counter);
        return thread_seed_state.?;
    }

    pub inline fn hashU64(seed: u64, value: u64) u64 {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        return StdWyhash.hash(seed, &bytes);
    }

    pub inline fn hashU32(seed: u64, value: u32) u64 {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        return StdWyhash.hash(seed, &bytes);
    }

    pub inline fn hashBytes(seed: u64, bytes: []const u8) u64 {
        return StdWyhash.hash(seed, bytes);
    }

    /// Comptime-dispatched hasher matching `wyhash.zig::hash`.
    pub inline fn hash(seed: u64, value: anytype) u64 {
        const T = @TypeOf(value);
        const ti = @typeInfo(T);
        return switch (ti) {
            .int => |int_info| blk: {
                if (int_info.bits <= 32) {
                    break :blk hashU32(seed, @intCast(@as(std.meta.Int(.unsigned, int_info.bits), @bitCast(value))));
                }
                if (int_info.bits == 64) {
                    break :blk hashU64(seed, @bitCast(value));
                }
                var bytes: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, .little);
                break :blk hashBytes(seed, &bytes);
            },
            .comptime_int => hashU64(seed, @intCast(value)),
            .bool => blk: {
                const b: [1]u8 = .{@intFromBool(value)};
                break :blk hashBytes(seed, &b);
            },
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk hashBytes(seed, value);
                }
                break :blk hashU64(seed, @intCast(@intFromPtr(value)));
            },
            else => @compileError("wyhash.hash: unsupported key type " ++ @typeName(T)),
        };
    }
};

// ============================================================
// Dense Map constants. Layout described in
// `docs/dense-map-implementation-plan.md` §1.1.
// ============================================================

/// Empty bucket sentinel.
const DENSE_MAP_EMPTY: u32 = 0xFFFFFFFF;
/// Distance increment encoded in `dist_and_fingerprint` (high 24 bits).
const DENSE_MAP_DIST_INC: u32 = 0x100;
/// Mask for the 8-bit fingerprint (low byte of `dist_and_fingerprint`).
const DENSE_MAP_FINGERPRINT_MASK: u32 = 0xFF;
/// Initial capacity at first allocation (power of 2).
const DENSE_MAP_INITIAL_CAPACITY: u32 = 8;
/// Load factor numerator/denominator: resize when len+1 > cap*7/8.
const DENSE_MAP_LOAD_NUM: u32 = 7;
const DENSE_MAP_LOAD_DEN: u32 = 8;

/// Bucket — 8 bytes. `dist_and_fingerprint` packs distance (high 24 bits,
/// +1 shifted by `DENSE_MAP_DIST_INC` so home slot reads `0x100`) and
/// fingerprint (low 8 bits = high byte of the 64-bit hash).
pub const DenseMapBucket = extern struct {
    dist_and_fingerprint: u32,
    entry_idx: u32,
};

comptime {
    std.debug.assert(@sizeOf(DenseMapBucket) == 8);
}

// ============================================================
// Map — dense, insertion-ordered, open-addressed table.
//
// The cell pointer (`?*const Map(K, V)`) is the buffer pointer.
// `null` is the empty-map sentinel — no allocation until first put.
// The struct's first field is `header: ArcHeader` so the runtime's
// `hasInlineArcHeader` recognises it for ARC dispatch (same shape as
// `List(T)` cells and the legacy HAMT cell).
//
// Layout (single contiguous allocation):
//
//   [ Self            (header, len, capacity, entry_cap, hash_seed) ]
//   [ buckets[capacity] of DenseMapBucket                            ]
//   [ entries[entry_cap] of MapEntry { hash, key, value }            ]
//
// Robin Hood probing with a `(dist << 8) | fingerprint` packed metric
// drives insertion and lookup. Delete is swap-remove on entries plus
// backshift on buckets. Refcount-aware mutators dispatch on
// `header.count() == 1` for the rc-1 fast path.
// ============================================================

pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        // Inline buffer header. Self IS the header; the cell pointer is
        // the buffer pointer. `header: ArcHeader` lives at offset 0 so
        // `ArcRuntime.hasInlineArcHeader` recognises this type as
        // self-managed (same shape as List(T) cells).

        /// ARC refcount. Initialised to 1 by `bufferAlloc`.
        header: ArcHeader,
        /// Number of populated entries (also the cursor for the next entry).
        len: u32,
        /// Number of bucket slots (always a power of 2, >= INITIAL_CAPACITY).
        capacity: u32,
        /// Number of entry slots (kept in lockstep with `capacity` here).
        entry_cap: u32,
        /// Per-instance hash seed sampled at construction. Used for every
        /// key hash so resize is deterministic.
        hash_seed: u64,

        /// Entry stored densely in insertion order. Plain (non-extern)
        /// struct so K and V can be slices, optionals, tagged unions, etc.
        pub const MapEntry = struct {
            hash: u64,
            key: K,
            value: V,
        };

        // -------------------------------------------------------------------
        // Layout helpers
        // -------------------------------------------------------------------

        inline fn bucketsByteOffset() usize {
            return std.mem.alignForward(usize, @sizeOf(Self), @alignOf(DenseMapBucket));
        }

        inline fn entriesByteOffset(capacity_arg: u32) usize {
            const after_buckets = bucketsByteOffset() + @as(usize, capacity_arg) * @sizeOf(DenseMapBucket);
            return std.mem.alignForward(usize, after_buckets, @alignOf(MapEntry));
        }

        inline fn bufferSize(capacity_arg: u32, entry_cap_arg: u32) usize {
            return entriesByteOffset(capacity_arg) + @as(usize, entry_cap_arg) * @sizeOf(MapEntry);
        }

        inline fn bufferAlign() std.mem.Alignment {
            const a_self = std.mem.Alignment.of(Self);
            const a_bucket = std.mem.Alignment.of(DenseMapBucket);
            const a_entry = std.mem.Alignment.of(MapEntry);
            return a_self.max(a_bucket).max(a_entry);
        }

        inline fn bucketsPtr(self: *const Self) [*]DenseMapBucket {
            const base: [*]u8 = @ptrCast(@constCast(self));
            return @as([*]DenseMapBucket, @ptrCast(@alignCast(base + bucketsByteOffset())));
        }

        inline fn entriesPtr(self: *const Self) [*]MapEntry {
            const base: [*]u8 = @ptrCast(@constCast(self));
            return @as([*]MapEntry, @ptrCast(@alignCast(base + entriesByteOffset(self.capacity))));
        }

        inline fn bucketAt(self: *Self, idx: u32) *DenseMapBucket {
            std.debug.assert(idx < self.capacity);
            return &self.bucketsPtr()[idx];
        }

        inline fn entryAt(self: *Self, idx: u32) *MapEntry {
            std.debug.assert(idx < self.len);
            return &self.entriesPtr()[idx];
        }

        inline fn entryAtConst(self: *const Self, idx: u32) *const MapEntry {
            std.debug.assert(idx < self.len);
            return &self.entriesPtr()[idx];
        }

        // -------------------------------------------------------------------
        // Public introspection
        // -------------------------------------------------------------------

        pub fn size(map: ?*const Self) i64 {
            if (map) |m| {
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
                return @intCast(m.len);
            }
            return 0;
        }

        pub fn isEmpty(map: ?*const Self) bool {
            return map == null;
        }

        pub fn empty() ?*const Self {
            return null;
        }

        // -------------------------------------------------------------------
        // Buffer alloc / free
        // -------------------------------------------------------------------

        /// Allocate a freshly-zeroed buffer with the given capacity.
        /// Refcount=1, all buckets EMPTY, `len=0`.
        fn bufferAlloc(capacity_arg: u32, seed: u64, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity_arg));
            const total = bufferSize(capacity_arg, capacity_arg);
            const allocator = std.heap.c_allocator;
            const align_v = comptime bufferAlign();
            const raw = allocator.alignedAlloc(u8, align_v, total) catch return null;
            const self_ptr: *Self = @ptrCast(@alignCast(raw.ptr));
            self_ptr.* = .{
                .header = ArcHeader.init(),
                .len = 0,
                .capacity = capacity_arg,
                .entry_cap = capacity_arg,
                .hash_seed = seed,
            };
            const buckets_ptr = self_ptr.bucketsPtr();
            for (0..capacity_arg) |i| {
                buckets_ptr[i] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
            }
            if (comptime instrument_map) {
                mapInstrumentationOnAlloc(@intFromPtr(self_ptr), 0, creation_callsite);
            }
            return self_ptr;
        }

        /// Free the buffer without deep-releasing K/V children. Used on
        /// the unique-owner resize path where children have been moved.
        fn bufferFreeShallow(self: *Self) void {
            const allocator = std.heap.c_allocator;
            const total = bufferSize(self.capacity, self.entry_cap);
            const align_v = comptime bufferAlign();
            const raw_ptr: [*]u8 = @ptrCast(self);
            const raw_slice = @as([*]align(align_v.toByteUnits()) u8, @alignCast(raw_ptr))[0..total];
            allocator.free(raw_slice);
        }

        fn bufferFreeDeep(self: *Self) void {
            const len = self.len;
            const entries = self.entriesPtr();
            const allocator = std.heap.c_allocator;
            for (0..len) |i| {
                releaseEntryKey(entries[i].key, allocator);
                releaseEntryValue(entries[i].value, allocator);
            }
            self.bufferFreeShallow();
        }

        // -------------------------------------------------------------------
        // Retain / release
        // -------------------------------------------------------------------

        pub fn retain(map: ?*const Self) ?*const Self {
            if (map) |m| {
                const mut: *Self = @constCast(m);
                mut.header.retain();
                arc_retains_total += 1;
                if (comptime instrument_map) {
                    const new_count = mut.header.count();
                    mapInstrumentationOnRetain(@intFromPtr(m), new_count);
                }
            }
            return map;
        }

        pub fn release(map: ?*const Self) void {
            if (map == null) return;
            const m = map.?;
            const mut: *Self = @constCast(m);
            arc_releases_total += 1;
            if (!mut.header.release()) return;
            if (comptime instrument_map) {
                mapInstrumentationOnRelease(@intFromPtr(m), m.len);
            }
            mut.bufferFreeDeep();
        }

        pub fn arcReleaseDeep(allocator: std.mem.Allocator, ptr: *const Self) void {
            _ = allocator;
            release(@as(?*const Self, ptr));
        }

        // -------------------------------------------------------------------
        // Clone helpers (deep-retain-children vs move-children)
        // -------------------------------------------------------------------

        fn cloneBufferRetainingChildren(self: *const Self, new_capacity: u32, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(new_capacity));
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.hash_seed, creation_callsite) orelse return null;

            const old_entries = self.entriesPtr();
            const new_entries = fresh.entriesPtr();
            for (0..self.len) |i| {
                new_entries[i] = old_entries[i];
                retainEntryKey(new_entries[i].key);
                retainEntryValue(new_entries[i].value);
            }
            fresh.len = self.len;

            if (new_capacity == self.capacity) {
                const old_buckets = self.bucketsPtr();
                const new_buckets = fresh.bucketsPtr();
                for (0..self.capacity) |i| {
                    new_buckets[i] = old_buckets[i];
                }
            } else {
                fresh.rebucketAll();
            }
            return fresh;
        }

        fn cloneBufferMovingChildren(self: *const Self, new_capacity: u32, creation_callsite: u64) ?*Self {
            std.debug.assert(std.math.isPowerOfTwo(new_capacity));
            std.debug.assert(new_capacity >= self.len);
            const fresh = bufferAlloc(new_capacity, self.hash_seed, creation_callsite) orelse return null;

            const old_entries = self.entriesPtr();
            const new_entries = fresh.entriesPtr();
            for (0..self.len) |i| {
                new_entries[i] = old_entries[i];
            }
            fresh.len = self.len;

            if (new_capacity == self.capacity) {
                const old_buckets = self.bucketsPtr();
                const new_buckets = fresh.bucketsPtr();
                for (0..self.capacity) |i| {
                    new_buckets[i] = old_buckets[i];
                }
            } else {
                fresh.rebucketAll();
            }
            return fresh;
        }

        fn rebucketAll(self: *Self) void {
            const len = self.len;
            for (0..len) |i| {
                const entry_idx: u32 = @intCast(i);
                const entry = self.entryAt(entry_idx);
                self.installBucket(entry.hash, entry_idx);
            }
        }

        // -------------------------------------------------------------------
        // Hash / probe helpers
        // -------------------------------------------------------------------

        inline fn hashKey(self: *const Self, key: K) u64 {
            if (K == Term) return hashTerm(self.hash_seed, key);
            return Wyhash.hash(self.hash_seed, key);
        }

        inline fn initialProbe(h: u64) u32 {
            const fp: u32 = @intCast(h >> 56);
            return DENSE_MAP_DIST_INC | fp;
        }

        inline fn homeSlot(self: *const Self, h: u64) u32 {
            const mask: u32 = self.capacity - 1;
            return @as(u32, @truncate(h)) & mask;
        }

        inline fn nextSlot(self: *const Self, slot: u32) u32 {
            const mask: u32 = self.capacity - 1;
            return (slot + 1) & mask;
        }

        // -------------------------------------------------------------------
        // Lookup
        // -------------------------------------------------------------------

        fn findEntry(map: ?*const Self, key: K) ?u32 {
            const self = map orelse return null;
            if (self.len == 0) return null;
            const h = self.hashKey(key);
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            const buckets = self.bucketsPtr();
            const entries = self.entriesPtr();
            while (true) {
                const b = buckets[slot];
                if (b.dist_and_fingerprint == DENSE_MAP_EMPTY) return null;
                if (b.dist_and_fingerprint < probe) return null;
                if (b.dist_and_fingerprint == probe) {
                    const e = &entries[b.entry_idx];
                    if (e.hash == h and keysEqual(e.key, key)) return b.entry_idx;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        pub fn hasKey(map: ?*const Self, key: K) bool {
            if (map) |m| {
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            return findEntry(map, key) != null;
        }

        pub fn get(map: ?*const Self, key: K, default: V) V {
            if (map) |m| {
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            const self = map orelse return default;
            const idx = findEntry(self, key) orelse return default;
            return self.entryAtConst(idx).value;
        }

        /// Vestigial helper kept for HAMT-era callers that hardcoded a
        /// `[]const u8` default into the result. The legacy implementation
        /// always returned the default; we preserve the behaviour.
        pub fn getStr(map: ?*const Self, key: K, default: []const u8) []const u8 {
            _ = key;
            if (map) |m| {
                if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(m));
            }
            return default;
        }

        // -------------------------------------------------------------------
        // Insert
        // -------------------------------------------------------------------

        pub fn put(map: ?*const Self, key: K, value: V) ?*const Self {
            const callsite = @returnAddress();
            if (comptime instrument_map) {
                if (map) |m| {
                    const ctx = mapInstrumentationBumpMutation(@intFromPtr(m), .put);
                    mapInstrumentationSetParent(ctx.lineage_id, ctx.instance_id);
                    defer mapInstrumentationClearParent();
                    const result = putInner(map, key, value, callsite);
                    if (ctx.had_share_event) {
                        if (result) |r| {
                            if (@intFromPtr(r) != @intFromPtr(m)) {
                                mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                            }
                        }
                    }
                    return result;
                }
            }
            return putInner(map, key, value, callsite);
        }

        fn putInner(map: ?*const Self, key: K, value: V, callsite: u64) ?*const Self {
            if (map == null) {
                const fresh = bufferAlloc(DENSE_MAP_INITIAL_CAPACITY, Wyhash.nextSeed(), callsite) orelse return null;
                _ = putInPlaceInsert(fresh, key, value);
                return fresh;
            }
            const self = map.?;

            // Phase 4 (dense Map): refcount-aware fast path.
            //
            // When the caller has transferred ownership of `self`
            // (refcount == 1), mutate the buffer in place and return
            // the same pointer (or a resized buffer with children
            // moved over verbatim). When `self` is shared
            // (refcount > 1), fall back to the deep-retain clone path
            // so the original map stays valid. This is the central
            // optimisation behind the dense Map design — in working-
            // dictionary patterns the receiver is uniquely owned
            // essentially every time, so the fast path collapses
            // repeated put/delete into a stream of in-place mutations
            // with no allocation churn.
            //
            // The codegen's owned-mutating call-site rewrite (in
            // `arc_ownership.rewriteOwnedConsumeBuiltinSites` and
            // `rewriteOwnedConsumeSites` plus the param convention
            // promotion in `arc_param_convention.shouldPromoteSlot`)
            // ensures that last-use Map.put calls reach this function
            // with refcount == 1.
            dense_map_mut_calls_total += 1;
            if (self.header.count() == 1) {
                dense_map_rc1_fast_path_total += 1;
                const mut: *Self = @constCast(self);
                return putInPlace(mut, key, value, callsite);
            }

            const target_cap = pickCapacity(self.capacity, self.len + 1);
            const clone = cloneBufferRetainingChildren(self, target_cap, callsite) orelse return null;
            return putInPlace(clone, key, value, callsite);
        }

        fn putInPlace(target: *Self, key: K, value: V, callsite: u64) ?*const Self {
            if (findEntry(target, key)) |existing_idx| {
                const allocator = std.heap.c_allocator;
                const entry = target.entryAt(existing_idx);
                releaseEntryValue(entry.value, allocator);
                entry.value = value;
                releaseEntryKey(key, allocator);
                return target;
            }

            const old_cap = target.capacity;
            const new_cap = pickCapacity(old_cap, target.len + 1);
            var dest: *Self = target;
            if (new_cap != old_cap) {
                dest = cloneBufferMovingChildren(target, new_cap, callsite) orelse return null;
                // Notify the instrumentation harness that the old
                // buffer is being retired before its zero-transition
                // release. The rc-1 fast-path resize transfers
                // children to a fresh buffer and then frees the old
                // one shallowly (no `release()` call), so the standard
                // `mapInstrumentationOnRelease` hook never fires for
                // these instances. Without this notification the
                // differential classifier would see every resize as a
                // class-V "lost" instance instead of the class-S
                // "single owner mutated in place" shape it actually
                // represents.
                if (comptime instrument_map) {
                    mapInstrumentationOnRelease(@intFromPtr(target), target.len);
                }
                target.bufferFreeShallow();
            }
            _ = putInPlaceInsert(dest, key, value);
            return dest;
        }

        fn putInPlaceInsert(dest: *Self, key: K, value: V) *Self {
            const h = dest.hashKey(key);
            const new_idx: u32 = dest.len;
            std.debug.assert(new_idx < dest.entry_cap);
            const entries = dest.entriesPtr();
            entries[new_idx] = .{ .hash = h, .key = key, .value = value };
            dest.len = new_idx + 1;
            dest.installBucket(h, new_idx);
            return dest;
        }

        // -------------------------------------------------------------------
        // Delete (swap-remove + Robin Hood backshift)
        // -------------------------------------------------------------------

        pub fn delete(map: ?*const Self, key: K) ?*const Self {
            const callsite = @returnAddress();
            if (comptime instrument_map) {
                if (map) |m| {
                    const ctx = mapInstrumentationBumpMutation(@intFromPtr(m), .delete);
                    mapInstrumentationSetParent(ctx.lineage_id, ctx.instance_id);
                    defer mapInstrumentationClearParent();
                    const result = deleteInner(map, key, callsite);
                    if (ctx.had_share_event) {
                        if (result) |r| {
                            if (@intFromPtr(r) != @intFromPtr(m)) {
                                mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                            }
                        } else {
                            mapInstrumentationNotePostShareMutation(@intFromPtr(m));
                        }
                    }
                    return result;
                }
            }
            return deleteInner(map, key, callsite);
        }

        fn deleteInner(map: ?*const Self, key: K, callsite: u64) ?*const Self {
            const self = map orelse return null;

            // Phase 4 (dense Map): refcount-aware fast path. On unique
            // ownership we mutate the live buffer in place (with
            // `deleteFoundInPlace` deep-releasing the removed entry's
            // K/V). On absent-key we still return the same handle
            // without allocating. On shared ownership we deep-retain
            // clone, then run the same swap-remove on the clone — the
            // source map stays unchanged.
            if (self.header.count() == 1) {
                const mut: *Self = @constCast(self);
                if (findEntry(mut, key)) |found_entry_idx| {
                    deleteFoundInPlace(mut, found_entry_idx);
                }
                return mut;
            }

            const clone = cloneBufferRetainingChildren(self, self.capacity, callsite) orelse return null;
            if (findEntry(clone, key)) |found_entry_idx| {
                deleteFoundInPlace(clone, found_entry_idx);
            }
            return clone;
        }

        fn deleteFoundInPlace(target: *Self, found_entry_idx: u32) void {
            const old_len = target.len;
            std.debug.assert(old_len > 0);

            const target_hash = target.entryAtConst(found_entry_idx).hash;
            const deleted_slot = target.findBucketSlotForEntry(target_hash, found_entry_idx);

            const allocator = std.heap.c_allocator;
            {
                const removed_entry = target.entryAtConst(found_entry_idx).*;
                releaseEntryKey(removed_entry.key, allocator);
                releaseEntryValue(removed_entry.value, allocator);
            }

            if (found_entry_idx != old_len - 1) {
                const tail_idx: u32 = old_len - 1;
                const tail_entry = target.entryAt(tail_idx).*;

                const tail_slot = target.findBucketSlotForEntry(tail_entry.hash, tail_idx);
                target.bucketAt(tail_slot).entry_idx = found_entry_idx;

                target.entryAt(found_entry_idx).* = tail_entry;
            }

            target.len = old_len - 1;

            const buckets = target.bucketsPtr();
            buckets[deleted_slot] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
            var cur = deleted_slot;
            while (true) {
                const nxt = target.nextSlot(cur);
                const nxt_dnf = buckets[nxt].dist_and_fingerprint;
                if (nxt_dnf == DENSE_MAP_EMPTY) break;
                const nxt_dist = nxt_dnf >> 8;
                if (nxt_dist <= 1) break;
                const fp = nxt_dnf & DENSE_MAP_FINGERPRINT_MASK;
                const new_dist = nxt_dist - 1;
                buckets[cur] = .{
                    .dist_and_fingerprint = (new_dist << 8) | fp,
                    .entry_idx = buckets[nxt].entry_idx,
                };
                buckets[nxt] = .{ .dist_and_fingerprint = DENSE_MAP_EMPTY, .entry_idx = 0 };
                cur = nxt;
            }
        }

        // -------------------------------------------------------------------
        // Merge
        // -------------------------------------------------------------------

        pub fn merge(map_a: ?*const Self, map_b: ?*const Self) ?*const Self {
            if (comptime instrument_map) {
                if (map_a) |m| _ = mapInstrumentationBumpMutation(@intFromPtr(m), .merge);
                if (map_b) |m| _ = mapInstrumentationBumpMutation(@intFromPtr(m), .merge);
            }

            if (map_a == null and map_b == null) return null;
            if (map_a == null) return retain(map_b);
            if (map_b == null) return retain(map_a);

            // Both non-null: fold each entry of `b` into a result whose
            // initial state is `a` retained. Each `put` either returns
            // the same handle (rc-1 fast path on a unique-owner clone
            // we just made) or a fresh clone, in which case we release
            // the prior intermediate.
            var result: ?*const Self = retain(map_a);
            const b = map_b.?;
            const b_len = b.len;
            const b_entries = b.entriesPtr();
            var i: u32 = 0;
            while (i < b_len) : (i += 1) {
                const entry = b_entries[i];
                retainEntryKey(entry.key);
                retainEntryValue(entry.value);
                const next_result = put(result, entry.key, entry.value) orelse {
                    const allocator = std.heap.c_allocator;
                    releaseEntryKey(entry.key, allocator);
                    releaseEntryValue(entry.value, allocator);
                    release(result);
                    return null;
                };
                if (next_result != result) {
                    release(result);
                    result = next_result;
                }
            }
            return result;
        }

        fn findBucketSlotForEntry(self: *Self, h: u64, entry_idx: u32) u32 {
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            const buckets = self.bucketsPtr();
            while (true) {
                const b = buckets[slot];
                std.debug.assert(b.dist_and_fingerprint != DENSE_MAP_EMPTY);
                std.debug.assert(b.dist_and_fingerprint >= probe);
                if (b.dist_and_fingerprint == probe and b.entry_idx == entry_idx) {
                    return slot;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        fn installBucket(self: *Self, h: u64, entry_idx: u32) void {
            var probe = initialProbe(h);
            var slot = self.homeSlot(h);
            var cur_entry_idx = entry_idx;
            const buckets = self.bucketsPtr();
            while (true) {
                const dnf = buckets[slot].dist_and_fingerprint;
                if (dnf == DENSE_MAP_EMPTY) {
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    return;
                }
                if (dnf < probe) {
                    const displaced = buckets[slot];
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    probe = displaced.dist_and_fingerprint;
                    cur_entry_idx = displaced.entry_idx;
                }
                probe += DENSE_MAP_DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        fn pickCapacity(old_cap: u32, target_len: u32) u32 {
            var cap: u32 = if (old_cap == 0) DENSE_MAP_INITIAL_CAPACITY else old_cap;
            while (target_len * DENSE_MAP_LOAD_DEN > cap * DENSE_MAP_LOAD_NUM) {
                cap *= 2;
            }
            return cap;
        }

        // -------------------------------------------------------------------
        // Key equality / Term hashing
        // -------------------------------------------------------------------

        inline fn keysEqual(a: K, b: K) bool {
            if (K == Term) return Term.eql(a, b);
            const ti = @typeInfo(K);
            return switch (ti) {
                .int, .comptime_int, .bool => a == b,
                .pointer => |p| if (p.size == .slice and p.child == u8)
                    std.mem.eql(u8, a, b)
                else
                    a == b,
                else => @compileError("Map: unsupported key type " ++ @typeName(K)),
            };
        }

        fn hashTerm(seed: u64, t: Term) u64 {
            return switch (t) {
                .int => |v| Wyhash.hashU64(seed, @bitCast(v)),
                .float => |v| Wyhash.hashU64(seed, @bitCast(v)),
                .str => |v| Wyhash.hashBytes(seed, v),
                .bool_val => |v| Wyhash.hashU32(seed, if (v) 1 else 0),
                .atom => |v| Wyhash.hashU32(seed, v),
                .nil => Wyhash.hashU64(seed, 0),
                .list => |v| Wyhash.hashU64(seed, @intFromPtr(v)),
                .map => |v| Wyhash.hashU64(seed, @intFromPtr(v)),
                .tuple => |elems| blk: {
                    var h: u64 = seed;
                    for (elems) |elem| {
                        h ^= hashTerm(h, elem);
                    }
                    break :blk h;
                },
            };
        }

        // -------------------------------------------------------------------
        // ARC child walkers
        // -------------------------------------------------------------------

        inline fn releaseEntryKey(key: K, allocator: std.mem.Allocator) void {
            releaseAnyShape(K, key, allocator);
        }

        inline fn releaseEntryValue(value: V, allocator: std.mem.Allocator) void {
            releaseAnyShape(V, value, allocator);
        }

        inline fn retainEntryKey(key: K) void {
            retainAnyShape(K, key);
        }

        inline fn retainEntryValue(value: V) void {
            retainAnyShape(V, value);
        }

        fn releaseAnyShape(comptime T: type, value: T, allocator: std.mem.Allocator) void {
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (value) |inner| releaseAnyShape(opt.child, inner, allocator);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.releaseArcAny(p.child, allocator, @constCast(value));
                    }
                },
                .@"struct" => {
                    ArcRuntime.releaseChildrenAny(T, allocator, value);
                },
                else => {},
            }
        }

        fn retainAnyShape(comptime T: type, value: T) void {
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (value) |inner| retainAnyShape(opt.child, inner);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.retainAnyPersistent(@as(*const p.child, @constCast(value)));
                    }
                },
                .@"struct" => {
                    ArcRuntime.retainChildrenAny(T, value);
                },
                else => {},
            }
        }

        // -------------------------------------------------------------------
        // Iteration API
        // -------------------------------------------------------------------

        pub fn keys(map: ?*const Self) ?*const List(K) {
            const self = map orelse return null;
            if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(self));
            const len = self.len;
            if (len == 0) return null;
            const entries = self.entriesPtr();
            var result: ?*const List(K) = null;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                retainEntryKey(entries[i].key);
                result = List(K).cons(entries[i].key, result);
            }
            return result;
        }

        pub fn values(map: ?*const Self) ?*const List(V) {
            const self = map orelse return null;
            if (comptime instrument_map) mapInstrumentationOnGet(@intFromPtr(self));
            const len = self.len;
            if (len == 0) return null;
            const entries = self.entriesPtr();
            var result: ?*const List(V) = null;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                retainEntryValue(entries[i].value);
                result = List(V).cons(entries[i].value, result);
            }
            return result;
        }

        pub fn next(map: ?*const Self) struct {
            u32,
            struct { K, V },
            ?*const Self,
        } {
            if (map == null or map.?.len == 0) {
                return .{ ATOM_DONE, .{ defaultK(), defaultV() }, map };
            }
            const self = map.?;
            const first = self.entryAtConst(0).*;
            // Deep-retain the yielded K/V so the caller has owned copies
            // even after `delete` runs swap-remove (which deep-releases
            // the entry's K/V).
            retainEntryKey(first.key);
            retainEntryValue(first.value);
            const remaining = delete(self, first.key);
            return .{ ATOM_CONT, .{ first.key, first.value }, remaining };
        }

        inline fn defaultK() K {
            if (K == Term) return Term{ .nil = {} };
            return std.mem.zeroes(K);
        }

        inline fn defaultV() V {
            if (V == Term) return Term{ .nil = {} };
            return std.mem.zeroes(V);
        }

        // -------------------------------------------------------------------
        // fromPairs — bulk construction from parallel arrays
        // -------------------------------------------------------------------

        pub fn fromPairs(key_ids: []const K, vals: []const V, count: u32) ?*const Self {
            if (count == 0) return null;
            const callsite = @returnAddress();
            const cap = pickCapacity(0, count);
            const self = bufferAlloc(cap, Wyhash.nextSeed(), callsite) orelse return null;
            for (0..@intCast(count)) |i| {
                _ = putInPlaceInsert(self, key_ids[i], vals[i]);
            }
            return self;
        }

        // -------------------------------------------------------------------
        // Reductions
        // -------------------------------------------------------------------

        pub fn enumReduceSimple(map: ?*const Self, initial: i64, callback: anytype) i64 {
            if (map == null) return initial;
            const self = map.?;
            var acc: i64 = initial;
            const entries = self.entriesPtr();
            for (0..self.len) |i| {
                acc = callback(acc, @as(i64, @intCast(entries[i].key)), entries[i].value);
            }
            return acc;
        }

        pub fn enumReduceValues(map: ?*const Self, initial: i64, callback: anytype) i64 {
            if (map == null) return initial;
            const self = map.?;
            var acc: i64 = initial;
            const entries = self.entriesPtr();
            for (0..self.len) |i| {
                acc = callback(acc, entries[i].value);
            }
            return acc;
        }
    }; // end of returned struct
} // end of Map

// ============================================================
// Generic List factory — produces monomorphic list types
// for any element type T. Used for string lists, atom lists, etc.
// ============================================================

/// Compile-time default-value builder. Mirrors `std.mem.zeroes` but
/// recurses through aggregates (tuples and structs) instead of bit-zeroing
/// — so types containing `Term` (a tagged union without a zero variant)
/// produce a valid default. Used by `List(T).defaultElement` so list
/// fall-through paths work for heterogeneous keyword-list element types.
fn defaultElementOf(comptime T: type) T {
    if (T == Term) return Term{ .nil = {} };
    const ti = @typeInfo(T);
    switch (ti) {
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                @field(result, field.name) = defaultElementOf(field.type);
            }
            return result;
        },
        .optional => return null,
        else => return std.mem.zeroes(T),
    }
}

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        // Phase H.1 — `List(T)` cells are now Arc-headered + pool-
        // allocated, mirroring `Map(K, V)` and `MArrayOf(T)`. The
        // first field is `ArcHeader` so retain/release lower through
        // the same opaque helpers and the inline-header detection in
        // `ArcRuntime.hasInlineArcHeader` recognises the type.
        //
        // Memory model: every `cons` allocates a fresh cell with
        // `refcount = 1` from a thread-local `MemoryPool(Self)`. The
        // caller-side share/release ABI keeps refcounts honest:
        //   * `cons(head, tail)` consumes its arguments — the cell
        //     stores `head`/`tail` as durable owners. Sharing is the
        //     caller's responsibility (Phase E.10's aggregate-store
        //     consume classification handles this in IR).
        //   * `retain(list)` bumps the refcount on the head cell only
        //     (the spine is not touched — every cell already has its
        //     own count).
        //   * `release(list)` decrements; on the zero-transition the
        //     cell's `head` is deep-released (if `T` carries Arc-
        //     managed children) and the `tail` pointer is released
        //     recursively before the cell returns to its pool.
        //
        // Persistent semantics are preserved: `cons` never mutates an
        // existing cell, and shared tails carry their own refcounts.
        header: ArcHeader,
        head: T,
        tail: ?*const Self,

        /// Per-(T) thread-local MemoryPool for List cells. Mirrors
        /// `Map(K, V).SelfPool` and `MArrayOf(T).InnerPool`: hot-path
        /// allocation becomes a free-list pop, reclamation becomes a
        /// free-list push. OS page commit happens once per pool growth
        /// instead of per-allocation. Single-threaded Zap programs
        /// share the pool across all `List(T)` operations.
        const SelfPool = struct {
            const PoolT = std.heap.MemoryPool(Self);
            threadlocal var pool: PoolT = .empty;
            threadlocal var stats: PoolStats = .{ .name = "List(" ++ @typeName(T) ++ ").Self" };

            fn create() *Self {
                ensureArcStatsAtexit();
                stats.noteAllocation();
                return pool.create(std.heap.page_allocator) catch
                    @panic("List cell pool: out of memory");
            }

            fn destroy(cell: *Self) void {
                stats.noteDeallocation();
                pool.destroy(cell);
            }
        };

        /// Default-initialised value of `T` for empty-list returns.
        /// Tagged unions (notably `Term`) cannot use `std.mem.zeroes`.
        /// Plain `Term` returns the `.nil` variant. For nested aggregates
        /// (tuples or structs whose components include `Term`), build a
        /// per-field default so heterogeneous keyword-list element types
        /// like `tuple{Atom, Term}` work as `List` element types.
        fn defaultElement() T {
            return defaultElementOf(T);
        }

        pub fn empty() ?*const Self {
            return null;
        }

        /// Construct a new list cell with `head` and `tail`. The cell's
        /// refcount starts at 1; the caller becomes the sole owner.
        ///
        /// Ownership semantics for ARC-managed `T`: `head` and `tail`
        /// are **consumed** — the cell stores them as durable owners,
        /// and the caller must NOT release them after `cons` returns.
        /// Phase E.10's classifier emits `move_value` for `local_get`
        /// uses whose only consumption is a `list_cons.head/tail`
        /// position, so the caller-side IR transfers ownership cleanly.
        ///
        /// When the cell's refcount later hits zero, `release` will
        /// deep-release the stored `head` (if `T` carries ARC children)
        /// and recurse into `tail`.
        pub fn cons(head: T, tail: ?*const Self) ?*const Self {
            const cell = SelfPool.create();
            cell.* = .{
                .header = ArcHeader.init(),
                .head = head,
                .tail = tail,
            };
            return cell;
        }

        /// Increment the refcount of a list cell and return the same
        /// handle. Null lists (the empty-list sentinel) are a no-op.
        /// Mirrors `Map.retain` / `MArrayOf.retain`. Only the head
        /// cell's refcount is bumped; the spine is shared by-pointer
        /// and each tail cell has its own count.
        pub fn retain(list: ?*const Self) ?*const Self {
            if (list) |cell| {
                const mut: *Self = @constCast(cell);
                mut.header.retain();
                arc_retains_total += 1;
            }
            return list;
        }

        /// Decrement the refcount of a list cell. On the zero-
        /// transition, deep-release the head (if `T` carries ARC
        /// children), iteratively walk the tail spine releasing each
        /// cell whose refcount also hits zero, and return reclaimed
        /// cells to the SelfPool.
        ///
        /// The walk is bounded by the actual ownership graph: every
        /// shared tail has its own refcount > 1, so the loop stops at
        /// the first cell whose decrement leaves a survivor count,
        /// leaving the rest of the spine alive for any other owner.
        ///
        /// Iteration (vs. recursion) is required because long lists
        /// would otherwise blow the call stack on teardown — the spine
        /// can be arbitrarily deep, but the work per cell is fixed, so
        /// a tight loop replaces the recursive call cleanly.
        pub fn release(list: ?*const Self) void {
            var current = list;
            while (current) |cell| {
                const mut: *Self = @constCast(cell);
                arc_releases_total += 1;
                if (!mut.header.release()) {
                    // Refcount survived — another owner still holds the
                    // remaining spine. Stop here.
                    return;
                }
                // Final owner of this cell — tear down owned children.
                // The walk dispatches on `T`'s shape:
                //   * If `T` is itself an ARC-managed pointer (e.g.
                //     `?*const Map(K, V)`), release the pointer
                //     directly via `releaseFieldChildAny`.
                //   * If `T` is a struct/tuple, walk its fields via
                //     `releaseChildrenAny` to deep-release any
                //     ARC-managed children inside.
                //   * Otherwise (i64, bool, ...), this compiles to
                //     nothing.
                releaseHeadChildren(cell.head);
                const next_tail = cell.tail;
                SelfPool.destroy(mut);
                current = next_tail;
            }
        }

        /// Codegen-side deep-release entry point. Invoked by
        /// `ArcRuntime.releaseArcAny` when the Zap-emitted release path
        /// dispatches on a `List(T)` value pointer. Mirrors `release`
        /// but takes the value-pointer shape that codegen produces.
        pub fn arcReleaseDeep(allocator: std.mem.Allocator, ptr: *const Self) void {
            _ = allocator;
            release(@as(?*const Self, ptr));
        }

        /// Deep-release the head value of a list cell. Dispatches on
        /// `T`'s shape: optional/pointer heads are released directly
        /// (mirroring how struct fields of the same shape are walked
        /// in `ArcRuntime.releaseFieldChildAny`); aggregate heads
        /// (structs, tuples) recurse through their fields; primitive
        /// heads (i64, bool, ...) compile to nothing.
        ///
        /// Inlined into `release` so the comptime dispatch happens at
        /// the list-monomorphization site, not inside an opaque
        /// helper.
        fn releaseHeadChildren(head_value: T) void {
            const allocator = std.heap.c_allocator;
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (head_value) |inner| {
                        releaseFieldShape(opt.child, allocator, inner);
                    }
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.releaseArcAny(p.child, allocator, @constCast(head_value));
                    }
                },
                .@"struct" => {
                    ArcRuntime.releaseChildrenAny(T, allocator, head_value);
                },
                else => {},
            }
        }

        /// Helper for `releaseHeadChildren`'s optional branch — walks
        /// one level deeper into an unwrapped optional payload. Mirrors
        /// `ArcRuntime.releaseFieldChildAny`'s semantics but stays in
        /// this file so the recursion bottoms out cleanly at the
        /// pointer / struct cases.
        fn releaseFieldShape(comptime FieldType: type, allocator: std.mem.Allocator, value: FieldType) void {
            switch (@typeInfo(FieldType)) {
                .optional => |opt| {
                    if (value) |inner| releaseFieldShape(opt.child, allocator, inner);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.releaseArcAny(p.child, allocator, @constCast(value));
                    }
                },
                .@"struct" => {
                    ArcRuntime.releaseChildrenAny(FieldType, allocator, value);
                },
                else => {},
            }
        }

        /// Inverse of `releaseHeadChildren`: deep-retain every
        /// ARC-managed child carried inside the head value. Used by
        /// `next` (and any other site that hands a cell-owned head out
        /// as a fresh owner without removing it from the cell). The
        /// switch arms exactly mirror `releaseHeadChildren` so retain
        /// and release stay in lockstep — drift between the two would
        /// produce one-sided refcount adjustments that leak or
        /// double-free.
        fn retainHeadChildren(head_value: T) void {
            switch (@typeInfo(T)) {
                .optional => |opt| {
                    if (head_value) |inner| {
                        retainFieldShape(opt.child, inner);
                    }
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        // List cons cells are persistent containers
                        // — the head value remains owned by the cell
                        // for as long as the cell lives. Use the
                        // persistent retain path so type-specific
                        // share-event instrumentation fires.
                        ArcRuntime.retainAnyPersistent(@as(*const p.child, @constCast(head_value)));
                    }
                },
                .@"struct" => {
                    ArcRuntime.retainChildrenAny(T, head_value);
                },
                else => {},
            }
        }

        /// Helper for `retainHeadChildren`'s optional branch — mirror
        /// of `releaseFieldShape`, walks one level deeper into an
        /// unwrapped optional payload and bumps refcounts at the
        /// pointer / struct cases.
        fn retainFieldShape(comptime FieldType: type, value: FieldType) void {
            switch (@typeInfo(FieldType)) {
                .optional => |opt| {
                    if (value) |inner| retainFieldShape(opt.child, inner);
                },
                .pointer => |p| {
                    if (p.size == .one) {
                        ArcRuntime.retainAnyPersistent(@as(*const p.child, @constCast(value)));
                    }
                },
                .@"struct" => {
                    ArcRuntime.retainChildrenAny(FieldType, value);
                },
                else => {},
            }
        }

        /// Returns a fresh owner of the cell's head value. The cell
        /// continues to own its copy too — `releaseHeadChildren` runs
        /// on the cell's zero-transition. To keep the two owners in
        /// balance, deep-retain the head's ARC children before handing
        /// the value out. This matches the IR's "list_head produces an
        /// owner" model used by `arc_drop_insertion`. Without the
        /// retain, the cell's deep-release and the caller's release
        /// race on the same children and produce double-frees once
        /// `.list` joins the ARC-managed set.
        pub fn getHead(list: ?*const Self) T {
            if (list) |cell| {
                retainHeadChildren(cell.head);
                return cell.head;
            }
            return defaultElement();
        }

        /// Returns a fresh owner of the cell's tail spine. Bumps the
        /// head cell of `cell.tail` (the spine's first cell) so the
        /// cell's own owner-side deep-release stays balanced with the
        /// caller's eventual release. Mirrors `getHead`.
        pub fn getTail(list: ?*const Self) ?*const Self {
            if (list) |cell| {
                _ = retain(cell.tail);
                return cell.tail;
            }
            return null;
        }

        pub fn isEmpty(list: ?*const Self) bool {
            return list == null;
        }

        pub fn length(list: ?*const Self) i64 {
            var current = list;
            var count: i64 = 0;
            while (current) |cell| {
                count += 1;
                current = cell.tail;
            }
            return count;
        }

        pub fn get(list: ?*const Self, index: i64) T {
            var current = list;
            var i: i64 = 0;
            while (current) |cell| {
                if (i == index) return cell.head;
                current = cell.tail;
                i += 1;
            }
            return defaultElement();
        }

        pub fn last(list: ?*const Self) T {
            var current = list;
            var result: T = defaultElement();
            while (current) |cell| {
                result = cell.head;
                current = cell.tail;
            }
            return result;
        }

        pub fn reverse(list: ?*const Self) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                result = cons(cell.head, result);
                current = cell.tail;
            }
            return result;
        }

        /// Iterator protocol: returns {atom, value, next_state}.
        /// :cont (5) with head and tail for non-empty, :done (7) for empty.
        ///
        /// Ownership semantics for ARC-managed `T`: the returned tuple's
        /// `head` and `next_state` are fresh **owners** — the caller's
        /// `result_convention` for this protocol-dispatched call sees
        /// every ARC-managed return slot as `.owned`. Because `cell.head`
        /// and `cell.tail` are still owned by `cell` after we read them,
        /// `next` must deep-retain `head` (recursively bumping the
        /// refcount of every ARC-managed child carried inside `T`) and
        /// retain `tail` (bumping the head cell of the tail spine, since
        /// the original list still references it). Without this, the
        /// caller's eventual release of the returned values would race
        /// with the cell's own deep-release on its zero-transition,
        /// producing double-frees for ARC-typed elements (the corruption
        /// surfaced by k-nucleotide once `.list` joins `.opaque_type`,
        /// `.map` in `isArcManagedTypeId`).
        /// See module-level note on Phase H ARC ABI: `next` returns
        /// fresh owners of `head` and `tail`, so we must deep-retain
        /// the head's ARC children and bump the tail spine's head-cell
        /// refcount before handing the values out. The cell itself
        /// still owns its copies — the symmetric deep-release fires on
        /// the cell's eventual zero-transition in `release`.
        pub fn next(list: ?*const Self) std.meta.Tuple(&.{ u32, T, ?*const Self }) {
            if (list) |cell| {
                retainHeadChildren(cell.head);
                _ = retain(cell.tail);
                return .{ ATOM_CONT, cell.head, cell.tail };
            }
            return .{ ATOM_DONE, defaultElement(), null };
        }

        pub fn contains(list: ?*const Self, value: T) bool {
            var current = list;
            while (current) |cell| {
                if (T == Term) {
                    if (Term.eql(cell.head, value)) return true;
                } else {
                    if (std.mem.eql(u8, std.mem.asBytes(&cell.head), std.mem.asBytes(&value))) return true;
                }
                current = cell.tail;
            }
            return false;
        }

        pub fn append(list: ?*const Self, value: T) ?*const Self {
            return reverse(cons(value, reverse(list)));
        }

        pub fn concat(first: ?*const Self, second: ?*const Self) ?*const Self {
            if (first == null) return second;
            var reversed_first = reverse(first);
            var result = second;
            while (reversed_first) |cell| {
                result = cons(cell.head, result);
                reversed_first = cell.tail;
            }
            return result;
        }

        pub fn take(list: ?*const Self, count: i64) ?*const Self {
            if (count <= 0 or list == null) return null;
            var current = list;
            var collected: ?*const Self = null;
            var remaining: i64 = count;
            while (current) |cell| {
                if (remaining <= 0) break;
                collected = cons(cell.head, collected);
                current = cell.tail;
                remaining -= 1;
            }
            return reverse(collected);
        }

        pub fn drop(list: ?*const Self, count: i64) ?*const Self {
            if (count <= 0) return list;
            var current = list;
            var remaining: i64 = count;
            while (current) |cell| {
                if (remaining <= 0) return current;
                current = cell.tail;
                remaining -= 1;
            }
            return null;
        }

        pub fn uniq(list: ?*const Self) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (!contains(result, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        // Higher-order functions
        pub fn mapFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                result = cons(call1(callback, cell.head), result);
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn filterFn(list: ?*const Self, predicate: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (call1(predicate, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn rejectFn(list: ?*const Self, predicate: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (!call1(predicate, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn enumReduceSimple(list: ?*const Self, initial: T, callback: anytype) T {
            var current = list;
            var acc: T = initial;
            while (current) |cell| {
                acc = call2(callback, acc, cell.head);
                current = cell.tail;
            }
            return acc;
        }

        pub fn eachFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            while (current) |cell| {
                _ = call1(callback, cell.head);
                current = cell.tail;
            }
            return list;
        }

        pub fn findFn(list: ?*const Self, default: T, predicate: anytype) T {
            var current = list;
            while (current) |cell| {
                if (call1(predicate, cell.head)) return cell.head;
                current = cell.tail;
            }
            return default;
        }

        pub fn anyFn(list: ?*const Self, predicate: anytype) bool {
            var current = list;
            while (current) |cell| {
                if (call1(predicate, cell.head)) return true;
                current = cell.tail;
            }
            return false;
        }

        pub fn allFn(list: ?*const Self, predicate: anytype) bool {
            var current = list;
            while (current) |cell| {
                if (!call1(predicate, cell.head)) return false;
                current = cell.tail;
            }
            return true;
        }

        pub fn countFn(list: ?*const Self, predicate: anytype) i64 {
            var current = list;
            var count: i64 = 0;
            while (current) |cell| {
                if (call1(predicate, cell.head)) count += 1;
                current = cell.tail;
            }
            return count;
        }

        pub fn sortFn(list: ?*const Self, comparator: anytype) ?*const Self {
            const len_val = length(list);
            if (len_val <= 1) return list;
            const len: usize = @intCast(len_val);
            const arr = bumpAllocSlice(T, len);
            if (arr.len == 0) return list;
            var current = list;
            var i: usize = 0;
            while (current) |cell| {
                if (i < len) arr[i] = cell.head;
                current = cell.tail;
                i += 1;
            }
            const Ctx = struct {
                cmp: @TypeOf(comparator),
                fn lessThan(ctx: @This(), a: T, b: T) bool {
                    return call2(ctx.cmp, a, b);
                }
            };
            std.sort.pdq(T, arr, Ctx{ .cmp = comparator }, Ctx.lessThan);
            var result: ?*const Self = null;
            var ri: usize = len;
            while (ri > 0) {
                ri -= 1;
                result = cons(arr[ri], result);
            }
            return result;
        }

        pub fn flatMapFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                var inner = call1(callback, cell.head);
                while (inner) |inner_cell| {
                    result = cons(inner_cell.head, result);
                    inner = inner_cell.tail;
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        // Numeric-only methods (only instantiated when T is an integer type)
        pub fn sum(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("sum requires integer element type");
            var current = list;
            var total: T = 0;
            while (current) |cell| {
                total += cell.head;
                current = cell.tail;
            }
            return total;
        }

        pub fn product(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("product requires integer element type");
            var current = list;
            var total: T = 1;
            while (current) |cell| {
                total *= cell.head;
                current = cell.tail;
            }
            return total;
        }

        pub fn maxVal(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("maxVal requires integer element type");
            if (list == null) return 0;
            var current = list;
            var result: T = list.?.head;
            while (current) |cell| {
                if (cell.head > result) result = cell.head;
                current = cell.tail;
            }
            return result;
        }

        pub fn minVal(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("minVal requires integer element type");
            if (list == null) return 0;
            var current = list;
            var result: T = list.?.head;
            while (current) |cell| {
                if (cell.head < result) result = cell.head;
                current = cell.tail;
            }
            return result;
        }
    };
}

// ============================================================
// MapHelpers — Operations on map values (anonymous structs of {key, value} entries)
//
// Maps in ZIR are represented as anonymous structs with numeric field names:
//   .{ .@"0" = .{ .key = k0, .value = v0 }, .@"1" = .{ .key = k1, .value = v1 }, ... }
//
// These helpers use @typeInfo + inline for to iterate entries at compile time,
// producing efficient code with no runtime overhead for small maps.
// ============================================================

pub const MapHelpers = struct {
    /// Get a value from a map by key. Returns the value if found, or a default.
    /// Usage: MapHelpers.get(map, key, default)
    pub fn get(map: anytype, key: anytype, default: anytype) @TypeOf(default) {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return default;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                // Check if this entry has key and value fields
                const is_kv_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv_entry) {
                    if (keysEqual(entry.key, key)) return entry.value;
                }
            }
        }
        return default;
    }

    /// Check if a map contains a key.
    pub fn has_key(map: anytype, key: anytype) bool {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_entry) {
                    if (keysEqual(entry.key, key)) return true;
                }
            }
        }
        return false;
    }

    /// Get the number of entries in a map.
    pub fn size(map: anytype) i64 {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return 0;
        return @intCast(info.@"struct".fields.len);
    }

    /// Create a new map with a key's value updated.
    /// Returns the same map type with the matching entry's value replaced.
    pub fn put(map: anytype, key: anytype, value: anytype) @TypeOf(map) {
        var result = map;
        const info = @typeInfo(@TypeOf(map));
        if (info != .@"struct") return result;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_kv = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv) {
                    if (keysEqual(entry.key, key)) {
                        @field(result, field.name).value = value;
                    }
                }
            }
        }
        return result;
    }

    /// Compare two keys, handling atom IDs (u32), strings, and integers.
    fn keysEqual(a: anytype, b: anytype) bool {
        const A = @TypeOf(a);
        const B = @TypeOf(b);
        if (A == B) {
            if (A == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
        // Cross-type comparison for atom IDs
        if ((@typeInfo(A) == .int or @typeInfo(A) == .comptime_int) and
            (@typeInfo(B) == .int or @typeInfo(B) == .comptime_int))
        {
            return a == b;
        }
        return false;
    }
};

// ============================================================
// Type-grouped runtime namespaces
//
// These structs are the user-visible runtime entry points reached
// from Zap source via `:zig.<Namespace>.<fn>(args)`. They group the
// runtime helpers by the type they operate on (Integer, Float, Bool,
// String, IO, File, Path, System, Math, Atom).
// ============================================================

pub const Integer = struct {
    fn formatSignedDecimal(value: i128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    fn formatUnsignedDecimal(value: u128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    fn digitCountUnsigned(value: u128) i64 {
        var remaining = value;
        var count: i64 = 1;
        while (remaining >= 10) {
            remaining /= 10;
            count += 1;
        }
        return count;
    }

    fn absMagnitudeI8(value: i8) u8 {
        if (value >= 0) return @intCast(value);
        return @as(u8, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI16(value: i16) u16 {
        if (value >= 0) return @intCast(value);
        return @as(u16, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI32(value: i32) u32 {
        if (value >= 0) return @intCast(value);
        return @as(u32, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI64(value: i64) u64 {
        if (value >= 0) return @intCast(value);
        return @as(u64, @intCast(-(value + 1))) + 1;
    }

    fn absMagnitudeI128(value: i128) u128 {
        if (value >= 0) return @intCast(value);
        return @as(u128, @intCast(-(value + 1))) + 1;
    }

    /// Parse a string into i64, returning 0 on failure (non-optional).
    pub fn parse(s: []const u8) i64 {
        return std.fmt.parseInt(i64, s, 10) catch 0;
    }

    /// Parse a string into i64, returning null on failure.
    pub fn parse_optional(s: []const u8) ?i64 {
        return std.fmt.parseInt(i64, s, 10) catch null;
    }

    pub fn to_string(value: i64) []const u8 {
        return to_string_i64(value);
    }

    pub fn to_string_i8(value: i8) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i16(value: i16) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i32(value: i32) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_i64(value: i64) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_u8(value: u8) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u16(value: u16) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u32(value: u32) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn to_string_u64(value: u64) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn abs(value: i64) i64 {
        return abs_i64(value);
    }

    pub fn abs_i8(value: i8) i8 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i16(value: i16) i16 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i32(value: i32) i32 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_i64(value: i64) i64 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_u8(value: u8) u8 {
        return value;
    }

    pub fn abs_u16(value: u16) u16 {
        return value;
    }

    pub fn abs_u32(value: u32) u32 {
        return value;
    }

    pub fn abs_u64(value: u64) u64 {
        return value;
    }

    pub fn max(value: i64, other: i64) i64 {
        return max_i64(value, other);
    }

    pub fn max_i8(value: i8, other: i8) i8 {
        return @max(value, other);
    }

    pub fn max_i16(value: i16, other: i16) i16 {
        return @max(value, other);
    }

    pub fn max_i32(value: i32, other: i32) i32 {
        return @max(value, other);
    }

    pub fn max_i64(value: i64, other: i64) i64 {
        return @max(value, other);
    }

    pub fn max_u8(value: u8, other: u8) u8 {
        return @max(value, other);
    }

    pub fn max_u16(value: u16, other: u16) u16 {
        return @max(value, other);
    }

    pub fn max_u32(value: u32, other: u32) u32 {
        return @max(value, other);
    }

    pub fn max_u64(value: u64, other: u64) u64 {
        return @max(value, other);
    }

    pub fn min(value: i64, other: i64) i64 {
        return min_i64(value, other);
    }

    pub fn min_i8(value: i8, other: i8) i8 {
        return @min(value, other);
    }

    pub fn min_i16(value: i16, other: i16) i16 {
        return @min(value, other);
    }

    pub fn min_i32(value: i32, other: i32) i32 {
        return @min(value, other);
    }

    pub fn min_i64(value: i64, other: i64) i64 {
        return @min(value, other);
    }

    pub fn min_u8(value: u8, other: u8) u8 {
        return @min(value, other);
    }

    pub fn min_u16(value: u16, other: u16) u16 {
        return @min(value, other);
    }

    pub fn min_u32(value: u32, other: u32) u32 {
        return @min(value, other);
    }

    pub fn min_u64(value: u64, other: u64) u64 {
        return @min(value, other);
    }

    pub fn div(value: i64, divisor: i64) i64 {
        return div_i64(value, divisor);
    }

    pub fn div_i8(value: i8, divisor: i8) i8 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i16(value: i16, divisor: i16) i16 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i32(value: i32, divisor: i32) i32 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_i64(value: i64, divisor: i64) i64 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u8(value: u8, divisor: u8) u8 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u16(value: u16, divisor: u16) u16 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u32(value: u32, divisor: u32) u32 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u64(value: u64, divisor: u64) u64 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn rem(value: i64, divisor: i64) i64 {
        return rem_i64(value, divisor);
    }

    pub fn rem_i8(value: i8, divisor: i8) i8 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i16(value: i16, divisor: i16) i16 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i32(value: i32, divisor: i32) i32 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_i64(value: i64, divisor: i64) i64 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u8(value: u8, divisor: u8) u8 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u16(value: u16, divisor: u16) u16 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u32(value: u32, divisor: u32) u32 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u64(value: u64, divisor: u64) u64 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn pow_i8(base: i8, exponent: i8) i8 {
        var result: i8 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i16(base: i16, exponent: i16) i16 {
        var result: i16 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i32(base: i32, exponent: i32) i32 {
        var result: i32 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_i64(base: i64, exponent: i64) i64 {
        var result: i64 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u8(base: u8, exponent: u8) u8 {
        var result: u8 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u16(base: u16, exponent: u16) u16 {
        var result: u16 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u32(base: u32, exponent: u32) u32 {
        var result: u32 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u64(base: u64, exponent: u64) u64 {
        var result: u64 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn clamp_i8(value: i8, lower: i8, upper: i8) i8 {
        return min_i8(max_i8(value, lower), upper);
    }

    pub fn clamp_i16(value: i16, lower: i16, upper: i16) i16 {
        return min_i16(max_i16(value, lower), upper);
    }

    pub fn clamp_i32(value: i32, lower: i32, upper: i32) i32 {
        return min_i32(max_i32(value, lower), upper);
    }

    pub fn clamp_i64(value: i64, lower: i64, upper: i64) i64 {
        return min_i64(max_i64(value, lower), upper);
    }

    pub fn clamp_u8(value: u8, lower: u8, upper: u8) u8 {
        return min_u8(max_u8(value, lower), upper);
    }

    pub fn clamp_u16(value: u16, lower: u16, upper: u16) u16 {
        return min_u16(max_u16(value, lower), upper);
    }

    pub fn clamp_u32(value: u32, lower: u32, upper: u32) u32 {
        return min_u32(max_u32(value, lower), upper);
    }

    pub fn clamp_u64(value: u64, lower: u64, upper: u64) u64 {
        return min_u64(max_u64(value, lower), upper);
    }

    pub fn digits_i8(value: i8) i64 {
        return digitCountUnsigned(absMagnitudeI8(value));
    }

    pub fn digits_i16(value: i16) i64 {
        return digitCountUnsigned(absMagnitudeI16(value));
    }

    pub fn digits_i32(value: i32) i64 {
        return digitCountUnsigned(absMagnitudeI32(value));
    }

    pub fn digits_i64(value: i64) i64 {
        return digitCountUnsigned(absMagnitudeI64(value));
    }

    pub fn digits_u8(value: u8) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u16(value: u16) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u32(value: u32) i64 {
        return digitCountUnsigned(value);
    }

    pub fn digits_u64(value: u64) i64 {
        return digitCountUnsigned(value);
    }

    // `count_digits_*` was a synonym of `digits_*` — same body, same
    // result type. The duplicate surface was removed when the Zap-side
    // `Integer.count_digits/1` got dropped in favour of `Integer.digits/1`,
    // and these intrinsics had no other consumer.

    pub fn to_f64(value: i64) f64 {
        return to_f64_i64(value);
    }

    pub fn to_f64_i8(value: i8) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i16(value: i16) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i32(value: i32) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_i64(value: i64) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u8(value: u8) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u16(value: u16) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u32(value: u32) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u64(value: u64) f64 {
        return @floatFromInt(value);
    }

    pub fn clz(value: i64) i64 {
        return clz_i64(value);
    }

    pub fn clz_i8(value: i8) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i16(value: i16) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i32(value: i32) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_i64(value: i64) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u8(value: u8) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u16(value: u16) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u32(value: u32) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u64(value: u64) i64 {
        return @intCast(@clz(value));
    }

    pub fn ctz(value: i64) i64 {
        return ctz_i64(value);
    }

    pub fn ctz_i8(value: i8) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i16(value: i16) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i32(value: i32) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_i64(value: i64) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u8(value: u8) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u16(value: u16) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u32(value: u32) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u64(value: u64) i64 {
        return @intCast(@ctz(value));
    }

    pub fn popcount(value: i64) i64 {
        return popcount_i64(value);
    }

    pub fn popcount_i8(value: i8) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i16(value: i16) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i32(value: i32) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_i64(value: i64) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u8(value: u8) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u16(value: u16) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u32(value: u32) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u64(value: u64) i64 {
        return @intCast(@popCount(value));
    }

    pub fn byte_swap(value: i64) i64 {
        return byte_swap_i64(value);
    }

    pub fn byte_swap_i8(value: i8) i8 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i16(value: i16) i16 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i32(value: i32) i32 {
        return @byteSwap(value);
    }

    pub fn byte_swap_i64(value: i64) i64 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u8(value: u8) u8 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u16(value: u16) u16 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u32(value: u32) u32 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u64(value: u64) u64 {
        return @byteSwap(value);
    }

    pub fn bit_reverse(value: i64) i64 {
        return bit_reverse_i64(value);
    }

    pub fn bit_reverse_i8(value: i8) i8 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i16(value: i16) i16 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i32(value: i32) i32 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_i64(value: i64) i64 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u8(value: u8) u8 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u16(value: u16) u16 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u32(value: u32) u32 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u64(value: u64) u64 {
        return @bitReverse(value);
    }

    pub fn add_sat(value: i64, other: i64) i64 {
        return add_sat_i64(value, other);
    }

    pub fn add_sat_i8(value: i8, other: i8) i8 {
        return value +| other;
    }

    pub fn add_sat_i16(value: i16, other: i16) i16 {
        return value +| other;
    }

    pub fn add_sat_i32(value: i32, other: i32) i32 {
        return value +| other;
    }

    pub fn add_sat_i64(value: i64, other: i64) i64 {
        return value +| other;
    }

    pub fn add_sat_u8(value: u8, other: u8) u8 {
        return value +| other;
    }

    pub fn add_sat_u16(value: u16, other: u16) u16 {
        return value +| other;
    }

    pub fn add_sat_u32(value: u32, other: u32) u32 {
        return value +| other;
    }

    pub fn add_sat_u64(value: u64, other: u64) u64 {
        return value +| other;
    }

    pub fn sub_sat(value: i64, other: i64) i64 {
        return sub_sat_i64(value, other);
    }

    pub fn sub_sat_i8(value: i8, other: i8) i8 {
        return value -| other;
    }

    pub fn sub_sat_i16(value: i16, other: i16) i16 {
        return value -| other;
    }

    pub fn sub_sat_i32(value: i32, other: i32) i32 {
        return value -| other;
    }

    pub fn sub_sat_i64(value: i64, other: i64) i64 {
        return value -| other;
    }

    pub fn sub_sat_u8(value: u8, other: u8) u8 {
        return value -| other;
    }

    pub fn sub_sat_u16(value: u16, other: u16) u16 {
        return value -| other;
    }

    pub fn sub_sat_u32(value: u32, other: u32) u32 {
        return value -| other;
    }

    pub fn sub_sat_u64(value: u64, other: u64) u64 {
        return value -| other;
    }

    pub fn mul_sat(value: i64, other: i64) i64 {
        return mul_sat_i64(value, other);
    }

    pub fn mul_sat_i8(value: i8, other: i8) i8 {
        return value *| other;
    }

    pub fn mul_sat_i16(value: i16, other: i16) i16 {
        return value *| other;
    }

    pub fn mul_sat_i32(value: i32, other: i32) i32 {
        return value *| other;
    }

    pub fn mul_sat_i64(value: i64, other: i64) i64 {
        return value *| other;
    }

    pub fn mul_sat_u8(value: u8, other: u8) u8 {
        return value *| other;
    }

    pub fn mul_sat_u16(value: u16, other: u16) u16 {
        return value *| other;
    }

    pub fn mul_sat_u32(value: u32, other: u32) u32 {
        return value *| other;
    }

    pub fn mul_sat_u64(value: u64, other: u64) u64 {
        return value *| other;
    }

    pub fn band(value: i64, other: i64) i64 {
        return band_i64(value, other);
    }

    pub fn band_i8(value: i8, other: i8) i8 {
        return value & other;
    }

    pub fn band_i16(value: i16, other: i16) i16 {
        return value & other;
    }

    pub fn band_i32(value: i32, other: i32) i32 {
        return value & other;
    }

    pub fn band_i64(value: i64, other: i64) i64 {
        return value & other;
    }

    pub fn band_u8(value: u8, other: u8) u8 {
        return value & other;
    }

    pub fn band_u16(value: u16, other: u16) u16 {
        return value & other;
    }

    pub fn band_u32(value: u32, other: u32) u32 {
        return value & other;
    }

    pub fn band_u64(value: u64, other: u64) u64 {
        return value & other;
    }

    pub fn bor(value: i64, other: i64) i64 {
        return bor_i64(value, other);
    }

    pub fn bor_i8(value: i8, other: i8) i8 {
        return value | other;
    }

    pub fn bor_i16(value: i16, other: i16) i16 {
        return value | other;
    }

    pub fn bor_i32(value: i32, other: i32) i32 {
        return value | other;
    }

    pub fn bor_i64(value: i64, other: i64) i64 {
        return value | other;
    }

    pub fn bor_u8(value: u8, other: u8) u8 {
        return value | other;
    }

    pub fn bor_u16(value: u16, other: u16) u16 {
        return value | other;
    }

    pub fn bor_u32(value: u32, other: u32) u32 {
        return value | other;
    }

    pub fn bor_u64(value: u64, other: u64) u64 {
        return value | other;
    }

    pub fn bxor(value: i64, other: i64) i64 {
        return bxor_i64(value, other);
    }

    pub fn bxor_i8(value: i8, other: i8) i8 {
        return value ^ other;
    }

    pub fn bxor_i16(value: i16, other: i16) i16 {
        return value ^ other;
    }

    pub fn bxor_i32(value: i32, other: i32) i32 {
        return value ^ other;
    }

    pub fn bxor_i64(value: i64, other: i64) i64 {
        return value ^ other;
    }

    pub fn bxor_u8(value: u8, other: u8) u8 {
        return value ^ other;
    }

    pub fn bxor_u16(value: u16, other: u16) u16 {
        return value ^ other;
    }

    pub fn bxor_u32(value: u32, other: u32) u32 {
        return value ^ other;
    }

    pub fn bxor_u64(value: u64, other: u64) u64 {
        return value ^ other;
    }

    pub fn bnot(value: i64) i64 {
        return bnot_i64(value);
    }

    pub fn bnot_i8(value: i8) i8 {
        return ~value;
    }

    pub fn bnot_i16(value: i16) i16 {
        return ~value;
    }

    pub fn bnot_i32(value: i32) i32 {
        return ~value;
    }

    pub fn bnot_i64(value: i64) i64 {
        return ~value;
    }

    pub fn bnot_u8(value: u8) u8 {
        return ~value;
    }

    pub fn bnot_u16(value: u16) u16 {
        return ~value;
    }

    pub fn bnot_u32(value: u32) u32 {
        return ~value;
    }

    pub fn bnot_u64(value: u64) u64 {
        return ~value;
    }

    pub fn bsl(value: i64, amount: i64) i64 {
        return bsl_i64(value, amount);
    }

    pub fn bsl_i8(value: i8, amount: i8) i8 {
        if (amount < 0 or amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i16(value: i16, amount: i16) i16 {
        if (amount < 0 or amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i32(value: i32, amount: i32) i32 {
        if (amount < 0 or amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_i64(value: i64, amount: i64) i64 {
        if (amount < 0 or amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u8(value: u8, amount: u8) u8 {
        if (amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u16(value: u16, amount: u16) u16 {
        if (amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u32(value: u32, amount: u32) u32 {
        if (amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u64(value: u64, amount: u64) u64 {
        if (amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value << shift;
    }

    pub fn bsr(value: i64, amount: i64) i64 {
        return bsr_i64(value, amount);
    }

    pub fn bsr_i8(value: i8, amount: i8) i8 {
        if (amount < 0 or amount >= 8) return if (value < 0) -1 else 0;
        const shift: u3 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i16(value: i16, amount: i16) i16 {
        if (amount < 0 or amount >= 16) return if (value < 0) -1 else 0;
        const shift: u4 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i32(value: i32, amount: i32) i32 {
        if (amount < 0 or amount >= 32) return if (value < 0) -1 else 0;
        const shift: u5 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_i64(value: i64, amount: i64) i64 {
        if (amount < 0 or amount >= 64) return if (value < 0) -1 else 0;
        const shift: u6 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u8(value: u8, amount: u8) u8 {
        if (amount >= 8) return 0;
        const shift: u3 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u16(value: u16, amount: u16) u16 {
        if (amount >= 16) return 0;
        const shift: u4 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u32(value: u32, amount: u32) u32 {
        if (amount >= 32) return 0;
        const shift: u5 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u64(value: u64, amount: u64) u64 {
        if (amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return value >> shift;
    }

    pub fn sign(value: i64) i64 {
        return sign_i64(value);
    }

    pub fn sign_i8(value: i8) i8 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i16(value: i16) i16 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i32(value: i32) i32 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_i64(value: i64) i64 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_u8(value: u8) u8 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u16(value: u16) u16 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u32(value: u32) u32 {
        return if (value > 0) 1 else 0;
    }

    pub fn sign_u64(value: u64) u64 {
        return if (value > 0) 1 else 0;
    }

    pub fn is_even(value: i64) bool {
        return is_even_i64(value);
    }

    pub fn is_even_i8(value: i8) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i16(value: i16) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i32(value: i32) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_i64(value: i64) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u8(value: u8) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u16(value: u16) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u32(value: u32) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u64(value: u64) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_odd(value: i64) bool {
        return is_odd_i64(value);
    }

    pub fn is_odd_i8(value: i8) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i16(value: i16) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i32(value: i32) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_i64(value: i64) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u8(value: u8) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u16(value: u16) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u32(value: u32) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u64(value: u64) bool {
        return @rem(value, 2) != 0;
    }

    pub fn gcd(value: i64, other: i64) i64 {
        return gcd_i64(value, other);
    }

    pub fn gcd_i8(value: i8, other: i8) i8 {
        var x = abs_i8(value);
        var y = abs_i8(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i16(value: i16, other: i16) i16 {
        var x = abs_i16(value);
        var y = abs_i16(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i32(value: i32, other: i32) i32 {
        var x = abs_i32(value);
        var y = abs_i32(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_i64(value: i64, other: i64) i64 {
        var x = abs_i64(value);
        var y = abs_i64(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u8(value: u8, other: u8) u8 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u16(value: u16, other: u16) u16 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u32(value: u32, other: u32) u32 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u64(value: u64, other: u64) u64 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn lcm(value: i64, other: i64) i64 {
        return lcm_i64(value, other);
    }

    pub fn lcm_i8(value: i8, other: i8) i8 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i8(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i8(value), divisor) *% abs_i8(other);
    }

    pub fn lcm_i16(value: i16, other: i16) i16 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i16(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i16(value), divisor) *% abs_i16(other);
    }

    pub fn lcm_i32(value: i32, other: i32) i32 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i32(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i32(value), divisor) *% abs_i32(other);
    }

    pub fn lcm_i64(value: i64, other: i64) i64 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i64(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i64(value), divisor) *% abs_i64(other);
    }

    pub fn lcm_u8(value: u8, other: u8) u8 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u8(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u16(value: u16, other: u16) u16 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u16(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u32(value: u32, other: u32) u32 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u32(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn lcm_u64(value: u64, other: u64) u64 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u64(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }

    pub fn to_string_i128(value: i128) []const u8 {
        return formatSignedDecimal(value);
    }

    pub fn to_string_u128(value: u128) []const u8 {
        return formatUnsignedDecimal(value);
    }

    pub fn abs_i128(value: i128) i128 {
        return if (value < 0) 0 -% value else value;
    }

    pub fn abs_u128(value: u128) u128 {
        return value;
    }

    pub fn max_i128(value: i128, other: i128) i128 {
        return @max(value, other);
    }

    pub fn max_u128(value: u128, other: u128) u128 {
        return @max(value, other);
    }

    pub fn min_i128(value: i128, other: i128) i128 {
        return @min(value, other);
    }

    pub fn min_u128(value: u128, other: u128) u128 {
        return @min(value, other);
    }

    pub fn div_i128(value: i128, divisor: i128) i128 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn div_u128(value: u128, divisor: u128) u128 {
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor);
    }

    pub fn rem_i128(value: i128, divisor: i128) i128 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn rem_u128(value: u128, divisor: u128) u128 {
        if (divisor == 0) return 0;
        return @rem(value, divisor);
    }

    pub fn pow_i128(base: i128, exponent: i128) i128 {
        var result: i128 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn pow_u128(base: u128, exponent: u128) u128 {
        var result: u128 = 1;
        var remaining = exponent;
        while (remaining > 0) : (remaining -= 1) result *%= base;
        return result;
    }

    pub fn clamp_i128(value: i128, lower: i128, upper: i128) i128 {
        return min_i128(max_i128(value, lower), upper);
    }

    pub fn clamp_u128(value: u128, lower: u128, upper: u128) u128 {
        return min_u128(max_u128(value, lower), upper);
    }

    pub fn digits_i128(value: i128) i64 {
        return digitCountUnsigned(absMagnitudeI128(value));
    }

    pub fn digits_u128(value: u128) i64 {
        return digitCountUnsigned(value);
    }

    pub fn to_f64_i128(value: i128) f64 {
        return @floatFromInt(value);
    }

    pub fn to_f64_u128(value: u128) f64 {
        return @floatFromInt(value);
    }

    pub fn clz_i128(value: i128) i64 {
        return @intCast(@clz(value));
    }

    pub fn clz_u128(value: u128) i64 {
        return @intCast(@clz(value));
    }

    pub fn ctz_i128(value: i128) i64 {
        return @intCast(@ctz(value));
    }

    pub fn ctz_u128(value: u128) i64 {
        return @intCast(@ctz(value));
    }

    pub fn popcount_i128(value: i128) i64 {
        return @intCast(@popCount(value));
    }

    pub fn popcount_u128(value: u128) i64 {
        return @intCast(@popCount(value));
    }

    pub fn byte_swap_i128(value: i128) i128 {
        return @byteSwap(value);
    }

    pub fn byte_swap_u128(value: u128) u128 {
        return @byteSwap(value);
    }

    pub fn bit_reverse_i128(value: i128) i128 {
        return @bitReverse(value);
    }

    pub fn bit_reverse_u128(value: u128) u128 {
        return @bitReverse(value);
    }

    pub fn add_sat_i128(value: i128, other: i128) i128 {
        return value +| other;
    }

    pub fn add_sat_u128(value: u128, other: u128) u128 {
        return value +| other;
    }

    pub fn sub_sat_i128(value: i128, other: i128) i128 {
        return value -| other;
    }

    pub fn sub_sat_u128(value: u128, other: u128) u128 {
        return value -| other;
    }

    pub fn mul_sat_i128(value: i128, other: i128) i128 {
        return value *| other;
    }

    pub fn mul_sat_u128(value: u128, other: u128) u128 {
        return value *| other;
    }

    pub fn band_i128(value: i128, other: i128) i128 {
        return value & other;
    }

    pub fn band_u128(value: u128, other: u128) u128 {
        return value & other;
    }

    pub fn bor_i128(value: i128, other: i128) i128 {
        return value | other;
    }

    pub fn bor_u128(value: u128, other: u128) u128 {
        return value | other;
    }

    pub fn bxor_i128(value: i128, other: i128) i128 {
        return value ^ other;
    }

    pub fn bxor_u128(value: u128, other: u128) u128 {
        return value ^ other;
    }

    pub fn bnot_i128(value: i128) i128 {
        return ~value;
    }

    pub fn bnot_u128(value: u128) u128 {
        return ~value;
    }

    pub fn bsl_i128(value: i128, amount: i128) i128 {
        if (amount < 0 or amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value << shift;
    }

    pub fn bsl_u128(value: u128, amount: u128) u128 {
        if (amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value << shift;
    }

    pub fn bsr_i128(value: i128, amount: i128) i128 {
        if (amount < 0 or amount >= 128) return if (value < 0) -1 else 0;
        const shift: u7 = @intCast(amount);
        return value >> shift;
    }

    pub fn bsr_u128(value: u128, amount: u128) u128 {
        if (amount >= 128) return 0;
        const shift: u7 = @intCast(amount);
        return value >> shift;
    }

    pub fn sign_i128(value: i128) i128 {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    pub fn sign_u128(value: u128) u128 {
        return if (value > 0) 1 else 0;
    }

    pub fn is_even_i128(value: i128) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_even_u128(value: u128) bool {
        return @rem(value, 2) == 0;
    }

    pub fn is_odd_i128(value: i128) bool {
        return @rem(value, 2) != 0;
    }

    pub fn is_odd_u128(value: u128) bool {
        return @rem(value, 2) != 0;
    }

    pub fn gcd_i128(value: i128, other: i128) i128 {
        var x = abs_i128(value);
        var y = abs_i128(other);
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn gcd_u128(value: u128, other: u128) u128 {
        var x = value;
        var y = other;
        while (y != 0) {
            const next = @rem(x, y);
            x = y;
            y = next;
        }
        return x;
    }

    pub fn lcm_i128(value: i128, other: i128) i128 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_i128(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(abs_i128(value), divisor) *% abs_i128(other);
    }

    pub fn lcm_u128(value: u128, other: u128) u128 {
        if (value == 0 and other == 0) return 0;
        const divisor = gcd_u128(value, other);
        if (divisor == 0) return 0;
        return @divTrunc(value, divisor) *% other;
    }
};

pub const Float = struct {
    pub fn to_string(value: f64) []const u8 {
        return to_string_f64(value);
    }

    pub fn to_string_f16(value: f16) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f32(value: f32) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f64(value: f64) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    /// Fixed-precision float formatter matching C's
    /// `printf("%.<decimals>f", value)` rounding (round half away
    /// from zero — actually round-to-even via Zig's `{d:.N}` which
    /// uses ryu-like semantics; that matches glibc / POSIX printf
    /// for the reference outputs this is wired up to compare against).
    /// `decimals` is clamped to [0, 32].
    pub fn to_string_f64_precision(value: f64, decimals: i64) []const u8 {
        var buf: [128]u8 = undefined;
        const d: usize = if (decimals < 0) 0 else if (decimals > 32) 32 else @intCast(decimals);
        const slice = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ value, d }) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    /// Parse a string into f64, returning 0.0 on failure (non-optional).
    pub fn parse(s: []const u8) f64 {
        return std.fmt.parseFloat(f64, s) catch 0.0;
    }

    /// Parse a string into f64, returning null on failure.
    pub fn parse_optional(s: []const u8) ?f64 {
        return std.fmt.parseFloat(f64, s) catch null;
    }

    pub fn abs(value: f64) f64 {
        return abs_f64(value);
    }

    pub fn abs_f16(value: f16) f16 {
        return @abs(value);
    }

    pub fn abs_f32(value: f32) f32 {
        return @abs(value);
    }

    pub fn abs_f64(value: f64) f64 {
        return @abs(value);
    }

    pub fn max(value: f64, other: f64) f64 {
        return max_f64(value, other);
    }

    pub fn max_f16(value: f16, other: f16) f16 {
        return @max(value, other);
    }

    pub fn max_f32(value: f32, other: f32) f32 {
        return @max(value, other);
    }

    pub fn max_f64(value: f64, other: f64) f64 {
        return @max(value, other);
    }

    pub fn min(value: f64, other: f64) f64 {
        return min_f64(value, other);
    }

    pub fn min_f16(value: f16, other: f16) f16 {
        return @min(value, other);
    }

    pub fn min_f32(value: f32, other: f32) f32 {
        return @min(value, other);
    }

    pub fn min_f64(value: f64, other: f64) f64 {
        return @min(value, other);
    }

    pub fn round(value: f64) f64 {
        return round_f64(value);
    }

    pub fn round_f16(value: f16) f16 {
        return @round(value);
    }

    pub fn round_f32(value: f32) f32 {
        return @round(value);
    }

    pub fn round_f64(value: f64) f64 {
        return @round(value);
    }

    pub fn floor(value: f64) f64 {
        return floor_f64(value);
    }

    pub fn floor_f16(value: f16) f16 {
        return @floor(value);
    }

    pub fn floor_f32(value: f32) f32 {
        return @floor(value);
    }

    pub fn floor_f64(value: f64) f64 {
        return @floor(value);
    }

    pub fn ceil(value: f64) f64 {
        return ceil_f64(value);
    }

    pub fn ceil_f16(value: f16) f16 {
        return @ceil(value);
    }

    pub fn ceil_f32(value: f32) f32 {
        return @ceil(value);
    }

    pub fn ceil_f64(value: f64) f64 {
        return @ceil(value);
    }

    pub fn trunc(value: f64) f64 {
        return trunc_f64(value);
    }

    pub fn trunc_f16(value: f16) f16 {
        return @trunc(value);
    }

    pub fn trunc_f32(value: f32) f32 {
        return @trunc(value);
    }

    pub fn trunc_f64(value: f64) f64 {
        return @trunc(value);
    }

    pub fn clamp_f16(value: f16, lower: f16, upper: f16) f16 {
        return min_f16(max_f16(value, lower), upper);
    }

    pub fn clamp_f32(value: f32, lower: f32, upper: f32) f32 {
        return min_f32(max_f32(value, lower), upper);
    }

    pub fn clamp_f64(value: f64, lower: f64, upper: f64) f64 {
        return min_f64(max_f64(value, lower), upper);
    }

    pub fn to_i64(value: f64) i64 {
        return to_i64_f64(value);
    }

    /// Convert a float to an i64 by truncating toward zero. Total over the
    /// finite-and-in-range float domain; panics on NaN, ±Inf, and values
    /// that don't round-trip into an i64 after truncation. The unchecked
    /// `@intFromFloat` builtin used previously was undefined behaviour on
    /// every one of those edges, so the surface conversion silently
    /// corrupted state when fed an upstream divide-by-zero or oversized
    /// magnitude. Each width gets its own helper because the safe upper
    /// bound depends on the float's mantissa precision — for f16 every
    /// finite value already fits in i64; for f32 the boundary is exactly
    /// 2^63 (representable); for f64 the closest representable value at
    /// the i64-max edge is 2^63 itself, which is i64 max + 1 and must be
    /// rejected.
    pub fn to_i64_f16(value: f16) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        return @intFromFloat(@trunc(value));
    }

    pub fn to_i64_f32(value: f32) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        if (truncated < -9.2233720368547758e18 or truncated >= 9.2233720368547758e18) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_i64_f64(value: f64) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        // i64 min == -2^63 is exactly representable as f64; i64 max == 2^63 - 1
        // is *not* — the closest f64 is 2^63, which would overflow. So the
        // upper bound is strict-less-than 2^63.
        const max_plus_one: f64 = 9.223372036854776e18;
        const min_value: f64 = -9.223372036854776e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_string_f80(value: f80) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn to_string_f128(value: f128) []const u8 {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn abs_f80(value: f80) f80 {
        return @abs(value);
    }

    pub fn abs_f128(value: f128) f128 {
        return @abs(value);
    }

    pub fn max_f80(value: f80, other: f80) f80 {
        return @max(value, other);
    }

    pub fn max_f128(value: f128, other: f128) f128 {
        return @max(value, other);
    }

    pub fn min_f80(value: f80, other: f80) f80 {
        return @min(value, other);
    }

    pub fn min_f128(value: f128, other: f128) f128 {
        return @min(value, other);
    }

    pub fn round_f80(value: f80) f80 {
        return @round(value);
    }

    pub fn round_f128(value: f128) f128 {
        return @round(value);
    }

    pub fn floor_f80(value: f80) f80 {
        return @floor(value);
    }

    pub fn floor_f128(value: f128) f128 {
        return @floor(value);
    }

    pub fn ceil_f80(value: f80) f80 {
        return @ceil(value);
    }

    pub fn ceil_f128(value: f128) f128 {
        return @ceil(value);
    }

    pub fn trunc_f80(value: f80) f80 {
        return @trunc(value);
    }

    pub fn trunc_f128(value: f128) f128 {
        return @trunc(value);
    }

    pub fn clamp_f80(value: f80, lower: f80, upper: f80) f80 {
        return min_f80(max_f80(value, lower), upper);
    }

    pub fn clamp_f128(value: f128, lower: f128, upper: f128) f128 {
        return min_f128(max_f128(value, lower), upper);
    }

    pub fn to_i64_f80(value: f80) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        const max_plus_one: f80 = 9.223372036854775808e18;
        const min_value: f80 = -9.223372036854775808e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }

    pub fn to_i64_f128(value: f128) i64 {
        if (std.math.isNan(value)) Kernel.raise("Float.to_integer: cannot convert NaN to integer");
        if (std.math.isInf(value)) Kernel.raise("Float.to_integer: cannot convert infinity to integer");
        const truncated = @trunc(value);
        const max_plus_one: f128 = 9.223372036854775808e18;
        const min_value: f128 = -9.223372036854775808e18;
        if (truncated < min_value or truncated >= max_plus_one) {
            Kernel.raise("Float.to_integer: value out of i64 range");
        }
        return @intFromFloat(truncated);
    }
};

pub const Math = struct {
    pub fn sqrt(x: f64) f64 {
        return sqrt_f64(x);
    }

    pub fn sqrt_i8(x: i8) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i16(x: i16) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i32(x: i32) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i64(x: i64) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_i128(x: i128) f128 {
        return @sqrt(@as(f128, @floatFromInt(x)));
    }

    pub fn sqrt_u8(x: u8) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u16(x: u16) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u32(x: u32) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u64(x: u64) f64 {
        return @sqrt(@as(f64, @floatFromInt(x)));
    }

    pub fn sqrt_u128(x: u128) f128 {
        return @sqrt(@as(f128, @floatFromInt(x)));
    }

    pub fn sqrt_f16(x: f16) f16 {
        return @sqrt(x);
    }

    pub fn sqrt_f32(x: f32) f32 {
        return @sqrt(x);
    }

    pub fn sqrt_f64(x: f64) f64 {
        return @sqrt(x);
    }

    pub fn sqrt_f80(x: f80) f80 {
        return @sqrt(x);
    }

    pub fn sqrt_f128(x: f128) f128 {
        return @sqrt(x);
    }

    pub fn sin(x: f64) f64 {
        return sin_f64(x);
    }

    pub fn sin_i8(x: i8) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i16(x: i16) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i32(x: i32) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i64(x: i64) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_i128(x: i128) f128 {
        return @sin(@as(f128, @floatFromInt(x)));
    }

    pub fn sin_u8(x: u8) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u16(x: u16) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u32(x: u32) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u64(x: u64) f64 {
        return @sin(@as(f64, @floatFromInt(x)));
    }

    pub fn sin_u128(x: u128) f128 {
        return @sin(@as(f128, @floatFromInt(x)));
    }

    pub fn sin_f16(x: f16) f16 {
        return @sin(x);
    }

    pub fn sin_f32(x: f32) f32 {
        return @sin(x);
    }

    pub fn sin_f64(x: f64) f64 {
        return @sin(x);
    }

    pub fn sin_f80(x: f80) f80 {
        return @sin(x);
    }

    pub fn sin_f128(x: f128) f128 {
        return @sin(x);
    }

    pub fn cos(x: f64) f64 {
        return cos_f64(x);
    }

    pub fn cos_i8(x: i8) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i16(x: i16) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i32(x: i32) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i64(x: i64) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_i128(x: i128) f128 {
        return @cos(@as(f128, @floatFromInt(x)));
    }

    pub fn cos_u8(x: u8) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u16(x: u16) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u32(x: u32) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u64(x: u64) f64 {
        return @cos(@as(f64, @floatFromInt(x)));
    }

    pub fn cos_u128(x: u128) f128 {
        return @cos(@as(f128, @floatFromInt(x)));
    }

    pub fn cos_f16(x: f16) f16 {
        return @cos(x);
    }

    pub fn cos_f32(x: f32) f32 {
        return @cos(x);
    }

    pub fn cos_f64(x: f64) f64 {
        return @cos(x);
    }

    pub fn cos_f80(x: f80) f80 {
        return @cos(x);
    }

    pub fn cos_f128(x: f128) f128 {
        return @cos(x);
    }

    pub fn tan(x: f64) f64 {
        return tan_f64(x);
    }

    pub fn tan_i8(x: i8) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i16(x: i16) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i32(x: i32) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i64(x: i64) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_i128(x: i128) f128 {
        return @tan(@as(f128, @floatFromInt(x)));
    }

    pub fn tan_u8(x: u8) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u16(x: u16) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u32(x: u32) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u64(x: u64) f64 {
        return @tan(@as(f64, @floatFromInt(x)));
    }

    pub fn tan_u128(x: u128) f128 {
        return @tan(@as(f128, @floatFromInt(x)));
    }

    pub fn tan_f16(x: f16) f16 {
        return @tan(x);
    }

    pub fn tan_f32(x: f32) f32 {
        return @tan(x);
    }

    pub fn tan_f64(x: f64) f64 {
        return @tan(x);
    }

    pub fn tan_f80(x: f80) f80 {
        return @tan(x);
    }

    pub fn tan_f128(x: f128) f128 {
        return @tan(x);
    }

    pub fn exp(x: f64) f64 {
        return exp_f64(x);
    }

    pub fn exp_i8(x: i8) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i16(x: i16) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i32(x: i32) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i64(x: i64) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_i128(x: i128) f128 {
        return @exp(@as(f128, @floatFromInt(x)));
    }

    pub fn exp_u8(x: u8) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u16(x: u16) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u32(x: u32) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u64(x: u64) f64 {
        return @exp(@as(f64, @floatFromInt(x)));
    }

    pub fn exp_u128(x: u128) f128 {
        return @exp(@as(f128, @floatFromInt(x)));
    }

    pub fn exp_f16(x: f16) f16 {
        return @exp(x);
    }

    pub fn exp_f32(x: f32) f32 {
        return @exp(x);
    }

    pub fn exp_f64(x: f64) f64 {
        return @exp(x);
    }

    pub fn exp_f80(x: f80) f80 {
        return @exp(x);
    }

    pub fn exp_f128(x: f128) f128 {
        return @exp(x);
    }

    pub fn exp2(x: f64) f64 {
        return exp2_f64(x);
    }

    pub fn exp2_i8(x: i8) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i16(x: i16) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i32(x: i32) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i64(x: i64) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_i128(x: i128) f128 {
        return @exp2(@as(f128, @floatFromInt(x)));
    }

    pub fn exp2_u8(x: u8) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u16(x: u16) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u32(x: u32) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u64(x: u64) f64 {
        return @exp2(@as(f64, @floatFromInt(x)));
    }

    pub fn exp2_u128(x: u128) f128 {
        return @exp2(@as(f128, @floatFromInt(x)));
    }

    pub fn exp2_f16(x: f16) f16 {
        return @exp2(x);
    }

    pub fn exp2_f32(x: f32) f32 {
        return @exp2(x);
    }

    pub fn exp2_f64(x: f64) f64 {
        return @exp2(x);
    }

    pub fn exp2_f80(x: f80) f80 {
        return @exp2(x);
    }

    pub fn exp2_f128(x: f128) f128 {
        return @exp2(x);
    }

    pub fn log(x: f64) f64 {
        return log_f64(x);
    }

    pub fn log_i8(x: i8) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i16(x: i16) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i32(x: i32) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i64(x: i64) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_i128(x: i128) f128 {
        return @log(@as(f128, @floatFromInt(x)));
    }

    pub fn log_u8(x: u8) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u16(x: u16) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u32(x: u32) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u64(x: u64) f64 {
        return @log(@as(f64, @floatFromInt(x)));
    }

    pub fn log_u128(x: u128) f128 {
        return @log(@as(f128, @floatFromInt(x)));
    }

    pub fn log_f16(x: f16) f16 {
        return @log(x);
    }

    pub fn log_f32(x: f32) f32 {
        return @log(x);
    }

    pub fn log_f64(x: f64) f64 {
        return @log(x);
    }

    pub fn log_f80(x: f80) f80 {
        return @log(x);
    }

    pub fn log_f128(x: f128) f128 {
        return @log(x);
    }

    pub fn log2(x: f64) f64 {
        return log2_f64(x);
    }

    pub fn log2_i8(x: i8) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i16(x: i16) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i32(x: i32) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i64(x: i64) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_i128(x: i128) f128 {
        return @log2(@as(f128, @floatFromInt(x)));
    }

    pub fn log2_u8(x: u8) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u16(x: u16) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u32(x: u32) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u64(x: u64) f64 {
        return @log2(@as(f64, @floatFromInt(x)));
    }

    pub fn log2_u128(x: u128) f128 {
        return @log2(@as(f128, @floatFromInt(x)));
    }

    pub fn log2_f16(x: f16) f16 {
        return @log2(x);
    }

    pub fn log2_f32(x: f32) f32 {
        return @log2(x);
    }

    pub fn log2_f64(x: f64) f64 {
        return @log2(x);
    }

    pub fn log2_f80(x: f80) f80 {
        return @log2(x);
    }

    pub fn log2_f128(x: f128) f128 {
        return @log2(x);
    }

    pub fn log10(x: f64) f64 {
        return log10_f64(x);
    }

    pub fn log10_i8(x: i8) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i16(x: i16) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i32(x: i32) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i64(x: i64) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_i128(x: i128) f128 {
        return @log10(@as(f128, @floatFromInt(x)));
    }

    pub fn log10_u8(x: u8) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u16(x: u16) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u32(x: u32) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u64(x: u64) f64 {
        return @log10(@as(f64, @floatFromInt(x)));
    }

    pub fn log10_u128(x: u128) f128 {
        return @log10(@as(f128, @floatFromInt(x)));
    }

    pub fn log10_f16(x: f16) f16 {
        return @log10(x);
    }

    pub fn log10_f32(x: f32) f32 {
        return @log10(x);
    }

    pub fn log10_f64(x: f64) f64 {
        return @log10(x);
    }

    pub fn log10_f80(x: f80) f80 {
        return @log10(x);
    }

    pub fn log10_f128(x: f128) f128 {
        return @log10(x);
    }

    // The legacy `floor_to_i64_*`, `ceil_to_i64_*`, and `round_to_i64_*`
    // intrinsics fused the rounding step with the i64 conversion. Now that
    // `Float.to_i64_f*` panics on NaN/±Inf/out-of-range, callers compose
    // `Float.to_integer(Float.floor(x))` and the optimizer is free to fuse
    // the rounding+convert when it can. Keeping a separate fused entry
    // would re-introduce the old "intrinsic doesn't validate, surface
    // function does" split that hid silent UB on edge values.
};

pub const Bool = struct {
    pub fn to_string(value: bool) []const u8 {
        return if (value) "true" else "false";
    }
};

pub const IO = struct {
    pub fn println(value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}\n", .{value});
        } else if (info == .int or info == .comptime_int) {
            stdoutPrint("{d}\n", .{value});
        } else if (info == .float or info == .comptime_float) {
            stdoutPrint("{d}\n", .{value});
        } else if (T == bool) {
            stdoutPrint("{}\n", .{value});
        } else if (info == .@"enum") {
            stdoutPrint(":{s}\n", .{@tagName(value)});
        } else if (T == u32) {
            // Could be an atom ID — print as atom if it looks up
            const name = atomToString(value);
            if (!std.mem.eql(u8, name, "<unknown_atom>")) {
                stdoutPrint(":{s}\n", .{name});
            } else {
                stdoutPrint("{d}\n", .{value});
            }
        } else {
            // For tuples, structs, and other compound types, use inspect formatting
            var iw_buf: [4096]u8 = undefined;
            var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
            inspectWrite(&iw, value);
            stdoutBufferedWrite(iw_buf[0..iw.pos]);
            stdoutPrint("\n", .{});
        }
    }

    pub fn print_str(value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}", .{value});
        } else {
            stdoutPrint("{any}", .{value});
        }
    }

    /// Append a single byte to the buffered stdout. Used by streaming
    /// output paths (e.g. the CLBG mandelbrot port) where building an
    /// intermediate `String` per byte would dominate cost. Returns the
    /// byte unchanged so it composes in pipe chains.
    pub fn write_byte(byte: i64) i64 {
        // Wrap to a u8 — Zap source-level i64 is the natural shape for
        // single-byte arithmetic (`byte_acc <<= 1`, `bor`, …) but the
        // wire shape is one byte.
        const b: u8 = @truncate(@as(u64, @bitCast(byte)));
        stdoutBufferedWriteByte(b);
        return byte;
    }

    /// Read a line from stdin. Returns the line without the trailing
    /// newline. Returns an empty string on EOF or error.
    pub fn gets() []const u8 {
        // Flush pending stdout so prompts ship before the read blocks.
        flushStdoutBuf();
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        // Read one byte at a time until newline or EOF
        while (len < buf.len - 1) {
            var one_buf = [_]u8{0};
            const n = posixRead(STDIN_FD, &one_buf);
            if (n == 0) break; // EOF
            if (one_buf[0] == '\n') break;
            buf[len] = one_buf[0];
            len += 1;
        }
        // Strip trailing \r if present (Windows line endings)
        if (len > 0 and buf[len - 1] == '\r') len -= 1;
        if (len == 0) return "";
        const result = bumpAlloc(len);
        if (result.len == 0) return "";
        @memcpy(result, buf[0..len]);
        return result;
    }

    /// Switch terminal mode. Accepts a u32 atom ID — checks atom name
    /// for "Raw" to enable raw mode (no canonical line buffering, no
    /// echo); any other value restores the saved original termios.
    pub fn set_terminal_mode(mode: u32) void {
        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const is_raw = std.mem.eql(u8, atomToString(mode), "Raw");
        if (is_raw) {
            var termios = posix.tcgetattr(stdin_fd) catch return;
            if (!raw_mode_saved) {
                original_termios = termios;
                raw_mode_saved = true;
            }
            termios.lflag.ICANON = false;
            termios.lflag.ECHO = false;
            termios.cc[@intFromEnum(posix.V.MIN)] = 1;
            termios.cc[@intFromEnum(posix.V.TIME)] = 0;
            posix.tcsetattr(stdin_fd, .FLUSH, termios) catch return;
        } else {
            if (raw_mode_saved) {
                posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch return;
            }
        }
    }

    /// Non-blocking read of a single character from stdin. Returns a
    /// 1-byte string if a key is available, "" otherwise. Must be in
    /// raw mode for meaningful use.
    pub fn try_get_char() []const u8 {
        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const POLLIN: i16 = 0x0001;

        var fds = [_]std.c.pollfd{.{
            .fd = stdin_fd,
            .events = POLLIN,
            .revents = 0,
        }};
        const ready = posix.poll(&fds, 0) catch return "";
        if (ready == 0) return "";

        var one_buf = [_]u8{0};
        const n = posixRead(STDIN_FD, &one_buf);
        if (n == 0) return "";
        const result_buf = bumpAlloc(1);
        if (result_buf.len == 0) return "";
        result_buf[0] = one_buf[0];
        return result_buf;
    }

    /// Read a single character from stdin. Returns a 1-byte string.
    /// In raw mode, returns immediately after one keypress; in normal
    /// mode, blocks until Enter then returns the first character.
    pub fn get_char() []const u8 {
        var one_buf = [_]u8{0};
        const n = posixRead(STDIN_FD, &one_buf);
        if (n == 0) return "";
        const result = bumpAlloc(1);
        if (result.len == 0) return "";
        result[0] = one_buf[0];
        return result;
    }

    /// Write a string to stderr followed by a newline. Flushes pending
    /// stdout first so error messages don't leapfrog buffered output.
    pub fn warn(message: []const u8) void {
        flushStdoutBuf();
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
    }

    pub fn inspect(value: anytype) InspectReturn(@TypeOf(value)) {
        var iw_buf: [4096]u8 = undefined;
        var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
        inspectWrite(&iw, value);
        stdoutBufferedWrite(iw_buf[0..iw.pos]);
        stdoutPrint("\n", .{});
        const RT = InspectReturn(@TypeOf(value));
        if (RT == void) return;
        return value;
    }
};

/// Returns `void` for comptime-only types (enum literals, comptime_int,
/// etc.) so that `IO.inspect` can be called at runtime without forcing
/// comptime evaluation. For all other types, returns the input type
/// to support piping.
fn InspectReturn(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .enum_literal, .comptime_int, .comptime_float, .type, .null, .undefined => void,
        else => T,
    };
}

fn inspectWrite(writer: anytype, value: anytype) void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (T == []const u8) {
        writer.print("\"{s}\"", .{value}) catch {};
    } else if (info == .pointer) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array) {
            if (child_info.array.child == u8) {
                writer.print("\"{s}\"", .{value}) catch {};
            } else {
                writer.print("[", .{}) catch {};
                for (0..child_info.array.len) |i| {
                    if (i > 0) writer.print(", ", .{}) catch {};
                    inspectWrite(writer, value[i]);
                }
                writer.print("]", .{}) catch {};
            }
        } else {
            writer.print("{any}", .{value}) catch {};
        }
    } else if (info == .int or info == .comptime_int) {
        writer.print("{d}", .{value}) catch {};
    } else if (info == .float or info == .comptime_float) {
        const rounded: i64 = @trunc(value);
        if (value == @as(@TypeOf(value), @floatFromInt(rounded))) {
            writer.print("{d}.0", .{rounded}) catch {};
        } else {
            writer.print("{d}", .{value}) catch {};
        }
    } else if (T == bool) {
        writer.print("{}", .{value}) catch {};
    } else if (info == .@"struct" and info.@"struct".is_tuple) {
        writer.print("{{", .{}) catch {};
        inline for (info.@"struct".fields, 0..) |field, i| {
            if (i > 0) writer.print(", ", .{}) catch {};
            inspectWrite(writer, @field(value, field.name));
        }
        writer.print("}}", .{}) catch {};
    } else if (info == .@"struct") {
        // Detect Zap map representation: struct of .{key, value} entry structs.
        const is_map = comptime blk: {
            if (info.@"struct".fields.len == 0) break :blk false;
            for (info.@"struct".fields) |f| {
                const inner = @typeInfo(f.type);
                if (inner != .@"struct") break :blk false;
                if (inner.@"struct".fields.len != 2) break :blk false;
                const has_key = for (inner.@"struct".fields) |ef| {
                    if (std.mem.eql(u8, ef.name, "key")) break true;
                } else false;
                const has_value = for (inner.@"struct".fields) |ef| {
                    if (std.mem.eql(u8, ef.name, "value")) break true;
                } else false;
                if (!has_key or !has_value) break :blk false;
            }
            break :blk true;
        };
        if (is_map) {
            writer.print("%{{", .{}) catch {};
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                const entry = @field(value, field.name);
                inspectWrite(writer, entry.key);
                writer.print(": ", .{}) catch {};
                inspectWrite(writer, entry.value);
            }
            writer.print("}}", .{}) catch {};
        } else {
            writer.print("%{{", .{}) catch {};
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                writer.print("{s}: ", .{field.name}) catch {};
                inspectWrite(writer, @field(value, field.name));
            }
            writer.print("}}", .{}) catch {};
        }
    } else if (info == .@"enum") {
        writer.print(":{s}", .{@tagName(value)}) catch {};
    } else {
        writer.print("{any}", .{value}) catch {};
    }
}

pub const File = struct {
    pub fn read(path: []const u8) []const u8 {
        const path_z = std.posix.toPosixPath(path) catch return "";
        const fd = std.c.open(&path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return "";
        defer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return "";
        const file_size: usize = @intCast(@max(stat.size, 0));
        if (file_size == 0) return "";
        const read_size = @min(file_size, 1024 * 1024);
        const result = bumpAlloc(read_size);
        if (result.len == 0) return "";
        var total: usize = 0;
        while (total < read_size) {
            const n = std.posix.read(fd, result[total..read_size]) catch break;
            if (n == 0) break;
            total += n;
        }
        return result[0..total];
    }

    pub fn write(path: []const u8, content: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const fd = std.c.open(&path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return false;
        defer _ = std.c.close(fd);
        var written: usize = 0;
        while (written < content.len) {
            const rc = std.c.write(fd, content[written..].ptr, content[written..].len);
            if (rc <= 0) return false;
            written += @intCast(rc);
        }
        return true;
    }

    pub fn exists(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.faccessat(std.posix.AT.FDCWD, &path_z, std.posix.F_OK, 0) == 0;
    }

    pub fn rm(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, 0) == 0;
    }

    pub fn mkdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.mkdirat(std.posix.AT.FDCWD, &path_z, 0o755) == 0;
    }

    pub fn rmdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const AT_REMOVEDIR: u32 = 0x80; // POSIX standard
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, AT_REMOVEDIR) == 0;
    }

    pub fn rename(old_path: []const u8, new_path: []const u8) bool {
        const old_z = std.posix.toPosixPath(old_path) catch return false;
        const new_z = std.posix.toPosixPath(new_path) catch return false;
        return std.c.renameat(std.posix.AT.FDCWD, &old_z, std.posix.AT.FDCWD, &new_z) == 0;
    }

    pub fn cp(src: []const u8, dest: []const u8) bool {
        const content = read(src);
        if (content.len == 0) return false;
        return write(dest, content);
    }

    pub fn is_dir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFDIR;
    }

    pub fn is_regular(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFREG;
    }
};

pub const Prim = struct {
    pub fn glob(pattern: []const u8) ?*const List([]const u8) {
        const allocator = std.heap.page_allocator;
        const matches = globCollect(allocator, pattern) catch return null;
        defer {
            for (matches) |matched_path| allocator.free(matched_path);
            allocator.free(matches);
        }

        var result: ?*const List([]const u8) = null;
        var index = matches.len;
        while (index > 0) {
            index -= 1;
            const copied_path = bumpCopy(matches[index]);
            if (copied_path.len == 0 and matches[index].len != 0) return null;
            result = List([]const u8).cons(copied_path, result);
        }
        return result;
    }

    fn bumpCopy(value: []const u8) []const u8 {
        const result = bumpAlloc(value.len);
        if (result.len == 0 and value.len != 0) return "";
        @memcpy(result, value);
        return result;
    }

    fn globCollect(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temporary_allocator = arena.allocator();

        const clean_pattern = stripLeadingCurrentDir(pattern);
        var results: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        if (!globHasMagic(clean_pattern)) {
            const access_path = try temporary_allocator.dupe(u8, clean_pattern);
            if (std.Io.Dir.cwd().access(std.Options.debug_io, access_path, .{})) |_| {
                try results.append(allocator, try allocator.dupe(u8, clean_pattern));
            } else |_| {}
            return results.toOwnedSlice(allocator);
        }

        const base_prefix = globBasePrefix(clean_pattern);
        const search_path = if (base_prefix.len == 0)
            try temporary_allocator.dupe(u8, ".")
        else
            try temporary_allocator.dupe(u8, base_prefix);
        const initial_prefix = stripTrailingSlash(base_prefix);

        try globWalk(
            allocator,
            temporary_allocator,
            search_path,
            initial_prefix,
            clean_pattern,
            &results,
        );

        globSort(results.items);
        return results.toOwnedSlice(allocator);
    }

    fn globWalk(
        result_allocator: std.mem.Allocator,
        temporary_allocator: std.mem.Allocator,
        dir_path: []const u8,
        relative_prefix: []const u8,
        pattern: []const u8,
        results: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(std.Options.debug_io);

        var iterator = dir.iterate();
        while (iterator.next(std.Options.debug_io) catch null) |entry| {
            const full_path = try std.fs.path.join(temporary_allocator, &.{ dir_path, entry.name });
            const relative_path = if (relative_prefix.len == 0)
                try temporary_allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(temporary_allocator, "{s}/{s}", .{ relative_prefix, entry.name });

            if (entry.kind == .directory) {
                if (globMatch(pattern, relative_path)) {
                    try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
                }
                try globWalk(result_allocator, temporary_allocator, full_path, relative_path, pattern, results);
                continue;
            }

            if (entry.kind == .file and globMatch(pattern, relative_path)) {
                try results.append(result_allocator, try result_allocator.dupe(u8, relative_path));
            }
        }
    }

    fn globMatch(pattern: []const u8, path: []const u8) bool {
        const clean_pattern = stripLeadingCurrentDir(pattern);
        const clean_path = stripLeadingCurrentDir(path);
        return globMatchSegments(clean_pattern, clean_path, 0, 0);
    }

    fn globMatchSegments(pattern: []const u8, path: []const u8, pattern_start: usize, path_start: usize) bool {
        if (pattern_start >= pattern.len) return path_start >= path.len;

        const pattern_segment = globNextSegment(pattern, pattern_start);
        if (std.mem.eql(u8, pattern_segment.value, "**")) {
            if (pattern_segment.next >= pattern.len) return true;
            if (globMatchSegments(pattern, path, pattern_segment.next, path_start)) return true;

            var current_path_start = path_start;
            while (current_path_start < path.len) {
                const path_segment = globNextSegment(path, current_path_start);
                if (globMatchSegments(pattern, path, pattern_segment.next, path_segment.next)) return true;
                current_path_start = path_segment.next;
            }
            return false;
        }

        if (path_start >= path.len) return false;
        const path_segment = globNextSegment(path, path_start);
        if (!globMatchSegment(pattern_segment.value, path_segment.value)) return false;
        return globMatchSegments(pattern, path, pattern_segment.next, path_segment.next);
    }

    const GlobSegment = struct {
        value: []const u8,
        next: usize,
    };

    fn globNextSegment(value: []const u8, start: usize) GlobSegment {
        var end = start;
        while (end < value.len and value[end] != '/') {
            end += 1;
        }
        return .{
            .value = value[start..end],
            .next = if (end < value.len) end + 1 else end,
        };
    }

    fn globMatchSegment(pattern: []const u8, value: []const u8) bool {
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

    fn globSort(items: [][]const u8) void {
        std.mem.sort([]const u8, items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
    }

    fn globBasePrefix(pattern: []const u8) []const u8 {
        var prefix_end: usize = 0;
        for (pattern, 0..) |character, index| {
            if (character == '*' or character == '?') break;
            if (character == '/') prefix_end = index + 1;
        }
        return pattern[0..prefix_end];
    }

    fn globHasMagic(pattern: []const u8) bool {
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
};

pub const Path = struct {
    pub fn join(a: []const u8, b: []const u8) []const u8 {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const need_sep = a[a.len - 1] != '/';
        const total = a.len + b.len + @as(usize, if (need_sep) 1 else 0);
        const result = bumpAlloc(total);
        if (result.len == 0) return "";
        @memcpy(result[0..a.len], a);
        if (need_sep) {
            result[a.len] = '/';
            @memcpy(result[a.len + 1 ..][0..b.len], b);
        } else {
            @memcpy(result[a.len..][0..b.len], b);
        }
        return result;
    }

    pub fn basename(path: []const u8) []const u8 {
        if (path.len == 0) return "";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') return path[i + 1 ..];
        }
        return path;
    }

    pub fn dirname(path: []const u8) []const u8 {
        if (path.len == 0) return ".";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') {
                if (i == 0) return "/";
                return path[0..i];
            }
        }
        return ".";
    }

    pub fn extname(path: []const u8) []const u8 {
        const base = basename(path);
        var i: usize = base.len;
        while (i > 0) {
            i -= 1;
            if (base[i] == '.') return base[i..];
        }
        return "";
    }
};

pub const System = struct {
    pub fn cwd() []const u8 {
        var buf: [4096]u8 = undefined;
        const ptr = std.c.getcwd(&buf, buf.len) orelse return "";
        const len = std.mem.sliceTo(ptr, 0).len;
        const result = bumpAlloc(len);
        if (result.len == 0) return "";
        @memcpy(result, buf[0..len]);
        return result;
    }

    pub fn get_env(name: []const u8) []const u8 {
        return envGetRuntime(name) orelse "";
    }

    /// Look up a build-time option provided via `-Dkey=value` on the
    /// command line. The compiler bakes these into a runtime-readable
    /// table per-target binary; absent that table (e.g. compiling a
    /// target with no `-D` flags), every name returns the empty
    /// string. Callers must not assume non-empty values exist.
    pub fn get_build_opt(_: []const u8) []const u8 {
        return "";
    }

    pub fn arg_count() i64 {
        const argv = getArgv();
        return if (argv.len > 0) @as(i64, @intCast(argv.len)) - 1 else 0;
    }

    pub fn arg_at(index: i64) []const u8 {
        const argv = getArgv();
        if (index < 0) return "";
        const idx: usize = @intCast(index);
        if (idx + 1 < argv.len) return std.mem.sliceTo(argv[idx + 1], 0);
        return "";
    }
};

// ============================================================
// Tests
// ============================================================

test "Arc basic reference counting" {
    const alloc = std.testing.allocator;
    const arc = try Arc(i64).init(alloc, 42);
    try std.testing.expectEqual(@as(u32, 1), arc.refCount());
    try std.testing.expectEqual(@as(i64, 42), arc.get().*);

    const arc2 = arc.retain();
    try std.testing.expectEqual(@as(u32, 2), arc.refCount());

    arc2.release(alloc);
    try std.testing.expectEqual(@as(u32, 1), arc.refCount());

    arc.release(alloc);
}

test "ArcRuntime.allocAny creates arc-managed value" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 42);
    defer ArcRuntime.freeAny(std.testing.allocator, val);
    try std.testing.expectEqual(@as(i64, 42), val.*);
}

test "ArcRuntime.retainAny and refCountAny" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 99);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    ArcRuntime.retainAny(val);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(val));

    // First free decrements but doesn't deallocate
    ArcRuntime.freeAny(std.testing.allocator, val);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    // Second free deallocates
    ArcRuntime.freeAny(std.testing.allocator, val);
}

test "ArcRuntime.prepareReleaseAny returns ptr only on the zero-transition" {
    const alloc = std.testing.allocator;
    const val = ArcRuntime.allocAny(i64, alloc, 7);
    // Second owner — refcount now 2.
    ArcRuntime.retainAny(val);

    // First prepare: count goes 2 → 1. We're not the final owner.
    try std.testing.expect(ArcRuntime.prepareReleaseAny(i64, val) == null);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(val));

    // Second prepare: count goes 1 → 0. We ARE the final owner.
    const owned = ArcRuntime.prepareReleaseAny(i64, val) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(i64, 7), owned.*);
    // Children would be walked here in a deep-release helper. Then:
    ArcRuntime.destroyPreparedAny(i64, alloc, owned);
}

test "Arc struct value" {
    const alloc = std.testing.allocator;
    const Point = struct { x: f64, y: f64 };
    const arc = try Arc(Point).init(alloc, .{ .x = 1.0, .y = 2.0 });
    try std.testing.expectEqual(@as(f64, 1.0), arc.getConst().x);
    try std.testing.expectEqual(@as(f64, 2.0), arc.getConst().y);
    arc.release(alloc);
}

test "MArrayOf(i64) new initializes every slot and length matches" {
    const array = MArrayOf(i64).new(5, 7);
    defer MArrayOf(i64).release(array);

    try std.testing.expectEqual(@as(i64, 5), MArrayOf(i64).length(array));
    var index: i64 = 0;
    while (index < 5) : (index += 1) {
        try std.testing.expectEqual(@as(i64, 7), MArrayOf(i64).get(array, index));
    }
}

test "MArrayOf(i64) set returns the written value and persists it" {
    const array = MArrayOf(i64).new(3, 0);
    defer MArrayOf(i64).release(array);

    try std.testing.expectEqual(@as(i64, 10), MArrayOf(i64).set(array, 0, 10));
    try std.testing.expectEqual(@as(i64, 20), MArrayOf(i64).set(array, 1, 20));
    try std.testing.expectEqual(@as(i64, 30), MArrayOf(i64).set(array, 2, 30));

    try std.testing.expectEqual(@as(i64, 10), MArrayOf(i64).get(array, 0));
    try std.testing.expectEqual(@as(i64, 20), MArrayOf(i64).get(array, 1));
    try std.testing.expectEqual(@as(i64, 30), MArrayOf(i64).get(array, 2));
}

test "MArrayOf(f64) initialises slots and round-trips writes" {
    const array = MArrayOf(f64).new(4, 1.5);
    defer MArrayOf(f64).release(array);

    try std.testing.expectEqual(@as(i64, 4), MArrayOf(f64).length(array));
    try std.testing.expectEqual(@as(f64, 1.5), MArrayOf(f64).get(array, 2));

    _ = MArrayOf(f64).set(array, 2, 2.75);
    try std.testing.expectEqual(@as(f64, 2.75), MArrayOf(f64).get(array, 2));
}

test "MArrayOf retain/release roundtrips refcount" {
    const array = MArrayOf(i64).new(2, 99);
    const inner: *const MArrayOf(i64).Inner = @ptrCast(@alignCast(array.?));
    try std.testing.expectEqual(@as(u32, 1), inner.header.count());

    const second_handle = MArrayOf(i64).retain(array);
    try std.testing.expectEqual(@as(u32, 2), inner.header.count());

    // First release brings count to 1 — does not free.
    MArrayOf(i64).release(second_handle);
    try std.testing.expectEqual(@as(u32, 1), inner.header.count());

    // Final release frees both the items buffer and the Inner.
    MArrayOf(i64).release(array);
}

test "MArrayI64 / MArrayF64 specialised aliases are concrete instantiations" {
    // The aliases must satisfy `==` with their generic instantiations
    // — Zig deduplicates generic types by comptime parameter values,
    // so this is a compile-time identity check.
    try std.testing.expect(MArrayI64 == MArrayOf(i64));
    try std.testing.expect(MArrayF64 == MArrayOf(f64));

    const ints = MArrayI64.new(2, 5);
    defer MArrayI64.release(ints);
    try std.testing.expectEqual(@as(i64, 5), MArrayI64.get(ints, 0));

    const floats = MArrayF64.new(2, 0.25);
    defer MArrayF64.release(floats);
    try std.testing.expectEqual(@as(f64, 0.25), MArrayF64.get(floats, 1));
}

test "releaseChildrenAny releases ?*const Map(K, V) field" {
    // Phase F regression test: when a struct holds a `?*const Map(K, V)`
    // child field, `releaseChildrenAny` must walk the field via
    // `releaseFieldChildAny` -> `releaseArcAny` and dispatch into the
    // Map's inline-header `release` method. Prior to Phase F the `.map`
    // type was not flagged as ARC-managed at the IR level, so this code
    // path was never exercised through the codegen. Now that `.map` is
    // ARC-managed, the runtime helper that releases struct children
    // must correctly recognize the inline-header path and avoid the
    // `Arc(T)`-wrapper double-counting that would arise if it routed
    // through `prepareReleaseAny`.
    const MapI64 = Map(i64, i64);

    const before_releases = arc_releases_total;

    const keys = [_]i64{ 1, 2, 3 };
    const vals = [_]i64{ 10, 20, 30 };
    const map_ptr = MapI64.fromPairs(&keys, &vals, 3) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(i64, 20), MapI64.get(map_ptr, 2, -1));

    // Wrap the Map pointer inside a struct, mimicking the codegen-emitted
    // shape for an aggregate that owns a Map child via an indirect-storage
    // optional pointer field.
    const Holder = struct {
        map_field: ?*const MapI64,
        scalar: i64,
    };
    const holder = Holder{ .map_field = map_ptr, .scalar = 7 };

    // releaseChildrenAny must traverse `map_field` and invoke the Map's
    // inline-header `release` (not the generic Arc(T) path). The non-arc
    // `scalar` field must be skipped without compile error.
    ArcRuntime.releaseChildrenAny(Holder, std.testing.allocator, holder);

    // The Map's `release` bumps `arc_releases_total` exactly once when it
    // hits the zero-transition. The generic wrapper short-circuits the
    // bump for inline-header types, so we expect exactly one release tick.
    try std.testing.expectEqual(before_releases + 1, arc_releases_total);
}

test "List(i64) cons + retain + release with refcount semantics" {
    // Phase H.1: every `cons` allocates a fresh Arc-headered cell from
    // the per-(T) MemoryPool. Refcount starts at 1; `retain` bumps,
    // `release` decrements. The cell is returned to the pool only on
    // the zero-transition.
    const ListI64 = List(i64);
    const before_retains = arc_retains_total;
    const before_releases = arc_releases_total;

    const cell_a = ListI64.cons(1, null) orelse {
        try std.testing.expect(false);
        return;
    };
    const cell_b = ListI64.cons(2, cell_a) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(i64, 2), ListI64.getHead(cell_b));
    try std.testing.expectEqual(@as(i64, 2), ListI64.length(cell_b));

    // Retain bumps the head cell only.
    _ = ListI64.retain(cell_b);
    try std.testing.expectEqual(before_retains + 1, arc_retains_total);

    // Release once — refcount drops to 1, cell stays alive.
    ListI64.release(cell_b);
    try std.testing.expectEqual(before_releases + 1, arc_releases_total);

    // Final release — cell_b's refcount hits zero, head is shallow
    // (i64), tail recurse into cell_a which also drops to zero.
    // Two cells freed, two release ticks.
    ListI64.release(cell_b);
    try std.testing.expectEqual(before_releases + 3, arc_releases_total);
}

test "releaseChildrenAny releases ?*const List(T) field" {
    // Phase H.1 regression test mirroring the Phase F Map-field test:
    // when a struct holds a `?*const List(T)` child field,
    // `releaseChildrenAny` must walk the field via
    // `releaseFieldChildAny` -> `releaseArcAny` and dispatch into the
    // List's inline-header `release` method (via `arcReleaseDeep`).
    // Now that List carries an inline `ArcHeader`, the runtime helper
    // must recognize the inline-header path and avoid the `Arc(T)`-
    // wrapper double-counting that would arise from
    // `prepareReleaseAny`.
    const ListI64 = List(i64);

    const before_releases = arc_releases_total;

    const cell_a = ListI64.cons(10, null) orelse {
        try std.testing.expect(false);
        return;
    };
    const cell_b = ListI64.cons(20, cell_a) orelse {
        try std.testing.expect(false);
        return;
    };

    // Wrap the list pointer inside a struct, mimicking the codegen-
    // emitted shape for an aggregate that owns a List child via an
    // indirect-storage optional pointer field.
    const Holder = struct {
        list_field: ?*const ListI64,
        scalar: i64,
    };
    const holder = Holder{ .list_field = cell_b, .scalar = 7 };

    // releaseChildrenAny must traverse `list_field` and invoke the
    // List's inline-header `release` (not the generic Arc(T) path).
    // The non-arc `scalar` field must be skipped without compile error.
    ArcRuntime.releaseChildrenAny(Holder, std.testing.allocator, holder);

    // The List's `release` bumps `arc_releases_total` once per cell
    // freed (two cells in this spine), and the generic wrapper short-
    // circuits its own bump for inline-header types.
    try std.testing.expectEqual(before_releases + 2, arc_releases_total);
}

test "List(?*const Map) deep-releases Map heads on cell teardown" {
    // Phase H.1 keystone: a list of ARC-managed values (here, Map
    // pointers) must release each head when the cell is reclaimed.
    // Without this, the doc-runner fails — `compose_member_detail`
    // builds a list whose heads are Maps, the comptime store consumes
    // the +1, then the cell drops with a stale Map pointer that gets
    // reused.
    const MapI64 = Map(i64, i64);
    const ListMap = List(?*const MapI64);

    const before_releases = arc_releases_total;

    const keys_one = [_]i64{ 1, 2 };
    const vals_one = [_]i64{ 10, 20 };
    const map_one = MapI64.fromPairs(&keys_one, &vals_one, 2) orelse {
        try std.testing.expect(false);
        return;
    };
    const keys_two = [_]i64{ 3, 4 };
    const vals_two = [_]i64{ 30, 40 };
    const map_two = MapI64.fromPairs(&keys_two, &vals_two, 2) orelse {
        try std.testing.expect(false);
        return;
    };

    // Build [map_one, map_two] — `cons` consumes its arguments, so
    // the list now owns the +1 on each Map.
    const cell_a = ListMap.cons(map_two, null) orelse {
        try std.testing.expect(false);
        return;
    };
    const cell_b = ListMap.cons(map_one, cell_a) orelse {
        try std.testing.expect(false);
        return;
    };

    // Releasing the list's head cell tears down the entire spine and
    // each cell deep-releases its head Map. Expect:
    //   * 2 List cells freed (2 release ticks from List.release).
    //   * 2 Map cells freed (2 release ticks from Map.release).
    ListMap.release(cell_b);
    try std.testing.expectEqual(before_releases + 4, arc_releases_total);
}

test "Atom well-known values" {
    try std.testing.expectEqual(@as(u32, 0), Atom.nil.id);
    try std.testing.expectEqual(@as(u32, 1), Atom.true.id);
    try std.testing.expect(Atom.nil.eql(Atom.nil));
    try std.testing.expect(!Atom.nil.eql(Atom.true));
}

test "AtomTable intern and retrieve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var table = AtomTable.init(alloc);
    defer table.deinit();

    const hello = try table.intern("hello");
    const world = try table.intern("world");
    const hello2 = try table.intern("hello");

    try std.testing.expect(hello.eql(hello2));
    try std.testing.expect(!hello.eql(world));
    try std.testing.expectEqualStrings("hello", table.getName(hello));
    try std.testing.expectEqualStrings("world", table.getName(world));

    // Well-known atoms should exist
    try std.testing.expectEqualStrings("nil", table.getName(Atom.nil));
    try std.testing.expectEqualStrings("true", table.getName(Atom.true));
}

test "String operations" {
    try std.testing.expect(String.contains("hello world", "world"));
    try std.testing.expect(!String.contains("hello world", "xyz"));
    try std.testing.expect(String.startsWith("hello", "hel"));
    try std.testing.expect(String.endsWith("hello", "llo"));
    try std.testing.expectEqualStrings("llo", String.slice("hello", 2, 5));
    try std.testing.expectEqualStrings("hello", String.trim("  hello  "));
}

test "String concat" {
    try std.testing.expectEqualStrings("hello world", String.concat("hello", " world"));
}

// ============================================================
// Map workload instrumentation differential tests (Phase A)
//
// These three tests validate the S/W/V classifier against three
// canonical lifetime patterns. They are gated by `comptime if
// (instrument_map)`: when the compiler is built with the default
// `-Dinstrument-map=false` they pass trivially, and when built with
// `-Dinstrument-map=true` they exercise the full classifier path.
// ============================================================

test "instrumentation: S — never shared" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const before_id = mapInstrumentationLastInstanceId();
    const m_initial = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    var m: ?*const MapI64 = m_initial;
    var k: i64 = 2;
    while (k <= 5) : (k += 1) {
        const next_m = MapI64.put(m, k, k * 100) orelse {
            try std.testing.expect(false);
            return;
        };
        MapI64.release(m);
        m = next_m;
    }
    // First derived id is `before_id + 1`. We re-resolve via a probe:
    // the initial allocation registered exactly one instance with the
    // first-allocated cell pointer, which became the parent for the
    // four follow-up `put` calls. Releasing m releases the chain head.
    MapI64.release(m);

    // Walk the finalised list looking for the chain we just produced
    // (lineage_id was assigned to the first allocation; every put
    // inherited it via the parent context). We expect 5 records (one
    // per allocation), all class S with peak_strong_count = 1.
    var saw_first: bool = false;
    var seen_class_S: u32 = 0;
    var puts_on_first: u32 = 0;
    var gets_on_first: u32 = 0;
    for (instrumentation_state.finalised.items) |rec| {
        if (rec.instance_id <= before_id) continue;
        try std.testing.expectEqual(@as(u32, 1), rec.peak_strong_count);
        if (rec.class == 'S') seen_class_S += 1;
        if (!saw_first and rec.parent_instance_id == 0) {
            saw_first = true;
            puts_on_first = rec.puts;
            gets_on_first = rec.gets;
        }
    }
    try std.testing.expect(seen_class_S >= 5);
    try std.testing.expect(saw_first);
    // The first map had four `put` calls applied to it (the chain
    // wraps it four times before the final release).
    try std.testing.expectEqual(@as(u32, 1), puts_on_first);
    try std.testing.expectEqual(@as(u32, 0), gets_on_first);
}

test "instrumentation: W — shared but never post-share-mutated" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const m = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    const cell_ptr = @intFromPtr(m);
    const initial_record = instrumentation_state.active.getPtr(cell_ptr).?;
    const instance_id = initial_record.instance_id;

    // Share by retaining — refcount goes 1 → 2.
    _ = MapI64.retain(m);
    // Drop the share without mutating — refcount returns to 1.
    MapI64.release(m);
    // Final release — class W expected (had_share_event=true,
    // had_post_share_mutation=false).
    MapI64.release(m);

    const rec = mapInstrumentationFindFinalised(0, instance_id) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(rec.had_share_event);
    try std.testing.expect(!rec.had_post_share_mutation);
    try std.testing.expectEqual(@as(u8, 'W'), rec.class);
    try std.testing.expectEqual(@as(u32, 2), rec.peak_strong_count);
}

test "instrumentation: V — shared and post-share-mutated" {
    if (!comptime instrument_map) return;
    const MapI64 = Map(i64, i64);
    const original = MapI64.put(null, 1, 100) orelse {
        try std.testing.expect(false);
        return;
    };
    const original_ptr = @intFromPtr(original);
    const original_id = instrumentation_state.active.getPtr(original_ptr).?.instance_id;

    // Share — refcount goes 1 → 2 — `had_share_event` flips on.
    _ = MapI64.retain(original);

    // Mutate while still shared. `put` allocates a fresh derived map.
    const derived = MapI64.put(original, 2, 200) orelse {
        try std.testing.expect(false);
        return;
    };
    // The mutation hook should have flagged `had_post_share_mutation`
    // on the original cell.

    // Release the second share, then the original cell, then the
    // derived. We expect the original cell to land in finalised with
    // class V.
    MapI64.release(original);
    MapI64.release(original);
    MapI64.release(derived);

    const rec = mapInstrumentationFindFinalised(0, original_id) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(rec.had_share_event);
    try std.testing.expect(rec.had_post_share_mutation);
    try std.testing.expectEqual(@as(u8, 'V'), rec.class);
}
