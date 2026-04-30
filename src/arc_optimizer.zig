const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");

// ============================================================
// ARC Optimization Pass (Research Plan Phase 7)
//
// Uses escape/ownership/region analysis results to minimize ARC
// operations. Eliminates redundant retain/release and skips ARC
// for stack-allocated values and borrowed parameters.
//
// Optimizations:
//   1. Stack-allocated value elimination: values with strategy
//      eliminated/scalar_replaced/stack_block/stack_function
//      need no retain/release
//   2. Borrowed parameter elimination: params where
//      param_summary.canBorrow() need no retain on entry or
//      release on exit
//   3. Loop hoisting: loop-invariant retain/release are moved
//      outside the loop
//   4. COW preparation: unique values that are mutated need no
//      retain before mutation
// ============================================================

pub const ArcOptimizer = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    ctx: *lattice.AnalysisContext,

    /// Values that should skip ARC operations.
    skip_arc: std.AutoHashMap(lattice.ValueKey, SkipReason),

    /// Optimized ARC operations to emit.
    optimized_ops: std.ArrayList(lattice.ArcOperation),

    pub const SkipReason = enum {
        /// Value is stack-allocated, no RC needed.
        stack_allocated,
        /// Value's parameter is borrowed, no retain/release at call boundary.
        borrowed_param,
        /// Value is eliminated/scalar-replaced, doesn't exist at runtime.
        eliminated,
        /// Value is in a caller-provided region.
        caller_region,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        program: *const ir.Program,
        ctx: *lattice.AnalysisContext,
    ) ArcOptimizer {
        return .{
            .allocator = allocator,
            .program = program,
            .ctx = ctx,
            .skip_arc = std.AutoHashMap(lattice.ValueKey, SkipReason).init(allocator),
            .optimized_ops = .empty,
        };
    }

    pub fn deinit(self: *ArcOptimizer) void {
        self.skip_arc.deinit();
        self.optimized_ops.deinit(self.allocator);
    }

    /// Run the full ARC optimization pass.
    /// Populates ctx.arc_ops with the optimized ARC operation placements.
    pub fn optimize(self: *ArcOptimizer) !void {
        // Phase 1: Identify values that can skip ARC.
        try self.identifySkippableValues();

        // Phase 2: Identify borrowed parameters.
        try self.identifyBorrowedParams();

        // Phase 3: Eliminate redundant retain/release pairs.
        try self.eliminateRedundantPairs();

        // Phase 4: Loop hoisting — move ARC ops on loop-invariant values
        // outside of loops.
        try self.hoistLoopInvariantArc();

        // Phase 5: Record optimized ARC placements.
        // For values that DO need ARC, determine optimal placement.
        try self.computeOptimizedPlacements();
    }

    // --------------------------------------------------------
    // Phase 1: Stack-allocated value elimination
    // --------------------------------------------------------

    fn identifySkippableValues(self: *ArcOptimizer) !void {
        // Iterate values that have a known alloc site (reverse map populated
        // by GeneralizedEscapeAnalyzer). For each one, look up the chosen
        // allocation strategy and decide whether ARC ops can be skipped.
        // Previously this paired the FIRST escape-state entry with EVERY
        // alloc summary (only one match per site, but the match wasn't
        // checked) — so most values silently lost their skip metadata.
        var iter = self.ctx.alloc_site_for_value.iterator();
        while (iter.next()) |entry| {
            const vkey = entry.key_ptr.*;
            const site_id = entry.value_ptr.*;
            const strategy = self.ctx.getAllocStrategy(site_id);
            const reason: ?SkipReason = switch (strategy) {
                .eliminated => .eliminated,
                .scalar_replaced => .eliminated,
                .stack_block, .stack_function => .stack_allocated,
                .caller_region => .caller_region,
                .heap_arc => null, // Needs ARC.
            };
            if (reason) |r| {
                try self.skip_arc.put(vkey, r);
            }
        }
    }

    // --------------------------------------------------------
    // Phase 2: Borrowed parameter elimination
    // --------------------------------------------------------

    fn identifyBorrowedParams(self: *ArcOptimizer) !void {
        var iter = self.ctx.function_summaries.iterator();
        while (iter.next()) |entry| {
            const func_id = entry.key_ptr.*;
            const summary = entry.value_ptr.*;

            for (summary.param_summaries, 0..) |ps, i| {
                if (ps.canBorrow()) {
                    const vkey = lattice.ValueKey{
                        .function = func_id,
                        .local = @intCast(i),
                    };
                    try self.skip_arc.put(vkey, .borrowed_param);
                }
            }
        }
    }

    // --------------------------------------------------------
    // Phase 3: Eliminate redundant retain/release pairs
    // --------------------------------------------------------

    fn eliminateRedundantPairs(self: *ArcOptimizer) !void {
        // A retain immediately followed by a release on the same value (or
        // vice versa) is a no-op pair that can be eliminated. We scan the
        // arc_ops list and mark paired operations for removal.
        //
        // Also: for unique values (ownership == unique in the type system),
        // retain is unnecessary before mutation (COW pattern). We mark
        // retain ops on unique-owned values for elimination.
        const ops = self.ctx.arc_ops.items;
        if (ops.len < 2) return;

        // Track which ops to remove (by index).
        var remove_set = std.AutoHashMap(usize, void).init(self.allocator);
        defer remove_set.deinit();

        // Pass 1: Find retain/release pairs on the same value at the same point.
        for (ops, 0..) |op, i| {
            if (i + 1 >= ops.len) break;
            const next = ops[i + 1];

            // retain then release on same value at same function → redundant.
            if (op.kind == .retain and next.kind == .release and
                op.value == next.value and
                op.insertion_point.function == next.insertion_point.function)
            {
                try remove_set.put(i, {});
                try remove_set.put(i + 1, {});
            }
            // release then retain on same value → also redundant.
            if (op.kind == .release and next.kind == .retain and
                op.value == next.value and
                op.insertion_point.function == next.insertion_point.function)
            {
                try remove_set.put(i, {});
                try remove_set.put(i + 1, {});
            }
        }

        // Pass 2: Mark retains on unique-owned values (COW optimization).
        // If a value's escape state is no_escape or block_local and its
        // ownership is unique, retain is unnecessary.
        for (ops, 0..) |op, i| {
            if (op.kind == .retain) {
                const vkey = lattice.ValueKey{
                    .function = op.insertion_point.function,
                    .local = op.value,
                };
                const escape = self.ctx.getEscape(vkey);
                // If value doesn't escape the block, retain is unnecessary
                // (the value is provably unique at the mutation point).
                if (escape == .no_escape or escape == .bottom) {
                    try remove_set.put(i, {});
                }
            }
        }

        // Apply removals.
        if (remove_set.count() > 0) {
            var kept: std.ArrayList(lattice.ArcOperation) = .empty;
            defer kept.deinit(self.allocator);
            for (ops, 0..) |op, i| {
                if (!remove_set.contains(i)) {
                    try kept.append(self.allocator, op);
                }
            }
            self.ctx.arc_ops.clearRetainingCapacity();
            for (kept.items) |op| {
                try self.ctx.arc_ops.append(self.allocator, op);
            }
        }
    }

    // --------------------------------------------------------
    // Phase 4: Loop hoisting
    // --------------------------------------------------------

    /// Identify ARC operations on loop-invariant values (values defined
    /// before any recursive call and not modified inside the loop) and
    /// mark them for hoisting. In Zap's functional IR, loops are
    /// represented as recursive calls, so a "loop-invariant" value is
    /// one that comes from a parameter or capture and is not reassigned.
    fn hoistLoopInvariantArc(self: *ArcOptimizer) !void {
        const ops = self.ctx.arc_ops.items;
        if (ops.len == 0) return;

        // For each ARC operation, check if it's on a value that is
        // loop-invariant in a recursive function. If so, the operation
        // can be hoisted to the function entry/exit instead of being
        // executed on each recursive iteration.
        for (self.program.functions) |func| {
            // Check if this function is recursive (calls itself).
            var is_recursive = false;
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .tail_call => |tc| {
                            if (std.mem.eql(u8, tc.name, func.name)) is_recursive = true;
                        },
                        .call_direct => |cd| {
                            if (cd.function == func.id) is_recursive = true;
                        },
                        else => {},
                    }
                }
            }
            if (!is_recursive) continue;

            // Find parameters in this function (loop-invariant by definition).
            var param_locals = std.AutoHashMap(ir.LocalId, void).init(self.allocator);
            defer param_locals.deinit();
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .param_get => |pg| {
                            try param_locals.put(pg.dest, {});
                        },
                        .capture_get => |cg| {
                            try param_locals.put(cg.dest, {});
                        },
                        else => {},
                    }
                }
            }

            // Mark ARC operations on parameter-derived locals for hoisting.
            // Hoisting means: keep the operation but change its reason to
            // loop_hoist, signaling to codegen that it should be moved
            // outside the recursive path.
            for (self.ctx.arc_ops.items) |*op| {
                if (op.insertion_point.function == func.id) {
                    if (param_locals.contains(op.value)) {
                        op.reason = .loop_hoist;
                    }
                }
            }
        }
    }

    // --------------------------------------------------------
    // Phase 5: Compute optimized ARC placements
    // --------------------------------------------------------

    fn computeOptimizedPlacements(self: *ArcOptimizer) !void {
        // For each existing ARC operation in the context, check if it can
        // be eliminated or moved.
        for (self.ctx.arc_ops.items) |op| {
            const vkey = lattice.ValueKey{
                .function = op.insertion_point.function,
                .local = op.value,
            };

            // If this value can skip ARC, don't emit the operation.
            if (self.skip_arc.contains(vkey)) continue;

            // Otherwise, keep the operation as-is.
            try self.optimized_ops.append(self.allocator, op);
        }

        // Replace the context's arc_ops with the optimized set.
        self.ctx.arc_ops.clearRetainingCapacity();
        for (self.optimized_ops.items) |op| {
            try self.ctx.arc_ops.append(self.allocator, op);
        }
    }

    /// Check if a specific value should skip ARC operations.
    pub fn shouldSkipArc(self: *const ArcOptimizer, vkey: lattice.ValueKey) bool {
        return self.skip_arc.contains(vkey);
    }

    /// Get the reason a value skips ARC, if any.
    pub fn getSkipReason(self: *const ArcOptimizer, vkey: lattice.ValueKey) ?SkipReason {
        return self.skip_arc.get(vkey);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "ArcOptimizer skips ARC for stack-allocated values" {
    const alloc = testing.allocator;

    // Create a minimal program.
    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 0, .type_name = "Point", .fields = &.{} } },
        .{ .ret = .{ .value = null } },
    };
    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &instrs },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "test_fn",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var ctx = lattice.AnalysisContext.init(alloc);
    defer ctx.deinit();

    // Mark the struct as stack-allocated. Populate `alloc_site_for_value`
    // with the value→site mapping that GeneralizedEscapeAnalyzer would
    // normally publish — `identifySkippableValues` reads this map to find
    // the alloc strategy for each value.
    const vkey = lattice.ValueKey{ .function = 0, .local = 0 };
    _ = try ctx.joinEscape(vkey, .no_escape);
    try ctx.alloc_strategies.put(0, .stack_function);
    try ctx.alloc_summaries.put(0, lattice.AllocSiteSummary.init(0, 0));
    try ctx.alloc_site_for_value.put(vkey, 0);

    // Add an ARC operation that should be eliminated.
    try ctx.arc_ops.append(alloc, .{
        .kind = .retain,
        .value = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .before },
        .reason = .shared_binding,
    });

    var optimizer = ArcOptimizer.init(alloc, &program, &ctx);
    defer optimizer.deinit();
    try optimizer.optimize();

    // The retain operation should have been eliminated.
    try testing.expectEqual(@as(usize, 0), ctx.arc_ops.items.len);
}

