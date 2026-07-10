//! P6-J3 string-blob crossover benchmark: large-string send cost, walker
//! path vs blob share tier, as a function of string size.
//!
//! Phase-6 job P6-J3 of `docs/concurrency-implementation-plan.md` (plan item
//! 6.3, Blob-backed String per rev-2 §5.4). It measures the two ways a
//! top-level `String` can cross a process boundary, to locate the
//! **promotion threshold** (`string_blob_promotion_threshold` in
//! `src/runtime.zig`) by measurement rather than instinct:
//!
//!   * **walker path** (the sub-threshold path, and the whole story before
//!     P6-J3): Copy A — `serializeMessage` (walk + `c_allocator` blob +
//!     bytes in); Copy B — the kernel mailbox `@memcpy` (`zap_proc_send`
//!     into the payload ledger; modeled here as a bare `@memcpy` into a
//!     preallocated buffer, its exact cost shape); Copy C —
//!     `deserializeMessage` (receiver-owned allocation + bytes out).
//!     Three size-proportional copies per send.
//!   * **blob promotion** (the ≥-threshold path for a not-yet-backed
//!     string): ONE copy into a fresh page-backed blob
//!     (`BlobDomain.createFromParts` — mmap + memcpy + slot publish), then
//!     the moved envelope carries a pointer. Adoption is a ledger append
//!     (O(1), pointer-sized) — modeled by the header→handle recovery the
//!     receive path performs. The per-op release models the receiver
//!     teardown's drain (munmap), so an op is the full steady-state
//!     lifecycle cost.
//!   * **blob share** (the already-backed string — a received string
//!     forwarded, or an append-promoted accumulator): ONE probe
//!     (`resolveWholePayloadView`) + atomic retain + release. Size-
//!     independent; reported to quantify the forward win.
//!
//! The CROSSOVER is the smallest size at which promotion beats the walker's
//! three copies; the threshold ships as the next power of two at or above
//! it (bounding the receiver-side page-rounding overhead — a page minimum
//! per adopted payload). The `append` mode additionally compares the rc==1
//! in-place blob append against the arena-concat local path per appended
//! KiB (the local-cost honesty check for accumulators that entered the
//! tier).
//!
//! ## Protocol (E1/E6/E9 ledger conventions)
//!
//! One measurement at a time, foreground; `CLOCK_UPTIME_RAW` directly (never
//! through code under test); per size an unrecorded warmup then `reps`
//! (default 7) repetitions; samples pooled → median/min/p99; anti-elision
//! checksums folded into a printed sink. Run via `run-string-blob-bench.sh`
//! (records `uptime` before each mode).
//!
//! ## Toolchain
//!
//! MUST be compiled with the Zap Zig fork (ledger convention; the module
//! graph binds the REAL runtime + REAL ARC manager exactly like `bench.zig`
//! — see the runner script).

const std = @import("std");
const zap = @import("zapruntime");
const blob_domain_module = @import("blobdomain");

const BlobDomain = blob_domain_module.BlobDomain;

// -- harness clock (CLOCK_UPTIME_RAW, never through the code under test) ----

fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// -- configuration -----------------------------------------------------------

const default_repetition_count: usize = 7;

/// String sizes bracketing the candidate threshold: 256 B → 1 MB.
const size_targets = [_]usize{ 256, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 262144, 1048576 };

fn sampleCountForSize(byte_length: usize) usize {
    if (byte_length <= 4096) return 8_000;
    if (byte_length <= 65_536) return 3_000;
    if (byte_length <= 262_144) return 1_200;
    return 400;
}

var elision_sink: u64 = 0;

const Distribution = struct {
    samples: []u64,
    filled: usize = 0,

    fn push(dist: *Distribution, value: u64) void {
        dist.samples[dist.filled] = value;
        dist.filled += 1;
    }
    fn finalize(dist: *Distribution) void {
        std.mem.sort(u64, dist.samples[0..dist.filled], {}, std.sort.asc(u64));
    }
    fn median(dist: *Distribution) u64 {
        return dist.samples[dist.filled / 2];
    }
    fn min(dist: *Distribution) u64 {
        return dist.samples[0];
    }
    fn percentile(dist: *Distribution, per_mille: usize) u64 {
        const index = (dist.filled * per_mille) / 1000;
        return dist.samples[@min(index, dist.filled - 1)];
    }
};

fn makeDistribution(allocator: std.mem.Allocator, capacity: usize) !Distribution {
    return .{ .samples = try allocator.alloc(u64, capacity) };
}

// -- the send-path comparison -------------------------------------------------

