//! E1 spike benchmark (concurrency campaign, job S0.2).
//!
//! THROWAWAY SPIKE CODE — see README.md. Measures, on the Zig fork's std.Io
//! implementations:
//!   * task spawn cost (`Io.async`, windowed and serial, plus `Io.Group.async`)
//!   * ping-pong message RTT through two capacity-1 `Io.Queue(u64)`s
//!   * raw single-task `Io.Queue` putOne/getOne floor
//! on both `Io.Evented` (Dispatch/GCD on macOS) and `Io.Threaded`.
//!
//! Build (asdf zig 0.16.0 binary against the fork's std):
//!   zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast bench.zig
//! Run (one measurement at a time):
//!   ./bench <evented|threaded> <spawn|spawn-serial|spawn-group|pingpong|queue> [ops] [reps] [warmup]

const std = @import("std");
const Io = std.Io;

const default_spawn_count = 100_000;
const default_round_trips = 100_000;
const default_queue_op_pairs = 1_000_000;
const default_repetitions = 5;

/// Maximum number of in-flight `Io.Future`s during the windowed spawn
/// benchmark. Dispatch fibers each reserve ~60 MB of lazily-committed
/// address space (`Io/Dispatch.zig` `Fiber.min_stack_size`), so holding all
/// 100k futures at once is not feasible on that backend; a fixed window
/// bounds peak in-flight tasks while still amortizing await overhead.
const spawn_window = 64;

const Backend = enum { evented, threaded };
const Benchmark = enum { spawn, @"spawn-serial", @"spawn-group", pingpong, queue };

/// Io-independent monotonic nanosecond clock (CLOCK_UPTIME_RAW), so timing
/// never routes through the Io implementation under test.
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Sample = struct {
    total_ns: u64,
    op_count: usize,
    /// Number of `Io.async` calls that completed eagerly inline
    /// (`Future.any_future == null`) instead of being assigned a task.
    eager_count: usize = 0,

    fn perOpNs(sample: Sample) f64 {
        return @as(f64, @floatFromInt(sample.total_ns)) /
            @as(f64, @floatFromInt(sample.op_count));
    }
};

fn trivialTask() u64 {
    return 1;
}

fn trivialGroupTask() void {}

/// Spawn `spawn_count` trivial tasks via `Io.async`, keeping at most
/// `spawn_window` futures in flight; awaits everything before stopping the
/// clock. Per-op number = amortized spawn + await cost.
fn benchSpawnWindowed(io: Io, spawn_count: usize) Sample {
    var futures: [spawn_window]?Io.Future(u64) = @splat(null);
    var eager_count: usize = 0;
    var checksum: u64 = 0;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < spawn_count) : (index += 1) {
        const slot = index % spawn_window;
        if (futures[slot]) |*future| checksum +%= future.await(io);
        futures[slot] = io.async(trivialTask, .{});
        if (futures[slot].?.any_future == null) eager_count += 1;
    }
    for (&futures) |*maybe_future| {
        if (maybe_future.*) |*future| checksum +%= future.await(io);
    }
    const total_ns = nowNanoseconds() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .total_ns = total_ns, .op_count = spawn_count, .eager_count = eager_count };
}

/// Spawn one trivial task and await it immediately, `spawn_count` times.
/// Per-op number = full spawn -> complete -> await round trip.
fn benchSpawnSerial(io: Io, spawn_count: usize) Sample {
    var eager_count: usize = 0;
    var checksum: u64 = 0;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < spawn_count) : (index += 1) {
        var future = io.async(trivialTask, .{});
        if (future.any_future == null) eager_count += 1;
        checksum +%= future.await(io);
    }
    const total_ns = nowNanoseconds() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .total_ns = total_ns, .op_count = spawn_count, .eager_count = eager_count };
}

