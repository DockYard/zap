const std = @import("std");
const harness = @import("validation_harness.zig");
const cases = @import("validation_cases.zig");

const Case = struct {
    name: []const u8,
    source: []const u8,
};

const benchmark_cases = [_]Case{
    .{ .name = "switch_dispatch", .source = cases.switch_dispatch },
    .{ .name = "borrowed_closure_arg", .source = cases.borrowed_closure_arg },
    .{ .name = "shared_closure_arg", .source = cases.shared_closure_arg },
};

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    for (benchmark_cases) |case| {
        try runBenchmarkCase(stdout, case);
    }
}

fn runBenchmarkCase(writer: anytype, case: Case) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const start_ns = std.time.nanoTimestamp();
    var snapshot = try harness.compileAndAnalyzeSnapshot(alloc, case.source);
    defer snapshot.deinit(alloc);
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;

    try writer.print(
        "{s}: time_ns={d} functions={d} closures={d} alloc_sites={d} arc_ops={d} reuse_pairs={d} drop_specs={d} arc_calls_in_output={d}\n",
        .{
            case.name,
            elapsed_ns,
            snapshot.summary.function_count,
            snapshot.summary.closure_tier_count,
            snapshot.summary.alloc_summary_count,
            snapshot.summary.arc_op_count,
            snapshot.summary.reuse_pair_count,
            snapshot.summary.drop_specialization_count,
            harness.countArcOpsInOutput(snapshot.compile_result.output),
        },
    );
}