/// One walker-path op: serialize (Copy A) + kernel-transport memcpy
/// (Copy B, into a preallocated ledger-model buffer) + reconstruct (Copy C).
fn walkerOp(source: []const u8, transport_buffer: []u8) !u64 {
    const start = nowNanoseconds();
    const blob = try zap.serializeMessage([]const u8, source, std.heap.c_allocator);
    @memcpy(transport_buffer[0..blob.len], blob);
    const copy = try zap.deserializeMessage([]const u8, transport_buffer[0..blob.len]);
    const elapsed = nowNanoseconds() - start;
    std.debug.assert(copy.len == source.len);
    elision_sink +%= copy[0] +% copy[copy.len - 1];
    std.heap.c_allocator.free(blob);
    return elapsed;
}

/// One walker op on the REAL gate-ON receiver substrate for large strings:
/// Copy A + Copy B as in `walkerOp`, but Copy C allocates the receiver's
/// buffer from the page allocator — which is exactly what the gate-ON
/// `readStringCopy` does for strings past the ARC slab boundary
/// (`containerBufferAlloc` routes >4096-byte buffers to page-backed large
/// allocations, P3-J5), and frees it as the teardown drain's munmap. The
/// plain `walkerOp`'s warm-arena Copy C is the gate-OFF substrate — an
/// UNDERESTIMATE of the gate-ON walker cost at these sizes.
fn walkerPageBackedOp(source: []const u8, transport_buffer: []u8) !u64 {
    const start = nowNanoseconds();
    const blob = try zap.serializeMessage([]const u8, source, std.heap.c_allocator);
    @memcpy(transport_buffer[0..blob.len], blob);
    const receiver_buffer = try std.heap.page_allocator.alloc(u8, source.len);
    @memcpy(receiver_buffer, transport_buffer[4 .. 4 + source.len]);
    const elapsed = nowNanoseconds() - start;
    elision_sink +%= receiver_buffer[0] +% receiver_buffer[source.len - 1];
    std.heap.page_allocator.free(receiver_buffer);
    std.heap.c_allocator.free(blob);
    return elapsed;
}

/// One blob-promotion op: createFromParts (the ONE copy — mmap + memcpy +
/// slot publish) + the receive side's header→handle recovery + payload read
/// touch + release (the teardown drain's munmap) — the full steady-state
/// lifecycle of one promoted send.
fn promoteOp(domain: *BlobDomain, source: []const u8) !u64 {
    const start = nowNanoseconds();
    const handle = try domain.createFromParts(source, &.{}, 0);
    const payload = domain.payloadPointer(handle).?;
    const recovered = BlobDomain.handleForPayloadPointer(payload);
    std.debug.assert(recovered.toBits() == handle.toBits());
    elision_sink +%= payload[0] +% payload[source.len - 1];
    _ = domain.release(handle);
    return nowNanoseconds() - start;
}

/// One blob-share op (the already-backed forward): whole-view probe +
/// atomic flight retain + receiver-side read touch + release. Zero copies.
fn shareOp(domain: *BlobDomain, payload: [*]const u8, byte_length: usize) u64 {
    const start = nowNanoseconds();
    const handle = domain.resolveWholePayloadView(payload, byte_length).?;
    std.debug.assert(domain.tryRetain(handle));
    elision_sink +%= payload[0] +% payload[byte_length - 1];
    _ = domain.release(handle);
    return nowNanoseconds() - start;
}

