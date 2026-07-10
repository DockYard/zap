//! E6 re-run harness (P6-J1, plan item 6.1a): the O(1) region-move send vs the
//! two-copy serialize/reconstruct send, measured END-TO-END through the REAL
//! kernel — real spawned processes, real mailboxes, the real
//! `Process.send_move`/`receive` paths — on real refcounted `Map(i64, i64)` /
//! `List(i64)` ARC cells.
//!
//! ## What it measures
//!
//! A root process and an echo process ping-pong ONE value per operation:
//!
//!   * **move mode** — `send_message_moved` both ways. The value's backing is
//!     a page-backed LARGE cell (the runtime detaches it, the kernel carries
//!     the pointer, the receiver adopts it in place), so the per-op cost is
//!     two mailbox hops + two O(1) detach/adopt pairs, INDEPENDENT of payload
//!     size. Verified per run, not assumed: pointer IDENTITY must hold across
//!     every round trip (a copy fallback would mint a fresh cell) and the
//!     `region_move_sends_total` / `region_move_adopts_total` counters must
//!     equal exactly two per round trip (the stats-build rewrite in
//!     `run-move-bench.sh` keeps the counters live).
//!   * **copy mode** — `send_message` both ways: two serialize + two
//!     transport + two reconstruct passes per round trip (for a `Map`, the
//!     reconstruct is the hash-table rebuild E6 measured at 2.19 ms/MB). The
//!     move counters must stay at zero.
//!   * **small mode** — a slab-backed (15-entry) map through `send_move`:
//!     the honest degradation row. The move counters must stay at zero (the
//!     detach declines, the send transparently copies).
//!
//! Per (shape, size): one unrecorded warmup pass, then `reps` timed
//! repetitions; each repetition times ONE batch of `ops` round trips with a
//! single `CLOCK_UPTIME_RAW` pair (the E1 kernel-bench convention — no
//! per-op clock read inside the loop), reporting the per-op round trip as
//! median-of-reps + min-of-reps. Anti-elision: a lookup on the received
//! value per op folds into a printed sink.
//!
//! ## Build
//!
//! MUST be compiled with the Zap Zig fork (the kernel's fibers require the
//! x30-clobber fix). The concurrency gate and the stat counters are source
//! defaults the compiler normally rewrites; `run-move-bench.sh` performs the
//! same marker rewrite on a build-local copy of `runtime.zig` (see the
//! script), links the REAL ARC manager (`zaparcmanager`) and the REAL kernel
//! (`zapkernel`, rooted at `abi.zig` exactly like `concurrency_driver.zig`
//! roots the production kernel object).

const std = @import("std");
const builtin = @import("builtin");
const zap = @import("zapruntime");

// Force the kernel module so its `zap_proc_*` C-ABI exports are emitted (the
// runtime binds them through extern declarations). The REAL ARC manager is
// bound the PRODUCTION way instead: registered as the `zap_active_manager`
// source module with `RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT` rewritten to
// true (exactly what the compiler does for every user binary), so the
// runtime's comptime-bound `active_manager.*` direct calls — the shipped
// single-manager dispatch — are what this bench measures.
comptime {
    _ = @import("zapkernel");
}

/// Io-independent monotonic nanosecond clock (`CLOCK_UPTIME_RAW`), never
/// through runtime code under test (E1/E9 convention).
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const max_repetition_count: usize = 7;
const default_repetition_count: usize = 5;

/// Anti-elision accumulator, printed at exit.
var elision_sink: u64 = 0;

// -- cross-process bench configuration (globals: one OS process, the root
// -- writes these before spawning the echo) --------------------------------

var bench_mode_is_move: bool = true;
var echo_total_rounds: usize = 0;
var root_pid_bits: u64 = 0;
var repetition_count: usize = default_repetition_count;

// -- shapes -----------------------------------------------------------------

const MapCell = zap.Map(i64, i64);
const MapMessage = ?*const MapCell;
const ListCell = zap.List(i64);
const ListMessage = ?*const ListCell;

/// One measured row: element count chosen so the SERIALIZED blob matches the
/// E6 copy-crossover byte targets (map blob = 4 + 16n; list blob = 4 + 8n),
/// keeping the before/after tables directly comparable.
const SizeRow = struct {
    label: []const u8,
    elements: usize,
    ops: usize,
};