/// Spawn `spawn_count` trivial tasks into one `Io.Group` and await the group.
/// Group task resources are released when each task returns, so in-flight
/// memory is bounded by how fast the backend drains the tasks.
fn benchSpawnGroup(io: Io, spawn_count: usize) Sample {
    var group: Io.Group = .init;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < spawn_count) : (index += 1) {
        group.async(io, trivialGroupTask, .{});
    }
    group.await(io) catch |err| std.debug.panic("group await: {s}", .{@errorName(err)});
    const total_ns = nowNanoseconds() - start_ns;
    return .{ .total_ns = total_ns, .op_count = spawn_count };
}

fn pingActor(io: Io, out_queue: *Io.Queue(u64), in_queue: *Io.Queue(u64), round_trips: usize) u64 {
    var token: u64 = 0;
    var round: usize = 0;
    while (round < round_trips) : (round += 1) {
        out_queue.putOne(io, token) catch |err|
            std.debug.panic("ping put: {s}", .{@errorName(err)});
        token = in_queue.getOne(io) catch |err|
            std.debug.panic("ping get: {s}", .{@errorName(err)});
    }
    return token;
}

fn pongActor(io: Io, in_queue: *Io.Queue(u64), out_queue: *Io.Queue(u64), round_trips: usize) void {
    var round: usize = 0;
    while (round < round_trips) : (round += 1) {
        const token = in_queue.getOne(io) catch |err|
            std.debug.panic("pong get: {s}", .{@errorName(err)});
        out_queue.putOne(io, token + 1) catch |err|
            std.debug.panic("pong put: {s}", .{@errorName(err)});
    }
}

/// Two tasks exchange a token through two capacity-1 queues for
/// `round_trips` round trips. Both actors are spawned with `Io.concurrent`
/// so each is guaranteed its own unit of concurrency (with `Io.async` on a
/// saturated Threaded pool an actor could run inline and deadlock).
fn benchPingPong(io: Io, round_trips: usize) Sample {
    var ping_buffer: [1]u64 = undefined;
    var pong_buffer: [1]u64 = undefined;
    var ping_queue: Io.Queue(u64) = .init(&ping_buffer);
    var pong_queue: Io.Queue(u64) = .init(&pong_buffer);

    const start_ns = nowNanoseconds();
    var ping_future = io.concurrent(pingActor, .{ io, &ping_queue, &pong_queue, round_trips }) catch |err|
        std.debug.panic("concurrent(ping): {s}", .{@errorName(err)});
    var pong_future = io.concurrent(pongActor, .{ io, &ping_queue, &pong_queue, round_trips }) catch |err|
        std.debug.panic("concurrent(pong): {s}", .{@errorName(err)});
    const final_token = ping_future.await(io);
    pong_future.await(io);
    const total_ns = nowNanoseconds() - start_ns;

    std.debug.assert(final_token == round_trips);
    return .{ .total_ns = total_ns, .op_count = round_trips };
}

/// Single-task floor reference: alternate putOne/getOne on a capacity-1
/// queue from the main task; neither operation ever blocks. Per-op number
/// is one put + one get pair.
fn benchQueueFloor(io: Io, op_pairs: usize) Sample {
    var buffer: [1]u64 = undefined;
    var queue: Io.Queue(u64) = .init(&buffer);
    var checksum: u64 = 0;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < op_pairs) : (index += 1) {
        queue.putOne(io, index) catch |err|
            std.debug.panic("floor put: {s}", .{@errorName(err)});
        checksum +%= queue.getOne(io) catch |err|
            std.debug.panic("floor get: {s}", .{@errorName(err)});
    }
    const total_ns = nowNanoseconds() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .total_ns = total_ns, .op_count = op_pairs };
}

fn runBenchmark(io: Io, benchmark: Benchmark, op_count: usize) Sample {
    return switch (benchmark) {
        .spawn => benchSpawnWindowed(io, op_count),
        .@"spawn-serial" => benchSpawnSerial(io, op_count),
        .@"spawn-group" => benchSpawnGroup(io, op_count),
        .pingpong => benchPingPong(io, op_count),
        .queue => benchQueueFloor(io, op_count),
    };
}

