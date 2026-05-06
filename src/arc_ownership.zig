const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const types_mod = @import("types.zig");

// ============================================================
// ARC ownership classification and normalization pass.
//
// Phase A of the Phase 6 redux plan introduces this module as a
// scaffold. The pass slots into the compilation pipeline between
// `arc_liveness` (last-use analysis) and `arc_drop_insertion`
// (scope-exit `release` emission), per §2.2 of the plan:
//
//     ... → arc_liveness
//             → arc_ownership   (THIS PASS — normalization)
//                  → arc_verifier (invariants — Phase E)
//                       → arc_drop_insertion
//                            → ...
//
// In Phase A this pass is a stub: it accepts every function and
// performs no IR mutation. The metadata it will eventually consume
// (`Function.param_conventions`, `Function.local_ownership`,
// `Function.result_convention`) is already populated by the IR
// builder with safe defaults — ARC-managed parameters classified as
// `.borrowed`, ARC-managed locals classified as `.owned`, and ARC-
// managed return types classified as `.owned`.
//
// Phase C will implement the borrow/copy decision logic. Walking
// each function body, the pass replaces overloaded `local_get`
// instructions with explicit `borrow_value` or `copy_value` forms
// based on the destination's eventual usage:
//   - dest is a call argument to a borrowing-convention parameter
//     -> `borrow_value` (no retain, no scope-exit destroy)
//   - dest is stored into another owned aggregate
//     -> `copy_value` (retain, scope-exit destroy)
//   - dest flows into a `ret` whose source is a parameter
//     -> `copy_value` (promote borrow to owned for return)
//   - default -> `copy_value` (conservative; Phase E verifier
//     prompts refinement when conservative classification is wrong)
//
// Phase E activates the verifier on the post-normalization IR and
// uses ownership classes to enforce single-destroy / no-leak / no-
// borrow-escape invariants.
// ============================================================

// ============================================================
// Phase C — borrow / copy classifier
// ============================================================
//
// `classifyAndNormalize` walks every instruction stream in
// `function` (top-level body and every nested sub-stream) and
// rewrites each `.local_get` into either a `.borrow_value` (no
// runtime retain, no scope-exit destroy on dest) or a
// `.copy_value` (lowering emits a runtime retain on the source's
// cell, and the dest pairs with a scope-exit destroy). The
// rewrite also strips the immediately-following `.retain {value =
// dest}` instruction emitted by `IrBuilder.emitLocalGet` for ARC-
// managed sources — that retain semantics is now baked into the
// `.copy_value` lowering in `zir_builder.zig` (and absent from the
// `.borrow_value` lowering by design).
//
// Classification rule (conservative; verifier is Phase E):
//   - `borrow_value` iff every use of `dest` is one of:
//       * `.share_value.source`  — caller-side share that pairs
//         with a post-call release (ABI-level borrow shape)
//       * `.local_get.source` / `.borrow_value.source` /
//         `.copy_value.source` — chained alias; the chain's
//         eventual classification is checked recursively
//         (single-level enough for today's IR shapes)
//   - `copy_value` otherwise (default).
//
// Conservative defaults: a misclassification toward `copy_value`
// pays an extra retain/release pair but is always safe. A
// misclassification toward `borrow_value` could produce a UAF;
// the verifier in Phase E will reject any such case before drop
// insertion runs.
//
// Side effect on `local_ownership`: when classifying a
// `.local_get` as `.borrow_value`, the classifier rewrites
// `function.local_ownership[dest]` from `.owned` to `.borrowed`
// so that `arc_drop_insertion` skips dest at scope exit. The
// non-ARC sources keep `.trivial` and need no update — they were
// never going to receive a destroy.

