//! Wyhash for Zap's dense Map.
//!
//! Wraps Zig's stdlib production wyhash (the same `final v3` implementation used by
//! `ankerl::unordered_dense` by default) and adds:
//!
//!   * Comptime-dispatched type specializations for the keys Zap actually
//!     hashes — `u64`/`i64`, `Atom` (a u32 newtype), `[]const u8`, plus
//!     reasonable defaults for other ints, bools, and pointers.
//!
//!   * A per-process random seed source. The seed is materialized lazily on
//!     first read into a thread-local cache, mixed from process-startup
//!     entropy (return-address / ASLR), a strictly-monotonic atomic counter,
//!     and `SplitMix64` finishing rounds. This is sufficient for hash-flooding
//!     resistance — the attacker cannot predict the seed without process
//!     introspection — and crucially does not require an `Io` instance, which
//!     would otherwise force every `Map` allocation to thread one through.
//!
//! This file is fully standalone: it only imports `std`. It does NOT import
//! `runtime.zig` or any Zap-specific types. Callers that need to hash an
//! `Atom` pass in `u32` directly via the `u32` specialization.
//!
//! Reference (test vectors verified at the bottom of this file):
//!   https://github.com/wangyi-fudan/wyhash

const std = @import("std");
const builtin = @import("builtin");
const StdWyhash = std.hash.Wyhash;

// -----------------------------------------------------------------------------
// Seed source
// -----------------------------------------------------------------------------

/// Strictly-monotonic counter bumped on every seed materialization. Combined
/// with ASLR-derived entropy via SplitMix64 to produce a per-instance hash seed
/// that is unpredictable to an attacker without process introspection.
var seed_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

threadlocal var thread_seed_state: ?u64 = null;

/// SplitMix64 mixer. Pure 64-bit avalanche function.
inline fn splitMix64(state: u64) u64 {
    var z = state +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Mix in best-effort OS entropy if available. Best-effort because we don't
/// have `Io` wiring at hash-construction time. On Linux this taps the
/// `getrandom(2)` syscall directly; on other platforms we fall through to the
/// purely deterministic-but-ASLR-seeded path.
fn osEntropy() u64 {
    var buf: [8]u8 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.getrandom(&buf, buf.len, 0);
            // rc is unsigned; treat any short read as failure.
            if (rc == buf.len) {
                return std.mem.readInt(u64, &buf, .little);
            }
        },
        else => {},
    }
    return 0;
}

/// Compute a fresh per-instance hash seed.
///
/// Inputs:
///   * Static return-address of an inline function call site (ASLR-based
///     entropy that varies per process).
///   * A strictly-monotonic atomic counter (varies per instance within a
///     process).
///   * Best-effort OS entropy (only effective on Linux today; harmless zero
///     elsewhere).
///   * A SplitMix64 finishing round to avalanche all sources.
pub fn nextSeed() u64 {
    const counter = seed_counter.fetchAdd(1, .monotonic);
    if (thread_seed_state == null) {
        // Initialize the per-thread state on first use. Uses
        // `@returnAddress()` for ASLR-derived entropy without requiring an
        // `Io` parameter.
        const ra: u64 = @intCast(@returnAddress());
        thread_seed_state = splitMix64(ra ^ osEntropy() ^ 0xD1B54A32D192ED03);
    }
    // Advance the per-thread state and mix in the global counter.
    thread_seed_state = splitMix64(thread_seed_state.? +% counter);
    return thread_seed_state.?;
}

// -----------------------------------------------------------------------------
// Hash functions
// -----------------------------------------------------------------------------

/// Hash a single 64-bit integer with a single round of wyhash mixing on the
/// 64-bit value. Equivalent to running wyhash on the 8 little-endian bytes of
/// `value` — but we keep the implementation here so it stays inline-friendly
/// and dispatches at comptime.
pub inline fn hashU64(seed: u64, value: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return StdWyhash.hash(seed, &bytes);
}

/// Hash a 32-bit integer (e.g. an `Atom`). Equivalent to wyhash on the 4
/// little-endian bytes.
pub inline fn hashU32(seed: u64, value: u32) u64 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return StdWyhash.hash(seed, &bytes);
}

/// Hash a byte slice with full wyhash.
pub inline fn hashBytes(seed: u64, bytes: []const u8) u64 {
    return StdWyhash.hash(seed, bytes);
}

