const std = @import("std");
const harness = @import("validation_harness.zig");
const cases = @import("validation_cases.zig");

test "phase9 borrowed closure case has zero ARC calls in output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var snapshot = try harness.compileAndAnalyzeSnapshot(alloc, cases.borrowed_closure_arg);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), harness.countArcOpsInOutput(snapshot.compile_result.output));
}

test "phase9 shared closure case emits ARC calls in output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var snapshot = try harness.compileAndAnalyzeSnapshot(alloc, cases.shared_closure_arg);
    defer snapshot.deinit(alloc);

    try std.testing.expect(harness.countArcOpsInOutput(snapshot.compile_result.output) > 0);
}

test "phase9 switch dispatch case records reuse-free specialization summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var snapshot = try harness.compileAndAnalyzeSnapshot(alloc, cases.switch_dispatch);
    defer snapshot.deinit(alloc);

    try std.testing.expect(snapshot.summary.function_count > 0);
    try harness.expectContains(snapshot.compile_result.output, ".call_fn == @ptrCast(&__closure_invoke_");
}