/// Classify and normalize ownership for `function`.
///
/// Walks each instruction stream and replaces overloaded
/// `.local_get` with explicit `.borrow_value` / `.copy_value`
/// based on the dest's eventual usage. Strips the now-redundant
/// retain that `IrBuilder.emitLocalGet` emitted for ARC-managed
/// sources — `.copy_value` lowering re-emits the retain at ZIR
/// time, and `.borrow_value` deliberately does not.
pub fn classifyAndNormalize(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    ownership: *const arc_liveness.ArcOwnership,
    type_store: *const types_mod.TypeStore,
) !void {
    _ = ownership;
    _ = type_store;

    // Two-pass strategy mirrors `arc_drop_insertion.zig`:
    //   1. Pre-pass: collect, across every instruction stream in
    //      the function, the per-local count of borrowing-position
    //      uses vs total uses. This lets the per-instruction
    //      decision in pass 2 answer "does dest's use set fit the
    //      borrow pattern?" with O(1) lookup.
    //   2. Rewrite pass: walk every stream (recursively) and
    //      rebuild it whenever a `.local_get` (and the optional
    //      following `.retain` it produced) needs replacing.
    //
    // Both passes recurse into the same nested-region set as
    // `ir.forEachInstruction` (if_expr, case_block, switch_*,
    // optional_dispatch handled by reusing the helper).
    var use_summary: UseSummary = .{};
    defer use_summary.deinit(allocator);
    try collectUseSummary(allocator, function, &use_summary);

    var rewriter = StreamRewriter{
        .allocator = allocator,
        .function = function,
        .use_summary = &use_summary,
    };

    for (function.body, 0..) |_, block_index| {
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const original = block_ptr.instructions;
        const rebuilt = try rewriter.rewriteStream(original);
        if (rebuilt) |new_slice| {
            block_ptr.instructions = new_slice;
        }
    }
}

/// Per-local count of borrowing-position uses (`share_value.source`
/// and chained alias sources) and total uses (any non-dest
/// reference). A `.local_get` whose dest's `borrow_use_count`
/// equals `total_use_count` is a borrow candidate; otherwise it
/// promotes to `.copy_value`.
const LocalUseCounts = struct {
    borrow_use_count: u32 = 0,
    total_use_count: u32 = 0,
};

const UseSummary = struct {
    counts: std.AutoHashMapUnmanaged(ir.LocalId, LocalUseCounts) = .empty,

    fn deinit(self: *UseSummary, allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
    }

    fn recordUse(
        self: *UseSummary,
        allocator: std.mem.Allocator,
        local: ir.LocalId,
        is_borrow_position: bool,
    ) !void {
        const gop = try self.counts.getOrPut(allocator, local);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total_use_count += 1;
        if (is_borrow_position) gop.value_ptr.borrow_use_count += 1;
    }

    fn get(self: *const UseSummary, local: ir.LocalId) LocalUseCounts {
        return self.counts.get(local) orelse LocalUseCounts{};
    }
};

fn collectUseSummary(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    summary: *UseSummary,
) !void {
    const Walker = struct {
        allocator: std.mem.Allocator,
        summary: *UseSummary,
        err: ?anyerror = null,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (self.err != null) return;
            recordInstructionUses(self.allocator, self.summary, instr) catch |e| {
                self.err = e;
            };
        }
    };
    var walker = Walker{ .allocator = allocator, .summary = summary };
    ir.forEachInstruction(function, &walker, Walker.visit);
    if (walker.err) |e| return e;
}