/// Comptime-dispatched hasher. Picks a specialization based on the static type
/// of `value`:
///   * `u64`/`i64`/`u32`/`i32`/...  — fixed-size integer mixing.
///   * `[]const u8`                  — byte-slice wyhash.
///   * `bool`                        — treated as a 1-byte slice.
///   * pointer types                 — hash the integer address.
///   * any other type                — `@compileError`.
///
/// Atoms are u32 in Zap's runtime; callers should pass the underlying u32.
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
            // Wider ints: hash all bytes.
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
            // Hash the address.
            break :blk hashU64(seed, @intCast(@intFromPtr(value)));
        },
        else => @compileError("zap.wyhash.hash: unsupported key type " ++ @typeName(T)),
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

// Reference test vectors from the wyhash repository's `test_vector.cpp`.
// These are the same vectors Zig's stdlib uses; we reaffirm them here so
// regressions in our wrapper are caught locally.
test "wyhash reference test vectors" {
    const Vector = struct { seed: u64, input: []const u8, expected: u64 };
    const vectors = [_]Vector{
        .{ .seed = 0, .input = "", .expected = 0x409638ee2bde459 },
        .{ .seed = 1, .input = "a", .expected = 0xa8412d091b5fe0a9 },
        .{ .seed = 2, .input = "abc", .expected = 0x32dd92e4b2915153 },
        .{ .seed = 3, .input = "message digest", .expected = 0x8619124089a3a16b },
        .{ .seed = 4, .input = "abcdefghijklmnopqrstuvwxyz", .expected = 0x7a43afb61d7f5f40 },
        .{ .seed = 5, .input = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", .expected = 0xff42329b90e50d58 },
        .{ .seed = 6, .input = "12345678901234567890123456789012345678901234567890123456789012345678901234567890", .expected = 0xc39cab13b115aad3 },
    };
    for (vectors) |v| {
        try testing.expectEqual(v.expected, hashBytes(v.seed, v.input));
    }
}

test "hashU64 deterministic" {
    const a = hashU64(0xdeadbeef, 12345);
    const b = hashU64(0xdeadbeef, 12345);
    try testing.expectEqual(a, b);
}

test "hashU64 changes with seed" {
    const a = hashU64(0, 12345);
    const b = hashU64(1, 12345);
    try testing.expect(a != b);
}

test "hashU64 changes with value" {
    const a = hashU64(7, 12345);
    const b = hashU64(7, 12346);
    try testing.expect(a != b);
}

test "hashU32 deterministic" {
    const a = hashU32(0x1234, 0xCAFE);
    const b = hashU32(0x1234, 0xCAFE);
    try testing.expectEqual(a, b);
}

test "hashU32 changes with input" {
    const a = hashU32(99, 1);
    const b = hashU32(99, 2);
    try testing.expect(a != b);
}

test "hashBytes equivalence with raw stdlib" {
    const seed: u64 = 0xABCDEF0123456789;
    const input = "the quick brown fox jumps over the lazy dog";
    try testing.expectEqual(StdWyhash.hash(seed, input), hashBytes(seed, input));
}

test "comptime hash dispatch — u64" {
    const value: u64 = 0xDEAD_BEEF_CAFE_F00D;
    try testing.expectEqual(hashU64(7, value), hash(7, value));
}

test "comptime hash dispatch — u32" {
    const value: u32 = 0xCAFEF00D;
    try testing.expectEqual(hashU32(7, value), hash(7, value));
}

test "comptime hash dispatch — i64" {
    const value: i64 = -42;
    const u: u64 = @bitCast(value);
    try testing.expectEqual(hashU64(7, u), hash(7, value));
}

test "comptime hash dispatch — bytes" {
    const slice: []const u8 = "hello";
    try testing.expectEqual(hashBytes(7, slice), hash(7, slice));
}

test "comptime hash dispatch — bool" {
    // Just verify it compiles, returns deterministic values, and the two booleans differ.
    const a = hash(0, true);
    const b = hash(0, false);
    const a2 = hash(0, true);
    try testing.expectEqual(a, a2);
    try testing.expect(a != b);
}

test "nextSeed produces non-zero, varying values" {
    const a = nextSeed();
    const b = nextSeed();
    const c = nextSeed();
    try testing.expect(a != b);
    try testing.expect(b != c);
    try testing.expect(a != c);
    try testing.expect(a != 0);
    try testing.expect(b != 0);
    try testing.expect(c != 0);
}

test "nextSeed counter is strictly monotonic" {
    // The internal counter must advance on each call, even if we somehow
    // produced colliding mixed seeds. Verify by reading the counter directly
    // and bracketing two calls.
    const before = seed_counter.load(.monotonic);
    _ = nextSeed();
    _ = nextSeed();
    _ = nextSeed();
    const after = seed_counter.load(.monotonic);
    try testing.expect(after >= before + 3);
}