const map_rows = [_]SizeRow{
    .{ .label = "16KB", .elements = 1_023, .ops = 4_000 },
    .{ .label = "64KB", .elements = 4_095, .ops = 2_000 },
    .{ .label = "256KB", .elements = 16_383, .ops = 600 },
    .{ .label = "1MB", .elements = 65_535, .ops = 150 },
};

const list_rows = [_]SizeRow{
    .{ .label = "16KB", .elements = 2_047, .ops = 4_000 },
    .{ .label = "1MB", .elements = 131_071, .ops = 400 },
};

/// The slab-backed honest-degradation row (E6's ~256 B map: 15 entries).
const small_map_elements: usize = 15;

fn buildMap(element_count: usize) MapMessage {
    var map: MapMessage = null;
    var index: usize = 0;
    while (index < element_count) : (index += 1) {
        map = MapCell.put(map, @intCast(index), @intCast(index * 3));
    }
    return map;
}

fn buildList(element_count: usize) ListMessage {
    var list: ListMessage = ListCell.new_empty(@intCast(element_count));
    var index: usize = 0;
    while (index < element_count) : (index += 1) {
        list = ListCell.push(list, @intCast(index));
    }
    return list;
}

// -- echo processes (comptime-typed per message shape) ----------------------

fn EchoEntry(comptime Message: type) type {
    return struct {
        fn run() void {
            var remaining = echo_total_rounds;
            while (remaining > 0) : (remaining -= 1) {
                const value = zap.ProcessRuntime.receiveMessage(Message);
                if (bench_mode_is_move) {
                    _ = zap.ProcessRuntime.send_message_moved(root_pid_bits, value);
                } else {
                    _ = zap.ProcessRuntime.send_message(root_pid_bits, value);
                    releaseMessage(Message, value);
                }
            }
        }
    };
}

fn releaseMessage(comptime Message: type, value: Message) void {
    if (Message == MapMessage) {
        MapCell.release(value);
    } else if (Message == ListMessage) {
        ListCell.release(value);
    } else {
        comptime unreachable;
    }
}

fn touchMessage(comptime Message: type, value: Message, probe_key: i64) u64 {
    if (Message == MapMessage) {
        return @bitCast(MapCell.get(value, probe_key, -1));
    } else if (Message == ListMessage) {
        return @bitCast(ListCell.get(value, @intCast(probe_key)));
    } else {
        comptime unreachable;
    }
}

// -- one (shape, size, mode) measurement, run INSIDE the root process -------

fn runOneRow(
    comptime Message: type,
    shape_name: []const u8,
    row: SizeRow,
    move_mode: bool,
    expect_move: bool,
) void {
    const warmup_ops = @max(row.ops / 10, 16);
    bench_mode_is_move = move_mode;
    echo_total_rounds = warmup_ops + repetition_count * row.ops;
    root_pid_bits = zap.ProcessRuntime.self_pid_bits();
    const echo_pid = zap.ProcessRuntime.spawn_process(EchoEntry(Message).run);

    var value: Message = if (Message == MapMessage)
        buildMap(row.elements)
    else
        buildList(row.elements);
    const probe_key: i64 = @intCast(row.elements / 2);

    const identity_before: usize = @intFromPtr(value.?);
    const move_sends_before = zap.region_move_sends_total;
    const move_adopts_before = zap.region_move_adopts_total;

    // Warmup (unrecorded).
    var index: usize = 0;
    while (index < warmup_ops) : (index += 1) {
        value = oneRoundTrip(Message, echo_pid, value, move_mode);
        elision_sink +%= touchMessage(Message, value, probe_key);
    }

    var rep_per_op: [max_repetition_count]u64 = undefined;
    var rep: usize = 0;
    while (rep < repetition_count) : (rep += 1) {
        const t0 = nowNanoseconds();
        var op: usize = 0;
        while (op < row.ops) : (op += 1) {
            value = oneRoundTrip(Message, echo_pid, value, move_mode);
        }
        const t1 = nowNanoseconds();
        rep_per_op[rep] = (t1 - t0) / row.ops;
        elision_sink +%= touchMessage(Message, value, probe_key);
    }

    // Move-vs-copy PROOF, not assumption. In a genuine-move run the SAME cell
    // ping-pongs (pointer identity) and each round trip is exactly two moved
    // sends + two adopts; a copy run must leave the counters untouched.
    const rounds_total: u64 = echo_total_rounds;
    const move_sends = zap.region_move_sends_total - move_sends_before;
    const move_adopts = zap.region_move_adopts_total - move_adopts_before;
    if (expect_move) {
        if (@intFromPtr(value.?) != identity_before)
            @panic("move-bench: pointer identity broken — a supposed move round trip minted a fresh cell");
        if (move_sends != 2 * rounds_total or move_adopts != 2 * rounds_total)
            @panic("move-bench: move counters disagree with the round-trip count — a copy fallback slipped in");
    } else {
        if (move_sends != 0 or move_adopts != 0)
            @panic("move-bench: copy-expected run bumped the move counters");
    }

    releaseMessage(Message, value);

    std.mem.sort(u64, rep_per_op[0..repetition_count], {}, std.sort.asc(u64));
    const median = rep_per_op[repetition_count / 2];
    const minimum = rep_per_op[0];
    std.debug.print(
        "RESULT shape={s} size={s} elems={d} mode={s} reps={d} ops={d} rtt_median_ns={d} rtt_min_ns={d} per_direction_median_ns={d} moved_sends={d} moved_adopts={d}\n",
        .{
            shape_name,
            row.label,
            row.elements,
            if (move_mode) @as([]const u8, "move") else "copy",
            repetition_count,
            row.ops,
            median,
            minimum,
            median / 2,
            move_sends,
            move_adopts,
        },
    );
}