fn runRepetitions(
    io: Io,
    backend: Backend,
    benchmark: Benchmark,
    op_count: usize,
    repetitions: usize,
    warmup_override: ?usize,
) void {
    std.debug.print(
        "backend={s} bench={s} ops={d} reps={d} window={d}\n",
        .{ @tagName(backend), @tagName(benchmark), op_count, repetitions, spawn_window },
    );

    // Warmup: one unrecorded pass at a tenth of the workload.
    const warmup_ops = warmup_override orelse @max(op_count / 10, 1000);
    if (warmup_ops > 0) _ = runBenchmark(io, benchmark, warmup_ops);

    var per_op_samples: [64]f64 = undefined;
    std.debug.assert(repetitions <= per_op_samples.len);
    for (0..repetitions) |rep| {
        const sample = runBenchmark(io, benchmark, op_count);
        per_op_samples[rep] = sample.perOpNs();
        std.debug.print(
            "  rep {d}: total_ns={d} per_op_ns={d:.1} eager={d}/{d}\n",
            .{ rep + 1, sample.total_ns, sample.perOpNs(), sample.eager_count, sample.op_count },
        );
    }

    const timed = per_op_samples[0..repetitions];
    std.mem.sort(f64, timed, {}, std.sort.asc(f64));
    const median = if (repetitions % 2 == 1)
        timed[repetitions / 2]
    else
        (timed[repetitions / 2 - 1] + timed[repetitions / 2]) / 2.0;
    std.debug.print(
        "RESULT backend={s} bench={s} median_per_op_ns={d:.1} min_per_op_ns={d:.1}\n",
        .{ @tagName(backend), @tagName(benchmark), median, timed[0] },
    );
}

fn usageAndExit() noreturn {
    std.debug.print(
        "usage: bench <evented|threaded> <spawn|spawn-serial|spawn-group|pingpong|queue> [ops] [reps] [warmup]\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `Init.Minimal` hands over argv without start.zig constructing its own
    // implicit Threaded Io instance — this spike controls the Io under test.
    var args_iterator: std.process.Args.Iterator = .init(init.args);
    _ = args_iterator.next(); // program name

    const backend_arg = args_iterator.next() orelse usageAndExit();
    const benchmark_arg = args_iterator.next() orelse usageAndExit();
    const backend = std.meta.stringToEnum(Backend, backend_arg) orelse usageAndExit();
    const benchmark = std.meta.stringToEnum(Benchmark, benchmark_arg) orelse usageAndExit();

    const default_ops: usize = switch (benchmark) {
        .spawn, .@"spawn-serial", .@"spawn-group" => default_spawn_count,
        .pingpong => default_round_trips,
        .queue => default_queue_op_pairs,
    };
    const op_count = if (args_iterator.next()) |ops_arg|
        try std.fmt.parseInt(usize, ops_arg, 10)
    else
        default_ops;
    const repetitions = if (args_iterator.next()) |reps_arg|
        try std.fmt.parseInt(usize, reps_arg, 10)
    else
        default_repetitions;
    const warmup_override: ?usize = if (args_iterator.next()) |warmup_arg|
        try std.fmt.parseInt(usize, warmup_arg, 10)
    else
        null;

    switch (backend) {
        .threaded => {
            var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            runRepetitions(threaded.io(), backend, benchmark, op_count, repetitions, warmup_override);
        },
        .evented => {
            if (Io.Evented == void) @panic("Io.Evented unsupported on this target");
            var evented: Io.Evented = undefined;
            // smp_allocator is already thread-safe, so Dispatch's own
            // backing-allocator mutex is unnecessary.
            try Io.Evented.init(&evented, std.heap.smp_allocator, .{
                .backing_allocator_needs_mutex = false,
            });
            // FORK BUG (E1 finding): `Evented.deinit` does not compile —
            // Io/Dispatch.zig:584 passes `ev.main_loop_stack[0..main_loop_stack_size]`
            // (comptime length => `*[8192]u8` pointer-to-array, not a slice) to
            // `Allocator.free`, which comptime-asserts a slice. deinit is
            // skipped here; process exit reclaims the resources.
            runRepetitions(evented.io(), backend, benchmark, op_count, repetitions, warmup_override);
        },
    }
}