test "ArcOptimizer marks borrowed params as skippable" {
    const alloc = testing.allocator;

    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &instrs },
    };
    const params = [_]ir.Param{
        .{ .name = "x", .type_expr = .i64 },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "test_fn",
            .scope_id = 0,
            .arity = 1,
            .params = &params,
            .return_type = .i64,
            .body = &blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var ctx = lattice.AnalysisContext.init(alloc);
    defer ctx.deinit();

    // Add a function summary where param 0 is read-only (can borrow).
    const param_summaries = try alloc.alloc(lattice.ParamSummary, 1);
    defer alloc.free(param_summaries);
    param_summaries[0] = lattice.ParamSummary.safe();
    const lambda_sets_arr = try alloc.alloc(lattice.LambdaSet, 1);
    defer alloc.free(lambda_sets_arr);
    lambda_sets_arr[0] = lattice.LambdaSet.empty();
    try ctx.function_summaries.put(0, .{
        .param_summaries = param_summaries,
        .return_summary = lattice.ReturnSummary.unknown(),
        .may_diverge = false,
        .param_lambda_sets = lambda_sets_arr,
    });

    var optimizer = ArcOptimizer.init(alloc, &program, &ctx);
    defer optimizer.deinit();
    try optimizer.optimize();

    // Param 0 should be marked as borrowed (skip ARC).
    const vkey = lattice.ValueKey{ .function = 0, .local = 0 };
    try testing.expect(optimizer.shouldSkipArc(vkey));
    try testing.expectEqual(ArcOptimizer.SkipReason.borrowed_param, optimizer.getSkipReason(vkey).?);
}

test "ArcOptimizer keeps ARC for heap-allocated values" {
    const alloc = testing.allocator;

    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 0, .type_name = "Point", .fields = &.{} } },
        .{ .ret = .{ .value = 0 } },
    };
    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &instrs },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "test_fn",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var ctx = lattice.AnalysisContext.init(alloc);
    defer ctx.deinit();

    // Mark the struct as heap-allocated.
    const vkey = lattice.ValueKey{ .function = 0, .local = 0 };
    _ = try ctx.joinEscape(vkey, .global_escape);
    try ctx.alloc_strategies.put(0, .heap_arc);

    // Add an ARC operation that should be kept.
    try ctx.arc_ops.append(alloc, .{
        .kind = .retain,
        .value = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .before },
        .reason = .shared_binding,
    });

    var optimizer = ArcOptimizer.init(alloc, &program, &ctx);
    defer optimizer.deinit();
    try optimizer.optimize();

    // The retain operation should be kept.
    try testing.expectEqual(@as(usize, 1), ctx.arc_ops.items.len);
}