fn runSendMode(allocator: std.mem.Allocator, reps: usize) !void {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    std.debug.print(
        "mode=send  columns: bytes | walker(A+B+C, warm-arena C) med/min/p99 | walker(page-backed C, the gate-ON >4096 substrate) med/min/p99 | promote med/min/p99 | share med/min/p99  (ns/op)\n",
        .{},
    );

    for (size_targets) |byte_length| {
        const source = try allocator.alloc(u8, byte_length);
        defer allocator.free(source);
        for (source, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
        const transport_buffer = try allocator.alloc(u8, byte_length + 16);
        defer allocator.free(transport_buffer);

        // The share row's standing blob (the "received earlier" string).
        const standing = try domain.createFromParts(source, &.{}, 0);
        defer _ = domain.release(standing);
        const standing_payload = domain.payloadPointer(standing).?;

        const samples = sampleCountForSize(byte_length);
        var walker_dist = try makeDistribution(allocator, samples * reps);
        defer allocator.free(walker_dist.samples);
        var walker_page_dist = try makeDistribution(allocator, samples * reps);
        defer allocator.free(walker_page_dist.samples);
        var promote_dist = try makeDistribution(allocator, samples * reps);
        defer allocator.free(promote_dist.samples);
        var share_dist = try makeDistribution(allocator, samples * reps);
        defer allocator.free(share_dist.samples);

        // Warmup (unrecorded).
        var warm: usize = 0;
        while (warm < 64) : (warm += 1) {
            _ = try walkerOp(source, transport_buffer);
            _ = try walkerPageBackedOp(source, transport_buffer);
            _ = try promoteOp(&domain, source);
            _ = shareOp(&domain, standing_payload, byte_length);
            zap.resetAllocator(); // bound the walker's arena growth (untimed)
        }

        var rep: usize = 0;
        while (rep < reps) : (rep += 1) {
            var sample: usize = 0;
            while (sample < samples) : (sample += 1) {
                walker_dist.push(try walkerOp(source, transport_buffer));
                walker_page_dist.push(try walkerPageBackedOp(source, transport_buffer));
                promote_dist.push(try promoteOp(&domain, source));
                share_dist.push(shareOp(&domain, standing_payload, byte_length));
                if (sample % 64 == 0) zap.resetAllocator(); // untimed arena bound
            }
        }

        walker_dist.finalize();
        walker_page_dist.finalize();
        promote_dist.finalize();
        share_dist.finalize();
        std.debug.print(
            "{d:>8} | {d:>8} {d:>8} {d:>8} | {d:>8} {d:>8} {d:>8} | {d:>8} {d:>8} {d:>8} | {d:>6} {d:>6} {d:>6}\n",
            .{
                byte_length,
                walker_dist.median(),
                walker_dist.min(),
                walker_dist.percentile(990),
                walker_page_dist.median(),
                walker_page_dist.min(),
                walker_page_dist.percentile(990),
                promote_dist.median(),
                promote_dist.min(),
                promote_dist.percentile(990),
                share_dist.median(),
                share_dist.min(),
                share_dist.percentile(990),
            },
        );
    }
}

// -- the append comparison ------------------------------------------------------

/// Per appended KiB: the rc==1 in-place blob append (frontier memcpy +
/// header/slot length stores) vs the arena concat (`zap.String.concat`,
/// which extends in place when the base is the latest arena allocation).
/// Chains of 512 × 1 KiB appends; per-append cost reported.
fn runAppendMode(allocator: std.mem.Allocator, reps: usize) !void {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const chunk_size: usize = 1024;
    const chain_length: usize = 512;
    var chunk: [chunk_size]u8 = undefined;
    for (&chunk, 0..) |*byte, index| byte.* = @truncate(index *% 17 +% 3);

    std.debug.print(
        "mode=append  columns: blob-in-place ns/append (med/min) | arena-concat ns/append (med/min)  ({d} x {d} B chains)\n",
        .{ chain_length, chunk_size },
    );

    var blob_dist = try makeDistribution(allocator, reps);
    defer allocator.free(blob_dist.samples);
    var arena_dist = try makeDistribution(allocator, reps);
    defer allocator.free(arena_dist.samples);

    var rep: usize = 0;
    while (rep < reps + 1) : (rep += 1) {
        // Blob chain: one blob with capacity for the whole chain, appended
        // in place at the frontier every step (rc==1 throughout).
        const seed = "seed";
        const handle = try domain.createFromParts(seed, &.{}, seed.len + chain_length * chunk_size);
        var frontier: usize = seed.len;
        const blob_start = nowNanoseconds();
        var step: usize = 0;
        while (step < chain_length) : (step += 1) {
            std.debug.assert(domain.tryAppendInPlace(handle, frontier, &chunk));
            frontier += chunk_size;
        }
        const blob_elapsed = nowNanoseconds() - blob_start;
        elision_sink +%= domain.bytesView(handle).?[frontier - 1];
        _ = domain.release(handle);

        // Arena chain: the existing local path (extend-in-place fast path).
        zap.resetAllocator();
        var accumulator: []const u8 = "seed";
        const arena_start = nowNanoseconds();
        step = 0;
        while (step < chain_length) : (step += 1) {
            accumulator = zap.String.concat(accumulator, &chunk);
        }
        const arena_elapsed = nowNanoseconds() - arena_start;
        std.debug.assert(accumulator.len == seed.len + chain_length * chunk_size);
        elision_sink +%= accumulator[accumulator.len - 1];
        zap.resetAllocator();

        if (rep == 0) continue; // warmup rep unrecorded
        blob_dist.push(blob_elapsed / chain_length);
        arena_dist.push(arena_elapsed / chain_length);
    }

    blob_dist.finalize();
    arena_dist.finalize();
    std.debug.print(
        "blob-in-place: {d} / {d}   arena-concat: {d} / {d}\n",
        .{ blob_dist.median(), blob_dist.min(), arena_dist.median(), arena_dist.min() },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    var arg_iterator: std.process.Args.Iterator = .init(init.args);
    _ = arg_iterator.next(); // program name
    const mode = arg_iterator.next() orelse "send";
    const reps: usize = if (arg_iterator.next()) |raw|
        try std.fmt.parseInt(usize, raw, 10)
    else
        default_repetition_count;

    if (std.mem.eql(u8, mode, "send")) {
        try runSendMode(allocator, reps);
    } else if (std.mem.eql(u8, mode, "append")) {
        try runAppendMode(allocator, reps);
    } else {
        std.debug.print("unknown mode '{s}' (send|append)\n", .{mode});
        return error.UnknownMode;
    }
    std.debug.print("elision_sink={d}\n", .{elision_sink});
}
