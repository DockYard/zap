// Computer Language Benchmarks Game — binary-trees, single-thread Zig.
// Mirrors the C peer's arena-allocator strategy so timing comparisons
// stay focused on the language's recursion + struct codegen rather
// than on free-list management.
//
// Build: zig build-exe -O ReleaseFast binary_trees.zig

const std = @import("std");

const Tree = struct {
    left: ?*Tree,
    right: ?*Tree,
};

fn make(arena: std.mem.Allocator, depth: i32) !*Tree {
    const t = try arena.create(Tree);
    if (depth == 0) {
        t.left = null;
        t.right = null;
    } else {
        t.left = try make(arena, depth - 1);
        t.right = try make(arena, depth - 1);
    }
    return t;
}

fn check(t: ?*const Tree) i64 {
    if (t) |node| {
        return 1 + check(node.left) + check(node.right);
    }
    return 0;
}

// Read depth from `BENCH_DEPTH`, default 14. Both Zap and the C
// peer use the same env-var convention so the harness can vary
// depth without rebuilding.
fn parseDepthFromEnv() i32 {
    const ptr = std.c.getenv("BENCH_DEPTH") orelse return 14;
    const env = std.mem.span(ptr);
    if (env.len == 0) return 14;
    return std.fmt.parseInt(i32, env, 10) catch 14;
}

fn writeAll(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(out);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const max_depth: i32 = parseDepthFromEnv();
    const min_depth: i32 = 4;
    const stretch_depth = max_depth + 1;

    const stretch_check = check(try make(arena, stretch_depth));
    printf("stretch tree of depth {d}\t check: {d}\n", .{ stretch_depth, stretch_check });

    const long_lived = try make(arena, max_depth);

    var depth: i32 = min_depth;
    while (depth <= max_depth) : (depth += 2) {
        const iterations: i64 = @as(i64, 1) << @as(u6, @intCast(max_depth - depth + 4));
        var acc: i64 = 0;
        var i: i64 = 0;
        while (i < iterations) : (i += 1) {
            acc += check(try make(arena, depth));
        }
        printf("{d}\t trees of depth {d}\t check: {d}\n", .{ iterations, depth, acc });
    }

    printf("long lived tree of depth {d}\t check: {d}\n", .{ max_depth, check(long_lived) });
}