/// Record every "use" of a local that this instruction performs.
/// For Phase C the borrowing-position bit is true when the local
/// appears as the source of a value-aliasing instruction whose own
/// dest's classification will (recursively) determine ownership:
/// `share_value`, `local_get`, `borrow_value`, `copy_value`. Every
/// other use (aggregate field, call argument list outside a
/// share, return value, etc.) is treated as ownership-transferring
/// for purposes of this classifier and counts as a non-borrow use.
fn recordInstructionUses(
    allocator: std.mem.Allocator,
    summary: *UseSummary,
    instr: *const ir.Instruction,
) !void {
    switch (instr.*) {
        .share_value => |sv| {
            // Caller-side share is the canonical borrow-shape: the
            // share produces a fresh local that pairs with a post-
            // call release. The source local stays live across the
            // share; no ownership transfers to the share's dest.
            try summary.recordUse(allocator, sv.source, true);
        },
        .local_get => |lg| {
            // Chained alias — propagate the borrow signal.
            try summary.recordUse(allocator, lg.source, true);
        },
        .borrow_value => |bv| {
            try summary.recordUse(allocator, bv.source, true);
        },
        .copy_value => |cv| {
            // A `.copy_value` source is itself an ownership-bumped
            // alias; from the source's perspective it is still a
            // value-alias use that does not consume the source.
            try summary.recordUse(allocator, cv.source, true);
        },
        .move_value => |mv| {
            // Move semantics: source is consumed. Counts as a
            // non-borrow use so a `.local_get` feeding directly
            // into a move classifies as `.copy_value`.
            try summary.recordUse(allocator, mv.source, false);
        },
        .local_set => |ls| {
            // Direct binding write. Conservative: not a borrow
            // position; the dest may live arbitrarily long.
            try summary.recordUse(allocator, ls.value, false);
        },
        .ret => |r| {
            if (r.value) |v| try summary.recordUse(allocator, v, false);
        },
        .cond_return => |cr| {
            try summary.recordUse(allocator, cr.condition, false);
            if (cr.value) |v| try summary.recordUse(allocator, v, false);
        },
        .tuple_init => |ti| {
            for (ti.elements) |elem| try summary.recordUse(allocator, elem, false);
        },
        .list_init => |li| {
            for (li.elements) |elem| try summary.recordUse(allocator, elem, false);
        },
        .list_cons => |lc| {
            try summary.recordUse(allocator, lc.head, false);
            try summary.recordUse(allocator, lc.tail, false);
        },
        .map_init => |mi| {
            for (mi.entries) |entry| {
                try summary.recordUse(allocator, entry.key, false);
                try summary.recordUse(allocator, entry.value, false);
            }
        },
        .struct_init => |si| {
            for (si.fields) |field| try summary.recordUse(allocator, field.value, false);
        },
        .union_init => |ui| {
            try summary.recordUse(allocator, ui.value, false);
        },
        .field_get => |fg| try summary.recordUse(allocator, fg.object, false),
        .field_set => |fs| {
            try summary.recordUse(allocator, fs.object, false);
            try summary.recordUse(allocator, fs.value, false);
        },
        .index_get => |ig| try summary.recordUse(allocator, ig.object, false),
        .list_len_check => |llc| try summary.recordUse(allocator, llc.scrutinee, false),
        .list_get => |lg| try summary.recordUse(allocator, lg.list, false),
        .list_is_not_empty => |lne| try summary.recordUse(allocator, lne.list, false),
        .list_head => |lh| try summary.recordUse(allocator, lh.list, false),
        .list_tail => |lt| try summary.recordUse(allocator, lt.list, false),
        .map_has_key => |mhk| {
            try summary.recordUse(allocator, mhk.map, false);
            try summary.recordUse(allocator, mhk.key, false);
        },
        .map_get => |mg| {
            try summary.recordUse(allocator, mg.map, false);
            try summary.recordUse(allocator, mg.key, false);
        },
        .binary_op => |bo| {
            try summary.recordUse(allocator, bo.lhs, false);
            try summary.recordUse(allocator, bo.rhs, false);
        },
        .unary_op => |uo| try summary.recordUse(allocator, uo.operand, false),
        .call_direct => |cd| {
            for (cd.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .call_named => |cn| {
            for (cn.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .call_closure => |cc| {
            try summary.recordUse(allocator, cc.callee, false);
            for (cc.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .call_dispatch => |cd| {
            for (cd.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .call_builtin => |cb| {
            for (cb.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .tail_call => |tc| {
            for (tc.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .try_call_named => |tcn| {
            for (tcn.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .error_catch => |ec| {
            try summary.recordUse(allocator, ec.source, false);
            try summary.recordUse(allocator, ec.catch_value, false);
        },
        .if_expr => |ie| try summary.recordUse(allocator, ie.condition, false),
        .cond_branch => |cb| try summary.recordUse(allocator, cb.condition, false),
        .switch_tag => |st| try summary.recordUse(allocator, st.scrutinee, false),
        .switch_literal => |sl| try summary.recordUse(allocator, sl.scrutinee, false),
        .switch_return => {
            // scrutinee is a parameter index, not a local; nothing
            // to record at this level. Nested arm bodies still get
            // walked by the caller's `forEachInstruction` recursion.
        },
        .union_switch_return => {},
        .union_switch => |us| try summary.recordUse(allocator, us.scrutinee, false),
        .optional_dispatch => {},
        .match_atom => |ma| try summary.recordUse(allocator, ma.scrutinee, false),
        .match_int => |mi| try summary.recordUse(allocator, mi.scrutinee, false),
        .match_float => |mf| try summary.recordUse(allocator, mf.scrutinee, false),
        .match_string => |ms| try summary.recordUse(allocator, ms.scrutinee, false),
        .match_type => |mt| try summary.recordUse(allocator, mt.scrutinee, false),
        .optional_unwrap => |ou| try summary.recordUse(allocator, ou.source, false),
        // `.retain` and `.release` are refcount-bookkeeping
        // operations, NOT semantic uses of their value: a retain
        // following a `.local_get` is precisely the marker the
        // classifier needs to strip, and counting it as a non-
        // borrow use would force every ARC `.local_get` to
        // classify as `.copy_value` — making the pass a no-op.
        // Drop the retain/release accounting from the borrow-shape
        // decision; the IR still emits balanced refcount work via
        // the post-classification `.borrow_value` / `.copy_value`
        // lowering in `zir_builder.zig`.
        .retain, .release => {},
        .reset => |r| try summary.recordUse(allocator, r.source, false),
        .reuse_alloc => |ra| {
            if (ra.token) |t| try summary.recordUse(allocator, t, false);
        },
        .int_widen, .float_widen => |nw| try summary.recordUse(allocator, nw.source, false),
        .phi => |p| {
            for (p.sources) |src| try summary.recordUse(allocator, src.value, false);
        },
        .case_break => |cb| if (cb.value) |v| try summary.recordUse(allocator, v, false),
        .bin_len_check => |blc| try summary.recordUse(allocator, blc.scrutinee, false),
        .bin_read_int => |bri| try summary.recordUse(allocator, bri.source, false),
        .bin_read_float => |brf| try summary.recordUse(allocator, brf.source, false),
        .bin_slice => |bs| try summary.recordUse(allocator, bs.source, false),
        .bin_read_utf8 => |bru| try summary.recordUse(allocator, bru.source, false),
        .bin_match_prefix => |bmp| try summary.recordUse(allocator, bmp.source, false),
        .make_closure => |mc| {
            // Captures escape into a heap closure; never a borrow
            // position. Each captured local must be classified as
            // a copy if it traces back to a local_get.
            for (mc.captures) |cap| try summary.recordUse(allocator, cap, false);
        },
        // No use-emitting variants below.
        .const_int,
        .const_float,
        .const_string,
        .const_bool,
        .const_atom,
        .const_nil,
        .param_get,
        .enum_literal,
        .capture_get,
        .set_safety,
        .guard_block,
        .branch,
        .jump,
        .case_block,
        .match_fail,
        .match_error_return,
        => {},
    }
}

/// Decide between `.borrow_value` and `.copy_value` for the
/// `.local_get` whose dest is `dest`. Returns `true` for borrow,
/// `false` for copy. Conservative default is copy.
fn shouldBorrow(
    function: *const ir.Function,
    summary: *const UseSummary,
    dest: ir.LocalId,
) bool {
    const counts = summary.get(dest);
    // Dead destinations: nothing to retain or destroy. Treat as a
    // borrow (no-op assignment in zir_builder).
    if (counts.total_use_count == 0) return true;
    // Non-ARC destinations: ARC bookkeeping is a no-op anyway, so
    // pick the cheaper form. The classifier still sets the
    // ownership class to `.borrowed` for these — but they were
    // already `.trivial` in `local_ownership` and that classification
    // takes precedence (no destroy, no retain).
    if (dest >= function.local_ownership.len or function.local_ownership[dest] == .trivial) {
        return true;
    }
    // Borrow only when EVERY use is a borrowing-position use.
    return counts.borrow_use_count == counts.total_use_count;
}

const StreamRewriter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    use_summary: *const UseSummary,

    /// Rewrite one instruction stream. Returns `null` when no
    /// rewriting was needed. Otherwise returns a freshly-allocated
    /// slice in `self.allocator`.
    fn rewriteStream(
        self: *StreamRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First pass: rebuild children for any instruction that
        // contains nested streams. Track whether any change is
        // needed (either at this level or in a sub-stream).
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const child = try self.rewriteChildren(instr);
            if (child) |_| any_change = true;
            try rebuilt_children.append(self.allocator, child);
        }

        // Second pass: walk forward, classifying each `.local_get`
        // and dropping the optional follow-on `.retain {value=dest}`
        // emitted by `IrBuilder.emitLocalGet`.
        var new_instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer new_instrs.deinit(self.allocator);
        try new_instrs.ensureTotalCapacity(self.allocator, stream.len);

        var i: usize = 0;
        while (i < stream.len) : (i += 1) {
            const original = stream[i];
            // Effective instruction: child-rewritten copy when the
            // child rewrite changed something, otherwise the
            // original.
            const effective = rebuilt_children.items[i] orelse original;

            switch (effective) {
                .local_get => |lg| {
                    any_change = true;
                    if (shouldBorrow(self.function, self.use_summary, lg.dest)) {
                        try new_instrs.append(self.allocator, .{
                            .borrow_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                        // Refine the dest's ownership class to
                        // `.borrowed` so drop insertion skips it.
                        // Skip non-ARC destinations: they were
                        // already `.trivial` and that record is
                        // load-bearing for the drop pass.
                        if (lg.dest < self.function.local_ownership.len and
                            self.function.local_ownership[lg.dest] == .owned)
                        {
                            self.function.local_ownership[lg.dest] = .borrowed;
                        }
                    } else {
                        try new_instrs.append(self.allocator, .{
                            .copy_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                    }
                    // Strip the immediately-following
                    // `.retain {value=dest}` if present — it was
                    // emitted by `IrBuilder.emitLocalGet` for ARC
                    // sources. Both `.borrow_value` (no retain) and
                    // `.copy_value` (retain emitted by zir_builder
                    // lowering) supersede it.
                    if (i + 1 < stream.len) {
                        const peek_original = stream[i + 1];
                        const peek = rebuilt_children.items[i + 1] orelse peek_original;
                        if (peek == .retain and peek.retain.value == lg.dest) {
                            i += 1;
                        }
                    }
                },
                else => try new_instrs.append(self.allocator, effective),
            }
        }

        if (!any_change) {
            new_instrs.deinit(self.allocator);
            return null;
        }
        return try new_instrs.toOwnedSlice(self.allocator);
    }

    /// If `instr` has nested instruction streams, rewrite each one.
    /// Returns a copy of `instr` with the rebuilt streams when any
    /// child needed rewriting; otherwise `null`.
    fn rewriteChildren(
        self: *StreamRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        switch (instr.*) {
            .if_expr => |ie| {
                const new_then = try self.rewriteStream(ie.then_instrs);
                const new_else = try self.rewriteStream(ie.else_instrs);
                if (new_then == null and new_else == null) return null;
                var copy = ie;
                if (new_then) |s| copy.then_instrs = s;
                if (new_else) |s| copy.else_instrs = s;
                return ir.Instruction{ .if_expr = copy };
            },
            .case_block => |cb| {
                var any_arm_change = false;
                const new_pre = try self.rewriteStream(cb.pre_instrs);
                if (new_pre != null) any_arm_change = true;
                const new_default = try self.rewriteStream(cb.default_instrs);
                if (new_default != null) any_arm_change = true;
                var new_arms = try self.allocator.alloc(ir.IrCaseArm, cb.arms.len);
                var arms_changed = false;
                for (cb.arms, 0..) |arm, idx| {
                    var arm_copy = arm;
                    const new_cond = try self.rewriteStream(arm.cond_instrs);
                    const new_body = try self.rewriteStream(arm.body_instrs);
                    if (new_cond) |s| {
                        arm_copy.cond_instrs = s;
                        arms_changed = true;
                    }
                    if (new_body) |s| {
                        arm_copy.body_instrs = s;
                        arms_changed = true;
                    }
                    new_arms[idx] = arm_copy;
                }
                if (!any_arm_change and !arms_changed) {
                    self.allocator.free(new_arms);
                    return null;
                }
                var copy = cb;
                if (new_pre) |s| copy.pre_instrs = s;
                if (new_default) |s| copy.default_instrs = s;
                if (arms_changed) {
                    copy.arms = new_arms;
                } else {
                    self.allocator.free(new_arms);
                }
                return ir.Instruction{ .case_block = copy };
            },
            .switch_literal => |sl| {
                var any_change = false;
                const new_default = try self.rewriteStream(sl.default_instrs);
                if (new_default != null) any_change = true;
                var new_cases = try self.allocator.alloc(ir.LitCase, sl.cases.len);
                var cases_changed = false;
                for (sl.cases, 0..) |c, idx| {
                    var c_copy = c;
                    const new_body = try self.rewriteStream(c.body_instrs);
                    if (new_body) |s| {
                        c_copy.body_instrs = s;
                        cases_changed = true;
                    }
                    new_cases[idx] = c_copy;
                }
                if (!any_change and !cases_changed) {
                    self.allocator.free(new_cases);
                    return null;
                }
                var copy = sl;
                if (new_default) |s| copy.default_instrs = s;
                if (cases_changed) {
                    copy.cases = new_cases;
                } else {
                    self.allocator.free(new_cases);
                }
                return ir.Instruction{ .switch_literal = copy };
            },
            .switch_return => |sr| {
                var any_change = false;
                const new_default = try self.rewriteStream(sr.default_instrs);
                if (new_default != null) any_change = true;
                var new_cases = try self.allocator.alloc(ir.ReturnCase, sr.cases.len);
                var cases_changed = false;
                for (sr.cases, 0..) |c, idx| {
                    var c_copy = c;
                    const new_body = try self.rewriteStream(c.body_instrs);
                    if (new_body) |s| {
                        c_copy.body_instrs = s;
                        cases_changed = true;
                    }
                    new_cases[idx] = c_copy;
                }
                if (!any_change and !cases_changed) {
                    self.allocator.free(new_cases);
                    return null;
                }
                var copy = sr;
                if (new_default) |s| copy.default_instrs = s;
                if (cases_changed) {
                    copy.cases = new_cases;
                } else {
                    self.allocator.free(new_cases);
                }
                return ir.Instruction{ .switch_return = copy };
            },
            .union_switch => |us| {
                var new_cases = try self.allocator.alloc(ir.UnionCase, us.cases.len);
                var cases_changed = false;
                for (us.cases, 0..) |c, idx| {
                    var c_copy = c;
                    const new_body = try self.rewriteStream(c.body_instrs);
                    if (new_body) |s| {
                        c_copy.body_instrs = s;
                        cases_changed = true;
                    }
                    new_cases[idx] = c_copy;
                }
                if (!cases_changed) {
                    self.allocator.free(new_cases);
                    return null;
                }
                var copy = us;
                copy.cases = new_cases;
                return ir.Instruction{ .union_switch = copy };
            },
            .union_switch_return => |usr| {
                var new_cases = try self.allocator.alloc(ir.UnionCase, usr.cases.len);
                var cases_changed = false;
                for (usr.cases, 0..) |c, idx| {
                    var c_copy = c;
                    const new_body = try self.rewriteStream(c.body_instrs);
                    if (new_body) |s| {
                        c_copy.body_instrs = s;
                        cases_changed = true;
                    }
                    new_cases[idx] = c_copy;
                }
                if (!cases_changed) {
                    self.allocator.free(new_cases);
                    return null;
                }
                var copy = usr;
                copy.cases = new_cases;
                return ir.Instruction{ .union_switch_return = copy };
            },
            .try_call_named => |tcn| {
                const new_handler = try self.rewriteStream(tcn.handler_instrs);
                const new_success = try self.rewriteStream(tcn.success_instrs);
                if (new_handler == null and new_success == null) return null;
                var copy = tcn;
                if (new_handler) |s| copy.handler_instrs = s;
                if (new_success) |s| copy.success_instrs = s;
                return ir.Instruction{ .try_call_named = copy };
            },
            .guard_block => |gb| {
                const new_body = try self.rewriteStream(gb.body);
                if (new_body == null) return null;
                var copy = gb;
                copy.body = new_body.?;
                return ir.Instruction{ .guard_block = copy };
            },
            else => return null,
        }
    }
};

test "arc_ownership: stub function signature compiles" {
    // Phase A's stub must not error and must not require any
    // particular function shape. The integration test in compiler.zig
    // exercises the wired pipeline; this unit test pins the stub's
    // contract: the symbol exists with the right signature so
    // downstream wiring lights up. Phase C populates the real
    // classifier coverage with the suite below.
    const fn_ptr: *const @TypeOf(classifyAndNormalize) = &classifyAndNormalize;
    _ = fn_ptr;
}

// ============================================================
// Phase C tests: borrow / copy classification on representative
// shapes. Each test parses Zap source, lowers to IR, runs
// `arc_liveness.runProgramArcOwnership` so the classifier has the
// per-function ownership input it expects, then invokes
// `classifyAndNormalize` and asserts on the post-classification
// instruction stream.
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const hir_mod = @import("hir.zig");
const HirBuilder = hir_mod.HirBuilder;

/// End-to-end fixture for the Phase C classifier tests. Mirrors the
/// `DropTestSuite` shape used by `arc_drop_insertion.zig`: parses
/// Zap source, lowers through the front-end, and exposes the IR
/// program plus a per-function arc-liveness ownership table so
/// individual tests can drive `classifyAndNormalize` directly.
const ClassifyTestSuite = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    parser: *Parser,
    collector: *Collector,
    checker: *types_mod.TypeChecker,
    hir: *HirBuilder,
    hir_program: hir_mod.Program,
    ir_builder: *ir.IrBuilder,
    ir_program: ir.Program,
    program_ownership: arc_liveness.ProgramArcOwnership,

    fn init(allocator: std.mem.Allocator, source: []const u8) !ClassifyTestSuite {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena_ptr.allocator();

        const parser_ptr = try alloc.create(Parser);
        parser_ptr.* = Parser.init(alloc, source);
        const program = try parser_ptr.parseProgram();

        const collector_ptr = try alloc.create(Collector);
        collector_ptr.* = Collector.init(alloc, parser_ptr.interner, null);
        try collector_ptr.collectProgram(&program);

        const checker_ptr = try alloc.create(types_mod.TypeChecker);
        checker_ptr.* = types_mod.TypeChecker.init(alloc, parser_ptr.interner, &collector_ptr.graph);
        try checker_ptr.checkProgram(&program);

        const hir_ptr = try alloc.create(HirBuilder);
        hir_ptr.* = HirBuilder.init(alloc, parser_ptr.interner, &collector_ptr.graph, checker_ptr.store);
        const hir_program = try hir_ptr.buildProgram(&program);

        const ir_ptr = try alloc.create(ir.IrBuilder);
        ir_ptr.* = ir.IrBuilder.init(alloc, parser_ptr.interner);
        ir_ptr.type_store = checker_ptr.store;
        var ir_program = try ir_ptr.buildProgram(&hir_program);

        const program_ownership = try arc_liveness.runProgramArcOwnership(
            allocator,
            &ir_program,
            checker_ptr.store,
        );

        return .{
            .arena = arena_ptr,
            .allocator = allocator,
            .parser = parser_ptr,
            .collector = collector_ptr,
            .checker = checker_ptr,
            .hir = hir_ptr,
            .hir_program = hir_program,
            .ir_builder = ir_ptr,
            .ir_program = ir_program,
            .program_ownership = program_ownership,
        };
    }

    fn deinit(self: *ClassifyTestSuite) void {
        var po = self.program_ownership;
        po.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    fn findFunctionByName(self: *ClassifyTestSuite, name: []const u8) ?*ir.Function {
        for (self.ir_program.functions, 0..) |_, i| {
            const func: *ir.Function = @constCast(&self.ir_program.functions[i]);
            if (std.mem.indexOf(u8, func.name, name) != null) return func;
        }
        return null;
    }

    fn classify(self: *ClassifyTestSuite, function: *ir.Function) !void {
        const fn_ownership = self.program_ownership.get(function.id) orelse return;
        // Run the classifier with the arena allocator so any new IR
        // slices it creates share the arena's lifetime with the rest
        // of the IR program. Mirrors compiler.zig's usage where the
        // pipeline's allocator owns IR allocations end-to-end.
        try classifyAndNormalize(self.arena.allocator(), function, fn_ownership, self.checker.store);
    }
};

/// Walk every instruction (top-level and nested) and tally the count
/// of `.borrow_value` and `.copy_value` instructions whose source
/// equals `source_local`.
const ClassifyCounts = struct {
    borrow_count: usize = 0,
    copy_count: usize = 0,
    local_get_count: usize = 0,
};

fn countClassificationsFromSource(
    function: *const ir.Function,
    source_local: ir.LocalId,
) ClassifyCounts {
    const Walker = struct {
        counts: *ClassifyCounts,
        source_local: ir.LocalId,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            switch (instr.*) {
                .borrow_value => |bv| {
                    if (bv.source == self.source_local) self.counts.borrow_count += 1;
                },
                .copy_value => |cv| {
                    if (cv.source == self.source_local) self.counts.copy_count += 1;
                },
                .local_get => |lg| {
                    if (lg.source == self.source_local) self.counts.local_get_count += 1;
                },
                else => {},
            }
        }
    };
    var counts = ClassifyCounts{};
    var walker = Walker{ .counts = &counts, .source_local = source_local };
    ir.forEachInstruction(function, &walker, Walker.visit);
    return counts;
}

/// Walk every instruction (top-level and nested) and tally the total
/// counts of the three alias-shaped opcodes regardless of source.
fn countAliasOpcodes(function: *const ir.Function) ClassifyCounts {
    const Walker = struct {
        counts: *ClassifyCounts,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            switch (instr.*) {
                .borrow_value => self.counts.borrow_count += 1,
                .copy_value => self.counts.copy_count += 1,
                .local_get => self.counts.local_get_count += 1,
                else => {},
            }
        }
    };
    var counts = ClassifyCounts{};
    var walker = Walker{ .counts = &counts };
    ir.forEachInstruction(function, &walker, Walker.visit);
    return counts;
}

test "arc_ownership: ARC param passed to a borrowing call yields borrow_value" {
    // Phase C — pattern 1 from the redux plan §3.C tests: when a
    // `.local_get`'s dest's only use is the source of a
    // `share_value` that feeds a borrowing-convention call, the
    // classifier emits `.borrow_value`. No `.copy_value` is needed
    // because the caller-side share already supplies the +1 the
    // callee borrows under.
    //
    // The callee `peek` just returns its argument unchanged — its
    // body is irrelevant for the classifier; the call-site shape
    // is what matters. The caller's `aliased = h` produces a
    // `.local_get` whose dest's only use is the `share_value`
    // feeding `Test.peek(aliased)`. That use pattern classifies as
    // borrow.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn peek(h :: Handle) -> Handle { h }
        \\
        \\  pub fn caller(h :: Handle) -> Handle {
        \\    aliased = h
        \\    Test.peek(aliased)
        \\  }
        \\}
    ;
    var suite = try ClassifyTestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const caller_func = suite.findFunctionByName("caller") orelse return error.MissingFunction;
    try suite.classify(caller_func);

    // The named-binding `aliased = h` produces a `.local_get`
    // whose dest's only use is the call argument. After classify:
    // a `.borrow_value` with that source. Note that the call-result
    // tail expression also goes through a `.local_get` for its own
    // return; so multiple alias-shaped opcodes may legitimately
    // appear.
    const totals = countAliasOpcodes(caller_func);
    // Every `.local_get` must be replaced.
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // At least one borrow_value should appear (the alias `aliased = h`).
    try std.testing.expect(totals.borrow_count >= 1);
}

test "arc_ownership: ARC param stored into struct field yields copy_value" {
    // Phase C — pattern 2 from the redux plan §3.C tests: when a
    // `.local_get`'s dest flows into an aggregate initializer (here:
    // a struct field value), the classifier emits `.copy_value`.
    // The aggregate becomes an independent owner of the value, so a
    // retain is required to balance the eventual destroy of either
    // owner.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub struct Box {
        \\    handle :: Handle
        \\  }
        \\
        \\  pub fn caller(h :: Handle) -> Box {
        \\    aliased = h
        \\    %{handle: aliased}
        \\  }
        \\}
    ;
    var suite = try ClassifyTestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const caller_func = suite.findFunctionByName("caller") orelse return error.MissingFunction;
    try suite.classify(caller_func);

    const totals = countAliasOpcodes(caller_func);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // At least one copy_value should appear (the alias whose use is
    // the struct_init field value).
    try std.testing.expect(totals.copy_count >= 1);
}

test "arc_ownership: identity function emits copy_value at return site" {
    // Phase C — pattern 3 from the redux plan §3.C tests: a function
    // that returns one of its borrowed parameters must promote the
    // borrow to ownership at the return site. The classifier emits
    // `.copy_value` for the `.local_get` whose dest flows into a
    // `ret`. Without this promotion, the caller's post-call release
    // would decrement a value the callee was lending out.
    //
    // The IR builder elides the trivially-direct `pub fn id(h) { h }`
    // shape — no `.local_get` is emitted because `param_get`'s dest
    // is the return value directly. To exercise the return-promotion
    // path we use a named binding (`bound = h`) so the body has a
    // `.local_get` whose dest flows into the `ret`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle {
        \\    bound = h
        \\    bound
        \\  }
        \\}
    ;
    var suite = try ClassifyTestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const id_func = suite.findFunctionByName("id") orelse return error.MissingFunction;
    try suite.classify(id_func);

    const totals = countAliasOpcodes(id_func);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // A copy_value must appear at the return site for the param's
    // borrow→owned promotion.
    try std.testing.expect(totals.copy_count >= 1);
    try std.testing.expectEqual(@as(usize, 0), totals.borrow_count);
}

test "arc_ownership: aliased reads of a shared param both yield borrow_value" {
    // Phase C — pattern 4 from the redux plan §3.C tests: two
    // separate `.local_get`s aliasing the same ARC parameter, each
    // feeding a borrowing call, must both classify as
    // `.borrow_value`. This is the simplest reproducer that pinned
    // the Phase 6.7-6.8 oscillation: under "always retain" both
    // aliases bump h's cell, leaving an unbalanced refcount; under
    // "never retain" the first scope-exit destroy wins and the
    // second alias becomes a UAF. The borrow form makes both
    // semantics-correct: no retain on either alias, no destroy on
    // either alias.
    //
    // The caller binds `a1 = h`, calls `Test.peek(a1)`, then binds
    // `a2 = h`, calls `Test.peek(a2)` and returns its result. Each
    // alias's only use is the share_value source feeding the call.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn peek(h :: Handle) -> Handle { h }
        \\
        \\  pub fn caller(h :: Handle) -> Handle {
        \\    a1 = h
        \\    _ = Test.peek(a1)
        \\    a2 = h
        \\    Test.peek(a2)
        \\  }
        \\}
    ;
    var suite = try ClassifyTestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const caller_func = suite.findFunctionByName("caller") orelse return error.MissingFunction;
    try suite.classify(caller_func);

    const totals = countAliasOpcodes(caller_func);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // At least two borrow_values for the two aliases. Other
    // alias-shaped opcodes may appear from pattern-bind / call-
    // result lowering, but the load-bearing assertion is the
    // absence of `.local_get` and presence of borrow classifications
    // for the named `a1`/`a2` aliases of `h`.
    try std.testing.expect(totals.borrow_count >= 2);
}