fn oneRoundTrip(comptime Message: type, echo_pid: u64, value: Message, move_mode: bool) Message {
    if (move_mode) {
        _ = zap.ProcessRuntime.send_message_moved(echo_pid, value);
        return zap.ProcessRuntime.receiveMessage(Message);
    }
    _ = zap.ProcessRuntime.send_message(echo_pid, value);
    const back = zap.ProcessRuntime.receiveMessage(Message);
    // The copy round trip mints a fresh same-size cell each way; the returned
    // copy becomes the next op's source and the previous value is released
    // here, so exactly ONE value is live at any time in either mode (send
    // BORROWS in copy mode, so the pre-send value is still ours to drop).
    releaseMessage(Message, value);
    return back;
}

// -- root process -----------------------------------------------------------

const Mode = enum { move, copy, small, all };

var selected_mode: Mode = .all;

fn benchRoot() u8 {
    if (selected_mode == .move or selected_mode == .all) {
        for (map_rows) |row| runOneRow(MapMessage, "map", row, true, true);
        for (list_rows) |row| runOneRow(ListMessage, "list", row, true, true);
    }
    if (selected_mode == .copy or selected_mode == .all) {
        for (map_rows) |row| runOneRow(MapMessage, "map", row, false, false);
        for (list_rows) |row| runOneRow(ListMessage, "list", row, false, false);
    }
    if (selected_mode == .small or selected_mode == .all) {
        // Slab-backed map through send_move: the honest degradation row — the
        // detach declines and the send transparently copies (counters stay 0).
        runOneRow(MapMessage, "map-small-degrades", .{
            .label = "244B",
            .elements = small_map_elements,
            .ops = 20_000,
        }, true, false);
    }
    std.debug.print("elision_sink={d}\n", .{elision_sink});
    std.mem.doNotOptimizeAway(elision_sink);
    return 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arguments: std.process.Args.Iterator = .init(init.args);
    _ = arguments.next(); // program name
    const mode_text = arguments.next() orelse "all";
    selected_mode = std.meta.stringToEnum(Mode, mode_text) orelse {
        std.debug.print("usage: move-bench <move|copy|small|all> [reps]\n", .{});
        return error.UnknownMode;
    };
    if (arguments.next()) |reps_text| {
        repetition_count = try std.fmt.parseInt(usize, reps_text, 10);
    }
    if (repetition_count == 0 or repetition_count > max_repetition_count) {
        std.debug.print("reps must be in 1..={d}\n", .{max_repetition_count});
        return error.BadRepetitionCount;
    }

    std.debug.print(
        "move-bench mode={s} reps={d} build={s} refcount_active={} concurrency_active={}\n",
        .{ mode_text, repetition_count, @tagName(builtin.mode), zap.refcount_v1_active, zap.runtime_concurrency_active },
    );

    zap.memoryStartupForEntry();
    const status = zap.runRootProcessMain(benchRoot);
    if (status != 0) return error.BenchFailed;
}
