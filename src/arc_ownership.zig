const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const types_mod = @import("types.zig");
const uniqueness_analysis = @import("uniqueness.zig");

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
//     -> `copy_value` + persistent retain (scope-exit destroy)
//   - dest flows into a `ret` whose source is a parameter
//     -> `copy_value` + persistent retain (promote borrow to
//     owned for return)
//   - default -> `copy_value` + persistent retain (conservative;
//     Phase E verifier prompts refinement when conservative
//     classification is wrong)
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
// `.copy_value` paired with an explicit persistent retain (the dest
// pairs with a scope-exit destroy). The rewrite also strips the
// immediately-following `.retain {value = dest}` instruction emitted
// by `IrBuilder.emitLocalGet` for ARC-managed sources; copy
// classifications re-emit that ownership bump as an explicit
// `.retain {kind = .persistent}`, while borrow classifications drop
// it by design.
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
/// sources; `.copy_value` is paired with an explicit persistent
/// retain in IR, and `.borrow_value` deliberately is not.
pub fn classifyAndNormalize(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    ownership: *const arc_liveness.ArcOwnership,
    type_store: *const types_mod.TypeStore,
) !void {
    return classifyAndNormalizeWithProgram(allocator, function, ownership, type_store, null);
}

/// Variant of `classifyAndNormalize` that accepts an optional
/// program reference so the use-summary pass can consult callee
/// `param_conventions` and refine `share_value.source` borrow-
/// position accounting.
///
/// Phase H.5: `rewriteOwnedConsumeSites` converts `share_value`
/// into `move_value` whenever the call's matching param convention
/// is `.owned`. After the rewrite the source must own `+1` —
/// `move_value` transfers ownership rather than aliasing. If the
/// classifier ran without program awareness, it would record the
/// `share_value.source` use as a borrow (the default for share)
/// and emit `borrow_value` upstream — making the post-rewrite
/// chain `borrow_value → move_value`, which is unsound (the move
/// has nothing to transfer because the upstream borrow never
/// retained). Threading the program through here lets the
/// classifier mark such share sites as non-borrow positions
/// up-front, so the upstream `local_get` lowers to `copy_value`
/// plus an explicit retain, giving the eventual `move_value` a
/// real `+1` to transfer.
pub fn classifyAndNormalizeWithProgram(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    ownership: *const arc_liveness.ArcOwnership,
    type_store: *const types_mod.TypeStore,
    program: ?*const ir.Program,
) !void {
    _ = type_store;

    refineParamGetOwnership(function);

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
    try collectUseSummaryWithProgram(allocator, function, &use_summary, program);

    preclassifyBorrowedAliases(function, &use_summary);

    var rewriter = StreamRewriter{
        .allocator = allocator,
        .function = function,
        .use_summary = &use_summary,
        .ownership = ownership,
    };

    for (function.body, 0..) |_, block_index| {
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const original = block_ptr.instructions;
        rewriter.next_id = computeStreamStartIdForBlock(function, block_index);
        const rebuilt = try rewriter.rewriteStream(original);
        if (rebuilt) |new_slice| {
            block_ptr.instructions = new_slice;
        }
    }

    var promoter = BorrowedResultPromoter{
        .allocator = allocator,
        .function = function,
    };
    try promoter.rewriteFunction();
}

fn preclassifyBorrowedAliases(function: *ir.Function, summary: *const UseSummary) void {
    const Visitor = struct {
        function: *ir.Function,
        summary: *const UseSummary,

        fn markBorrowed(self: *@This(), local: ir.LocalId) void {
            if (local >= self.function.local_ownership.len) return;
            if (self.function.local_ownership[local] == .owned) {
                self.function.local_ownership[local] = .borrowed;
            }
        }

        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            switch (instr.*) {
                .local_get => |local_get| {
                    if (shouldBorrow(self.function, self.summary, local_get.dest)) {
                        self.markBorrowed(local_get.dest);
                    }
                },
                .borrow_value => |borrow_value| {
                    self.markBorrowed(borrow_value.dest);
                },
                else => {},
            }
        }
    };

    var visitor = Visitor{ .function = function, .summary = summary };
    ir.forEachInstruction(function, &visitor, Visitor.visit);
}

fn refineParamGetOwnership(function: *ir.Function) void {
    const Visitor = struct {
        function: *ir.Function,

        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (instr.* != .param_get) return;
            const param_get = instr.param_get;
            if (param_get.dest >= self.function.local_ownership.len) return;
            if (param_get.index >= self.function.param_conventions.len) return;
            self.function.local_ownership[param_get.dest] = switch (self.function.param_conventions[param_get.index]) {
                .trivial => .trivial,
                .borrowed => .borrowed,
                .owned => .owned,
            };
        }
    };

    var visitor = Visitor{ .function = function };
    ir.forEachInstruction(function, &visitor, Visitor.visit);
}

fn appendCopyValueWithPersistentRetain(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(ir.Instruction),
    dest: ir.LocalId,
    source: ir.LocalId,
) error{OutOfMemory}!void {
    try out.append(allocator, .{ .copy_value = .{ .dest = dest, .source = source } });
    try out.append(allocator, .{ .retain = .{ .value = dest, .kind = .persistent } });
}

const BorrowedResultPromoter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,

    fn rewriteFunction(self: *BorrowedResultPromoter) error{OutOfMemory}!void {
        for (self.function.body, 0..) |_, block_index| {
            const block_ptr: *ir.Block = @constCast(&self.function.body[block_index]);
            if (try self.rewriteStream(block_ptr.instructions, null)) |rewritten| {
                block_ptr.instructions = rewritten;
            }
        }
    }

    fn rewriteStream(
        self: *BorrowedResultPromoter,
        stream: []const ir.Instruction,
        aggregate_dest: ?ir.LocalId,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        var out: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, stream.len);

        var changed = false;
        for (stream) |instr| {
            const effective = if (try self.rewriteChildren(instr, aggregate_dest)) |rewritten| blk: {
                changed = true;
                break :blk rewritten;
            } else instr;

            switch (effective) {
                .struct_init => |struct_init| {
                    var copy = struct_init;
                    if (try self.promoteStructFieldsBefore(&out, copy.fields)) |fields| {
                        copy.fields = fields;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .struct_init = copy });
                },
                .list_init => |list_init| {
                    var copy = list_init;
                    if (try self.promoteLocalSliceBefore(&out, copy.elements)) |elements| {
                        copy.elements = elements;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .list_init = copy });
                },
                .list_cons => |list_cons| {
                    var copy = list_cons;
                    if (try self.promoteValueBefore(&out, copy.head, true)) |promoted| {
                        copy.head = promoted;
                        changed = true;
                    }
                    if (try self.promoteValueBefore(&out, copy.tail, true)) |promoted| {
                        copy.tail = promoted;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .list_cons = copy });
                },
                .map_init => |map_init| {
                    var copy = map_init;
                    if (try self.promoteMapEntriesBefore(&out, copy.entries)) |entries| {
                        copy.entries = entries;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .map_init = copy });
                },
                .tuple_init => |tuple_init| {
                    var copy = tuple_init;
                    if (try self.promoteLocalSliceBefore(&out, copy.elements)) |elements| {
                        copy.elements = elements;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .tuple_init = copy });
                },
                .union_init => |union_init| {
                    var copy = union_init;
                    if (try self.promoteValueBefore(&out, copy.value, true)) |promoted| {
                        copy.value = promoted;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .union_init = copy });
                },
                .ret => |ret| {
                    var copy = ret;
                    if (try self.promoteValueBefore(&out, copy.value, self.function.result_convention == .owned)) |promoted| {
                        copy.value = promoted;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .ret = copy });
                },
                .cond_return => |cond_return| {
                    var copy = cond_return;
                    if (try self.promoteValueBefore(&out, copy.value, self.function.result_convention == .owned)) |promoted| {
                        copy.value = promoted;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .cond_return = copy });
                },
                .case_break => |case_break| {
                    var copy = case_break;
                    const require_owned = if (aggregate_dest) |dest| self.localIsOwned(dest) else false;
                    if (try self.promoteValueBefore(&out, copy.value, require_owned)) |promoted| {
                        copy.value = promoted;
                        changed = true;
                    }
                    try out.append(self.allocator, .{ .case_break = copy });
                },
                else => try out.append(self.allocator, effective),
            }
        }

        if (!changed) {
            out.deinit(self.allocator);
            return null;
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn promoteLocalSliceBefore(
        self: *BorrowedResultPromoter,
        out: *std.ArrayListUnmanaged(ir.Instruction),
        values: []const ir.LocalId,
    ) error{OutOfMemory}!?[]const ir.LocalId {
        var replacement: ?[]ir.LocalId = null;
        for (values, 0..) |value, index| {
            if (try self.promoteValueBefore(out, value, true)) |promoted| {
                if (replacement == null) {
                    replacement = try self.allocator.dupe(ir.LocalId, values);
                }
                replacement.?[index] = promoted;
            }
        }
        return replacement;
    }

    fn promoteStructFieldsBefore(
        self: *BorrowedResultPromoter,
        out: *std.ArrayListUnmanaged(ir.Instruction),
        fields: []const ir.StructFieldInit,
    ) error{OutOfMemory}!?[]const ir.StructFieldInit {
        var replacement: ?[]ir.StructFieldInit = null;
        for (fields, 0..) |field, index| {
            if (try self.promoteValueBefore(out, field.value, true)) |promoted| {
                if (replacement == null) {
                    replacement = try self.allocator.dupe(ir.StructFieldInit, fields);
                }
                replacement.?[index].value = promoted;
            }
        }
        return replacement;
    }

    fn promoteMapEntriesBefore(
        self: *BorrowedResultPromoter,
        out: *std.ArrayListUnmanaged(ir.Instruction),
        entries: []const ir.MapEntry,
    ) error{OutOfMemory}!?[]const ir.MapEntry {
        var replacement: ?[]ir.MapEntry = null;
        for (entries, 0..) |entry, index| {
            if (try self.promoteValueBefore(out, entry.key, true)) |promoted| {
                if (replacement == null) {
                    replacement = try self.allocator.dupe(ir.MapEntry, entries);
                }
                replacement.?[index].key = promoted;
            }
            if (try self.promoteValueBefore(out, entry.value, true)) |promoted| {
                if (replacement == null) {
                    replacement = try self.allocator.dupe(ir.MapEntry, entries);
                }
                replacement.?[index].value = promoted;
            }
        }
        return replacement;
    }

    fn rewriteChildren(
        self: *BorrowedResultPromoter,
        instr: ir.Instruction,
        enclosing_aggregate_dest: ?ir.LocalId,
    ) error{OutOfMemory}!?ir.Instruction {
        switch (instr) {
            .if_expr => |ie| {
                var copy = ie;
                var changed = false;
                if (try self.rewriteStream(copy.then_instrs, null)) |rewritten| {
                    copy.then_instrs = rewritten;
                    changed = true;
                }
                if (try self.rewriteStream(copy.else_instrs, null)) |rewritten| {
                    copy.else_instrs = rewritten;
                    changed = true;
                }
                const require_owned = self.localIsOwned(copy.dest);
                if (try self.promoteValueAtEnd(&copy.then_instrs, copy.then_result, require_owned)) |promoted| {
                    copy.then_result = promoted;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.else_instrs, copy.else_result, require_owned)) |promoted| {
                    copy.else_result = promoted;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .if_expr = copy } else null;
            },
            .case_block => |cb| {
                var copy = cb;
                var changed = false;
                const aggregate_dest: ?ir.LocalId = if (self.localIsOwned(copy.dest)) copy.dest else null;

                if (try self.rewriteStream(copy.pre_instrs, aggregate_dest)) |rewritten| {
                    copy.pre_instrs = rewritten;
                    changed = true;
                }

                if (copy.arms.len > 0) {
                    var new_arms = try self.allocator.alloc(ir.IrCaseArm, copy.arms.len);
                    var arms_changed = false;
                    for (copy.arms, 0..) |arm, idx| {
                        var arm_copy = arm;
                        if (try self.rewriteStream(arm_copy.cond_instrs, aggregate_dest)) |rewritten| {
                            arm_copy.cond_instrs = rewritten;
                            arms_changed = true;
                        }
                        if (try self.rewriteStream(arm_copy.body_instrs, aggregate_dest)) |rewritten| {
                            arm_copy.body_instrs = rewritten;
                            arms_changed = true;
                        }
                        if (try self.promoteValueAtEnd(&arm_copy.body_instrs, arm_copy.result, aggregate_dest != null)) |promoted| {
                            arm_copy.result = promoted;
                            arms_changed = true;
                        }
                        new_arms[idx] = arm_copy;
                    }
                    if (arms_changed) {
                        copy.arms = new_arms;
                        changed = true;
                    }
                }

                if (try self.rewriteStream(copy.default_instrs, aggregate_dest)) |rewritten| {
                    copy.default_instrs = rewritten;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.default_instrs, copy.default_result, aggregate_dest != null)) |promoted| {
                    copy.default_result = promoted;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .case_block = copy } else null;
            },
            .switch_literal => |sl| {
                var copy = sl;
                var changed = false;
                const require_owned = self.localIsOwned(copy.dest);
                if (copy.cases.len > 0) {
                    var new_cases = try self.allocator.alloc(ir.LitCase, copy.cases.len);
                    var cases_changed = false;
                    for (copy.cases, 0..) |case, idx| {
                        var case_copy = case;
                        if (try self.rewriteStream(case_copy.body_instrs, null)) |rewritten| {
                            case_copy.body_instrs = rewritten;
                            cases_changed = true;
                        }
                        if (try self.promoteValueAtEnd(&case_copy.body_instrs, case_copy.result, require_owned)) |promoted| {
                            case_copy.result = promoted;
                            cases_changed = true;
                        }
                        new_cases[idx] = case_copy;
                    }
                    if (cases_changed) {
                        copy.cases = new_cases;
                        changed = true;
                    }
                }
                if (try self.rewriteStream(copy.default_instrs, null)) |rewritten| {
                    copy.default_instrs = rewritten;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.default_instrs, copy.default_result, require_owned)) |promoted| {
                    copy.default_result = promoted;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .switch_literal = copy } else null;
            },
            .switch_return => |sr| {
                var copy = sr;
                var changed = false;
                const require_owned = self.function.result_convention == .owned;
                if (copy.cases.len > 0) {
                    var new_cases = try self.allocator.alloc(ir.ReturnCase, copy.cases.len);
                    var cases_changed = false;
                    for (copy.cases, 0..) |case, idx| {
                        var case_copy = case;
                        if (try self.rewriteStream(case_copy.body_instrs, null)) |rewritten| {
                            case_copy.body_instrs = rewritten;
                            cases_changed = true;
                        }
                        if (try self.promoteValueAtEnd(&case_copy.body_instrs, case_copy.return_value, require_owned)) |promoted| {
                            case_copy.return_value = promoted;
                            cases_changed = true;
                        }
                        new_cases[idx] = case_copy;
                    }
                    if (cases_changed) {
                        copy.cases = new_cases;
                        changed = true;
                    }
                }
                if (try self.rewriteStream(copy.default_instrs, null)) |rewritten| {
                    copy.default_instrs = rewritten;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.default_instrs, copy.default_result, require_owned)) |promoted| {
                    copy.default_result = promoted;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .switch_return = copy } else null;
            },
            .union_switch => |us| {
                var copy = us;
                var changed = false;
                const require_owned = self.localIsOwned(copy.dest);
                if (copy.cases.len > 0) {
                    var new_cases = try self.allocator.alloc(ir.UnionCase, copy.cases.len);
                    var cases_changed = false;
                    for (copy.cases, 0..) |case, idx| {
                        var case_copy = case;
                        if (try self.rewriteStream(case_copy.body_instrs, null)) |rewritten| {
                            case_copy.body_instrs = rewritten;
                            cases_changed = true;
                        }
                        if (try self.promoteValueAtEnd(&case_copy.body_instrs, case_copy.return_value, require_owned)) |promoted| {
                            case_copy.return_value = promoted;
                            cases_changed = true;
                        }
                        new_cases[idx] = case_copy;
                    }
                    if (cases_changed) {
                        copy.cases = new_cases;
                        changed = true;
                    } else {
                        self.allocator.free(new_cases);
                    }
                }
                // The catch-all `_` prong is rewritten and result-promoted
                // exactly like a case arm; without this, a borrowed value
                // flowing out of the else prong (via else_result) was never
                // promoted with copy+retain, so the caller released a
                // borrowed cell (refcount underflow / double free). See
                // audit finding arc-own-2--01.
                if (copy.has_else) {
                    if (try self.rewriteStream(copy.else_instrs, null)) |rewritten| {
                        copy.else_instrs = rewritten;
                        changed = true;
                    }
                    if (try self.promoteValueAtEnd(&copy.else_instrs, copy.else_result, require_owned)) |promoted| {
                        copy.else_result = promoted;
                        changed = true;
                    }
                }
                return if (changed) ir.Instruction{ .union_switch = copy } else null;
            },
            .union_switch_return => |usr| {
                var copy = usr;
                var changed = false;
                const require_owned = self.function.result_convention == .owned;
                if (copy.cases.len > 0) {
                    var new_cases = try self.allocator.alloc(ir.UnionCase, copy.cases.len);
                    var cases_changed = false;
                    for (copy.cases, 0..) |case, idx| {
                        var case_copy = case;
                        if (try self.rewriteStream(case_copy.body_instrs, null)) |rewritten| {
                            case_copy.body_instrs = rewritten;
                            cases_changed = true;
                        }
                        if (try self.promoteValueAtEnd(&case_copy.body_instrs, case_copy.return_value, require_owned)) |promoted| {
                            case_copy.return_value = promoted;
                            cases_changed = true;
                        }
                        new_cases[idx] = case_copy;
                    }
                    if (cases_changed) {
                        copy.cases = new_cases;
                        changed = true;
                    }
                }
                return if (changed) ir.Instruction{ .union_switch_return = copy } else null;
            },
            .optional_dispatch => |od| {
                var copy = od;
                var changed = false;
                const require_owned = self.function.result_convention == .owned;
                if (try self.rewriteStream(copy.nil_instrs, null)) |rewritten| {
                    copy.nil_instrs = rewritten;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.nil_instrs, copy.nil_result, require_owned)) |promoted| {
                    copy.nil_result = promoted;
                    changed = true;
                }
                if (try self.rewriteStream(copy.struct_instrs, null)) |rewritten| {
                    copy.struct_instrs = rewritten;
                    changed = true;
                }
                if (try self.promoteValueAtEnd(&copy.struct_instrs, copy.struct_result, require_owned)) |promoted| {
                    copy.struct_result = promoted;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .optional_dispatch = copy } else null;
            },
            .try_call_named => |tc| {
                var copy = tc;
                var changed = false;
                if (try self.rewriteStream(copy.handler_instrs, null)) |rewritten| {
                    copy.handler_instrs = rewritten;
                    changed = true;
                }
                if (try self.rewriteStream(copy.success_instrs, null)) |rewritten| {
                    copy.success_instrs = rewritten;
                    changed = true;
                }
                return if (changed) ir.Instruction{ .try_call_named = copy } else null;
            },
            .guard_block => |gb| {
                var copy = gb;
                if (try self.rewriteStream(copy.body, enclosing_aggregate_dest)) |rewritten| {
                    copy.body = rewritten;
                    return ir.Instruction{ .guard_block = copy };
                }
                return null;
            },
            else => return null,
        }
    }

    fn promoteValueAtEnd(
        self: *BorrowedResultPromoter,
        stream: *[]const ir.Instruction,
        maybe_value: ?ir.LocalId,
        require_owned: bool,
    ) error{OutOfMemory}!?ir.LocalId {
        const value = maybe_value orelse return null;
        if (!require_owned or !self.localIsBorrowed(value)) return null;
        var out: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, stream.*.len + 2);
        try out.appendSlice(self.allocator, stream.*);
        const promoted = try self.appendOwnedCopy(&out, value);
        stream.* = try out.toOwnedSlice(self.allocator);
        return promoted;
    }

    fn promoteValueBefore(
        self: *BorrowedResultPromoter,
        out: *std.ArrayListUnmanaged(ir.Instruction),
        maybe_value: ?ir.LocalId,
        require_owned: bool,
    ) error{OutOfMemory}!?ir.LocalId {
        const value = maybe_value orelse return null;
        if (!require_owned or !self.localIsBorrowed(value)) return null;
        return try self.appendOwnedCopy(out, value);
    }

    fn appendOwnedCopy(
        self: *BorrowedResultPromoter,
        out: *std.ArrayListUnmanaged(ir.Instruction),
        source: ir.LocalId,
    ) error{OutOfMemory}!ir.LocalId {
        const dest = try self.allocOwnedLocal();
        try appendCopyValueWithPersistentRetain(self.allocator, out, dest, source);
        return dest;
    }

    fn allocOwnedLocal(self: *BorrowedResultPromoter) error{OutOfMemory}!ir.LocalId {
        const dest = self.function.local_count;
        const new_len: usize = @intCast(dest + 1);
        const old = self.function.local_ownership;
        const replacement = try self.allocator.alloc(ir.OwnershipClass, new_len);
        const copy_len = @min(old.len, replacement.len);
        if (copy_len > 0) @memcpy(replacement[0..copy_len], old[0..copy_len]);
        if (copy_len < replacement.len) {
            @memset(replacement[copy_len..], .trivial);
        }
        replacement[dest] = .owned;
        self.function.local_ownership = replacement;
        self.function.local_count = dest + 1;
        return dest;
    }

    fn localIsBorrowed(self: *const BorrowedResultPromoter, local: ir.LocalId) bool {
        if (local >= self.function.local_ownership.len) return false;
        return self.function.local_ownership[local] == .borrowed;
    }

    fn localIsOwned(self: *const BorrowedResultPromoter, local: ir.LocalId) bool {
        if (local >= self.function.local_ownership.len) return false;
        return self.function.local_ownership[local] == .owned;
    }
};

/// Per-local count of borrowing-position uses (`share_value.source`
/// and chained alias sources) and total uses (any non-dest
/// reference). A `.local_get` whose dest's `borrow_use_count`
/// equals `total_use_count` is a borrow candidate; otherwise it
/// promotes to `.copy_value`.
///
/// Phase E.8 adds `tail_call_arg_use_count` so the classifier can
/// recognise the move-into-tail-call shape: a `.local_get` whose
/// dest's only use is as a tail_call argument, AND whose source's
/// only use is this `.local_get`, can be lowered as `.move_value`
/// (no caller-side retain). Without this discrimination the
/// classifier conservatively emits `.copy_value` plus a retain,
/// leaking +1 retain per iteration on deep tail-recursive workloads
/// (the exact signature observed in Phase F retry-3 — 8.75M Map
/// cells/run).
const LocalUseCounts = struct {
    borrow_use_count: u32 = 0,
    tail_call_arg_use_count: u32 = 0,
    /// Phase E.10: count of uses that occur as operands of a non-
    /// ARC aggregate-init instruction (`list_cons.head` /
    /// `list_cons.tail`, `list_init.elements[]`,
    /// `tuple_init.elements[]`, `struct_init.field.value`,
    /// `union_init.value`). When a `.local_get` whose dest's ONLY
    /// use is one of these positions is being classified, the
    /// classifier emits `.move_value` instead of `.copy_value` so
    /// the source's owns bit is transferred to dest. Combined with
    /// the parallel liveness rule (aggregate-init operands clear
    /// the operand's owns bit, mirroring `tail_call`), this makes
    /// the aggregate the durable owner of the stored cell — the
    /// scope-exit destroy that today's `.copy_value` + scope-exit
    /// release combination fires (and which freed the underlying
    /// cell while the bump-allocated aggregate retained the now-
    /// dangling pointer) is suppressed.
    aggregate_store_use_count: u32 = 0,
    /// Phase 4 (dense Map): count of uses that flow into a
    /// `share_value` whose enclosing call has owned-consume semantics
    /// — either the callee's matching param convention is `.owned`,
    /// OR the callee is a builtin slot that can accept a last-use
    /// owner directly (see `arc_liveness.builtinArgCanMoveAtLastUse`).
    /// When a `.local_get`'s dest's ONLY use is one of these
    /// positions, the classifier emits `.move_value` instead of
    /// `.copy_value` so the source's owns bit transfers cleanly into
    /// the consume site (after `rewriteOwnedConsumeSites` /
    /// `rewriteOwnedConsumeBuiltinSites` rewrite the share_value).
    /// Without this signal the classifier picks the conservative
    /// `.copy_value` plus a retain, which raises the cell to refcount
    /// 2 BEFORE the runtime-side rc-1 fast path can fire — defeating
    /// the dense-Map optimisation entirely.
    owned_consume_use_count: u32 = 0,
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

    /// Phase E.8: record a use of `local` that occurs as a
    /// `tail_call` argument. The tail-call site is a special
    /// "consume" position: the callee inherits ownership through
    /// the tail jump and the caller's frame goes away. When a
    /// local's ONLY use is in this position, classifying its
    /// producing `.local_get` as `.move_value` (no retain) is
    /// strictly cheaper than `.copy_value` plus a retain and paired
    /// release without losing correctness.
    fn recordTailCallArgUse(
        self: *UseSummary,
        allocator: std.mem.Allocator,
        local: ir.LocalId,
    ) !void {
        const gop = try self.counts.getOrPut(allocator, local);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total_use_count += 1;
        gop.value_ptr.tail_call_arg_use_count += 1;
    }

    /// Phase E.10: record a use of `local` that occurs as an
    /// operand of a non-ARC aggregate-init instruction. Aggregate-
    /// init sites are "consume" positions for ARC values: list,
    /// tuple, struct, and union cells are bump-allocated and never
    /// call retain on their stored elements, so the storage acts
    /// as a durable +1 holder. When a `.local_get`'s dest is used
    /// only here, the classifier emits `.move_value` so the
    /// source's owns bit transfers cleanly into the aggregate's
    /// implicit ownership without an extra retain.
    fn recordAggregateStoreUse(
        self: *UseSummary,
        allocator: std.mem.Allocator,
        local: ir.LocalId,
    ) !void {
        const gop = try self.counts.getOrPut(allocator, local);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total_use_count += 1;
        gop.value_ptr.aggregate_store_use_count += 1;
    }

    /// Phase 4 (dense Map): record a use of `local` that occurs as
    /// the source of a `share_value` whose dest will be rewritten to
    /// `move_value` because the receiving call has owned-consume
    /// semantics. The share is effectively a consume site, not a
    /// borrow + retain.
    fn recordOwnedConsumeUse(
        self: *UseSummary,
        allocator: std.mem.Allocator,
        local: ir.LocalId,
    ) !void {
        const gop = try self.counts.getOrPut(allocator, local);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total_use_count += 1;
        gop.value_ptr.owned_consume_use_count += 1;
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
    return collectUseSummaryWithProgram(allocator, function, summary, null);
}

fn collectUseSummaryWithProgram(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    summary: *UseSummary,
    program: ?*const ir.Program,
) !void {
    // Phase H.5: pre-collect the set of share_value dests whose
    // matching call's callee param convention is `.owned`. Those
    // shares will be rewritten to `move_value` by
    // `rewriteOwnedConsumeSites`, so the upstream chain that feeds
    // the share's source must own `+1` — `move_value` transfers
    // ownership and has nothing to transfer if the upstream is a
    // borrow. Recording the share's source use as non-borrow here
    // forces the producer's `local_get` to lower as `.copy_value`
    // plus an explicit retain instead of `.borrow_value`, so the move
    // has a real `+1` to transfer at the eventual call site.
    var consume_share_dests: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
    defer consume_share_dests.deinit(allocator);
    if (program) |prog| {
        try collectConsumeShareDests(allocator, function, prog, &consume_share_dests);
    }

    const Walker = struct {
        allocator: std.mem.Allocator,
        summary: *UseSummary,
        consume_share_dests: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
        err: ?anyerror = null,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (self.err != null) return;
            recordInstructionUses(self.allocator, self.summary, instr, self.consume_share_dests) catch |e| {
                self.err = e;
            };
        }
    };
    var walker = Walker{ .allocator = allocator, .summary = summary, .consume_share_dests = &consume_share_dests };
    ir.forEachInstruction(function, &walker, Walker.visit);
    if (walker.err) |e| return e;
}

/// Pre-pass for `collectUseSummaryWithProgram`. Walks every
/// instruction stream in `function` and records the LocalId of
/// each `share_value` whose dest flows into a call whose callee
/// param convention at the matching slot is `.owned`. Those
/// `share_value` sites will be rewritten to `move_value` by
/// `rewriteOwnedConsumeSites`, and the classifier needs to know
/// in advance so it doesn't emit a `borrow_value` upstream that
/// the move can't transfer through.
fn collectConsumeShareDests(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    consume_share_dests: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) !void {
    var index = try ConventionIndex.build(allocator, program);
    defer index.deinit();

    for (function.body) |block| {
        try collectConsumeShareDestsInStream(allocator, block.instructions, &index, consume_share_dests);
    }
}

fn collectConsumeShareDestsInStream(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    index: *const ConventionIndex,
    consume_share_dests: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        try collectConsumeShareDestsInInstr(allocator, instr, index, consume_share_dests);
    }

    // Within the same stream, scan for call sites whose owned-arg
    // slots reference a share_value's dest produced earlier in
    // this stream. The same pattern `rewriteOwnedConsumeSites`
    // uses to find share/release pairs — share_values and the
    // call that consumes them never cross structural boundaries.
    //
    // Two sources of owned-arg slots:
    //   * regular calls (call_named/call_direct/try_call_named) whose
    //     callee's `param_conventions` was promoted to `.owned` by
    //     `arc_param_convention.inferConventions`.
    //   * call_builtin invocations of curated consuming builtin
    //     slots — owned-mutating receivers plus list element writer
    //     values. Recognised by name/slot via
    //     `arc_liveness.builtinArgCanMoveAtLastUse`.
    var i: usize = 0;
    while (i < stream.len) : (i += 1) {
        // First check: regular calls with `.owned` convention slots.
        if (callArgs(stream[i])) |args| {
            if (lookupCalleeConventionsForCall(index, &stream[i])) |conventions| {
                const slot_count = @min(args.len, conventions.len);
                var slot: usize = 0;
                while (slot < slot_count) : (slot += 1) {
                    if (conventions[slot] != .owned) continue;
                    const arg_local = args[slot];
                    var j: usize = i;
                    while (j > 0) {
                        j -= 1;
                        if (stream[j] == .share_value and stream[j].share_value.dest == arg_local) {
                            try consume_share_dests.put(allocator, arg_local, {});
                            break;
                        }
                    }
                }
            }
        }
        // Second check: call_builtin owned-mutating intrinsics. The
        // callArgs() helper deliberately does NOT include call_builtin
        // (it's used by the convention-based logic above which doesn't
        // apply to runtime targets), so handle the builtin case
        // explicitly here.
        if (stream[i] == .call_builtin) {
            const cb = stream[i].call_builtin;
            for (cb.args, 0..) |arg_local, slot| {
                if (!arc_liveness.builtinArgCanMoveAtLastUse(cb.name, slot)) continue;
                var j: usize = i;
                while (j > 0) {
                    j -= 1;
                    if (stream[j] == .share_value and stream[j].share_value.dest == arg_local) {
                        try consume_share_dests.put(allocator, arg_local, {});
                        break;
                    }
                }
            }
        }
    }
}

/// Recurse into every nested sub-stream via the canonical enumerator
/// (covers `union_switch.else_instrs`, previously skipped) so the
/// per-stream consume-share scan in `collectConsumeShareDestsInStream`
/// runs over every region.
fn collectConsumeShareDestsInInstr(
    allocator: std.mem.Allocator,
    instr: *const ir.Instruction,
    index: *const ConventionIndex,
    consume_share_dests: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) error{OutOfMemory}!void {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        index: *const ConventionIndex,
        consume_share_dests: *std.AutoHashMapUnmanaged(ir.LocalId, void),
        err: ?error{OutOfMemory} = null,
        fn onStream(self_ctx: *@This(), child: ir.ChildStream) void {
            if (self_ctx.err != null) return;
            collectConsumeShareDestsInStream(self_ctx.allocator, child.stream, self_ctx.index, self_ctx.consume_share_dests) catch |e| {
                self_ctx.err = e;
            };
        }
    };
    var ctx = Ctx{ .allocator = allocator, .index = index, .consume_share_dests = consume_share_dests };
    ir.forEachChildStream(instr, &ctx, Ctx.onStream);
    if (ctx.err) |e| return e;
}

fn lookupCalleeConventionsForCall(
    index: *const ConventionIndex,
    instr: *const ir.Instruction,
) ?[]const ir.ParamConvention {
    switch (instr.*) {
        .call_direct => |cd| return index.lookupById(cd.function),
        .call_named => |cn| {
            if (index.lookupByName(cn.name)) |conventions| return conventions;
            // Cross-struct fallback: when the per-struct
            // `classifyAndNormalize` runs against an IR that doesn't
            // contain the callee function (most commonly `List:i64.set`
            // and friends — defined in the `List` struct, called
            // from any other struct), the lookup above returns null
            // and the share leading into the call gets treated as a
            // borrow position. The downstream `rewriteOwnedConsumeSites`
            // pass on the merged IR DOES rewrite the share to a
            // `move_value`, but the upstream `local_get` was already
            // baked into a `borrow_value` by the per-struct classifier
            // — leaving a `borrow_value -> move_value` chain whose
            // borrow lacks the +1 ownership the move needs to transfer.
            //
            // The fix: recognise the canonical owned-mutating-wrapper
            // name pattern `<Container>__<method>__<arity>` even when
            // the function isn't in the per-struct program, and
            // synthesise conventions where slot 0 is `.owned`. This
            // matches the convention `arc_param_convention.inferConventions`
            // will eventually assign to those wrappers on the merged IR.
            //
            // Conservative: only triggers for the curated set of
            // owned-mutating wrappers in `arc_liveness.ownedMutatingBuiltinSlot`'s
            // namespace (Map.{put,delete,merge}, List.{set,push,pop,append}
            // and their typed peers); other unresolved names continue
            // to return null.
            if (calleeConventionsFromOwnedWrapperName(cn.name)) |conv| return conv;
            return null;
        },
        else => return null,
    }
}

/// Synthesise a `param_conventions` slice for an owned-mutating Zap
/// thin wrapper based on its name pattern. Returns the static
/// `OWNED_RECEIVER_CONVENTIONS` slice (slot 0 = `.owned`, rest
/// `.trivial`) when the name decomposes as
/// `<Container>__<method>__<arity>` and `<Container>.<method>`
/// matches `arc_liveness.ownedMutatingBuiltinSlot`. Returns null
/// otherwise.
///
/// This is the per-struct fallback for `lookupCalleeConventionsForCall`
/// when the cross-struct callee isn't in the local program. The merged-
/// IR pass will eventually assign these conventions canonically via
/// `arc_param_convention.inferConventions`; the synthetic slice keeps
/// the per-struct classifier's `consume_share_dests` collection accurate
/// in the meantime, so the upstream `local_get` lowers to `.move_value`
/// instead of the unsound `.borrow_value -> move_value` chain.
fn calleeConventionsFromOwnedWrapperName(name: []const u8) ?[]const ir.ParamConvention {
    // Parse `<Container>__<method>__<arity>`. The container can
    // contain digits / underscores (e.g. encoded container names), but the
    // separator pattern `__<method>__<arity>` is unambiguous: scan
    // backward for `__`, that delimits arity from method, then scan
    // backward again for `__` to find the container/method boundary.
    if (std.mem.lastIndexOf(u8, name, "__")) |arity_sep| {
        // Validate the arity portion is purely digits.
        const arity_str = name[arity_sep + 2 ..];
        if (arity_str.len == 0) return null;
        for (arity_str) |c| {
            if (c < '0' or c > '9') return null;
        }
        // Walk backward from `arity_sep` to find the `__` delimiting
        // method from container.
        if (arity_sep < 2) return null;
        const before_arity = name[0..arity_sep];
        if (std.mem.lastIndexOf(u8, before_arity, "__")) |method_sep| {
            const container = name[0..method_sep];
            const method = name[method_sep + 2 .. arity_sep];
            // Recompose as `<Container>.<method>` for the
            // owned-mutating-builtin name matcher.
            var dotted_buf: [128]u8 = undefined;
            const total = container.len + 1 + method.len;
            if (total >= dotted_buf.len) return null;
            @memcpy(dotted_buf[0..container.len], container);
            dotted_buf[container.len] = '.';
            @memcpy(dotted_buf[container.len + 1 ..][0..method.len], method);
            const dotted = dotted_buf[0..total];
            if (arc_liveness.ownedMutatingBuiltinSlot(dotted)) |slot| {
                if (slot != 0) return null; // we currently only handle slot-0 wrappers
                return &OWNED_RECEIVER_CONVENTIONS;
            }
        }
    }
    return null;
}

/// Pre-allocated convention slice for owned-mutating-wrapper synthesis.
/// Slot 0 is `.owned` (the receiver consumes its arg); subsequent
/// slots default to `.trivial`. The slice is sized to cover the
/// arity of every owned-mutating wrapper currently recognised
/// (Map.put: 3, List.set: 3, List.append: 2, etc.) — extending
/// is safe; the consumer slices into the prefix.
const OWNED_RECEIVER_CONVENTIONS = [_]ir.ParamConvention{
    .owned,
    .trivial,
    .trivial,
    .trivial,
    .trivial,
    .trivial,
    .trivial,
    .trivial,
};

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
    consume_share_dests: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
) !void {
    switch (instr.*) {
        .share_value => |sv| {
            // Caller-side share is the canonical borrow-shape: the
            // share produces a fresh local that pairs with a post-
            // call release. The source local stays live across the
            // share; no ownership transfers to the share's dest.
            //
            // Phase H.5 / Phase 4: when the share's dest will be
            // rewritten to `move_value` by `rewriteOwnedConsumeSites`
            // (callee param convention `.owned`) or by
            // `rewriteOwnedConsumeBuiltinSites` (call_builtin name
            // matches `ownedMutatingBuiltinSlot`), the share is *not*
            // a borrow position — it becomes an ownership transfer.
            // Tag the source's use as `owned_consume`, which lets
            // `shouldMoveIntoOwnedConsume` (below) lower the upstream
            // `.local_get` as `.move_value` instead of the
            // conservative `.copy_value`. Without the move, the
            // copy's retain bumps refcount to 2 BEFORE the runtime
            // rc-1 fast path can fire, defeating the dense-Map
            // optimisation entirely.
            const is_consume_share = consume_share_dests.contains(sv.dest);
            if (is_consume_share) {
                try summary.recordOwnedConsumeUse(allocator, sv.source);
            } else {
                try summary.recordUse(allocator, sv.source, true);
            }
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
        // Phase E.10 — aggregate-store positions are special "consume"
        // positions, NOT ordinary non-borrow uses. The classifier needs
        // to recognise these so it can emit `.move_value` (instead of
        // the conservative `.copy_value`) when a `.local_get`'s dest's
        // only use lands in one of these slots. Map IS ARC-managed and
        // its `Map.put` substrate retains stored children correctly,
        // so `.map_init` is excluded from this consume-position set —
        // its operands continue to be ordinary non-borrow uses.
        .tuple_init => |ti| {
            for (ti.elements) |elem| try summary.recordAggregateStoreUse(allocator, elem);
        },
        .list_init => |li| {
            for (li.elements) |elem| try summary.recordAggregateStoreUse(allocator, elem);
        },
        .list_cons => |lc| {
            try summary.recordAggregateStoreUse(allocator, lc.head);
            try summary.recordAggregateStoreUse(allocator, lc.tail);
        },
        .map_init => |mi| {
            for (mi.entries) |entry| {
                try summary.recordUse(allocator, entry.key, false);
                // FCC residual-4 (Map-of-boxes): a boxed `Callable` map VALUE
                // is consumed into the map cell (see the `map_init` consume in
                // `arc_liveness.applyOwnsEffect`), so it is an aggregate-store
                // position — a `local_get` whose only use is the map value can
                // lower as `move_value` (transfer ownership into the cell)
                // instead of the conservative `copy_value` + retain. A NON-box
                // value keeps the Map.put-retains contract (`recordUse(false)`).
                if (mi.value_type == .protocol_box) {
                    try summary.recordAggregateStoreUse(allocator, entry.value);
                } else {
                    try summary.recordUse(allocator, entry.value, false);
                }
            }
        },
        .struct_init => |si| {
            for (si.fields) |field| try summary.recordAggregateStoreUse(allocator, field.value);
        },
        .union_init => |ui| {
            try summary.recordAggregateStoreUse(allocator, ui.value);
        },
        .box_as_protocol => |bx| {
            // The inner value is stored into the box's heap slot — an
            // aggregate-store position. The box claims ownership at
            // construction (the matching release runs through the
            // vtable's synthetic `__drop__` slot when the box dies),
            // so the source's `.local_get` can lower as `.move_value`
            // when the source's only remaining use is this box site.
            try summary.recordAggregateStoreUse(allocator, bx.value);
        },
        .protocol_dispatch => |pd| {
            // Dispatch reads the receiver and each non-receiver arg.
            // The receiver itself is a borrow at the dispatch site —
            // ownership of the box stays with the surrounding scope
            // whose scope-exit drop pairs against the construction.
            try summary.recordUse(allocator, pd.receiver, false);
            for (pd.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .protocol_box_unbox => |bu| {
            // Unbox reads the box without transferring ownership; the
            // extracted value is a borrowed view backed by the box's
            // heap cell.
            try summary.recordUse(allocator, bu.box, false);
        },
        .protocol_box_vtable_eq => |ve| {
            // The runtime type-test guard (Phase 3.a) reads the box's
            // vtable slot without transferring ownership; the box stays
            // owned by the surrounding scope (the rescue landing pad),
            // whose scope-exit drop pairs against the recovery.
            try summary.recordUse(allocator, ve.box, false);
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
            // Phase E.8: tail-call args are recorded specially so
            // the classifier can detect dests whose ONLY use is
            // here and emit `.move_value` (no retain) for the
            // matching `.local_get`.
            for (tc.args) |arg| try summary.recordTailCallArgUse(allocator, arg);
        },
        .try_call_named => |tcn| {
            for (tcn.args) |arg| try summary.recordUse(allocator, arg, false);
        },
        .error_catch => |ec| {
            try summary.recordUse(allocator, ec.source, false);
            try summary.recordUse(allocator, ec.catch_value, false);
        },
        // Phase 3.b: error-union unwrap reads its source (the call result).
        .unwrap_error_union => |ueu| try summary.recordUse(allocator, ueu.source, false),
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
        .match_variant_tag => |mvt| try summary.recordUse(allocator, mvt.scrutinee, false),
        .variant_payload_get => |vpg| try summary.recordUse(allocator, vpg.scrutinee, false),
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
        // Typed-undefined placeholder uses no locals — its operand is the
        // interned `undef` value.
        .typed_undef => {},
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
        // Phase 3.b: a propagating raise is a pure error-return terminator.
        // The boxed error's ownership flow (out through the side-channel to
        // the recovering handler) is accounted for by the preceding
        // recoverable_raise call instruction, exactly like Phase 3.a.
        .ret_raise => {},
        // Debug-info markers do not affect ownership analysis. Treat
        // `.dbg_var` as a non-consuming use of its named local so the
        // ownership classifier does not promote the operand into an
        // owned-consume site for a debug marker.
        .dbg_stmt => {},
        .dbg_var => |dv| {
            try summary.recordUse(allocator, dv.value, true);
        },
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

/// Phase E.8: decide whether a `.local_get{dest, source}` should
/// be lowered as `.move_value` instead of `.copy_value`. Returns
/// `true` when ALL of these hold:
///
///   * dest is ARC-managed (`.owned` in `local_ownership`).
///   * dest's only use is a `tail_call` argument
///     (`tail_call_arg_use_count == total_use_count == 1`).
///   * source is at LAST-USE at this `.local_get`
///     (path-sensitive: `ownership.isLastUseAt(source, local_get_id)`).
///
/// Under these preconditions the move is safe:
///   * Source owns +1; the move transfers that ownership to dest
///     without bumping the refcount. Source becomes dead at the
///     move site (arc_liveness's forward dataflow already clears
///     source's bit on `.move_value`, so no scope-exit drop fires).
///   * Dest's owned +1 enters the tail_call arg slot. The
///     tail_call's existing arg-handling already excludes arg
///     locals from scope-exit drops (the callee inherits
///     ownership through the tail jump).
///   * The callee's borrowing parameter convention does not
///     decrement the cell. Net per-iteration retain delta is 0.
///
/// Path-sensitive last-use: a flat `source_counts.total_use_count == 1`
/// check would over-reject when the source has earlier reads that
/// are themselves last-uses on their own paths (e.g., a `borrow_value`
/// used as a share-source for an intermediate call). Those earlier
/// reads do not extend the source's live range past this `local_get`
/// when the live-set dataflow has already cleared the source's bit
/// before this point. Mirrors the path-sensitive refinement applied
/// to `shouldMoveIntoOwnedConsume` (Phase 1.4) and
/// `shouldMoveIntoAggregate`.
///
/// Without this discrimination, the conservative `.copy_value`
/// emits a retain on source's cell that has no matching release
/// (the post-call release was elided as a tail-call arg cleanup
/// by the rewriter — see Phase E.6 / E.8 orphan-share fix). The
/// missing release accumulates +1 per iteration, producing the
/// exact pool-leak signature observed in Phase F's retry-3.
///
/// The spectral-norm cascade: `iterate`'s tail call to itself
/// passes a destructured `v_after` (slot 1). Without path-sensitive
/// last-use, the source's earlier read as a `borrow_value` for the
/// previous `ata_times_u` call's share argument blocks the move,
/// the classifier emits `copy_value` (refcount bumps to 2), and
/// the dataflow downgrades the resulting dest to non-unique. The
/// interprocedural fixpoint then cascades that demotion through
/// `ata_times_u → at_times_u → List.set`, defeating 50% of the
/// `List.set` calls' fast-path uniqueness rewrite.
fn shouldMove(
    function: *const ir.Function,
    summary: *const UseSummary,
    ownership: *const arc_liveness.ArcOwnership,
    dest: ir.LocalId,
    source: ir.LocalId,
    local_get_id: arc_liveness.InstructionId,
) bool {
    // Dest must be ARC-managed; trivial dests get no ARC ops at all
    // and the move/copy distinction is moot.
    if (dest >= function.local_ownership.len) return false;
    if (function.local_ownership[dest] != .owned) return false;
    // Source must be ARC-managed too (a trivial source can't
    // transfer +1 ownership; nothing to move).
    if (source >= function.local_ownership.len) return false;
    if (function.local_ownership[source] != .owned) return false;

    const dest_counts = summary.get(dest);
    if (dest_counts.total_use_count != 1) return false;
    if (dest_counts.tail_call_arg_use_count != 1) return false;

    // Path-sensitive last-use: the source must be dead immediately
    // after this read on the local_get's execution path. Multiple
    // last-use sites per source (one per branch of an if/case where
    // the binding is read in every arm) all satisfy this predicate
    // independently, mirroring the live-set dataflow's per-arm
    // answer. A flat `source.total_use_count == 1` would over-reject
    // when the source has earlier reads (e.g., a `borrow_value`)
    // whose own last-use site lies before this local_get.
    //
    // Fallback to the flat `total_use_count == 1` check when the
    // analyzer has no `last_use_sites` populated (typical of unit
    // tests with hand-rolled IR). The flat check is sound but
    // strictly weaker; production code paths always provide a
    // populated ownership table.
    if (ownership.last_use_sites.count() == 0) {
        const source_counts = summary.get(source);
        return source_counts.total_use_count == 1;
    }
    return ownership.isLastUseAt(source, local_get_id);
}

/// Phase E.10: decide whether a `.local_get{dest, source}` should
/// be lowered as `.move_value` instead of `.copy_value` because
/// dest's only use is an aggregate-store operand position. Returns
/// `true` when ALL of these hold:
///
///   * dest is ARC-managed (`.owned` in `local_ownership`).
///   * dest's only use is an aggregate-init operand
///     (`aggregate_store_use_count == total_use_count == 1`).
///   * source is ARC-managed and its only use is this `.local_get`
///     (`source.total_use_count == 1`). With more than one use, the
///     source's other use sites still need the cell alive, so the
///     classifier must fall back to `.copy_value` to keep both
///     owner aliases viable.
///
/// Aggregate-init slots (`list_cons.head/tail`, `list_init.elements`,
/// `tuple_init.elements`, `struct_init.field.value`, `union_init.value`)
/// are non-ARC bump-allocated cells. They never retain stored elements
/// and they are never freed via the ARC runtime, so the only way to
/// keep the stored cell alive is to suppress the scope-exit destroy on
/// the alias that fed the operand. `.move_value` (paired with the
/// matching liveness rule in `arc_liveness.applyOwnsEffect`) achieves
/// this: source's owns bit clears at the move, dest's owns bit clears
/// at the aggregate-init, and the cell's existing `+1` from its
/// producer (the `.map_init` / call-result that originally created the
/// owner) becomes the durable refcount the aggregate's stored pointer
/// rides on.
///
/// Note on Map: `.map_init` is intentionally NOT in this consume-
/// position set. Map cells are themselves ARC-managed and `Map.put`
/// retains its inserted value (Phase 6 substrate). A `.local_get`
/// flowing into `.map_init.entry.value` therefore continues to
/// classify as `.copy_value` — the Map runtime's retain handles the
/// stored cell's lifetime, so the conservative copy is correct.
/// Phase 4 (dense Map): decide whether a `.local_get{dest, source}`
/// should be lowered as `.move_value` because dest's only use is
/// feeding a `share_value` whose receiving call has owned-consume
/// semantics (callee param convention is `.owned` OR callee is an
/// owned-mutating call_builtin like `Map.put`). Returns `true` when:
///
///   * dest is ARC-managed (`.owned` in `local_ownership`).
///   * source is ARC-managed (`.owned`) too.
///   * dest's only use is an owned-consume share
///     (`owned_consume_use_count == total_use_count == 1`).
///   * source is at last-use at this `.local_get` along the local_get's
///     execution path. Path-sensitive — the flat
///     `total_use_count == 1` check would over-reject when the source
///     is a binding read in every arm of an `if_expr` / `case_block`
///     (each arm reads the binding once; total flat count is N, but
///     along any one execution path it's 1). The path-sensitive
///     `ArcOwnership.isLastUseAt` predicate answers exactly the
///     question we need: "is the source dead immediately after this
///     local_get on this execution path?"
///
/// Mirrors `shouldMoveIntoAggregate` but for the owned-consume share-
/// value position. Without this rule the classifier picks
/// `.copy_value` plus a retain at every working-dictionary `Map.put`
/// chain step, the runtime sees refcount >= 2, and the rc-1 fast
/// path never fires — turning every put into a full buffer copy and
/// regressing k-nucleotide back into the multi-minute regime.
///
/// Phase 1.4 path-sensitive refinement: with the flat use-counter,
/// an `if_expr` like
///
///     if cond { cleared } else { count_kmers_loop(..., cleared) }
///
/// records `total_use_count == 2` for the `cleared` binding (one read
/// per arm), so the conservative `.copy_value` fired in the else
/// arm even though `cleared` is at last-use along that path. The copy
/// retains the cell to refcount 2, demoting the receiver's uniqueness
/// uniqueness on entry to `count_kmers_loop`, which cascades to demote
/// every owned-consume site reachable through the call. Replacing the
/// flat source-count check with `ArcOwnership.isLastUseAt` recognises
/// that `cleared`'s read in the else arm IS its last use on that
/// path, allowing the move and preserving the chain of unique-on-entry
/// guarantees through the recursion.
fn shouldMoveIntoOwnedConsume(
    function: *const ir.Function,
    summary: *const UseSummary,
    ownership: *const arc_liveness.ArcOwnership,
    dest: ir.LocalId,
    source: ir.LocalId,
    local_get_id: arc_liveness.InstructionId,
) bool {
    if (dest >= function.local_ownership.len) return false;
    if (function.local_ownership[dest] != .owned) return false;
    if (source >= function.local_ownership.len) return false;
    if (function.local_ownership[source] != .owned) return false;

    const dest_counts = summary.get(dest);
    if (dest_counts.total_use_count != 1) return false;
    if (dest_counts.owned_consume_use_count != 1) return false;

    // Path-sensitive: the source must be at last-use here. The
    // `local_get` instruction's id keys into `last_use_sites`; a hit
    // means the source is dead immediately after this read on the
    // local_get's execution path. Multiple last-use sites per source
    // (one per branch of an if/case where the binding is read in
    // every arm) all satisfy this predicate independently, mirroring
    // the live-set dataflow's per-arm answer.
    if (!ownership.isLastUseAt(source, local_get_id)) return false;

    return true;
}

fn shouldMoveIntoAggregate(
    function: *const ir.Function,
    summary: *const UseSummary,
    ownership: *const arc_liveness.ArcOwnership,
    dest: ir.LocalId,
    source: ir.LocalId,
    local_get_id: arc_liveness.InstructionId,
) bool {
    if (dest >= function.local_ownership.len) return false;
    if (function.local_ownership[dest] != .owned) return false;
    if (source >= function.local_ownership.len) return false;
    if (function.local_ownership[source] != .owned) return false;

    const dest_counts = summary.get(dest);
    if (dest_counts.total_use_count != 1) return false;
    if (dest_counts.aggregate_store_use_count != 1) return false;

    // Phase 2.2 — path-sensitive last-use check on the source (same
    // as `shouldMoveIntoOwnedConsume`'s Phase 1.4 refinement). The
    // flat `total_use_count == 1` over-rejects when the source is a
    // binding read in every arm of an `if_expr` / `case_block` (each
    // arm reads the binding once; total flat count is N, but along
    // any one execution path it's 1). The path-sensitive predicate
    // matches the same correctness criterion already used by the
    // owned-consume path: source is dead immediately after this read
    // along the local_get's execution path.
    //
    // Fallback to the flat `total_use_count == 1` check when the
    // analyzer has no `last_use_sites` populated (typical of unit
    // tests with hand-rolled IR). The flat check is sound but
    // strictly weaker; production code paths always provide a
    // populated ownership table.
    if (ownership.last_use_sites.count() == 0) {
        const source_counts = summary.get(source);
        return source_counts.total_use_count == 1;
    }
    return ownership.isLastUseAt(source, local_get_id);
}

const StreamRewriter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    use_summary: *const UseSummary,
    /// Live-set side table. Used by `shouldMoveIntoOwnedConsume` to
    /// answer the path-sensitive "is the source at last-use here?"
    /// question via `ArcOwnership.isLastUseAt`. Without this signal,
    /// the flat `total_use_count == 1` predicate over-counts uses
    /// across mutually-exclusive arms (e.g., a binding read in every
    /// arm of an `if_expr`), forcing the conservative `.copy_value`
    /// path and defeating uniqueness at every owned-consume site downstream.
    ownership: *const arc_liveness.ArcOwnership,
    /// Running InstructionId mirrored from `arc_liveness`'s depth-
    /// first traversal. Tracked so per-`local_get` queries against
    /// `ownership.last_use_sites` use the same id space the analyzer
    /// recorded.
    next_id: arc_liveness.InstructionId = 0,

    /// Rewrite one instruction stream. Returns `null` when no
    /// rewriting was needed. Otherwise returns a freshly-allocated
    /// slice in `self.allocator`.
    fn rewriteStream(
        self: *StreamRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First pass: assign InstructionIds to each top-level entry,
        // recurse into nested streams, and collect any rebuilt
        // children. The id assignment mirrors
        // `arc_liveness.flattenStream`'s DFS traversal so the ids we
        // record match those used in `ownership.last_use_sites`.
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var top_level_ids: std.ArrayListUnmanaged(arc_liveness.InstructionId) = .empty;
        defer top_level_ids.deinit(self.allocator);
        try top_level_ids.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const id = self.next_id;
            self.next_id += 1;
            try top_level_ids.append(self.allocator, id);
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
            const local_get_id = top_level_ids.items[i];

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
                    } else if (shouldMove(self.function, self.use_summary, self.ownership, lg.dest, lg.source, local_get_id)) {
                        // Phase E.8 + Phase 1.4 path-sensitive refinement:
                        // dest's only use is a tail_call arg AND
                        // source is at last-use here. Emit
                        // `.move_value` to transfer ownership without
                        // a retain. The arc_liveness forward dataflow
                        // on `.move_value` clears source's owned bit
                        // and sets dest's, so no scope-exit release
                        // fires for source; the tail_call arg-set
                        // handling already suppresses the destroy on
                        // dest.
                        try new_instrs.append(self.allocator, .{
                            .move_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                    } else if (shouldMoveIntoAggregate(self.function, self.use_summary, self.ownership, lg.dest, lg.source, local_get_id)) {
                        // Phase E.10: dest's only use is an aggregate-
                        // init operand AND source's only use is this
                        // read. Aggregate-init operand positions are
                        // consume sites (mirroring `tail_call`): the
                        // bump-allocated cell takes implicit ownership
                        // of the stored value. Emit `.move_value` so
                        // the source's owns bit transfers cleanly to
                        // dest, and rely on the matching liveness
                        // rule in `arc_liveness.applyOwnsEffect` to
                        // clear dest's owns bit at the aggregate-init
                        // (so neither owner alias's scope-exit destroy
                        // fires on the cell whose live pointer the
                        // aggregate now holds).
                        try new_instrs.append(self.allocator, .{
                            .move_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                    } else if (shouldMoveIntoOwnedConsume(self.function, self.use_summary, self.ownership, lg.dest, lg.source, local_get_id)) {
                        // Phase 4 (dense Map): dest's only use feeds an
                        // owned-mutating call site (call_named/call_direct
                        // with `.owned`-promoted convention via
                        // `arc_param_convention.inferConventions`, OR
                        // call_builtin matching `ownedMutatingBuiltinSlot`).
                        // The downstream rewrite passes
                        // (`rewriteOwnedConsumeSites` /
                        // `rewriteOwnedConsumeBuiltinSites`) turn the
                        // share_value into a `move_value` and drop the
                        // post-call release. Lowering the local_get as
                        // `.move_value` here means the source's `+1`
                        // flows through unchanged: source -> dest ->
                        // (rewritten move into call arg) -> callee
                        // consumes. Without this rule we emit
                        // `.copy_value` plus a retain and the runtime
                        // sees refcount >= 2 at the call, missing the
                        // rc-1 fast path.
                        try new_instrs.append(self.allocator, .{
                            .move_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                    } else {
                        try new_instrs.append(self.allocator, .{
                            .copy_value = .{ .dest = lg.dest, .source = lg.source },
                        });
                    }
                    // Strip the immediately-following
                    // `.retain {value=dest}` if present — it was
                    // emitted by `IrBuilder.emitLocalGet` for ARC
                    // sources. Borrow (no retain) and move (transfers
                    // ownership) supersede it.
                    //
                    // For `.copy_value` rewrites under Phase 1 Class A,
                    // we re-emit the retain explicitly with
                    // `kind = .persistent` so the IR carries the
                    // persistent-retain semantics (long-lived owner
                    // bookkeeping for Map workload share-event tracking)
                    // that the ZIR `.copy_value` handler used to emit
                    // implicitly via `retainAnyPersistent`. Now the
                    // ZIR `.copy_value` handler is pure dataflow and
                    // the IR-level retain is the single source of
                    // truth.
                    if (i + 1 < stream.len) {
                        const peek_original = stream[i + 1];
                        const peek = rebuilt_children.items[i + 1] orelse peek_original;
                        if (peek == .retain and peek.retain.value == lg.dest) {
                            const last = new_instrs.items[new_instrs.items.len - 1];
                            if (last == .copy_value) {
                                try new_instrs.append(self.allocator, .{
                                    .retain = .{ .value = lg.dest, .kind = .persistent },
                                });
                            }
                            i += 1;
                        }
                    }
                },
                .borrow_value => |bv| {
                    if (shouldBorrow(self.function, self.use_summary, bv.dest)) {
                        try new_instrs.append(self.allocator, effective);
                    } else {
                        // A merged-program re-run can discover stricter
                        // callee conventions than the per-struct pass saw.
                        // Revisit existing borrow aliases so a downstream
                        // owned-consume rewrite never moves from a borrowed
                        // source. The destination becomes an owned alias via
                        // either `.move_value` or `.copy_value`.
                        any_change = true;
                        if (bv.dest < self.function.local_ownership.len and
                            self.function.local_ownership[bv.dest] == .borrowed)
                        {
                            self.function.local_ownership[bv.dest] = .owned;
                        }
                        if (shouldMove(self.function, self.use_summary, self.ownership, bv.dest, bv.source, local_get_id)) {
                            try new_instrs.append(self.allocator, .{
                                .move_value = .{ .dest = bv.dest, .source = bv.source },
                            });
                        } else if (shouldMoveIntoAggregate(self.function, self.use_summary, self.ownership, bv.dest, bv.source, local_get_id)) {
                            try new_instrs.append(self.allocator, .{
                                .move_value = .{ .dest = bv.dest, .source = bv.source },
                            });
                        } else if (shouldMoveIntoOwnedConsume(self.function, self.use_summary, self.ownership, bv.dest, bv.source, local_get_id)) {
                            try new_instrs.append(self.allocator, .{
                                .move_value = .{ .dest = bv.dest, .source = bv.source },
                            });
                        } else {
                            try new_instrs.append(self.allocator, .{
                                .copy_value = .{ .dest = bv.dest, .source = bv.source },
                            });
                            // Phase 1 Class A: pair the .copy_value
                            // with an explicit `.retain { kind:
                            // .persistent }` so the IR carries the
                            // persistent-retain semantics. The
                            // .borrow_value → .copy_value rewrite
                            // produces a fresh persistent owner; the
                            // matching scope-exit `.release` is
                            // inserted by `arc_drop_insertion`.
                            try new_instrs.append(self.allocator, .{
                                .retain = .{ .value = bv.dest, .kind = .persistent },
                            });
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

    /// If `instr` has nested instruction streams, rewrite each one via
    /// the canonical `ir.mapChildStreams` transformer — which visits
    /// sub-streams in the exact order `arc_liveness.flattenStream`
    /// numbers them (so `next_id` stays aligned with the analyzer's id
    /// space) and now rewrites `union_switch.else_instrs`, previously
    /// skipped here. Returns a copy of `instr` with the rebuilt streams
    /// when any child changed; otherwise `null`.
    fn rewriteChildren(
        self: *StreamRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        return ir.mapChildStreams(self.allocator, instr, self, rewriteChildStream);
    }

    fn rewriteChildStream(
        self: *StreamRewriter,
        child: ir.ChildStream,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        return self.rewriteStream(child.stream);
    }
};

// ============================================================
// Phase E.9 — owned-convention call-site consume rewrite
// ============================================================
//
// `rewriteOwnedConsumeSites` walks every instruction stream in
// `function` and, for each non-tail call whose target's parameter
// convention has been promoted to `.owned` by
// `arc_param_convention.inferConventions`, rewrites the call's
// argument-preparation pair from share_value/release into
// move_value (no post-call release). The rewrite preserves the
// call's argument LocalIds — the call still references the
// `shared` local previously produced by `share_value`. After the
// rewrite that local is bound by `move_value`, which the ZIR
// backend lowers as a plain value-ref propagation (no retain). The
// post-call `release{shared_local}` is dropped because the callee
// now owns `shared_local`'s cell and is responsible for releasing
// it at scope exit (Phase B's drop-insertion filter releases
// `.owned` parameters; only `.borrowed` parameters are skipped).
//
// Why this rewrite is the load-bearing fix for the k-nucleotide
// leak signature: under the borrow-by-default ABI the caller emits
// `share_value` (retain) + `release` (post-call decrement). For a
// callee that internally consumes the value (e.g., a tail-recursive
// accumulator that creates a fresh `Map.put` result and tail-jumps
// with it), the caller's retain bumps the cell to refcount 2, the
// callee never decrements, and the caller's post-call release only
// undoes its own retain — leaving +1 on every iteration. After the
// promotion to `.owned`, the rewrite below replaces the +1 retain
// with a value-ref move (no refcount delta) and drops the
// caller's release; the callee's scope-exit drop becomes the sole
// decrement, balancing the +1 the producer emitted. Net delta per
// iteration: 0. This is the inference rule's correctness payoff.
//
// The pass operates only on call sites whose target's convention
// has been promoted. Today the inference promotes only when every
// call site (recursive AND non-recursive) consumes the source local;
// the verifier's V7 (in `arc_verifier.zig`) catches any caller that
// fails to participate in the convention.

/// Rewrite consume sites for callees whose parameter convention has
/// been promoted to `.owned`. Looks up callee conventions via the
/// program-wide name/id index built from `program.functions`.
pub fn rewriteOwnedConsumeSites(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    program: *const ir.Program,
) !void {
    var index = try ConventionIndex.build(allocator, program);
    defer index.deinit();

    var rewriter = ConsumeSiteRewriter{
        .allocator = allocator,
        .index = &index,
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

/// Index from function name (and FunctionId) to that function's
/// param_conventions slice. The index is read-only; entries point
/// directly into the program's IR.
const ConventionIndex = struct {
    by_name: std.StringHashMapUnmanaged([]const ir.ParamConvention),
    by_id: std.AutoHashMapUnmanaged(ir.FunctionId, []const ir.ParamConvention),
    allocator: std.mem.Allocator,

    fn build(
        allocator: std.mem.Allocator,
        program: *const ir.Program,
    ) !ConventionIndex {
        var idx = ConventionIndex{
            .by_name = .empty,
            .by_id = .empty,
            .allocator = allocator,
        };
        for (program.functions) |func| {
            try idx.by_name.put(allocator, func.name, func.param_conventions);
            // The local_name index is best-effort: collisions favour
            // the first registration. Fall back to `by_id` lookups
            // when the name resolves ambiguously.
            if (func.local_name.len != 0) {
                const gop = try idx.by_name.getOrPut(allocator, func.local_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = func.param_conventions;
                }
            }
            try idx.by_id.put(allocator, func.id, func.param_conventions);
        }
        return idx;
    }

    fn deinit(self: *ConventionIndex) void {
        self.by_name.deinit(self.allocator);
        self.by_id.deinit(self.allocator);
    }

    fn lookupByName(self: *const ConventionIndex, name: []const u8) ?[]const ir.ParamConvention {
        return self.by_name.get(name);
    }

    fn lookupById(self: *const ConventionIndex, id: ir.FunctionId) ?[]const ir.ParamConvention {
        return self.by_id.get(id);
    }
};

const ConsumeSiteRewriter = struct {
    allocator: std.mem.Allocator,
    index: *const ConventionIndex,

    fn rewriteStream(
        self: *ConsumeSiteRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First, recurse into any nested streams. Track per-instruction
        // whether the rebuilt copy is needed.
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const child = try self.rewriteChildren(instr);
            if (child) |_| any_change = true;
            try rebuilt_children.append(self.allocator, child);
        }

        // Identify call sites with at least one `.owned` arg slot.
        // For each such call:
        //   * Locate the most recent `share_value{dest=args[slot]}`
        //     earlier in the same stream and mark it for rewrite.
        //   * Locate the next `release{value=args[slot]}` immediately
        //     following the call (in the same stream) and mark it for
        //     elision.
        // The IrBuilder's lowering invariants make the search trivial:
        // share_values and post-call releases never cross structural
        // boundaries. They live in the same stream as the call.
        var rewrite_share_to_move: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer rewrite_share_to_move.deinit(self.allocator);
        var drop_release: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer drop_release.deinit(self.allocator);

        var i: usize = 0;
        while (i < stream.len) : (i += 1) {
            const original = stream[i];
            const effective = rebuilt_children.items[i] orelse original;
            const owned_slots = try self.collectOwnedArgSlots(effective);
            defer self.allocator.free(owned_slots);
            if (owned_slots.len == 0) continue;

            const args = callArgs(effective) orelse continue;
            for (owned_slots) |slot| {
                if (slot >= args.len) continue;
                const arg_local = args[slot];
                // Walk backward in the stream to find the most recent
                // `share_value{dest=arg_local}`. Bound the walk by `i`
                // — share_values are emitted strictly before the
                // call.
                var j: usize = i;
                while (j > 0) {
                    j -= 1;
                    const prev = rebuilt_children.items[j] orelse stream[j];
                    if (prev == .share_value and prev.share_value.dest == arg_local) {
                        try rewrite_share_to_move.put(self.allocator, j, {});
                        any_change = true;
                        break;
                    }
                }
                // Walk forward (just past the call) to find the
                // matching `release{value=arg_local}`. Stop at the
                // first non-release / non-arc-bookkeeping
                // instruction — the IrBuilder packs all post-call
                // releases together, so any other instruction means
                // the search exhausted.
                var k: usize = i + 1;
                while (k < stream.len) : (k += 1) {
                    const peek = rebuilt_children.items[k] orelse stream[k];
                    switch (peek) {
                        .release => |rel| {
                            if (rel.value == arg_local) {
                                try drop_release.put(self.allocator, k, {});
                                any_change = true;
                                break;
                            }
                            // Keep scanning past releases of OTHER
                            // arg slots — they will get their own
                            // release-drop entry when the outer
                            // iteration visits their slot.
                        },
                        else => break,
                    }
                }
            }
        }

        if (!any_change) {
            return null;
        }

        // Build the rebuilt stream applying both rewrite tables.
        var new_instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer new_instrs.deinit(self.allocator);
        try new_instrs.ensureTotalCapacity(self.allocator, stream.len);

        for (stream, 0..) |_, idx| {
            if (drop_release.contains(idx)) continue;
            const effective = rebuilt_children.items[idx] orelse stream[idx];
            if (rewrite_share_to_move.contains(idx)) {
                // The original was a `.share_value`; rewrite to
                // `.move_value` with the same dest/source.
                std.debug.assert(effective == .share_value);
                const sv = effective.share_value;
                try new_instrs.append(self.allocator, .{
                    .move_value = .{ .dest = sv.dest, .source = sv.source },
                });
                // Phase 1 Class A item 2: the IR builder emits
                // `.share_value` followed by `.retain { kind: .normal,
                // value: dest }` to carry the share's retain semantics
                // explicitly at the IR level. When the consume-site
                // rewriter converts the `.share_value` to `.move_value`
                // (because the call site consumes the value), the
                // following `.retain` is no longer correct — move
                // transfers ownership without bumping the refcount —
                // and must be stripped. Without this strip we'd emit
                // both a move (transfer) and a retain (bump), inflating
                // the refcount by +1 on every consume site.
                if (idx + 1 < stream.len) {
                    const peek_original = stream[idx + 1];
                    const peek = rebuilt_children.items[idx + 1] orelse peek_original;
                    if (peek == .retain and peek.retain.value == sv.dest) {
                        try drop_release.put(self.allocator, idx + 1, {});
                    }
                }
            } else {
                try new_instrs.append(self.allocator, effective);
            }
        }

        return try new_instrs.toOwnedSlice(self.allocator);
    }

    /// Rewrite every child stream via the canonical `ir.mapChildStreams`
    /// transformer — visits sub-streams in the analyzer's flatten order
    /// (so `next_id` stays aligned) and now rewrites
    /// `union_switch.else_instrs`, previously skipped here.
    fn rewriteChildren(
        self: *ConsumeSiteRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        return ir.mapChildStreams(self.allocator, instr, self, rewriteChildStream);
    }

    fn rewriteChildStream(
        self: *ConsumeSiteRewriter,
        child: ir.ChildStream,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        return self.rewriteStream(child.stream);
    }

    /// For a call instruction, return a freshly-allocated slice of
    /// arg slot indices whose callee-side `param_conventions` is
    /// `.owned`. Returns an empty slice for non-call instructions
    /// or for callees not registered in the convention index.
    fn collectOwnedArgSlots(
        self: *const ConsumeSiteRewriter,
        instr: ir.Instruction,
    ) error{OutOfMemory}![]usize {
        const callee_conv: []const ir.ParamConvention = switch (instr) {
            .call_named => |cn| self.index.lookupByName(cn.name) orelse return &.{},
            .call_direct => |cd| self.index.lookupById(cd.function) orelse return &.{},
            .try_call_named => |tcn| self.index.lookupByName(tcn.name) orelse return &.{},
            // tail_call / call_dispatch / call_closure / call_builtin
            // are NOT rewritten here:
            //   * tail_call: the IR builder's tail-call rewriter
            //     already elided share/release pairs (Phase E.8); the
            //     args reference the original sources directly and no
            //     post-call release exists.
            //   * call_dispatch: resolves to a clause group; the
            //     concrete callee (and its convention) is unknown
            //     until trampoline lowering.
            //   * call_closure / call_builtin: convention is fixed
            //     (closures borrow; builtins borrow per the runtime
            //     audit). No promotion ever applies.
            else => return &.{},
        };
        var slots: std.ArrayListUnmanaged(usize) = .empty;
        errdefer slots.deinit(self.allocator);
        for (callee_conv, 0..) |c, idx| {
            if (c == .owned) {
                try slots.append(self.allocator, idx);
            }
        }
        return slots.toOwnedSlice(self.allocator);
    }
};

/// Return the args slice of a call-shaped instruction, or null for
/// non-call instructions.
fn callArgs(instr: ir.Instruction) ?[]const ir.LocalId {
    return switch (instr) {
        .call_named => |cn| cn.args,
        .call_direct => |cd| cd.args,
        .try_call_named => |tcn| tcn.args,
        else => null,
    };
}

// ============================================================
// Phase 4 (dense Map) — owned-mutating call_builtin consume rewrite
// ============================================================
//
// `rewriteOwnedConsumeBuiltinSites` walks every instruction stream in
// `function` and, for each `call_builtin` consuming slot known to the
// runtime ABI, rewrites that arg's preparation pair from `share_value`
// / post-call `release` into `move_value` / (no post-call release)
// when the source local of the share is at last-use at the share site.
// For slots that are always consumed but whose source is not at last
// use (`List.push` / `List.set` element values), the pass keeps the
// share and drops only the post-call release; the list now owns the
// temporary retain.
//
// This is the codegen counterpart to the dense Map's rc-1 fast path
// (`runtime.zig::Map(K,V).putInner` / `deleteInner`). Without this
// rewrite, every `:zig.Map.put` enters the runtime with refcount >= 2
// (caller's `share_value` retains), the rc-1 check fails, and the
// runtime always clones — turning every put into a full buffer copy
// with a deep-retain of every existing K/V.
//
// Why this is a per-call-site rewrite (Option A) rather than a callee-
// convention promotion (Option B): the receiver of a `call_builtin`
// is a runtime function written in Zig, not a Zap `pub fn`, so there
// is no `Function.param_conventions` slice to promote. The rewriter
// therefore reads the per-instruction last-use signal directly from
// `arc_liveness.ArcOwnership.last_use_map`. The matching consume
// effect in the analyzer's dataflow lives in
// `arc_liveness.applyOwnsEffect`'s `.call_builtin` branch.
//
// Soundness: the rewrite fires only when `last_use_map[source] ==
// share_value_id`, i.e. the source local has no further reads after
// the share. Substituting `share_value` (assign + retain) with
// `move_value` (assign only, transfer ownership) is therefore
// equivalent to the original share/release pair: the original
// retained then released the cell; the rewrite skips both ops. The
// runtime's owned-mutating function consumes the +1 the producer
// originally emitted, which is the same +1 the share would have
// retained-then-released.
//
// Companion to `rewriteOwnedConsumeSites` (Option B for `call_named`/
// `call_direct` targets with `.owned` param conventions). Both passes
// exist because user code goes through two layers when calling
// `Map.put`:
//   1. user code → `Map.put` (Zap fn) — handled by Option B (param
//      convention promoted by `arc_param_convention.inferConventions`,
//      then call site rewritten by `rewriteOwnedConsumeSites`).
//   2. `Map.put` body → `:zig.Map.put` (call_builtin to runtime) —
//      handled by THIS pass (Option A; per-call-site last-use gate).

/// Rewrite consume sites for consuming `call_builtin` invocations.
/// Reads `last_use_map` from `fn_ownership` to gate each rewrite —
/// move rewrites only fire when the source local is at its last use at
/// the matching `share_value` site. Release drops for always-consumed
/// slots do not require last-use. The pass mutates `function.body` in
/// place via `@constCast` at the seam (the slice header is `const` to
/// the rest of the IR but writeable here by design, mirroring
/// `rewriteOwnedConsumeSites`).
///
/// The pass MUST run before `arc_ownership.classifyAndNormalize`
/// rewrites `local_get` instructions, because that pass also strips
/// the immediately-following `retain` instruction it emitted, which
/// changes the instruction count and therefore the InstructionId
/// assignment. By running before classify, the IR shape matches the
/// shape the analyzer saw when populating `last_use_map`, so the
/// share's instruction id can be reproduced by walking the IR in the
/// same depth-first order the analyzer used.
pub fn rewriteOwnedConsumeBuiltinSites(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    fn_ownership: *const arc_liveness.ArcOwnership,
) !void {
    var rewriter = BuiltinConsumeSiteRewriter{
        .allocator = allocator,
        .function = function,
        .ownership = fn_ownership,
    };

    for (function.body, 0..) |_, block_index| {
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const original = block_ptr.instructions;
        rewriter.next_id = computeStreamStartIdForBlock(function, block_index);
        const rebuilt = try rewriter.rewriteStream(original);
        if (rebuilt) |new_slice| {
            block_ptr.instructions = new_slice;
        }
    }
}

/// Compute the InstructionId that arc_liveness.assignInstructionIds
/// (via `flattenStream`) would have assigned to the first instruction
/// of `function.body[block_index]`. We reproduce that traversal here
/// so the rewriter's last-use queries hit the same ids the analyzer
/// recorded when populating `last_use_map`.
fn computeStreamStartIdForBlock(
    function: *const ir.Function,
    block_index: usize,
) arc_liveness.InstructionId {
    var id: arc_liveness.InstructionId = 0;
    var i: usize = 0;
    while (i < block_index) : (i += 1) {
        id = countStreamInstructionIds(function.body[i].instructions, id);
    }
    return id;
}

fn countStreamInstructionIds(
    stream: []const ir.Instruction,
    start_id: arc_liveness.InstructionId,
) arc_liveness.InstructionId {
    var id = start_id;
    for (stream) |*instr| {
        id += 1;
        id = countNestedStreamInstructionIds(instr, id);
    }
    return id;
}

/// Count the InstructionIds occupied by `instr`'s nested sub-streams,
/// recursing via the canonical `ir.forEachChildStream` so the numbering
/// matches `arc_liveness.flattenChildren` exactly — including
/// `union_switch.else_instrs`, previously skipped here, which had shifted
/// every subsequent id below the analyzer's key.
fn countNestedStreamInstructionIds(
    instr: *const ir.Instruction,
    start_id: arc_liveness.InstructionId,
) arc_liveness.InstructionId {
    const Ctx = struct {
        id: arc_liveness.InstructionId,
        fn onStream(self: *@This(), child: ir.ChildStream) void {
            self.id = countStreamInstructionIds(child.stream, self.id);
        }
    };
    var ctx = Ctx{ .id = start_id };
    ir.forEachChildStream(instr, &ctx, Ctx.onStream);
    return ctx.id;
}

const BuiltinConsumeSiteRewriter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    ownership: *const arc_liveness.ArcOwnership,
    /// Running InstructionId mirrored from arc_liveness's traversal.
    next_id: arc_liveness.InstructionId = 0,

    fn rewriteStream(
        self: *BuiltinConsumeSiteRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First pass: assign InstructionIds to each top-level entry,
        // recurse into nested streams, and collect any rebuilt
        // children. The recursion must walk in the same depth-first
        // order as arc_liveness.flattenStream so the ids we record
        // line up with last_use_map entries.
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var top_level_ids: std.ArrayListUnmanaged(arc_liveness.InstructionId) = .empty;
        defer top_level_ids.deinit(self.allocator);
        try top_level_ids.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const id = self.next_id;
            self.next_id += 1;
            try top_level_ids.append(self.allocator, id);
            const child = try self.rewriteChildren(instr);
            if (child) |_| any_change = true;
            try rebuilt_children.append(self.allocator, child);
        }

        // Second pass: scan call_builtin sites whose ABI consumes one
        // or more argument owners. Rc1 mutator receivers (`Map.put`,
        // `List.append`, ...) only consume the receiver when the
        // source is at last-use, so those sites rewrite share->move
        // under the analyzer's last-use gate. List element writers
        // (`List.push(value)`, `List.set(index, value)`) always
        // consume the element owner because the runtime stores it
        // directly into the list buffer. When the source is not at
        // last-use, keep the share but drop its post-call release so
        // the list owns that temporary retain. When the argument is a
        // borrowed alias, rewrite that borrow to a copy so the runtime
        // receives a real owner to consume. Always-consuming
        // constructors (`List.cons`) follow the same ownership rule.
        var rewrite_share_to_move: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer rewrite_share_to_move.deinit(self.allocator);
        var rewrite_borrow_to_copy: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer rewrite_borrow_to_copy.deinit(self.allocator);
        var drop_release: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer drop_release.deinit(self.allocator);
        var drop_retain: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer drop_retain.deinit(self.allocator);

        var i: usize = 0;
        while (i < stream.len) : (i += 1) {
            const original = stream[i];
            const effective = rebuilt_children.items[i] orelse original;
            const cb = switch (effective) {
                .call_builtin => |x| x,
                else => continue,
            };

            for (cb.args, 0..) |arg_local, slot| {
                const can_move_at_last_use = arc_liveness.builtinArgCanMoveAtLastUse(cb.name, slot);
                const always_consumed = arc_liveness.alwaysConsumingBuiltinArg(cb.name, slot);
                if (!can_move_at_last_use and !always_consumed) continue;

                const share_site = self.findShareBefore(
                    stream,
                    rebuilt_children.items,
                    top_level_ids.items,
                    i,
                    arg_local,
                );

                var moved = false;
                if (share_site) |site| {
                    if (can_move_at_last_use) {
                        // Last-use gate: only rewrite when the source
                        // local is dead immediately after the share. The
                        // analyzer records the share_value's instruction
                        // id as the source's last use exactly in that
                        // case.
                        if (self.ownership.last_use_map.get(site.share.source)) |last_use| {
                            if (last_use == site.id and
                                sourceOwnsForConsumeRewrite(self.function, site.share.source))
                            {
                                try rewrite_share_to_move.put(self.allocator, site.index, {});
                                if (findShareRetain(
                                    stream,
                                    rebuilt_children.items,
                                    site.index + 1,
                                    site.share.dest,
                                )) |retain_index| {
                                    try drop_retain.put(self.allocator, retain_index, {});
                                }
                                any_change = true;
                                moved = true;
                            }
                        }
                    }

                    if (moved or always_consumed) {
                        if (try self.markPostCallReleaseDrop(
                            stream,
                            rebuilt_children.items,
                            i,
                            arg_local,
                            &drop_release,
                        )) {
                            any_change = true;
                        }
                    }
                    continue;
                }

                if (always_consumed) {
                    if (try self.planBorrowedConsumeCopy(
                        stream,
                        rebuilt_children.items,
                        i,
                        arg_local,
                        &rewrite_borrow_to_copy,
                    )) {
                        any_change = true;
                        if (try self.markPostCallReleaseDrop(
                            stream,
                            rebuilt_children.items,
                            i,
                            arg_local,
                            &drop_release,
                        )) {
                            any_change = true;
                        }
                    }
                }
            }
        }

        if (!any_change) return null;

        var new_instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer new_instrs.deinit(self.allocator);
        try new_instrs.ensureTotalCapacity(self.allocator, stream.len + rewrite_borrow_to_copy.count());

        for (stream, 0..) |_, idx| {
            if (drop_release.contains(idx)) continue;
            if (drop_retain.contains(idx)) continue;
            const effective = rebuilt_children.items[idx] orelse stream[idx];
            if (rewrite_share_to_move.contains(idx)) {
                std.debug.assert(effective == .share_value);
                const sv = effective.share_value;
                try new_instrs.append(self.allocator, .{
                    .move_value = .{ .dest = sv.dest, .source = sv.source },
                });
            } else if (rewrite_borrow_to_copy.contains(idx)) {
                std.debug.assert(effective == .borrow_value);
                const borrow = effective.borrow_value;
                try appendCopyValueWithPersistentRetain(self.allocator, &new_instrs, borrow.dest, borrow.source);
            } else {
                try new_instrs.append(self.allocator, effective);
            }
        }
        return try new_instrs.toOwnedSlice(self.allocator);
    }

    const ShareSite = struct {
        index: usize,
        id: arc_liveness.InstructionId,
        share: ir.ShareValue,
    };

    fn findShareBefore(
        self: *BuiltinConsumeSiteRewriter,
        stream: []const ir.Instruction,
        rebuilt_children: []const ?ir.Instruction,
        top_level_ids: []const arc_liveness.InstructionId,
        call_index: usize,
        arg_local: ir.LocalId,
    ) ?ShareSite {
        _ = self;
        var j: usize = call_index;
        while (j > 0) {
            j -= 1;
            const prev = rebuilt_children[j] orelse stream[j];
            if (prev == .share_value and prev.share_value.dest == arg_local) {
                return .{
                    .index = j,
                    .id = top_level_ids[j],
                    .share = prev.share_value,
                };
            }
        }
        return null;
    }

    fn markPostCallReleaseDrop(
        self: *BuiltinConsumeSiteRewriter,
        stream: []const ir.Instruction,
        rebuilt_children: []const ?ir.Instruction,
        call_index: usize,
        arg_local: ir.LocalId,
        drop_release: *std.AutoHashMapUnmanaged(usize, void),
    ) error{OutOfMemory}!bool {
        // Walk forward from call_index+1 looking for the matching
        // `release{value=arg_local}`. The IR builder packs all
        // post-call releases together immediately after the call,
        // so any non-release instruction terminates the search.
        var k: usize = call_index + 1;
        while (k < stream.len) : (k += 1) {
            const peek = rebuilt_children[k] orelse stream[k];
            switch (peek) {
                .release => |rel| {
                    if (rel.value == arg_local) {
                        try drop_release.put(self.allocator, k, {});
                        return true;
                    }
                    // Keep scanning past releases of OTHER locals;
                    // they will get their own release-drop entry when
                    // the outer iteration reaches their slot.
                },
                else => return false,
            }
        }
        return false;
    }

    fn planBorrowedConsumeCopy(
        self: *BuiltinConsumeSiteRewriter,
        stream: []const ir.Instruction,
        rebuilt_children: []const ?ir.Instruction,
        call_index: usize,
        arg_local: ir.LocalId,
        rewrite_borrow_to_copy: *std.AutoHashMapUnmanaged(usize, void),
    ) error{OutOfMemory}!bool {
        if (arg_local >= self.function.local_ownership.len) return false;
        if (self.function.local_ownership[arg_local] != .borrowed) return false;

        const borrow_index = findPrecedingBorrowValue(
            stream,
            rebuilt_children,
            call_index,
            arg_local,
        ) orelse return false;
        const borrow_instr = rebuilt_children[borrow_index] orelse stream[borrow_index];
        std.debug.assert(borrow_instr == .borrow_value);
        const borrow = borrow_instr.borrow_value;
        if (!sourceCellIsLifetimeExtended(self.function, borrow.source)) return false;

        try rewrite_borrow_to_copy.put(self.allocator, borrow_index, {});
        self.function.local_ownership[arg_local] = .owned;
        return true;
    }

    /// Rewrite every child stream via the canonical `ir.mapChildStreams`
    /// transformer — visits sub-streams in the analyzer's flatten order
    /// (so `next_id` stays aligned) and now rewrites
    /// `union_switch.else_instrs`, previously skipped here.
    fn rewriteChildren(
        self: *BuiltinConsumeSiteRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        return ir.mapChildStreams(self.allocator, instr, self, rewriteChildStream);
    }

    fn rewriteChildStream(
        self: *BuiltinConsumeSiteRewriter,
        child: ir.ChildStream,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        return self.rewriteStream(child.stream);
    }
};

fn sourceOwnsForConsumeRewrite(function: *const ir.Function, source: ir.LocalId) bool {
    if (paramIndexForLocal(function, source)) |index| {
        if (index >= function.param_conventions.len) return false;
        return function.param_conventions[index] == .owned;
    }
    if (source >= function.local_ownership.len) return false;
    return function.local_ownership[source] == .owned;
}

fn paramIndexForLocal(function: *const ir.Function, local: ir.LocalId) ?u32 {
    const Visitor = struct {
        target: ir.LocalId,
        result: ?u32 = null,

        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (self.result != null) return;
            switch (instr.*) {
                .param_get => |param_get| {
                    if (param_get.dest == self.target) self.result = param_get.index;
                },
                else => {},
            }
        }
    };

    var visitor = Visitor{ .target = local };
    ir.forEachInstruction(function, &visitor, Visitor.visit);
    return visitor.result;
}

// ============================================================
// Phase H/uniqueness (dense Map) — codegen rewrite to unchecked variants
// ============================================================
//
// `rewriteUncheckedUniquenessSites` is the codegen counterpart to the uniqueness
// static-uniqueness analysis (`uniqueness.zig`). The analysis
// produces a per-call-site predicate: at this owned-mutating call,
// is the receiver provably refcount=1 by construction? When the
// answer is yes, the runtime's rc==1 fast path will fire — but the
// runtime still pays a per-call cost for the atomic load + branch
// that decides between the unique-mutate and shared-clone paths.
//
// This pass closes that gap. At every owned-mutating call site
// (`Map.put` / `.delete` / `.merge`, `List.set` / `.push` / `.pop`
// / `.append` and their post-monomorph encoded variants — see
// `arc_liveness.ownedMutatingBuiltinSlot`) where uniqueness = true, we swap
// the call's name to its `_owned_unchecked` peer. The unchecked
// variant has an identical Zig signature and identical post-state
// semantics; it just skips the rc-load-and-branch.
//
// Safety: the uniqueness verifier (`arc_verifier.runUniquenessCheck`) re-runs the
// analysis after this rewrite and rejects any unchecked call where
// uniqueness was not proven. A wrong rewrite here is therefore
// caught by the verifier rather than reaching the runtime.
//
// Pipeline placement (per docs/dense-map-implementation-plan.md
// §1.6):
//
//     ... → rewriteOwnedConsumeBuiltinSites   (Phase 4)
//          → classifyAndNormalize             (borrow/copy)
//             → rewriteOwnedConsumeSites      (Phase E.9.2)
//                → rewriteUncheckedUniquenessSites    (THIS PASS)
//                   → arc_verifier.verify     (V1-uniqueness — uniqueness catches mistakes)
//                      → arc_drop_insertion
//                         → ...
//
// This pass runs AFTER classifyAndNormalize and the Phase E.9.2
// owned-consume rewrite for two reasons:
//   1. The IR shape consumed by uniqueness must match the post-classification
//      shape (move_value / borrow_value / copy_value all decided);
//      the Phase 4 / E.9.2 rewrites give us that shape.
//   2. The verifier runs immediately after this pass on the
//      post-rewrite IR, so the verifier sees exactly what codegen
//      will emit.
//
// The rewrite is purely a name swap: arg list, dest local, arg modes,
// and surrounding instructions are unchanged. Only `call_builtin.name`
// (or `call_named.name` / `try_call_named.name`) is rewritten.

/// Rewrite owned-mutating call sites whose uniqueness predicate holds to use
/// the `*_owned_unchecked` runtime variant. Reads `uniqueness` to
/// gate per-site rewrites; sites where uniqueness fails are left untouched
/// (the checked variant is correct).
///
/// `uniqueness` MUST have been computed against the SAME IR shape
/// `function` currently presents — i.e., after every prior pass that
/// could mutate instruction streams. Run this pass after
/// `classifyAndNormalize` and `rewriteOwnedConsumeSites` so the
/// instruction-id traversal aligns with the analysis.
///
/// Two rewrite shapes are produced:
///
///   1. `call_builtin "Map.put"` -> `call_builtin "Map.put_owned_unchecked"`
///      (and List / monomorphized peers). The name is rewritten in
///      place; arg list, dest, and arg modes are preserved verbatim.
///
///   2. `call_named "Map__put__3"` (or similar mangled name to a Zap
///      thin wrapper whose body forwards to an owned-mutating
///      call_builtin) -> `call_builtin "<runtime_name>_owned_unchecked"`.
///      The wrapper is bypassed entirely: we look at the wrapper's
///      body, lift the runtime call name, and emit the unchecked
///      variant directly. The wrapper itself is unchanged (other
///      callers without uniqueness still go through it).
///
/// `program` is required to resolve call_named callees to their
/// wrapper bodies. Without `program`, only call_builtin sites are
/// rewritten (used by the unit tests).
pub fn rewriteUncheckedUniquenessSites(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
) !void {
    return rewriteUncheckedUniquenessSitesWithProgram(allocator, function, uniqueness, null);
}

/// Variant of `rewriteUncheckedUniquenessSites` that takes a program reference
/// so call_named sites to Zap thin wrappers can be rewritten to
/// call_builtin to the unchecked runtime variant. Used by the
/// production pipeline (`compiler.zig::runArcOwnershipAndVerify`);
/// unit tests that don't need the call_named rewrite call the
/// no-program variant.
pub fn rewriteUncheckedUniquenessSitesWithProgram(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
    program: ?*const ir.Program,
) !void {
    return rewriteUncheckedUniquenessSitesInternal(allocator, function, uniqueness, program, null);
}

/// Rewrite unchecked uniqueness sites and also mark flat-buffer
/// `.list_tail` instructions as source-consuming when the source list
/// is both proven unique and at last-use. This lets list destructuring
/// lower to `slice_owned_unchecked` without changing the safe clone
/// fallback for shared or still-live sources.
pub fn rewriteUncheckedUniquenessSitesWithOwnership(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
    program: ?*const ir.Program,
    ownership: *const arc_liveness.ArcOwnership,
) !void {
    return rewriteUncheckedUniquenessSitesInternal(allocator, function, uniqueness, program, ownership);
}

fn rewriteUncheckedUniquenessSitesInternal(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
    program: ?*const ir.Program,
    ownership: ?*const arc_liveness.ArcOwnership,
) !void {
    var rewriter = UncheckedUniquenessSiteRewriter{
        .allocator = allocator,
        .function = function,
        .uniqueness = uniqueness,
        .program = program,
        .ownership = ownership,
    };

    for (function.body, 0..) |_, block_index| {
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const original = block_ptr.instructions;
        rewriter.next_id = computeStreamStartIdForBlock(function, block_index);
        const rebuilt = try rewriter.rewriteStream(original);
        if (rebuilt) |new_slice| {
            block_ptr.instructions = new_slice;
        }
    }
}

/// Construct the unchecked peer of `name`. Returns `null` if `name`
/// is not an owned-mutating builtin or already an unchecked variant.
///
/// Examples:
///   "Map.put"                  -> "Map.put_owned_unchecked"
///   "Map:i64:i64.put"          -> "Map:i64:i64.put_owned_unchecked"
///   "List:i64.set"             -> "List:i64.set_owned_unchecked"
///   "List.push"                -> "List.push_owned_unchecked"
///   "Map.put_owned_unchecked"  -> null  (already unchecked)
///   "Map.get"                  -> null  (not owned-mutating)
fn allocUncheckedName(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]const u8 {
    if (arc_liveness.isUncheckedOwnedMutatingBuiltin(name)) return null;
    if (arc_liveness.ownedMutatingBuiltinSlot(name) == null) return null;
    return try std.fmt.allocPrint(allocator, "{s}_owned_unchecked", .{name});
}

const UncheckedUniquenessSiteRewriter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
    program: ?*const ir.Program,
    ownership: ?*const arc_liveness.ArcOwnership,
    /// Running InstructionId mirrored from
    /// `arc_liveness.assignInstructionIds` / `uniqueness.Analyzer`'s
    /// depth-first walk. The id at each owned-mutating call site must
    /// match the id under which uniqueness recorded its predicate; otherwise
    /// the rewrite would consult the wrong site.
    next_id: arc_liveness.InstructionId = 0,

    /// Per-site rewrite plan: either rename the existing call (in
    /// place name swap) or replace the whole instruction (turn a
    /// call_named to a thin wrapper into a direct call_builtin to the
    /// unchecked runtime variant).
    const SiteRewrite = union(enum) {
        rename: []const u8,
        replace: ir.Instruction,
    };

    fn rewriteStream(
        self: *UncheckedUniquenessSiteRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First pass: recurse into nested streams, assign ids, and
        // collect any rebuilt children. The recursion mirrors
        // `uniqueness.Analyzer.walkStream`'s DFS so per-call ids
        // line up with the analysis's recorded predicate.
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var top_level_ids: std.ArrayListUnmanaged(arc_liveness.InstructionId) = .empty;
        defer top_level_ids.deinit(self.allocator);
        try top_level_ids.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const id = self.next_id;
            self.next_id += 1;
            try top_level_ids.append(self.allocator, id);
            const child = try self.rewriteChildren(instr);
            if (child) |_| any_change = true;
            try rebuilt_children.append(self.allocator, child);
        }

        // Second pass: scan for owned-mutating call sites whose uniqueness
        // predicate is true; queue per-call rewrites.
        var plan: std.AutoHashMapUnmanaged(usize, SiteRewrite) = .empty;
        defer plan.deinit(self.allocator);
        var rewrite_borrow_to_copy: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer rewrite_borrow_to_copy.deinit(self.allocator);

        for (stream, 0..) |_, idx| {
            const effective = rebuilt_children.items[idx] orelse stream[idx];
            const id = top_level_ids.items[idx];
            if (!self.uniqueness.isUnique(id)) continue;

            if (self.planListTailConsume(effective, id)) |replacement| {
                try plan.put(self.allocator, idx, .{ .replace = replacement });
                any_change = true;
                continue;
            }

            // Direct builtin name swap.
            if (ownedMutatingCallName(effective)) |checked_name| {
                if (try allocUncheckedName(self.allocator, checked_name)) |unchecked| {
                    try plan.put(self.allocator, idx, .{ .rename = unchecked });
                    any_change = true;
                    continue;
                }
            }

            // Zap-fn wrapper (call_named / call_direct / try_call_named):
            // bypass the wrapper by lifting its body's runtime call
            // and emitting the unchecked variant directly.
            if (try self.planCalleeBypass(effective)) |bypass| {
                if (try self.planConsumedBorrowArgCopies(
                    stream,
                    rebuilt_children.items,
                    idx,
                    bypass,
                    &rewrite_borrow_to_copy,
                )) {
                    any_change = true;
                }
                try plan.put(self.allocator, idx, .{ .replace = bypass });
                any_change = true;
            }
        }

        if (!any_change) return null;

        var new_instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer new_instrs.deinit(self.allocator);
        try new_instrs.ensureTotalCapacity(self.allocator, stream.len + rewrite_borrow_to_copy.count());

        for (stream, 0..) |_, idx| {
            const effective = rebuilt_children.items[idx] orelse stream[idx];
            if (plan.get(idx)) |rewrite| {
                switch (rewrite) {
                    .rename => |new_name| try new_instrs.append(self.allocator, withRenamedCall(effective, new_name)),
                    .replace => |new_instr| try new_instrs.append(self.allocator, new_instr),
                }
            } else if (rewrite_borrow_to_copy.contains(idx)) {
                std.debug.assert(effective == .borrow_value);
                const borrow = effective.borrow_value;
                try appendCopyValueWithPersistentRetain(self.allocator, &new_instrs, borrow.dest, borrow.source);
            } else {
                try new_instrs.append(self.allocator, effective);
            }
        }

        return try new_instrs.toOwnedSlice(self.allocator);
    }

    fn planConsumedBorrowArgCopies(
        self: *UncheckedUniquenessSiteRewriter,
        stream: []const ir.Instruction,
        rebuilt_children: []const ?ir.Instruction,
        call_index: usize,
        replacement: ir.Instruction,
        rewrite_borrow_to_copy: *std.AutoHashMapUnmanaged(usize, void),
    ) error{OutOfMemory}!bool {
        const call_builtin = switch (replacement) {
            .call_builtin => |call| call,
            else => return false,
        };

        var changed = false;
        for (call_builtin.args, 0..) |arg_local, slot| {
            if (!arc_liveness.alwaysConsumingBuiltinArg(call_builtin.name, slot)) continue;
            if (arg_local >= self.function.local_ownership.len) continue;
            if (self.function.local_ownership[arg_local] != .borrowed) continue;

            const borrow_idx = findPrecedingBorrowValue(
                stream,
                rebuilt_children,
                call_index,
                arg_local,
            ) orelse continue;
            const borrow = (rebuilt_children[borrow_idx] orelse stream[borrow_idx]).borrow_value;
            if (!sourceCellIsLifetimeExtended(self.function, borrow.source)) continue;

            try rewrite_borrow_to_copy.put(self.allocator, borrow_idx, {});
            self.function.local_ownership[arg_local] = .owned;
            changed = true;
        }
        return changed;
    }

    fn planListTailConsume(
        self: *UncheckedUniquenessSiteRewriter,
        instr: ir.Instruction,
        id: arc_liveness.InstructionId,
    ) ?ir.Instruction {
        const ownership = self.ownership orelse return null;
        const lt = switch (instr) {
            .list_tail => |value| value,
            else => return null,
        };
        if (lt.consume_source) return null;
        if (!sourceOwnsForConsumeRewrite(self.function, lt.list)) return null;
        if (!ownership.isLastUseAt(lt.list, id)) {
            if (ownership.last_use_map.get(lt.list)) |last_use| {
                if (last_use != id) return null;
            } else {
                return null;
            }
        }
        var copy = lt;
        copy.consume_source = true;
        return ir.Instruction{ .list_tail = copy };
    }

    /// If `instr` is a call to a Zap thin wrapper that forwards to an
    /// owned-mutating runtime call_builtin, return a `call_builtin`
    /// instruction that bypasses the wrapper and invokes the
    /// `*_owned_unchecked` runtime variant directly. Returns null
    /// when the call is not a recognised wrapper shape, when the
    /// program reference is absent, or when no uniqueness-eligible runtime
    /// call is found inside the wrapper body.
    ///
    /// The wrapper bypass is sound because:
    ///   * uniqueness holds at this site (caller's gate, checked by caller).
    ///   * The Zap wrapper has at least one `.owned` slot + `.owned`
    ///     result (the convention pair), meaning it consumes the
    ///     caller's +1 and returns a fresh +1. Bypassing forwards
    ///     the +1 directly to the runtime, which has the same
    ///     contract.
    ///   * `arg_modes`, dest, and args are preserved verbatim.
    fn planCalleeBypass(
        self: *UncheckedUniquenessSiteRewriter,
        instr: ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        const program = self.program orelse return null;
        const callee_info = calleeInfoFromCall(instr) orelse return null;
        const callee = lookupFunctionByName(program, callee_info.name) orelse
            (lookupFunctionById(program, callee_info.function_id) orelse return null);

        // Soundness gate: the wrapper MUST have at least one `.owned`
        // slot + `.owned` result convention. Without this, uniqueness wouldn't
        // have classified the call as owned-mutating, so reaching
        // here means it did, but we re-check defensively to avoid a
        // mismatch between uniqueness's classifier and ours.
        if (functionHasOwnedReceiverConvention(callee) == null) return null;

        const runtime_name = (findRuntimeOwnedMutatingCall(callee)) orelse return null;

        // Only bypass when the wrapper's body is a thin 1:1 forward
        // to the runtime intrinsic — same arity, args lined up, no
        // intermediate reshaping. The signature compatibility check
        // is structural: the bypass replacement passes the exact
        // arg list to the unchecked builtin, so the wrapper must
        // accept the same arity. Mismatched arity is a sign that the
        // wrapper does extra work (e.g., default-arg expansion or a
        // pre-call helper) that we cannot safely skip.
        if (callee.arity != callee_info.args.len) return null;

        const unchecked = (try allocUncheckedName(self.allocator, runtime_name)) orelse return null;

        return ir.Instruction{ .call_builtin = .{
            .dest = callee_info.dest,
            .name = unchecked,
            .args = callee_info.args,
            .arg_modes = callee_info.arg_modes,
            .result_type = callee.return_type,
        } };
    }

    /// Rewrite every child stream via the canonical `ir.mapChildStreams`
    /// transformer — visits sub-streams in the analyzer's flatten order
    /// (so `next_id` stays aligned) and now rewrites
    /// `union_switch.else_instrs`, previously skipped here.
    fn rewriteChildren(
        self: *UncheckedUniquenessSiteRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        return ir.mapChildStreams(self.allocator, instr, self, rewriteChildStream);
    }

    fn rewriteChildStream(
        self: *UncheckedUniquenessSiteRewriter,
        child: ir.ChildStream,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        return self.rewriteStream(child.stream);
    }
};

/// Read the callee name from an owned-mutating call site, regardless
/// of which call instruction shape it takes. Returns null when the
/// instruction is not a recognised owned-mutating call.
fn ownedMutatingCallName(instr: ir.Instruction) ?[]const u8 {
    return switch (instr) {
        .call_builtin => |cb| cb.name,
        .call_named => |cn| cn.name,
        .try_call_named => |tcn| tcn.name,
        else => null,
    };
}

const CalleeInfo = struct {
    name: []const u8,
    function_id: ?ir.FunctionId,
    dest: ir.LocalId,
    args: []const ir.LocalId,
    arg_modes: []const ir.ValueMode,
};

/// Extract the parts of a call instruction needed to build a
/// `call_builtin` replacement. Returns null when the instruction is
/// not a call shape we can rewrite (e.g., closure / dispatch calls
/// don't have a stable runtime name and aren't covered).
fn calleeInfoFromCall(instr: ir.Instruction) ?CalleeInfo {
    return switch (instr) {
        .call_named => |cn| .{
            .name = cn.name,
            .function_id = null,
            .dest = cn.dest,
            .args = cn.args,
            .arg_modes = cn.arg_modes,
        },
        .call_direct => |cd| .{
            .name = "",
            .function_id = cd.function,
            .dest = cd.dest,
            .args = cd.args,
            .arg_modes = cd.arg_modes,
        },
        .try_call_named => |tcn| .{
            .name = tcn.name,
            .function_id = null,
            .dest = tcn.dest,
            .args = tcn.args,
            .arg_modes = tcn.arg_modes,
        },
        else => null,
    };
}

/// Return the index of the first `.owned` parameter slot when
/// `function` has at least one such slot AND
/// `result_convention == .owned`. Returns null otherwise. Mirror of
/// `uniqueness.calleeFunctionOwnedReceiverSlot` to keep the
/// rewriter and analyzer in lock-step on what counts as an owned-
/// mutating Zap-fn wrapper.
fn functionHasOwnedReceiverConvention(function: *const ir.Function) ?usize {
    if (function.result_convention != .owned) return null;
    for (function.param_conventions, 0..) |conv, idx| {
        if (conv == .owned) return idx;
    }
    return null;
}

fn lookupFunctionByName(program: *const ir.Program, name: []const u8) ?*const ir.Function {
    if (name.len == 0) return null;
    for (program.functions) |*func| {
        if (std.mem.eql(u8, func.name, name)) return func;
    }
    return null;
}

fn lookupFunctionById(program: *const ir.Program, id: ?ir.FunctionId) ?*const ir.Function {
    const fid = id orelse return null;
    for (program.functions) |*func| {
        if (func.id == fid) return func;
    }
    return null;
}

/// Walk `function`'s body for the FIRST owned-mutating runtime
/// call_builtin and return its name. The Zap thin wrappers in
/// `lib/list.zap` and `lib/map.zap` each contain a single
/// forwarding `:zig.<Type>.<method>(...)` line, so the first hit is
/// the runtime call. Returns null when no owned-mutating runtime
/// call_builtin exists in the wrapper's body (the function is not a
/// thin wrapper around an owned-mutating intrinsic).
fn findRuntimeOwnedMutatingCall(function: *const ir.Function) ?[]const u8 {
    for (function.body) |block| {
        if (findRuntimeOwnedMutatingCallInStream(block.instructions)) |name| return name;
    }
    return null;
}

/// Recurse via the canonical enumerator (covers
/// `union_switch.else_instrs`, previously skipped) to find the first
/// non-unchecked owned-mutating builtin call in `stream` or any nested
/// sub-stream.
fn findRuntimeOwnedMutatingCallInStream(stream: []const ir.Instruction) ?[]const u8 {
    for (stream) |*instr| {
        if (instr.* == .call_builtin) {
            const cb = instr.call_builtin;
            if (arc_liveness.ownedMutatingBuiltinSlot(cb.name) != null and
                !arc_liveness.isUncheckedOwnedMutatingBuiltin(cb.name))
            {
                return cb.name;
            }
        }
        const Finder = struct {
            found: ?[]const u8 = null,
            fn onStream(self: *@This(), child: ir.ChildStream) void {
                if (self.found != null) return;
                if (findRuntimeOwnedMutatingCallInStream(child.stream)) |n| self.found = n;
            }
        };
        var finder = Finder{};
        ir.forEachChildStream(instr, &finder, Finder.onStream);
        if (finder.found) |n| return n;
    }
    return null;
}

/// Return a copy of `instr` with its callee name replaced by
/// `new_name`. Only the name field is rewritten; arg list, dest,
/// arg_modes, and any nested streams are preserved verbatim. The
/// caller is responsible for invoking this only on instruction
/// shapes that have a name field — `ownedMutatingCallName` returning
/// non-null is the gate.
fn withRenamedCall(instr: ir.Instruction, new_name: []const u8) ir.Instruction {
    return switch (instr) {
        .call_builtin => |cb| .{ .call_builtin = .{
            .dest = cb.dest,
            .name = new_name,
            .args = cb.args,
            .arg_modes = cb.arg_modes,
            .result_type = cb.result_type,
        } },
        .call_named => |cn| blk: {
            var copy = cn;
            copy.name = new_name;
            break :blk .{ .call_named = copy };
        },
        .try_call_named => |tcn| blk: {
            var copy = tcn;
            copy.name = new_name;
            break :blk .{ .try_call_named = copy };
        },
        else => instr,
    };
}

// ============================================================
// Phase 7 — borrowed pass-through elision
// ============================================================
//
// `elideBorrowedPassThroughShares` walks every instruction stream in
// `function` and eliminates redundant retain/release atomic round-trips
// for the canonical "borrowed pass-through" shape produced by the IR
// builder:
//
//     share_value{dest=L_shared, source=L_src}    // alias
//     retain{value=L_shared, kind=normal}         // up rc
//     call_X{... args=[..., L_shared, ...] ...}   // .borrowed slot
//     release{value=L_shared}                     // down rc
//
// When the matching callee slot convention is `.borrowed` (callee will
// not retain internally) AND `L_src` is itself `.borrowed` or `.owned`
// in the caller's `local_ownership` table, the retain/release pair is
// pure bookkeeping: the caller-side retain bumps the cell's refcount
// from N to N+1, the callee borrows it without modification, then the
// post-call release decrements back to N. Net refcount delta is 0, but
// the two atomic ops (acq_rel retain + acq_rel release) dominate
// wall-time on tight recursive numeric loops.
//
// The rewrite replaces the four-instruction sequence with a single
// `borrow_value{dest=L_shared, source=L_src}`. Net refcount delta is
// still 0; atomic ops drop from 2 to 0 per call.
//
// Soundness — why we don't need the retain
// ----------------------------------------
//
// The retain exists to extend the source cell's lifetime across the
// call: without it, if the source is moved/consumed elsewhere, the
// cell could be freed mid-call. Eliding the retain is sound IFF
// something else in the caller's scope keeps the cell alive for the
// duration of the call.
//
//   * Source is `.borrowed`: by definition, the source's owning
//     caller (one level up the call stack) holds `+1` on the cell
//     valid for the entire span the local is borrowed. Our function
//     is itself within that span, so the cell is guaranteed alive
//     across every call we make.
//
//   * Source is `.owned`: our function holds `+1` on the cell valid
//     until the matching scope-exit `release` (emitted by
//     `arc_drop_insertion`). Any call we make inside that scope sees
//     the cell alive without any additional retain.
//
//   * Source is `.trivial`: the local is non-ARC. There is no
//     refcount, no retain/release, and `share_value` was never
//     emitted for it in the first place. The IrBuilder's gating
//     check (`should_share_arc` in `lowerExpr.call`) excludes
//     non-ARC types from the share path.
//
// We therefore only need to identify the `.borrowed` / `.owned`
// cases; nothing else needs special handling. A misclassification
// toward elision when the source's cell could go to zero would be
// unsound (UAF); a missed elision costs 2 atomic ops per call. The
// rule above is conservative: it gates on `local_ownership` which is
// already set by `classifyAndNormalize` / `refineParamGetOwnership`.
//
// Why this pass runs AFTER `rewriteOwnedConsumeSites`
// ---------------------------------------------------
//
// `rewriteOwnedConsumeSites` rewrites `share_value` into `move_value`
// at every call site whose callee slot is `.owned`. Every remaining
// `share_value` after that pass therefore targets a `.borrowed` slot.
// Running the elision here lets us treat every surviving share as a
// candidate without re-checking the callee convention from scratch
// for `call_named` / `call_direct` / `try_call_named`. For
// `call_builtin` we still check the builtin ABI consume predicates to
// skip slots that the consume rewriter intentionally left alone (e.g.,
// `List.push` element values whose last-use signal didn't fire, and
// `List.cons` arguments that are always consumed by the runtime).
//
// Why this pass runs BEFORE `arc_drop_insertion`
// ----------------------------------------------
//
// After the rewrite, the share's dest local becomes `.borrowed` in
// `local_ownership`. `arc_drop_insertion` reads `local_ownership` to
// decide which locals need scope-exit `release` instructions; classing
// the now-borrowed local correctly here suppresses a spurious
// post-rewrite scope-exit release.
//
// Verifier interaction
// --------------------
//
// V1 (`release` must not target `.borrowed`): we drop the release,
// trivially satisfied.
//
// V3 (borrowed values must not escape into aggregate storage): we
// produce a `.borrowed` local that flows into a call slot, not an
// aggregate. The call's argument is `.borrowed` by convention; the
// callee never escapes its borrowed args. Trivially satisfied.
//
// V6 (`move_value` source must be `.owned`): no move involved.
//
// V7 (caller/callee convention agreement): the producer kind for
// `borrow_value` is `.other`, which V7 accepts for `.borrowed` slots.
//
// The verifier is run on the post-rewrite IR; any soundness gap
// surfaces as a hard build error rather than a runtime UAF.

/// Run the borrowed pass-through elision over `function`. `program`
/// is consulted to resolve callee `param_conventions` for
/// `call_named` / `call_direct` / `try_call_named` instructions.
pub fn elideBorrowedPassThroughShares(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    program: *const ir.Program,
) !void {
    var index = try ConventionIndex.build(allocator, program);
    defer index.deinit();

    var rewriter = BorrowedPassThroughRewriter{
        .allocator = allocator,
        .function = function,
        .index = &index,
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

const BorrowedPassThroughRewriter = struct {
    allocator: std.mem.Allocator,
    function: *ir.Function,
    index: *const ConventionIndex,

    fn rewriteStream(
        self: *BorrowedPassThroughRewriter,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        // First pass: recurse into nested streams and collect
        // rebuilt-child copies. Mirrors the structural recursion in
        // `ConsumeSiteRewriter.rewriteStream` so the elision sees the
        // post-rewrite IR for arms / cases / dispatch bodies before
        // making top-level decisions on this stream.
        var rebuilt_children: std.ArrayListUnmanaged(?ir.Instruction) = .empty;
        defer rebuilt_children.deinit(self.allocator);
        try rebuilt_children.ensureTotalCapacity(self.allocator, stream.len);

        var any_change = false;
        for (stream) |*instr| {
            const child = try self.rewriteChildren(instr);
            if (child) |_| any_change = true;
            try rebuilt_children.append(self.allocator, child);
        }

        // Identify pass-through-borrow shares to elide. For each
        // surviving share, find its matching call and the call's
        // borrowed slot, then the post-call release. All three indices
        // are recorded in `plan` so the rebuild pass can rewrite or
        // drop them in a single linear pass.
        var rewrite_share_to_borrow: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer rewrite_share_to_borrow.deinit(self.allocator);
        var drop_index: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer drop_index.deinit(self.allocator);

        var i: usize = 0;
        while (i < stream.len) : (i += 1) {
            const original = stream[i];
            const effective = rebuilt_children.items[i] orelse original;
            const args = callArgs(effective) orelse blk: {
                // `callArgs` returns null for call_builtin (intentionally,
                // since the convention-based pass doesn't apply). Handle
                // it explicitly here.
                if (effective != .call_builtin) continue;
                break :blk effective.call_builtin.args;
            };

            // Per-call: walk each arg slot. If the slot's callee
            // convention is `.borrowed` (or it's a non-consume
            // call_builtin slot), look for a preceding share_value
            // whose source ownership is `.borrowed` / `.owned`.
            //
            // For call_builtin, we skip slots that
            // `builtinArgCanMoveAtLastUse` flags as consume slots —
            // those are the responsibility of
            // `rewriteOwnedConsumeBuiltinSites`. The remainder are
            // borrow slots by ABI.
            const is_builtin = effective == .call_builtin;
            const callee_conv = if (!is_builtin)
                lookupCalleeConventionsForCall(self.index, &effective)
            else
                null;

            for (args, 0..) |arg_local, slot| {
                if (is_builtin) {
                    const builtin_name = effective.call_builtin.name;
                    // The consume-rewriter handles the consume slots;
                    // any surviving share here is on a borrow slot.
                    if (!builtinArgIsBorrowOnly(builtin_name, slot)) continue;
                } else if (callee_conv) |conv| {
                    if (slot < conv.len) {
                        // Only elide on .borrowed slots. .owned slots
                        // were already rewritten by
                        // rewriteOwnedConsumeSites; .trivial slots
                        // have non-ARC args (no share emitted at all).
                        if (conv[slot] != .borrowed) continue;
                    } else {
                        // No convention info for this slot — skip.
                        continue;
                    }
                } else {
                    // Without callee conventions we cannot prove the
                    // slot is borrowing. Conservative: skip.
                    continue;
                }

                // Walk backward in the stream to find the most recent
                // `share_value{dest=arg_local}`. Bound by `i` since
                // shares are emitted strictly before the call.
                const share_idx = findPrecedingShareValue(stream, rebuilt_children.items, i, arg_local) orelse continue;
                const share = (rebuilt_children.items[share_idx] orelse stream[share_idx]).share_value;

                // Soundness gate: source must hold `+1` independently
                // of this share (either as a borrow rooted in a higher
                // scope or as an owned local with scope-exit release).
                if (!sourceCellIsLifetimeExtended(self.function, share.source)) continue;

                // Locate the `retain{value=arg_local, kind=normal}`
                // emitted immediately after the share. The Phase 8
                // slice only certifies the complete
                // share/retain/call/release shape; if the retain is
                // already absent, leave the stream alone rather than
                // widening the proof obligation.
                const retain_idx = findShareRetain(stream, rebuilt_children.items, share_idx + 1, arg_local) orelse continue;

                // Locate the matching post-call release. Bound the
                // forward scan to the contiguous run of releases
                // following the call (the IR builder packs all per-call
                // releases together).
                const release_idx = findPostCallRelease(stream, rebuilt_children.items, i + 1, arg_local) orelse continue;

                if (arg_local >= self.function.local_ownership.len) continue;
                if (self.function.local_ownership[arg_local] != .owned) continue;
                if (countLocalDefsInFunction(self.function, arg_local) != 1) continue;
                if (countLocalUsesInFunction(self.function, arg_local) != 3) continue;
                if (!shareDestHasOnlyBorrowedCallPath(
                    stream,
                    rebuilt_children.items,
                    share_idx,
                    retain_idx,
                    i,
                    release_idx,
                    arg_local,
                )) continue;

                // All four pieces matched: schedule the rewrite.
                try rewrite_share_to_borrow.put(self.allocator, share_idx, {});
                try drop_index.put(self.allocator, retain_idx, {});
                try drop_index.put(self.allocator, release_idx, {});
                any_change = true;

                // Refine `local_ownership[arg_local]` to `.borrowed`
                // so drop insertion skips the now-borrowed alias and
                // the verifier accepts the chain.
                self.function.local_ownership[arg_local] = .borrowed;
            }
        }

        if (!any_change) return null;

        var new_instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        errdefer new_instrs.deinit(self.allocator);
        try new_instrs.ensureTotalCapacity(self.allocator, stream.len);

        for (stream, 0..) |_, idx| {
            if (drop_index.contains(idx)) continue;
            const effective = rebuilt_children.items[idx] orelse stream[idx];
            if (rewrite_share_to_borrow.contains(idx)) {
                std.debug.assert(effective == .share_value);
                const sv = effective.share_value;
                try new_instrs.append(self.allocator, .{
                    .borrow_value = .{ .dest = sv.dest, .source = sv.source },
                });
            } else {
                try new_instrs.append(self.allocator, effective);
            }
        }

        return try new_instrs.toOwnedSlice(self.allocator);
    }

    /// Rewrite every child stream via the canonical `ir.mapChildStreams`
    /// transformer — visits sub-streams in the analyzer's flatten order
    /// (so `next_id` stays aligned) and now rewrites
    /// `union_switch.else_instrs`, previously skipped here.
    fn rewriteChildren(
        self: *BorrowedPassThroughRewriter,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!?ir.Instruction {
        return ir.mapChildStreams(self.allocator, instr, self, rewriteChildStream);
    }

    fn rewriteChildStream(
        self: *BorrowedPassThroughRewriter,
        child: ir.ChildStream,
    ) error{OutOfMemory}!?[]const ir.Instruction {
        return self.rewriteStream(child.stream);
    }
};

fn builtinArgIsBorrowOnly(name: []const u8, slot: usize) bool {
    return !arc_liveness.builtinArgCanMoveAtLastUse(name, slot) and
        !arc_liveness.alwaysConsumingBuiltinArg(name, slot);
}

/// Walk backward from `before_index` to find the most recent
/// `share_value{dest = arg_local}` in `stream`. Returns the stream
/// index or null when no matching share is present in the prelude.
///
/// Honors rebuilt children: when `rebuilt_children[k]` is non-null we
/// inspect the rebuilt copy instead of `stream[k]` so structural
/// rewrites done during child recursion are visible to the share
/// match.
fn findPrecedingShareValue(
    stream: []const ir.Instruction,
    rebuilt_children: []const ?ir.Instruction,
    before_index: usize,
    arg_local: ir.LocalId,
) ?usize {
    var j: usize = before_index;
    while (j > 0) {
        j -= 1;
        const candidate = rebuilt_children[j] orelse stream[j];
        switch (candidate) {
            .share_value => |sv| if (sv.dest == arg_local) return j,
            // Stop the scan when we encounter a control-flow boundary
            // that the IR builder cannot emit a share/call sequence
            // across: any non-arc-bookkeeping instruction that mutates
            // the same arg local would be a different share or a
            // direct definition. Conservatively stop on any define of
            // `arg_local` that isn't a share.
            .local_get => |lg| if (lg.dest == arg_local) return null,
            .borrow_value => |bv| if (bv.dest == arg_local) return null,
            .copy_value => |cv| if (cv.dest == arg_local) return null,
            .move_value => |mv| if (mv.dest == arg_local) return null,
            else => {},
        }
    }
    return null;
}

/// Walk backward from `before_index` to find the most recent
/// `borrow_value{dest = arg_local}` in `stream`. Returns null when a
/// different definition of `arg_local` is encountered first.
fn findPrecedingBorrowValue(
    stream: []const ir.Instruction,
    rebuilt_children: []const ?ir.Instruction,
    before_index: usize,
    arg_local: ir.LocalId,
) ?usize {
    var j: usize = before_index;
    while (j > 0) {
        j -= 1;
        const candidate = rebuilt_children[j] orelse stream[j];
        switch (candidate) {
            .borrow_value => |bv| if (bv.dest == arg_local) return j,
            .local_get => |lg| if (lg.dest == arg_local) return null,
            .share_value => |sv| if (sv.dest == arg_local) return null,
            .copy_value => |cv| if (cv.dest == arg_local) return null,
            .move_value => |mv| if (mv.dest == arg_local) return null,
            else => {},
        }
    }
    return null;
}

/// If a `retain{value = arg_local, kind = .normal}` immediately
/// follows `start_idx`, return its index. The IR builder always emits
/// the retain immediately after the share for `.share` mode args, so
/// the search is at most one position long. The intervening positions
/// are scanned defensively to tolerate analysis passes that may insert
/// debug instructions between the share and its retain.
fn findShareRetain(
    stream: []const ir.Instruction,
    rebuilt_children: []const ?ir.Instruction,
    start_idx: usize,
    arg_local: ir.LocalId,
) ?usize {
    if (start_idx >= stream.len) return null;
    const candidate = rebuilt_children[start_idx] orelse stream[start_idx];
    if (candidate == .retain and candidate.retain.value == arg_local and candidate.retain.kind == .normal) {
        return start_idx;
    }
    return null;
}

/// Locate the post-call `release{value = arg_local}` immediately
/// following the call at `start_idx`. The IR builder packs all per-
/// call releases in a contiguous run after the call instruction, so
/// the scan walks forward past releases of OTHER arg locals without
/// matching. Stops at the first non-release instruction.
fn findPostCallRelease(
    stream: []const ir.Instruction,
    rebuilt_children: []const ?ir.Instruction,
    start_idx: usize,
    arg_local: ir.LocalId,
) ?usize {
    var k: usize = start_idx;
    while (k < stream.len) : (k += 1) {
        const candidate = rebuilt_children[k] orelse stream[k];
        switch (candidate) {
            .release => |rel| {
                if (rel.value == arg_local) return k;
                // Skip releases for OTHER arg slots — they'll get their
                // own elision plan when the outer loop visits them.
            },
            else => return null,
        }
    }
    return null;
}

/// Prove the share destination is used only by the certified borrowed
/// pass-through path:
///
///   share_value dest <- source
///   retain dest
///   borrowed call(..., dest, ...)
///   release dest
///
/// A second use of `dest` would extend the local's semantic role
/// beyond "one borrowed call argument". Rewriting such a value to
/// `borrow_value` and changing its `local_ownership` to `.borrowed`
/// could hide a real ownership edge from drop insertion or verifier
/// checks, so the pass refuses those streams.
fn shareDestHasOnlyBorrowedCallPath(
    stream: []const ir.Instruction,
    rebuilt_children: []const ?ir.Instruction,
    share_idx: usize,
    retain_idx: usize,
    call_idx: usize,
    release_idx: usize,
    arg_local: ir.LocalId,
) bool {
    var total_uses: usize = 0;
    for (stream, 0..) |original, idx| {
        const effective = rebuilt_children[idx] orelse original;
        const use_count = countLocalUsesRecursive(effective, arg_local);
        if (use_count == 0) continue;
        total_uses += use_count;

        if (idx == share_idx) {
            return false;
        } else if (idx == retain_idx) {
            if (use_count != 1) return false;
            if (effective != .retain) return false;
            const retain = effective.retain;
            if (retain.value != arg_local or retain.kind != .normal) return false;
        } else if (idx == call_idx) {
            if (use_count != 1) return false;
            if (!callUsesArgExactlyOnce(effective, arg_local)) return false;
        } else if (idx == release_idx) {
            if (use_count != 1) return false;
            if (effective != .release) return false;
            if (effective.release.value != arg_local) return false;
        } else {
            return false;
        }
    }

    return total_uses == 3;
}

fn callUsesArgExactlyOnce(instr: ir.Instruction, arg_local: ir.LocalId) bool {
    const args = callArgs(instr) orelse switch (instr) {
        .call_builtin => |call_builtin| call_builtin.args,
        else => return false,
    };
    var count: usize = 0;
    for (args) |arg| {
        if (arg == arg_local) count += 1;
    }
    return count == 1;
}

/// Count uses of `local` in `instr` and all its nested sub-streams,
/// recursing via the canonical enumerator (covers
/// `union_switch.else_instrs`, previously skipped — an undercount there
/// could flip the elideBorrowedPassThroughShares soundness gate from
/// refuse to allow). Used by the != 1 / != 3 exact-count soundness gates.
fn countLocalUsesRecursive(instr: ir.Instruction, local: ir.LocalId) usize {
    const count = countImmediateLocalUses(instr, local);
    const Ctx = struct {
        local: ir.LocalId,
        count: usize = 0,
        fn onStream(self: *@This(), child: ir.ChildStream) void {
            self.count += countLocalUsesInStream(child.stream, self.local);
        }
    };
    var ctx = Ctx{ .local = local };
    ir.forEachChildStream(&instr, &ctx, Ctx.onStream);
    return count + ctx.count;
}

fn countLocalUsesInStream(stream: []const ir.Instruction, local: ir.LocalId) usize {
    var count: usize = 0;
    for (stream) |instr| {
        count += countLocalUsesRecursive(instr, local);
    }
    return count;
}

fn countLocalUsesInFunction(function: *const ir.Function, local: ir.LocalId) usize {
    var count: usize = 0;
    for (function.body) |block| {
        count += countLocalUsesInStream(block.instructions, local);
    }
    return count;
}

fn countImmediateLocalUses(instr: ir.Instruction, local: ir.LocalId) usize {
    var uses: arc_liveness.UseList = .{};
    defer uses.deinit(std.heap.page_allocator);
    arc_liveness.collectUses(instr, &uses);

    var count: usize = 0;
    for (uses.slice()) |used_local| {
        if (used_local == local) count += 1;
    }
    switch (instr) {
        .try_call_named => |try_call_named| {
            if (try_call_named.handler_result == local) count += 1;
            if (try_call_named.success_result == local) count += 1;
        },
        else => {},
    }
    return count;
}

/// Count definitions of `local` in `instr` and all its nested
/// sub-streams, recursing via the canonical enumerator (covers
/// `union_switch.else_instrs`, previously skipped). Used by the
/// elideBorrowedPassThroughShares != 1 soundness gate.
fn countLocalDefsRecursive(instr: ir.Instruction, local: ir.LocalId) usize {
    const count = countImmediateLocalDefs(instr, local);
    const Ctx = struct {
        local: ir.LocalId,
        count: usize = 0,
        fn onStream(self: *@This(), child: ir.ChildStream) void {
            self.count += countLocalDefsInStream(child.stream, self.local);
        }
    };
    var ctx = Ctx{ .local = local };
    ir.forEachChildStream(&instr, &ctx, Ctx.onStream);
    return count + ctx.count;
}

fn countLocalDefsInStream(stream: []const ir.Instruction, local: ir.LocalId) usize {
    var count: usize = 0;
    for (stream) |instr| {
        count += countLocalDefsRecursive(instr, local);
    }
    return count;
}

fn countLocalDefsInFunction(function: *const ir.Function, local: ir.LocalId) usize {
    var count: usize = 0;
    for (function.body) |block| {
        count += countLocalDefsInStream(block.instructions, local);
    }
    return count;
}

fn countImmediateLocalDefs(instr: ir.Instruction, local: ir.LocalId) usize {
    const defs = arc_liveness.collectDefs(instr);
    var count: usize = 0;
    for (defs.slice()) |defined_local| {
        if (defined_local == local) count += 1;
    }
    return count;
}

/// Soundness predicate for the borrowed pass-through elision: does the
/// caller hold a `+1` on `source`'s cell that is independent of any
/// per-call share's retain and that spans every call within the
/// caller's scope?
///
/// True when `local_ownership[source]` is `.borrowed` or `.owned`:
///   * `.borrowed`: the upstream caller holds `+1` for the entire
///     span the source local is borrowed in this function. Every
///     call we make inside the function is within that span.
///   * `.owned`: this function holds `+1` until its scope-exit
///     `release` (emitted by `arc_drop_insertion`). Every call we
///     make before that release sees the cell alive.
///
/// False when `local_ownership[source]` is `.trivial`: not ARC-managed
/// (no refcount; share/retain never emitted; this branch is
/// defensive). Also false when the local id is out of range, which
/// indicates a malformed IR that should be rejected upstream.
fn sourceCellIsLifetimeExtended(function: *const ir.Function, source: ir.LocalId) bool {
    if (source >= function.local_ownership.len) return false;
    return switch (function.local_ownership[source]) {
        .borrowed, .owned => true,
        .trivial => false,
    };
}

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
const arc_drop_insertion = @import("arc_drop_insertion.zig");

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
/// of `.borrow_value`, `.copy_value`, and `.move_value` instructions
/// whose source equals `source_local`.
const ClassifyCounts = struct {
    borrow_count: usize = 0,
    copy_count: usize = 0,
    move_count: usize = 0,
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
                .move_value => |mv| {
                    if (mv.source == self.source_local) self.counts.move_count += 1;
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
                .move_value => self.counts.move_count += 1,
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

test "arc_ownership: borrowed param flowing through case_break is promoted to owned case result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var type_store = types_mod.TypeStore.init(std.testing.allocator, &interner);
    defer type_store.deinit();

    var element_type: ir.ZigType = .i64;
    const list_type = ir.ZigType{ .list = &element_type };
    var params = [_]ir.Param{.{
        .name = "xs",
        .type_expr = list_type,
    }};
    var param_conventions = [_]ir.ParamConvention{.borrowed};
    var local_ownership = [_]ir.OwnershipClass{
        .owned,
        .owned,
    };
    var pre_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .case_break = .{ .value = 1 } },
    };
    var instructions = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 0,
            .pre_instrs = &pre_instrs,
            .arms = &.{},
            .default_instrs = &.{},
            .default_result = null,
        } },
        .{ .ret = .{ .value = 0 } },
    };
    var blocks = [_]ir.Block{.{ .label = 0, .instructions = &instructions }};
    var function = ir.Function{
        .id = 0,
        .name = "case_identity",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = list_type,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = &param_conventions,
        .local_ownership = &local_ownership,
        .result_convention = .owned,
    };
    var ownership = arc_liveness.ArcOwnership{};
    defer ownership.deinit(alloc);

    try classifyAndNormalize(alloc, &function, &ownership, &type_store);

    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[1]);
    try std.testing.expectEqual(@as(u32, 3), function.local_count);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[2]);

    const rewritten_case = function.body[0].instructions[0].case_block;
    try std.testing.expectEqual(@as(usize, 4), rewritten_case.pre_instrs.len);
    try std.testing.expect(rewritten_case.pre_instrs[1] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten_case.pre_instrs[1].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten_case.pre_instrs[1].copy_value.source);
    try std.testing.expect(rewritten_case.pre_instrs[2] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten_case.pre_instrs[2].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten_case.pre_instrs[2].retain.kind);
    try std.testing.expect(rewritten_case.pre_instrs[3] == .case_break);
    try std.testing.expectEqual(@as(?ir.LocalId, 2), rewritten_case.pre_instrs[3].case_break.value);
}

test "arc_ownership: borrowed param through flat-case guard case_break is promoted to owned case result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var type_store = types_mod.TypeStore.init(std.testing.allocator, &interner);
    defer type_store.deinit();

    var element_type: ir.ZigType = .i64;
    const list_type = ir.ZigType{ .list = &element_type };
    var params = [_]ir.Param{.{
        .name = "xs",
        .type_expr = list_type,
    }};
    var param_conventions = [_]ir.ParamConvention{.borrowed};
    var local_ownership = [_]ir.OwnershipClass{
        .owned,
        .owned,
        .trivial,
    };
    var guard_body = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .case_break = .{ .value = 1 } },
    };
    var pre_instrs = [_]ir.Instruction{
        .{ .const_bool = .{ .dest = 2, .value = true } },
        .{ .guard_block = .{ .condition = 2, .body = &guard_body } },
    };
    var instructions = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 0,
            .pre_instrs = &pre_instrs,
            .arms = &.{},
            .default_instrs = &.{},
            .default_result = null,
        } },
        .{ .ret = .{ .value = 0 } },
    };
    var blocks = [_]ir.Block{.{ .label = 0, .instructions = &instructions }};
    var function = ir.Function{
        .id = 0,
        .name = "flat_case_guard_identity",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = list_type,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = &param_conventions,
        .local_ownership = &local_ownership,
        .result_convention = .owned,
    };
    var ownership = arc_liveness.ArcOwnership{};
    defer ownership.deinit(alloc);

    try classifyAndNormalize(alloc, &function, &ownership, &type_store);

    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[1]);
    try std.testing.expectEqual(@as(u32, 4), function.local_count);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);

    const rewritten_case = function.body[0].instructions[0].case_block;
    const rewritten_guard = rewritten_case.pre_instrs[1].guard_block;
    try std.testing.expectEqual(@as(usize, 4), rewritten_guard.body.len);
    try std.testing.expect(rewritten_guard.body[1] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten_guard.body[1].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten_guard.body[1].copy_value.source);
    try std.testing.expect(rewritten_guard.body[2] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten_guard.body[2].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten_guard.body[2].retain.kind);
    try std.testing.expect(rewritten_guard.body[3] == .case_break);
    try std.testing.expectEqual(@as(?ir.LocalId, 3), rewritten_guard.body[3].case_break.value);
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

// ============================================================
// Phase D — recursion through optional_dispatch nested streams
// ============================================================

/// Phase D test guard: skip the test cleanly if the IR builder
/// declined to emit `optional_dispatch` for the input shape.
fn ownershipFunctionContainsOptionalDispatch(function: *const ir.Function) bool {
    const Detector = struct {
        seen: bool = false,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (instr.* == .optional_dispatch) self.seen = true;
        }
    };
    var detector = Detector{};
    ir.forEachInstruction(function, &detector, Detector.visit);
    return detector.seen;
}

test "arc_ownership: classifier normalises local_get inside optional_dispatch arms (Phase D)" {
    // Phase D (Phase 6 redux plan §3.D): the classifier's
    // `rewriteChildren` and the use-summary's `forEachInstruction`
    // walker must both recurse into `optional_dispatch.nil_instrs`
    // and `struct_instrs`. Without recursion, any `.local_get`
    // inside an arm would (a) be missed by the use summary —
    // leaving its dest's borrow count unrecorded — and (b) be
    // skipped by the rewrite pass entirely, surviving past
    // arc_ownership as the legacy overloaded form. Both failures
    // would leave Phase 6.8's emitLocalGet retain in the IR with
    // no matching destroy and no verifier reach, causing leaks
    // under `.map` (Phase F).
    //
    // The Zap source uses an optional struct-or-nil parameter so
    // the IR builder synthesises an `optional_dispatch`. The arm
    // bodies introduce a named binding (`bound = h`) so the body
    // contains a `.local_get` whose dest's classification depends
    // on the use-summary built by the pre-pass. After
    // `classifyAndNormalize`, no `.local_get` may remain anywhere
    // in the function — the assertion is uniform across every
    // nesting depth.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\  pub struct Node { tag :: i64 }
        \\
        \\  pub fn pick(nil, h :: Handle) -> Handle {
        \\    bound = h
        \\    bound
        \\  }
        \\  pub fn pick(_n :: Node, h :: Handle) -> Handle {
        \\    bound = h
        \\    bound
        \\  }
        \\}
    ;
    var suite = try ClassifyTestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const pick_func = suite.findFunctionByName("pick") orelse return error.MissingFunction;
    if (!ownershipFunctionContainsOptionalDispatch(pick_func)) {
        // The IR builder declined to emit `optional_dispatch`.
        return;
    }

    // Pre-condition: at least one `.local_get` exists somewhere in
    // the function (proving the arms have something to rewrite).
    const totals_before = countAliasOpcodes(pick_func);
    try std.testing.expect(totals_before.local_get_count >= 1);

    try suite.classify(pick_func);

    // Post-condition: zero `.local_get` instructions remain — the
    // recursion structurally reached every nested stream.
    const totals_after = countAliasOpcodes(pick_func);
    try std.testing.expectEqual(@as(usize, 0), totals_after.local_get_count);
    // At least one classified opcode (borrow_value or copy_value)
    // appeared. The exact form depends on use-classification (the
    // `bound` local feeds a return whose source is a parameter,
    // which classifies as `.copy_value` per pattern 3 in the
    // existing tests).
    try std.testing.expect(totals_after.borrow_count + totals_after.copy_count >= 1);
}

// ============================================================
// Phase E.8 — move_value emission for tail-call args at last use
// ============================================================

/// Hand-constructed IR fixture for the move_value emission tests.
/// The classifier's `ownership` and `type_store` parameters are
/// unused by `classifyAndNormalize` itself (they exist for future
/// phases); we pass dummies and free everything via the test arena.
fn buildMoveValueTestFunction(
    arena: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_ownership: []const ir.OwnershipClass,
    arity: u32,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership_copy = try arena.dupe(ir.OwnershipClass, local_ownership);
    const params = try arena.alloc(ir.Param, arity);
    for (params) |*p| p.* = .{ .name = "p", .type_expr = .void, .type_id = null };
    const param_conventions = try arena.alloc(ir.ParamConvention, arity);
    for (param_conventions) |*c| c.* = .borrowed;
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = arity,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = @intCast(local_ownership.len),
        .param_conventions = param_conventions,
        .local_ownership = ownership_copy,
        .result_convention = .owned,
    };
}

test "arc_ownership: emits move_value for local_get whose dest's only use is a tail_call arg and source is at last use (Phase E.8)" {
    // Phase E.8 of the Phase 6 redux plan — tail-call arg consume.
    //
    // The k-nucleotide hot loop's leak signature traces back to a
    // `.local_get` whose dest flows directly into a self-recursive
    // tail_call argument. The classifier conservatively emits
    // `.copy_value` with a persistent retain, bumping the source
    // cell's refcount by +1 per iteration.
    // Because the post-call arg-cleanup release was already elided
    // by the tail-call rewriter (callee inherits ownership through
    // the tail jump), the orphan retain accumulates linearly with
    // iteration count — 8.75M cells/run at the production scale
    // observed in Phase F retry-3.
    //
    // The fix: detect this exact shape (`.local_get{dest, source}`
    // where dest's only use is a tail_call arg AND source's only
    // use is this read) and emit `.move_value` instead. Move
    // semantics transfer ownership without retaining; downstream
    // arc_liveness already clears source's owned bit on
    // `.move_value`, so no scope-exit release fires for source,
    // and tail_call's existing arg-set handling already excludes
    // dest from scope-exit drops.
    //
    // Hand-constructed IR mirroring the leak shape:
    //   %0 = const_int 0                  // dummy producer (any owned source works)
    //   local_get %1 <- %0                // alias for tail_call arg
    //   tail_call self args=[%1]
    //   ret null
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 1;
    const instrs = [_]ir.Instruction{
        // %0: an owned ARC value (the producer's identity is
        // immaterial to the classifier — only the ownership class
        // and use pattern matter).
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        // %1: a `.local_get` whose dest's only use is the tail_call
        // arg, and whose source's only use is this read.
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        // self-recursive tail_call consuming %1.
        .{ .tail_call = .{ .name = "self_loop", .args = args } },
    };
    // Mark both locals as `.owned` so the move_value precondition
    // (dest is ARC-managed, source is ARC-managed) is met.
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "self_loop", &instrs, &ownership, 0);

    // The classifier's ownership / type_store args are unused;
    // pass dummies via undefined since `classifyAndNormalize`
    // explicitly discards them.
    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    // No .local_get must remain after classification.
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // The move_value path must fire — exactly one .move_value
    // (the classified `.local_get` from the test fixture).
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    // No .copy_value should be emitted: the leak comes from the
    // copy_value's persistent retain.
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
    // No .borrow_value either: the dest's only use (a tail_call
    // arg) is not a borrow-position use.
    try std.testing.expectEqual(@as(usize, 0), totals.borrow_count);
}

// ============================================================
// Phase E.9 Step 2 tests — rewriteOwnedConsumeSites
// ============================================================

test "arc_ownership: rewriteOwnedConsumeSites converts share_value to move_value and drops release for owned-convention call slot" {
    // Build a 2-function program:
    //   * `target_func`: declares a single ARC-managed parameter with
    //     `.owned` convention.
    //   * `caller_func`: emits the canonical share/call/release
    //     sequence for the call. The rewriter should rewrite the
    //     share_value into a move_value and drop the post-call
    //     release.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .owned;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.owned});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    // Caller: const_int %0 ; share_value %1 <- %0 ; call_named "target" args=[%1] dest=%2 ; release %1
    // After rewrite: const_int %0 ; move_value %1 <- %0 ; call_named ... args=[%1] dest=%2
    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try rewriteOwnedConsumeSites(arena, &functions[1], &program);

    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_dest_1: bool = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_of_1 = true;
            },
            .move_value => |mv| if (mv.dest == 1 and mv.source == 0) {
                saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_release_of_1);
    try std.testing.expect(saw_move_dest_1);
}

test "arc_ownership: rewriteOwnedConsumeSites is a no-op when callee param convention stays borrowed" {
    // Same shape as the positive test but the callee declares
    // `.borrowed` convention. The rewriter must NOT touch the
    // share_value/release pair — those reflect the caller's
    // ABI-correct retain/decrement and replacing them with
    // move_value would underflow the source's refcount on the next
    // use.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try rewriteOwnedConsumeSites(arena, &functions[1], &program);

    // The stream must be unchanged: share_value still present,
    // release still present, no move_value with dest=1.
    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_dest_1: bool = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_of_1 = true;
            },
            .move_value => |mv| if (mv.dest == 1 and mv.source == 0) {
                saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_of_1);
    try std.testing.expect(!saw_move_dest_1);
}

test "arc_ownership: classifier uses last-wins callee conventions for owned-consume shares" {
    // Regression for duplicate monomorphized function names in the
    // merged IR. `rewriteOwnedConsumeSites` indexes full function
    // names with last-wins semantics, so the classifier's pre-pass
    // must use the same lookup. If classification sees the first
    // `.borrowed` entry while the rewriter later sees the final
    // `.owned` entry, the stream becomes `borrow_value -> move_value`,
    // which the verifier correctly rejects.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const borrowed_conv = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    const owned_conv = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.owned});
    const target_params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "x", .type_expr = .void, .type_id = null },
    });
    const target_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    }});

    const borrowed_target = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = borrowed_conv,
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed}),
        .result_convention = .trivial,
    };

    const owned_target = ir.Function{
        .id = 101,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = owned_conv,
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.owned}),
        .result_convention = .trivial,
    };

    const caller_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{2});
    const caller_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .share_value = .{ .dest = 2, .source = 1 } },
        .{ .call_named = .{
            .dest = 3,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 2 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = caller_instrs,
    }});
    const caller = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = &.{},
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
            .owned, .owned, .owned, .trivial,
        }),
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 3);
    functions[0] = borrowed_target;
    functions[1] = owned_target;
    functions[2] = caller;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalizeWithProgram(arena, &functions[2], &dummy_ownership, &dummy_store, &program);

    const totals = countAliasOpcodes(&functions[2]);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 0), totals.borrow_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
    try std.testing.expectEqual(ir.OwnershipClass.owned, functions[2].local_ownership[1]);
}

test "arc_ownership: classifier promotes existing borrow_value when merged conventions require owned consume" {
    // Per-struct lowering can classify an alias as `borrow_value`
    // before the merged program sees cross-struct callers and
    // promotes the callee slot to `.owned`. The merged re-run must
    // revisit that existing borrow and promote it to an owned alias;
    // otherwise `rewriteOwnedConsumeSites` later rewrites the
    // downstream share into `move_value` from a borrowed source.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const borrowed_conv = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    const owned_conv = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.owned});
    const target_params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "x", .type_expr = .void, .type_id = null },
    });
    const target_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    }});
    const borrowed_target = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = borrowed_conv,
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed}),
        .result_convention = .trivial,
    };
    const owned_target = ir.Function{
        .id = 101,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = owned_conv,
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.owned}),
        .result_convention = .trivial,
    };

    const caller_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{2});
    const caller_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .borrow_value = .{ .dest = 1, .source = 0 } },
        .{ .share_value = .{ .dest = 2, .source = 1 } },
        .{ .call_named = .{
            .dest = 3,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 2 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = caller_instrs,
    }});
    const caller = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = &.{},
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
            .owned, .borrowed, .owned, .trivial,
        }),
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 3);
    functions[0] = borrowed_target;
    functions[1] = owned_target;
    functions[2] = caller;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalizeWithProgram(arena, &functions[2], &dummy_ownership, &dummy_store, &program);

    const totals = countAliasOpcodes(&functions[2]);
    try std.testing.expectEqual(@as(usize, 0), totals.borrow_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
    try std.testing.expectEqual(ir.OwnershipClass.owned, functions[2].local_ownership[1]);
}

test "arc_ownership: classifier sees owned-consume shares inside switch_return default" {
    // Regression for multi-clause fallback bodies. The owned-consume
    // pre-pass must recurse into `switch_return.default_instrs`;
    // otherwise a borrow alias in the default clause remains
    // borrowed, then `rewriteOwnedConsumeSites` later rewrites the
    // downstream share into `move_value` from a borrowed source.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const owned_conv = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.owned});
    const target_params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "x", .type_expr = .void, .type_id = null },
    });
    const target_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    }});
    const target = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = owned_conv,
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.owned}),
        .result_convention = .trivial,
    };

    const caller_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{2});
    const caller_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const default_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .borrow_value = .{ .dest = 1, .source = 0 } },
        .{ .share_value = .{ .dest = 2, .source = 1 } },
        .{ .call_named = .{
            .dest = 3,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 2 } },
    });
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .switch_return = .{
            .scrutinee_param = 0,
            .cases = &.{},
            .default_instrs = default_instrs,
            .default_result = null,
        } },
    });
    const caller_blocks = try arena.dupe(ir.Block, &[_]ir.Block{.{
        .label = 0,
        .instructions = caller_instrs,
    }});
    const caller = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = &.{},
        .local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
            .owned, .borrowed, .owned, .trivial,
        }),
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target;
    functions[1] = caller;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalizeWithProgram(arena, &functions[1], &dummy_ownership, &dummy_store, &program);

    const rewritten_switch = functions[1].body[0].instructions[1].switch_return;
    try std.testing.expect(rewritten_switch.default_instrs[0] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten_switch.default_instrs[0].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten_switch.default_instrs[0].copy_value.source);
    try std.testing.expectEqual(ir.OwnershipClass.owned, functions[1].local_ownership[1]);
}

test "arc_ownership: still emits copy_value when source has additional uses (Phase E.8 negative)" {
    // Phase E.8 negative: when source has any non-`local_get` use,
    // the move would steal ownership from the other use site. The
    // classifier must fall back to `.copy_value` to preserve the
    // source's living cell across uses.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 1;
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        // Extra use of source 0 (a local_set carrying it as its
        // value) — defeats the move precondition. The use-summary
        // counts this as a non-borrow use of source 0 so its
        // total_use_count rises to 2.
        .{ .local_set = .{ .dest = 2, .value = 0 } },
        .{ .tail_call = .{ .name = "self_loop", .args = args } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "self_loop", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // No move — source has another use (the retain).
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    // copy_value is the conservative fallback.
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: shouldMove returns true when source flat use_count=2 but local_get is at path-sensitive last-use" {
    // Phase 1.4 / Phase 2.2 / commit `8e783b2` regression — the path-
    // sensitive refinement: when `last_use_sites` is populated (the
    // production case), `shouldMove` must consult
    // `ArcOwnership.isLastUseAt` rather than the flat
    // `total_use_count == 1` predicate.
    //
    // Spectral-norm's `iterate` is the canonical reproducer: the
    // recursive-step tail_call's arg local has TWO flat reads — an
    // earlier `borrow_value` (used as a share-source for an
    // intermediate call) plus the tail_call's own `local_get`. The
    // flat predicate sees `total_use_count == 2` and falls back to
    // `copy_value`, retaining the cell at the tail-call boundary;
    // the dataflow downgrades the resulting dest to non-unique and
    // the interprocedural fixpoint cascades the demotion through
    // every subsequent owned-consume site. Per `isLastUseAt`, the
    // tail_call's `local_get` IS at the source's last use on its
    // execution path — the earlier `borrow_value`'s own last-use
    // site lies before this point, so the source is dead immediately
    // after this read.
    //
    // This unit test pins the path-sensitive predicate directly:
    // build a 2-use source where one use was a borrow (already at
    // last-use earlier) and the other is the tail_call's local_get,
    // then synthesise an `ArcOwnership` where ONLY the tail_call's
    // local_get is a recorded last-use site for the source. The
    // flat fallback would return false (total_use_count == 2); the
    // path-sensitive predicate must return true.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Function shape:
    //   %0 = (some owned producer; identity immaterial)
    //   %1 = borrow_value %0          -- earlier reader of %0
    //   %2 = local_get %0              -- tail_call's arg loader (last use)
    //   tail_call self args=[%2]
    //
    // `%0` has total_use_count == 2 (borrow + local_get). The
    // synthetic `ArcOwnership` records the local_get's id (2) as a
    // last-use site for %0; the borrow's id (1) is NOT recorded.
    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 2;
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .borrow_value = .{ .dest = 1, .source = 0 } },
        .{ .local_get = .{ .dest = 2, .source = 0 } },
        .{ .tail_call = .{ .name = "self_loop", .args = args } },
    };
    const local_ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "self_loop", &instrs, &local_ownership, 0);

    // Collect the use summary so the predicate's per-local counts
    // (tail_call_arg_use_count, total_use_count) match production.
    var use_summary: UseSummary = .{};
    defer use_summary.deinit(arena);
    try collectUseSummary(arena, &function, &use_summary);

    // Sanity: %0's flat use count is 2 (borrow + local_get); the
    // flat predicate WOULD reject the move. The path-sensitive
    // predicate must override.
    const source_counts = use_summary.get(0);
    try std.testing.expectEqual(@as(u32, 2), source_counts.total_use_count);

    // Build a synthetic ArcOwnership where %0's last-use is at the
    // local_get's id only. The local_get is the 3rd instruction
    // (id 2) in the top-level stream.
    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    const local_get_id: arc_liveness.InstructionId = 2;
    const local_get_key = (@as(u64, @intCast(@as(u32, 0))) << 32) | @as(u64, @intCast(local_get_id));
    try ownership.last_use_sites.put(arena, local_get_key, {});
    // Also record %2's last-use at the tail_call (id 3), since the
    // shouldMove caller passes the local_get's id for `source` and
    // the path-sensitive check ignores `dest`'s last-use entry —
    // this entry only exists to keep the ownership table "populated"
    // (last_use_sites.count() > 0) so the fallback path is skipped.
    const dest_key = (@as(u64, @intCast(@as(u32, 2))) << 32) | @as(u64, @intCast(3));
    try ownership.last_use_sites.put(arena, dest_key, {});

    // Path-sensitive predicate must return true.
    try std.testing.expect(shouldMove(&function, &use_summary, &ownership, 2, 0, local_get_id));

    // Flip the synthetic ownership so %0 is NOT at last-use at
    // local_get_id (only %2 has an entry, keeping the table non-
    // empty so the fallback is skipped). The predicate must return
    // false — the path-sensitive check fails.
    var ownership_no_last_use: arc_liveness.ArcOwnership = .{};
    defer ownership_no_last_use.deinit(arena);
    try ownership_no_last_use.last_use_sites.put(arena, dest_key, {});
    try std.testing.expect(!shouldMove(&function, &use_summary, &ownership_no_last_use, 2, 0, local_get_id));
}

test "arc_ownership: shouldMove falls back to flat total_use_count==1 when last_use_sites is empty" {
    // The fallback path covers the unit-test shape where the caller
    // hands a hand-rolled `ir.Function` to `classifyAndNormalize`
    // without first running `arc_liveness.computeArcOwnership` — the
    // resulting `ArcOwnership` is the zero-init `{}`, so
    // `last_use_sites.count()` is 0. The flat check is sound but
    // strictly weaker; production code paths always provide a
    // populated ownership table.
    //
    // This test pins the fallback directly: when `last_use_sites`
    // is empty AND the source has exactly one use (a `local_get`
    // feeding a tail_call), `shouldMove` returns true. With two
    // uses, it returns false.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Single-use shape — flat predicate accepts.
    {
        const args = try arena.alloc(ir.LocalId, 1);
        args[0] = 1;
        const instrs = [_]ir.Instruction{
            .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
            .{ .local_get = .{ .dest = 1, .source = 0 } },
            .{ .tail_call = .{ .name = "self_loop", .args = args } },
        };
        const local_ownership = [_]ir.OwnershipClass{ .owned, .owned };

        var function = try buildMoveValueTestFunction(arena, "self_loop_single_use", &instrs, &local_ownership, 0);

        var use_summary: UseSummary = .{};
        defer use_summary.deinit(arena);
        try collectUseSummary(arena, &function, &use_summary);

        const source_counts = use_summary.get(0);
        try std.testing.expectEqual(@as(u32, 1), source_counts.total_use_count);

        var empty_ownership: arc_liveness.ArcOwnership = .{};
        defer empty_ownership.deinit(arena);
        try std.testing.expectEqual(@as(u32, 0), empty_ownership.last_use_sites.count());

        // Fallback path: flat check passes (total_use_count == 1).
        const local_get_id: arc_liveness.InstructionId = 1;
        try std.testing.expect(shouldMove(&function, &use_summary, &empty_ownership, 1, 0, local_get_id));
    }

    // Two-use shape — flat predicate rejects.
    {
        const args = try arena.alloc(ir.LocalId, 1);
        args[0] = 1;
        const instrs = [_]ir.Instruction{
            .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
            .{ .local_get = .{ .dest = 1, .source = 0 } },
            // Second use of source 0: a local_set carrying %0
            // (non-borrow position). The use_summary counts this as
            // a non-borrow use so total_use_count rises to 2.
            .{ .local_set = .{ .dest = 2, .value = 0 } },
            .{ .tail_call = .{ .name = "self_loop_two_uses", .args = args } },
        };
        const local_ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

        var function = try buildMoveValueTestFunction(arena, "self_loop_two_uses", &instrs, &local_ownership, 0);

        var use_summary: UseSummary = .{};
        defer use_summary.deinit(arena);
        try collectUseSummary(arena, &function, &use_summary);

        const source_counts = use_summary.get(0);
        try std.testing.expectEqual(@as(u32, 2), source_counts.total_use_count);

        var empty_ownership: arc_liveness.ArcOwnership = .{};
        defer empty_ownership.deinit(arena);
        try std.testing.expectEqual(@as(u32, 0), empty_ownership.last_use_sites.count());

        // Fallback path: flat check fails (total_use_count == 2).
        const local_get_id: arc_liveness.InstructionId = 1;
        try std.testing.expect(!shouldMove(&function, &use_summary, &empty_ownership, 1, 0, local_get_id));
    }
}

// ============================================================
// Phase E.10 — move_value emission for aggregate-store operands
// ============================================================

test "arc_ownership: emits move_value for local_get whose dest's only use is a list_cons.head and source is at last use (Phase E.10)" {
    // Phase E.10 of the Phase 6 redux plan — aggregate-store consume.
    //
    // The doc-runner reproducer's UAF traces back to a `.local_get`
    // whose dest flows directly into `list_cons.head`. The classifier
    // conservatively emitted `.copy_value` with a persistent retain,
    // bumping the cell's refcount to +2; the bump-allocated list cell
    // stored the pointer without retaining; both owner aliases'
    // scope-exit `release` fired at function exit,
    // dropping the refcount to 0 — the cell freed while the list's
    // stored pointer dangled. Subsequent reads of the list (the
    // canonical reproducer is `Map.size(List.head(s))`) read the
    // freed-memory pattern `0xAAAAAAAA...` instead of a real value.
    //
    // The fix: detect this exact shape (`.local_get{dest, source}`
    // where dest's only use is a non-`.map_init` aggregate-init
    // operand AND source's only use is this read) and emit
    // `.move_value` instead. Move semantics transfer ownership
    // without retaining; the matching liveness rule in
    // `arc_liveness.applyOwnsEffect` clears the operand's owns bit
    // at the aggregate-init, so neither owner alias's scope-exit
    // destroy fires on the cell whose live pointer the aggregate
    // now holds.
    //
    // Hand-constructed IR mirroring the reproducer shape:
    //   %0 = const_int 0                  // dummy producer
    //   %1 = const_nil                    // tail of the list
    //   %2 = local_get <- %0              // alias for list_cons.head
    //   %3 = list_cons head=%2 tail=%1
    //   ret null
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .const_nil = 1 },
        .{ .local_get = .{ .dest = 2, .source = 0 } },
        .{ .list_cons = .{ .dest = 3, .head = 2, .tail = 1 } },
        .{ .ret = .{ .value = null } },
    };
    // %0 owned (the producer), %1 trivial (nil), %2 owned (the alias),
    // %3 owned (the list).
    const ownership = [_]ir.OwnershipClass{ .owned, .trivial, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "list_cons_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
    try std.testing.expectEqual(@as(usize, 0), totals.borrow_count);
}

test "arc_ownership: nested aggregate store copies from parent-stream borrow alias" {
    // Regression for the flat-buffer list destructuring shape:
    //
    //   %1 = local_get %0              // classifies as borrow_value
    //   switch ... {
    //     %2 = local_get %1            // feeds list_cons.tail
    //     %3 = list_cons head=%4 tail=%2
    //   }
    //
    // The stream rewriter rebuilds child streams before it rewrites
    // parent-stream local_get instructions. Without a preclassification
    // ownership refinement, the child sees %1 as .owned and lowers
    // `%2 = local_get %1` to `move_value`, even though %1 is only a
    // borrow alias of %0. Moving from the borrow alias leaves the real
    // owner live for a later scope-exit release, producing a UAF when
    // the aggregate stores the moved pointer.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const case_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .local_get = .{ .dest = 2, .source = 1 } },
        .{ .list_cons = .{ .dest = 3, .head = 4, .tail = 2 } },
    });
    const cases = try arena.dupe(ir.LitCase, &[_]ir.LitCase{
        .{ .value = .{ .int = 1 }, .body_instrs = case_body, .result = 3 },
    });
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 1, .type_hint = null } },
        .{ .switch_literal = .{
            .dest = 5,
            .scrutinee = 4,
            .cases = cases,
            .default_instrs = &.{},
            .default_result = null,
        } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned, .owned, .trivial, .owned };

    var function = try buildMoveValueTestFunction(arena, "nested_borrow_alias_aggregate", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[1]);

    const alias_counts = countClassificationsFromSource(&function, 1);
    try std.testing.expectEqual(@as(usize, 0), alias_counts.move_count);
    try std.testing.expectEqual(@as(usize, 1), alias_counts.copy_count);
}

test "arc_ownership: borrowed tuple_init operands are promoted before aggregate storage" {
    // Regression for fannkuch-redux's rotate_loop return shape:
    // a borrowed List parameter is re-packed into a tuple result.
    // V3 rightly rejects borrowed locals escaping into aggregate
    // storage, so ownership normalization must insert an owned copy
    // before the tuple_init instead of weakening the verifier.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const elems = try arena.alloc(ir.LocalId, 2);
    elems[0] = 0;
    elems[1] = 1;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 1, .type_hint = null } },
        .{ .tuple_init = .{ .dest = 2, .elements = elems } },
        .{ .ret = .{ .value = 2 } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .trivial, .owned };

    var function = try buildMoveValueTestFunction(arena, "tuple_borrow_promotion", &instrs, &ownership, 1);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 6), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);
    try std.testing.expect(rewritten[2] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[2].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[2].copy_value.source);
    try std.testing.expect(rewritten[3] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[3].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[3].retain.kind);
    try std.testing.expect(rewritten[4] == .tuple_init);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[4].tuple_init.elements[0]);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten[4].tuple_init.elements[1]);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: borrowed struct_init fields are promoted before aggregate storage" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const fields = try arena.alloc(ir.StructFieldInit, 1);
    fields[0] = .{ .name = "value", .value = 0 };
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .struct_init = .{ .dest = 1, .type_name = "Box", .fields = fields } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "struct_borrow_promotion", &instrs, &ownership, 1);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 5), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[2]);
    try std.testing.expect(rewritten[1] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[1].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[1].copy_value.source);
    try std.testing.expect(rewritten[2] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[2].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[2].retain.kind);
    try std.testing.expect(rewritten[3] == .struct_init);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[3].struct_init.fields[0].value);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: borrowed list_init elements are promoted before aggregate storage" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const elems = try arena.alloc(ir.LocalId, 2);
    elems[0] = 0;
    elems[1] = 1;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 1, .type_hint = null } },
        .{ .list_init = .{ .dest = 2, .elements = elems } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .trivial, .owned };

    var function = try buildMoveValueTestFunction(arena, "list_init_borrow_promotion", &instrs, &ownership, 1);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 6), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);
    try std.testing.expect(rewritten[2] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[2].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[2].copy_value.source);
    try std.testing.expect(rewritten[3] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[3].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[3].retain.kind);
    try std.testing.expect(rewritten[4] == .list_init);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[4].list_init.elements[0]);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten[4].list_init.elements[1]);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: borrowed list_cons operands are promoted before aggregate storage" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "list_cons_borrow_promotion", &instrs, &ownership, 2);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 8), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[1]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[4]);
    try std.testing.expect(rewritten[2] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[2].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[2].copy_value.source);
    try std.testing.expect(rewritten[3] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[3].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[3].retain.kind);
    try std.testing.expect(rewritten[4] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[4].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten[4].copy_value.source);
    try std.testing.expect(rewritten[5] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[5].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[5].retain.kind);
    try std.testing.expect(rewritten[6] == .list_cons);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[6].list_cons.head);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[6].list_cons.tail);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 2), totals.copy_count);
}

test "arc_ownership: borrowed map_init entries are promoted without consume semantics" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const entries = try arena.alloc(ir.MapEntry, 1);
    entries[0] = .{ .key = 0, .value = 1 };
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .map_init = .{ .dest = 2, .entries = entries } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "map_init_borrow_promotion", &instrs, &ownership, 2);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 8), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[1]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[4]);
    try std.testing.expect(rewritten[2] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[2].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[2].copy_value.source);
    try std.testing.expect(rewritten[3] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[3].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[3].retain.kind);
    try std.testing.expect(rewritten[4] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[4].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 1), rewritten[4].copy_value.source);
    try std.testing.expect(rewritten[5] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[5].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[5].retain.kind);
    try std.testing.expect(rewritten[6] == .map_init);
    try std.testing.expectEqual(@as(ir.LocalId, 3), rewritten[6].map_init.entries[0].key);
    try std.testing.expectEqual(@as(ir.LocalId, 4), rewritten[6].map_init.entries[0].value);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 2), totals.copy_count);
}

test "arc_ownership: borrowed union_init value is promoted before aggregate storage" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .union_init = .{ .dest = 1, .union_type = "U", .variant_name = "Value", .value = 0 } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "union_borrow_promotion", &instrs, &ownership, 1);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const rewritten = function.body[0].instructions;
    try std.testing.expectEqual(@as(usize, 5), rewritten.len);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, function.local_ownership[0]);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[2]);
    try std.testing.expect(rewritten[1] == .copy_value);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[1].copy_value.dest);
    try std.testing.expectEqual(@as(ir.LocalId, 0), rewritten[1].copy_value.source);
    try std.testing.expect(rewritten[2] == .retain);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[2].retain.value);
    try std.testing.expectEqual(ir.RetainKind.persistent, rewritten[2].retain.kind);
    try std.testing.expect(rewritten[3] == .union_init);
    try std.testing.expectEqual(@as(ir.LocalId, 2), rewritten[3].union_init.value);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: emits move_value for local_get whose dest's only use is a struct_init field value (Phase E.10)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const fields = try arena.alloc(ir.StructFieldInit, 1);
    fields[0] = .{ .name = "f", .value = 1 };
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .struct_init = .{ .dest = 2, .type_name = "Box", .fields = fields } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "struct_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
}

test "arc_ownership: emits move_value for local_get whose dest's only use is a tuple_init element (Phase E.10)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const elems = try arena.alloc(ir.LocalId, 1);
    elems[0] = 1;
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .tuple_init = .{ .dest = 2, .elements = elems } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "tuple_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
}

test "arc_ownership: emits move_value for local_get whose dest's only use is a list_init element (Phase E.10)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const elems = try arena.alloc(ir.LocalId, 1);
    elems[0] = 1;
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .list_init = .{ .dest = 2, .elements = elems } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "list_init_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
}

test "arc_ownership: emits move_value for local_get whose dest's only use is a union_init value (Phase E.10)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 1, .source = 0 } },
        .{ .union_init = .{ .dest = 2, .union_type = "U", .variant_name = "V", .value = 1 } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "union_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 1), totals.move_count);
    try std.testing.expectEqual(@as(usize, 0), totals.copy_count);
}

test "arc_ownership: still emits copy_value for map_init operands — Map retains its inserted children (Phase E.10)" {
    // Phase E.10 negative: `.map_init` is intentionally NOT in the
    // consume-position set. Map cells are themselves ARC-managed and
    // `Map.put` retains its inserted value via the Phase 6 substrate.
    // A `.local_get` flowing into `.map_init.entry.value` therefore
    // continues to classify as `.copy_value` — the runtime's retain
    // handles the stored cell's lifetime, so the conservative copy is
    // correct (and a `.move_value` would double-decrement at scope
    // exit).
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const entries = try arena.alloc(ir.MapEntry, 1);
    entries[0] = .{ .key = 0, .value = 2 };
    const instrs = [_]ir.Instruction{
        .{ .const_atom = .{ .dest = 0, .value = "k" } },
        .{ .const_int = .{ .dest = 1, .value = 0, .type_hint = null } },
        .{ .local_get = .{ .dest = 2, .source = 1 } },
        .{ .map_init = .{ .dest = 3, .entries = entries } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .trivial, .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "map_consume", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    // copy_value is correct here — Map.put's substrate retains the
    // inserted child, and a move would clear source's +1 leaving the
    // Map's runtime retain unbalanced.
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

test "arc_ownership: still emits copy_value when source has additional uses outside the aggregate-init (Phase E.10 negative)" {
    // Phase E.10 negative: even when dest's only use is an aggregate-
    // init operand, if source has any non-`local_get` use the move
    // would steal ownership from the other use site. The classifier
    // must fall back to `.copy_value` to keep both owner aliases
    // viable.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const elems = try arena.alloc(ir.LocalId, 1);
    elems[0] = 2;
    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        // Extra non-borrow use of source 0 (a local_set carrying it
        // as its value). This forces the classifier away from move.
        .{ .local_set = .{ .dest = 1, .value = 0 } },
        .{ .local_get = .{ .dest = 2, .source = 0 } },
        .{ .list_init = .{ .dest = 3, .elements = elems } },
        .{ .ret = .{ .value = null } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned, .owned };

    var function = try buildMoveValueTestFunction(arena, "no_consume_extra_use", &instrs, &ownership, 0);

    var dummy_ownership: arc_liveness.ArcOwnership = .{};
    defer dummy_ownership.deinit(arena);
    var dummy_store: types_mod.TypeStore = undefined;
    try classifyAndNormalize(arena, &function, &dummy_ownership, &dummy_store);

    const totals = countAliasOpcodes(&function);
    try std.testing.expectEqual(@as(usize, 0), totals.local_get_count);
    try std.testing.expectEqual(@as(usize, 0), totals.move_count);
    try std.testing.expectEqual(@as(usize, 1), totals.copy_count);
}

// ============================================================
// Phase 4 (dense Map) tests — rewriteOwnedConsumeBuiltinSites
// ============================================================
//
// These tests verify the call_builtin consume-rewrite pass for
// owned-mutating runtime intrinsics (`Map.put`, `.delete`, `.merge`).
// Each test hand-rolls a tiny IR shape that mirrors what the IR
// builder emits for `:zig.Map.put(map, k, v)` inside `Map.put`'s body
// in `lib/map.zap`, plus a synthetic `ArcOwnership.last_use_map` that
// records when the receiver source is at last use at the share site.
//
// The positive cases assert the share→move conversion fires AND the
// post-call release is dropped. The negative cases assert the rewrite
// is a no-op when:
//   * the source has additional uses after the share (not at last use)
//   * the call_builtin is a non-mutating helper (e.g. `Map.get`)

test "arc_ownership: rewriteOwnedConsumeBuiltinSites converts share to move + drops release for Map.put at last-use" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] const_int %0
    //   [1] share_value %1 <- %0
    //   [2] call_builtin "Map.put" args=[%1, %2_arg, %3_arg] dest=%4
    //   [3] release %1
    //   [4] ret
    //
    // Local %0's last use is at the share_value (id 1). After the
    // rewrite the share becomes move_value and the release of %1 is
    // dropped.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .trivial, .trivial,
    });
    var function = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    // Synthetic last_use_map: %0's last use is the share_value at id 1.
    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 1);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_of_1 = true;
            },
            .move_value => |mv| if (mv.dest == 1 and mv.source == 0) {
                saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_release_of_1);
    try std.testing.expect(saw_move_dest_1);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites does not move from borrowed parameter" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .trivial, .trivial, .owned, .trivial, .trivial,
    });
    const params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "map", .type_expr = .void, .type_id = null },
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    var function = ir.Function{
        .id = 201,
        .name = "Mod__borrowed_param_builtin__1",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 1);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_from_0 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |release| {
                if (release.value == 1) saw_release_of_1 = true;
            },
            .move_value => |move| {
                if (move.source == 0) saw_move_from_0 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_of_1);
    try std.testing.expect(!saw_move_from_0);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites drops List.cons releases without moving shares" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] share_value %1 <- %0
    //   [1] share_value %3 <- %2
    //   [2] call_builtin "List.cons" args=[%1, %3] dest=%4
    //   [3] release %1
    //   [4] release %3
    //   [5] ret %4
    //
    // `List.cons` consumes both argument owners by ABI. Unlike the
    // rc1-mutator path, this must not rewrite either share to a move:
    // the original sources may remain live, and the runtime consumes
    // the temporary owners produced by the shares.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1;
    args[1] = 3;

    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .share;
    arg_modes[1] = .share;

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .share_value = .{ .dest = 3, .source = 2 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.cons",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .release = .{ .value = 3 } },
        .{ .ret = .{ .value = 4 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned, .owned,
    });
    var function = ir.Function{
        .id = 205,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var share_count: u32 = 0;
    var move_count: u32 = 0;
    var saw_release_of_1 = false;
    var saw_release_of_3 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => share_count += 1,
            .move_value => move_count += 1,
            .release => |r| {
                if (r.value == 1) saw_release_of_1 = true;
                if (r.value == 3) saw_release_of_3 = true;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 2), share_count);
    try std.testing.expectEqual(@as(u32, 0), move_count);
    try std.testing.expect(!saw_release_of_1);
    try std.testing.expect(!saw_release_of_3);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites moves List.push consumed value at last-use" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] share_value %3 <- %2
    //   [1] call_builtin "List.push_owned_unchecked" args=[%1, %3] dest=%4
    //   [2] release %3
    //   [3] ret %4
    //
    // List.push stores `value` directly into the list buffer. When the
    // source is at last-use, the share becomes a move and the paired
    // release is dropped so the list owns the transferred element.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1;
    args[1] = 3;

    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move;
    arg_modes[1] = .share;

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .share_value = .{ .dest = 3, .source = 2 } },
        .{ .retain = .{ .value = 3, .kind = .normal } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.push_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 3 } },
        .{ .ret = .{ .value = 4 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .trivial, .owned, .owned, .owned, .owned,
    });
    var function = ir.Function{
        .id = 206,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 2, 0);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_retain_of_3 = false;
    var saw_release_of_3 = false;
    var saw_move_value = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .retain => |retain| {
                if (retain.value == 3) saw_retain_of_3 = true;
            },
            .release => |release| {
                if (release.value == 3) saw_release_of_3 = true;
            },
            .move_value => |move| {
                if (move.dest == 3 and move.source == 2) saw_move_value = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_retain_of_3);
    try std.testing.expect(!saw_release_of_3);
    try std.testing.expect(saw_move_value);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites copies borrowed List.push consumed value" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // List.push stores the element owner directly in the list buffer.
    // A borrowed alias cannot be consumed by that runtime contract, so
    // the pass must materialize an owned copy before the builtin call.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1;
    args[1] = 3;

    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move;
    arg_modes[1] = .share;

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .borrow_value = .{ .dest = 3, .source = 2 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.push_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .trivial, .owned, .owned, .borrowed, .owned,
    });
    var function = ir.Function{
        .id = 207,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_borrow = false;
    var saw_copy_value = false;
    var saw_persistent_retain = false;
    for (rewritten) |instr| {
        switch (instr) {
            .borrow_value => saw_borrow = true,
            .copy_value => |copy| {
                if (copy.dest == 3 and copy.source == 2) saw_copy_value = true;
            },
            .retain => |retain| {
                if (retain.value == 3 and retain.kind == .persistent) saw_persistent_retain = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_borrow);
    try std.testing.expect(saw_copy_value);
    try std.testing.expect(saw_persistent_retain);
    try std.testing.expectEqual(ir.OwnershipClass.owned, function.local_ownership[3]);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites keeps non-last-use List.push value share but drops release" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // The source remains live after the share, so the pass must keep
    // the retain-producing share. The post-call release is still
    // removed because List.push consumes that temporary owner by
    // storing it into the list.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1;
    args[1] = 3;

    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move;
    arg_modes[1] = .share;

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .share_value = .{ .dest = 3, .source = 2 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.push",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 3 } },
        .{ .ret = .{ .value = 4 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .trivial, .owned, .owned, .owned, .owned,
    });
    var function = ir.Function{
        .id = 207,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 2, 99);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_release_of_3 = false;
    var saw_move_value = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => |share| {
                if (share.dest == 3 and share.source == 2) saw_share = true;
            },
            .release => |release| {
                if (release.value == 3) saw_release_of_3 = true;
            },
            .move_value => |move| {
                if (move.dest == 3 and move.source == 2) saw_move_value = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_share);
    try std.testing.expect(!saw_release_of_3);
    try std.testing.expect(!saw_move_value);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites is a no-op when source has additional uses (not last use)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Same shape as the positive test, but the source local %0 has
    // a use AFTER the share — `last_use_map[%0]` points at the
    // trailing local_get (id 4). The rewrite must leave the share /
    // release pair untouched.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .local_get = .{ .dest = 7, .source = 0 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .trivial, .trivial, .owned,
    });
    var function = ir.Function{
        .id = 201,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 8,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    // %0's last use is at id 4 (the local_get), NOT the share at id 1.
    try ownership.last_use_map.put(arena, 0, 4);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_of_1 = true;
            },
            .move_value => |mv| if (mv.dest == 1 and mv.source == 0) {
                saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_of_1);
    try std.testing.expect(!saw_move_dest_1);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites is a no-op for non-mutating Map builtins (Map.get)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.get",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .trivial, .trivial,
    });
    var function = ir.Function{
        .id = 202,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 1);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_share = false;
    var saw_release_of_1 = false;
    var saw_move_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_of_1 = true;
            },
            .move_value => |mv| if (mv.dest == 1 and mv.source == 0) {
                saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_of_1);
    try std.testing.expect(!saw_move_dest_1);
}

test "arc_ownership: rewriteOwnedConsumeBuiltinSites recognizes monomorphized Map:K:V.put name" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map:u32:i64.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .trivial, .trivial,
    });
    var function = ir.Function{
        .id = 203,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 1);

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &ownership);

    const rewritten = function.body[0].instructions;
    var saw_move_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .move_value => |mv| {
                if (mv.dest == 1 and mv.source == 0) saw_move_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_move_dest_1);
}

// ============================================================
// Phase H/uniqueness (codegen) tests — rewriteUncheckedUniquenessSites
// ============================================================
//
// These tests verify the post-Phase-4 codegen rewrite pass that
// flips owned-mutating call sites from their checked names to the
// `*_owned_unchecked` peers when the uniqueness static-uniqueness analysis
// reports the receiver is provably refcount=1 by construction.
//
// Each test hand-rolls a tiny IR shape and runs the analysis end-
// to-end (real `uniqueness.analyzeUniqueness`), then invokes the
// rewriter and asserts on the call site's name field.
//
// Positive cases (uniqueness holds): name is rewritten to `*_owned_unchecked`.
// Negative cases (uniqueness fails): name is unchanged.
// Regression cases: parked-receiver and parameter-receiver shapes
// where uniqueness must fail; the rewrite must not fire.

fn expectCallBuiltinName(stream: []const ir.Instruction, dest: ir.LocalId, expected: []const u8) !void {
    for (stream) |instr| {
        switch (instr) {
            .call_builtin => |cb| if (cb.dest == dest) {
                try std.testing.expectEqualStrings(expected, cb.name);
                return;
            },
            else => {},
        }
    }
    try std.testing.expect(false); // call site not found
}

fn expectListTailConsume(stream: []const ir.Instruction, dest: ir.LocalId, expected: bool) !void {
    for (stream) |instr| {
        switch (instr) {
            .list_tail => |lt| if (lt.dest == dest) {
                try std.testing.expectEqual(expected, lt.consume_source);
                return;
            },
            else => {},
        }
    }
    try std.testing.expect(false); // list_tail site not found
}

test "arc_ownership: rewriteUncheckedUniquenessSites swaps Map.put -> Map.put_owned_unchecked when uniqueness holds" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                 -- fresh-alloc, unique
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0              -- transfers uniqueness
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //
    // uniqueness holds at id 4 -> rewrite to "Map.put_owned_unchecked".
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    });
    var function = ir.Function{
        .id = 300,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(4));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 4, "Map.put_owned_unchecked");
}

test "arc_ownership: rewriteUncheckedUniquenessSites marks unique last-use list_tail as consuming" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .list_init = .{ .dest = 0, .elements = &.{} } },
        .{ .list_tail = .{ .dest = 1, .list = 0, .element_type = .i64 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{ .owned, .owned });
    var function = ir.Function{
        .id = 401,
        .name = "Mod__tail__1",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 1);

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(1));

    try rewriteUncheckedUniquenessSitesWithOwnership(arena, &function, &uniqueness, null, &ownership);

    try expectListTailConsume(function.body[0].instructions, 1, true);
}

test "arc_ownership: rewriteUncheckedUniquenessSites leaves non-last-use list_tail cloning" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .list_init = .{ .dest = 0, .elements = &.{} } },
        .{ .list_tail = .{ .dest = 1, .list = 0, .element_type = .i64 } },
        .{ .list_is_not_empty = .{ .dest = 2, .list = 0, .element_type = .i64 } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{ .owned, .owned, .trivial });
    var function = ir.Function{
        .id = 402,
        .name = "Mod__tail_shared__1",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(arena);
    try ownership.last_use_map.put(arena, 0, 2);

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(1));

    try rewriteUncheckedUniquenessSitesWithOwnership(arena, &function, &uniqueness, null, &ownership);

    try expectListTailConsume(function.body[0].instructions, 1, false);
}

test "arc_ownership: rewriteUncheckedUniquenessSites leaves Map.put unchanged when uniqueness fails (parked receiver)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream — same shape as the uniqueness "parked" test:
    //   [0] map_init %0 = {}              -- fresh, unique
    //   [1] const_nil %1
    //   [2] list_cons %2 = [%0 | %1]      -- parks %0 (uniqueness cleared)
    //   [3] const_int %3 = 0
    //   [4] const_int %4 = 0
    //   [5] move_value %5 <- %0
    //   [6] call_builtin "Map.put" args=[%5, %3, %4] dest=%6
    //
    // uniqueness fails at id 6 -> name MUST stay "Map.put".
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 5;
    args[1] = 3;
    args[2] = 4;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .owned, .trivial, .trivial, .owned, .owned,
    });
    var function = ir.Function{
        .id = 301,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(!uniqueness.isUnique(6));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 6, "Map.put");
}

test "arc_ownership: rewriteUncheckedUniquenessSites swaps List.set, List.push, List.pop, List.append" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] call_builtin "List.new_filled" -> %0      -- fresh allocator: unique
    //   [1] move_value %1 <- %0
    //   [2] const_int %2 = 0
    //   [3] const_int %3 = 1
    //   [4] call_builtin "List.set" args=[%1, %2, %3] dest=%4      -- uniqueness holds
    //   [5] move_value %5 <- %4
    //   [6] const_int %6 = 9
    //   [7] call_builtin "List.push" args=[%5, %6] dest=%7         -- uniqueness holds
    //   [8] move_value %8 <- %7
    //   [9] call_builtin "List.pop" args=[%8] dest=%9              -- uniqueness holds
    //   [10] move_value %10 <- %9
    //   [11] call_builtin "List.append" args=[%10, %10] dest=%11   -- uniqueness holds
    //
    // Phase 1.4: `List.new_filled` is recognised as a fresh allocator
    // (`isFreshAllocatorBuiltin` returns true for `List.new_filled`),
    // so its dest is classified as unique. Every chained mutator
    // following the constructor has uniqueness holding.
    const ctor_args = try arena.alloc(ir.LocalId, 0);
    const ctor_modes = try arena.alloc(ir.ValueMode, 0);
    const set_args = try arena.alloc(ir.LocalId, 3);
    set_args[0] = 1;
    set_args[1] = 2;
    set_args[2] = 3;
    const set_modes = try arena.alloc(ir.ValueMode, 3);
    set_modes[0] = .move;
    set_modes[1] = .borrow;
    set_modes[2] = .borrow;
    const push_args = try arena.alloc(ir.LocalId, 2);
    push_args[0] = 5;
    push_args[1] = 6;
    const push_modes = try arena.alloc(ir.ValueMode, 2);
    push_modes[0] = .move;
    push_modes[1] = .borrow;
    const pop_args = try arena.alloc(ir.LocalId, 1);
    pop_args[0] = 8;
    const pop_modes = try arena.alloc(ir.ValueMode, 1);
    pop_modes[0] = .move;
    const append_args = try arena.alloc(ir.LocalId, 2);
    append_args[0] = 10;
    append_args[1] = 10;
    const append_modes = try arena.alloc(ir.ValueMode, 2);
    append_modes[0] = .move;
    append_modes[1] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .call_builtin = .{
            .dest = 0,
            .name = "List.new_filled",
            .args = ctor_args,
            .arg_modes = ctor_modes,
        } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 1 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.set",
            .args = set_args,
            .arg_modes = set_modes,
        } },
        .{ .move_value = .{ .dest = 5, .source = 4 } },
        .{ .const_int = .{ .dest = 6, .value = 9 } },
        .{ .call_builtin = .{
            .dest = 7,
            .name = "List.push",
            .args = push_args,
            .arg_modes = push_modes,
        } },
        .{ .move_value = .{ .dest = 8, .source = 7 } },
        .{ .call_builtin = .{
            .dest = 9,
            .name = "List.pop",
            .args = pop_args,
            .arg_modes = pop_modes,
        } },
        .{ .move_value = .{ .dest = 10, .source = 9 } },
        .{ .call_builtin = .{
            .dest = 11,
            .name = "List.append",
            .args = append_args,
            .arg_modes = append_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .owned, .trivial, .owned, .owned, .owned, .owned, .owned,
    });
    var function = ir.Function{
        .id = 302,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 12,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    // Phase 1.4: uniqueness now holds at every site in the chain because
    // `List.new_filled` is classified as a fresh allocator (rc=1
    // by runtime contract) and every owned-mutating step preserves
    // uniqueness through its result.
    try std.testing.expect(uniqueness.isUnique(4));
    try std.testing.expect(uniqueness.isUnique(7));
    try std.testing.expect(uniqueness.isUnique(9));
    try std.testing.expect(uniqueness.isUnique(11));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    // Phase 1.4: every site in the chain rewrites to its unchecked peer.
    try expectCallBuiltinName(function.body[0].instructions, 4, "List.set_owned_unchecked");
    try expectCallBuiltinName(function.body[0].instructions, 7, "List.push_owned_unchecked");
    try expectCallBuiltinName(function.body[0].instructions, 9, "List.pop_owned_unchecked");
    try expectCallBuiltinName(function.body[0].instructions, 11, "List.append_owned_unchecked");
}

test "arc_ownership: rewriteUncheckedUniquenessSites handles Map.delete and Map.merge" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                  -- fresh, unique
    //   [1] const_int %1 = 0
    //   [2] move_value %2 <- %0
    //   [3] call_builtin "Map.delete" args=[%2, %1] dest=%3
    //   [4] map_init %4 = {}
    //   [5] move_value %5 <- %3
    //   [6] move_value %6 <- %4
    //   [7] call_builtin "Map.merge" args=[%5, %6] dest=%7
    //
    // uniqueness holds at ids 3 and 7 -> both rewrite to unchecked.
    const delete_args = try arena.alloc(ir.LocalId, 2);
    delete_args[0] = 2;
    delete_args[1] = 1;
    const delete_modes = try arena.alloc(ir.ValueMode, 2);
    delete_modes[0] = .move;
    delete_modes[1] = .borrow;
    const merge_args = try arena.alloc(ir.LocalId, 2);
    merge_args[0] = 5;
    merge_args[1] = 6;
    const merge_modes = try arena.alloc(ir.ValueMode, 2);
    merge_modes[0] = .move;
    merge_modes[1] = .move;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .move_value = .{ .dest = 2, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 3,
            .name = "Map.delete",
            .args = delete_args,
            .arg_modes = delete_modes,
        } },
        .{ .map_init = .{ .dest = 4, .entries = &.{} } },
        .{ .move_value = .{ .dest = 5, .source = 3 } },
        .{ .move_value = .{ .dest = 6, .source = 4 } },
        .{ .call_builtin = .{
            .dest = 7,
            .name = "Map.merge",
            .args = merge_args,
            .arg_modes = merge_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .owned, .owned, .owned, .owned, .owned, .owned,
    });
    var function = ir.Function{
        .id = 303,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 8,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(3));
    try std.testing.expect(uniqueness.isUnique(7));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 3, "Map.delete_owned_unchecked");
    try expectCallBuiltinName(function.body[0].instructions, 7, "Map.merge_owned_unchecked");
}

test "arc_ownership: rewriteUncheckedUniquenessSites preserves monomorphized Map:K:V.method names" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] const_int %1 = 7
    //   [2] const_int %2 = 11
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Map:i64:i64.put" args=[%3, %1, %2] dest=%4
    //
    // uniqueness holds -> name becomes "Map:i64:i64.put_owned_unchecked".
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 7 } },
        .{ .const_int = .{ .dest = 2, .value = 11 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map:i64:i64.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    });
    var function = ir.Function{
        .id = 304,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(4));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 4, "Map:i64:i64.put_owned_unchecked");
}

test "arc_ownership: rewriteUncheckedUniquenessSites no-op for parameter receiver (uniqueness fails)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream simulating the body of `Map.put` (lib/map.zap) — receives
    // the map as parameter index 0 and forwards to :zig.Map.put.
    //
    //   [0] param_get %0 = param[0]
    //   [1] param_get %1 = param[1]
    //   [2] param_get %2 = param[2]
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //
    // uniqueness fails -> name MUST stay "Map.put". This is the regression
    // gate the user-spec asks for: a wrapper-body call site whose
    // receiver is a parameter must NEVER be rewritten.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .param_get = .{ .dest = 2, .index = 2 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    });
    const conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{
        .owned, .trivial, .trivial,
    });
    const params = try arena.alloc(ir.Param, 3);
    for (params) |*p| p.* = .{ .name = "p", .type_expr = .void, .type_id = null };
    var function = ir.Function{
        .id = 305,
        .name = "Map__put__3",
        .scope_id = 0,
        .arity = 3,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = conventions,
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);
    try std.testing.expect(!uniqueness.isUnique(4));

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 4, "Map.put");
}

test "arc_ownership: rewriteUncheckedUniquenessSites is idempotent on already-unchecked names" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // If a call site already uses the unchecked variant, the rewrite
    // must leave it alone (no double-suffix). This is a defensive
    // gate against accidentally introducing a "_owned_unchecked_owned_unchecked"
    // name through repeated pass execution.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    });
    var function = ir.Function{
        .id = 306,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    try expectCallBuiltinName(function.body[0].instructions, 4, "Map.put_owned_unchecked");
}

test "arc_ownership: rewriteUncheckedUniquenessSites no-op on non-mutating builtins (Map.get)" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .share_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.get",
            .args = args,
            .arg_modes = arg_modes,
        } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .trivial,
    });
    var function = ir.Function{
        .id = 307,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &function, null);
    defer uniqueness.deinit(arena);

    try rewriteUncheckedUniquenessSites(arena, &function, &uniqueness);

    // Map.get is not in ownedMutatingBuiltinSlot, so uniqueness doesn't classify
    // its receiver and the rewrite must not fire.
    try expectCallBuiltinName(function.body[0].instructions, 4, "Map.get");
}

test "arc_ownership: allocUncheckedName basic mappings" {
    const allocator = std.testing.allocator;

    {
        const got = try allocUncheckedName(allocator, "Map.put");
        defer if (got) |s| allocator.free(s);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("Map.put_owned_unchecked", got.?);
    }
    {
        const got = try allocUncheckedName(allocator, "Map:i64:i64.put");
        defer if (got) |s| allocator.free(s);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("Map:i64:i64.put_owned_unchecked", got.?);
    }
    {
        const got = try allocUncheckedName(allocator, "List:i64.set");
        defer if (got) |s| allocator.free(s);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("List:i64.set_owned_unchecked", got.?);
    }
    {
        // Already unchecked -> null.
        const got = try allocUncheckedName(allocator, "Map.put_owned_unchecked");
        try std.testing.expect(got == null);
    }
    {
        // Not owned-mutating -> null.
        const got = try allocUncheckedName(allocator, "Map.get");
        try std.testing.expect(got == null);
    }
    {
        // Lookalike receiver name -> null.
        const got = try allocUncheckedName(allocator, "Foo.put");
        try std.testing.expect(got == null);
    }
}

test "arc_ownership: rewriteUncheckedUniquenessSites materializes copied owner for bypassed List.push consumed element" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const wrapper_args = try arena.alloc(ir.LocalId, 2);
    wrapper_args[0] = 2;
    wrapper_args[1] = 1;
    const wrapper_modes = try arena.alloc(ir.ValueMode, 2);
    wrapper_modes[0] = .move;
    wrapper_modes[1] = .borrow;
    const wrapper_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .move_value = .{ .dest = 2, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 3,
            .name = "List.push",
            .args = wrapper_args,
            .arg_modes = wrapper_modes,
        } },
        .{ .ret = .{ .value = 3 } },
    });
    const wrapper_blocks = try arena.alloc(ir.Block, 1);
    wrapper_blocks[0] = .{ .label = 0, .instructions = wrapper_instrs };
    const wrapper_params = try arena.alloc(ir.Param, 2);
    wrapper_params[0] = .{ .name = "list", .type_expr = .void, .type_id = null };
    wrapper_params[1] = .{ .name = "value", .type_expr = .void, .type_id = null };
    const wrapper_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{
        .owned,
        .borrowed,
    });
    const wrapper_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned,
        .borrowed,
        .owned,
        .owned,
    });
    const wrapper = ir.Function{
        .id = 900,
        .name = "List__push__2",
        .scope_id = 0,
        .arity = 2,
        .params = wrapper_params,
        .return_type = .void,
        .body = wrapper_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = wrapper_conventions,
        .local_ownership = wrapper_local_ownership,
        .result_convention = .owned,
    };

    const caller_args = try arena.alloc(ir.LocalId, 2);
    caller_args[0] = 1;
    caller_args[1] = 3;
    const caller_modes = try arena.alloc(ir.ValueMode, 2);
    caller_modes[0] = .move;
    caller_modes[1] = .borrow;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .call_builtin = .{
            .dest = 0,
            .name = "List.new_filled",
            .args = &.{},
            .arg_modes = &.{},
        } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .map_init = .{ .dest = 2, .entries = &.{} } },
        .{ .borrow_value = .{ .dest = 3, .source = 2 } },
        .{ .call_direct = .{
            .dest = 4,
            .function = 900,
            .args = caller_args,
            .arg_modes = caller_modes,
        } },
        .{ .release = .{ .value = 2 } },
        .{ .ret = .{ .value = 4 } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned,
        .owned,
        .owned,
        .borrowed,
        .owned,
    });
    var caller = ir.Function{
        .id = 901,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = caller_local_ownership,
        .result_convention = .owned,
    };

    const functions = try arena.dupe(ir.Function, &[_]ir.Function{ caller, wrapper });
    const program = ir.Program{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };

    var uniqueness = try uniqueness_analysis.analyzeUniqueness(arena, &caller, &program);
    defer uniqueness.deinit(arena);
    try std.testing.expect(uniqueness.isUnique(4));

    try rewriteUncheckedUniquenessSitesWithProgram(arena, &caller, &uniqueness, &program);

    const rewritten = caller.body[0].instructions;
    var saw_borrow = false;
    var saw_copy = false;
    var saw_persistent_retain = false;
    var saw_unchecked_call = false;
    var saw_source_release = false;
    for (rewritten) |instr| {
        switch (instr) {
            .borrow_value => |borrow| {
                if (borrow.dest == 3 and borrow.source == 2) saw_borrow = true;
            },
            .copy_value => |copy| {
                if (copy.dest == 3 and copy.source == 2) saw_copy = true;
            },
            .retain => |retain| {
                if (retain.value == 3 and retain.kind == .persistent) saw_persistent_retain = true;
            },
            .call_builtin => |call_builtin| {
                if (call_builtin.dest == 4) {
                    try std.testing.expectEqualStrings("List.push_owned_unchecked", call_builtin.name);
                    saw_unchecked_call = true;
                }
            },
            .release => |release| {
                if (release.value == 2) saw_source_release = true;
            },
            else => {},
        }
    }

    try std.testing.expect(!saw_borrow);
    try std.testing.expect(saw_copy);
    try std.testing.expect(saw_persistent_retain);
    try std.testing.expect(saw_unchecked_call);
    try std.testing.expect(saw_source_release);
    try std.testing.expectEqual(ir.OwnershipClass.owned, caller.local_ownership[3]);
}
// ============================================================
// Phase 7 tests — elideBorrowedPassThroughShares
// ============================================================

test "arc_ownership: elideBorrowedPassThroughShares rewrites share+retain+call+release to borrow_value when source is .borrowed and slot is .borrowed" {
    // Build a 2-function program:
    //   * `target_func`: declares a single ARC-managed parameter with
    //     `.borrowed` convention.
    //   * `caller_func`: param[0] is `.borrowed`. The body reads the
    //     param, emits the canonical share/retain/call/release shape
    //     into `target_func`. The pass must rewrite the share to
    //     borrow_value and drop the retain + release.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    // Caller layout:
    //   param_get %0 (index=0, .borrowed)
    //   share_value %1 <- %0
    //   retain %1 (kind=normal)
    //   call_named "target" args=[%1] dest=%2
    //   release %1
    //   ret
    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 1);
    caller_param_conv[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "src", .type_expr = .void, .type_id = null };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);

    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_retain_1 = false;
    var saw_release_1 = false;
    var saw_borrow_dest_1 = false;
    var saw_call = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .retain => |r| if (r.value == 1) {
                saw_retain_1 = true;
            },
            .release => |r| if (r.value == 1) {
                saw_release_1 = true;
            },
            .borrow_value => |bv| if (bv.dest == 1 and bv.source == 0) {
                saw_borrow_dest_1 = true;
            },
            .call_named => saw_call = true,
            else => {},
        }
    }
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_retain_1);
    try std.testing.expect(!saw_release_1);
    try std.testing.expect(saw_borrow_dest_1);
    try std.testing.expect(saw_call);

    // `local_ownership[1]` (the share's dest, now a borrow alias) must
    // be refined from `.owned` to `.borrowed` so drop insertion skips
    // a spurious scope-exit release.
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares preserves share when source is .trivial" {
    // Defensive guard: even though the IR builder never emits a share
    // for a `.trivial` source (non-ARC types don't go through the
    // share path in `lowerExpr.call`), if a hand-rolled IR presents
    // such a shape the pass must refuse to elide. A .trivial source
    // has no refcount to begin with; treating it as life-extended
    // would be vacuously safe here but is not the shape we want to
    // certify.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .trivial, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);

    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_release_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_1 = true;
            },
            else => {},
        }
    }
    // .trivial source: the pass must refuse to elide.
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_1);
}

test "arc_ownership: elideBorrowedPassThroughShares is a no-op when callee slot is .owned" {
    // .owned slots are handled by `rewriteOwnedConsumeSites` which
    // already converted the share to move_value and dropped the
    // release before this pass runs. To simulate a programmer error
    // (or an upstream pass bug) where the share survived past that
    // rewrite, present an .owned slot and assert this pass refuses to
    // touch it — V7 would reject the resulting share→.owned chain.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .owned;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.owned});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 1);
    caller_param_conv[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "src", .type_expr = .void, .type_id = null };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);

    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_release_1 = false;
    var saw_borrow_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_1 = true;
            },
            .borrow_value => |bv| if (bv.dest == 1) {
                saw_borrow_dest_1 = true;
            },
            else => {},
        }
    }
    // .owned slot: no elision. The share/release pair stays.
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_1);
    try std.testing.expect(!saw_borrow_dest_1);
}

test "arc_ownership: elideBorrowedPassThroughShares rewrites share for call_builtin .borrowed slot when source is .owned" {
    // call_builtin path: `List.get`'s first slot is `.borrowed` by
    // the runtime ABI (not in `builtinArgCanMoveAtLastUse`). When the
    // source is `.owned` (our function holds a +1 until scope exit),
    // the retain/release pair is bookkeeping.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const caller_args = try arena.alloc(ir.LocalId, 2);
    caller_args[0] = 1; // share dest (the list)
    caller_args[1] = 3; // index local
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 2);
    caller_arg_modes[0] = .share;
    caller_arg_modes[1] = .move;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        // Locals: 0=owned list, 1=share dest, 2=get result, 3=index
        .{ .const_int = .{ .dest = 3, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "List.get",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
            .result_type = .i64,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[0], &program);

    const rewritten = functions[0].body[0].instructions;
    var saw_share = false;
    var saw_release_1 = false;
    var saw_borrow_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_1 = true;
            },
            .borrow_value => |bv| if (bv.dest == 1 and bv.source == 0) {
                saw_borrow_dest_1 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_release_1);
    try std.testing.expect(saw_borrow_dest_1);
}

test "arc_ownership: elideBorrowedPassThroughShares leaves consume call_builtin slots untouched" {
    // `Map.put`'s slot 0 is in `builtinArgCanMoveAtLastUse` — it's a
    // consume slot rewritten by `rewriteOwnedConsumeBuiltinSites`
    // when last-use fires. If the source has additional uses past
    // the share, the consume rewriter keeps the share so the runtime
    // sees refcount >= 2 (its consume signature is "always
    // consumed"; the share's retain provides the +1 it
    // decrements). This pass must NOT touch those — they look like
    // borrowed-pass-through but the runtime ABI is consume.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const caller_args = try arena.alloc(ir.LocalId, 3);
    caller_args[0] = 1; // map share dest
    caller_args[1] = 4; // key
    caller_args[2] = 5; // value
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 3);
    caller_arg_modes[0] = .share;
    caller_arg_modes[1] = .move;
    caller_arg_modes[2] = .move;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 4, .value = 7, .type_hint = null } },
        .{ .const_int = .{ .dest = 5, .value = 42, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "Map.put",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
            .result_type = .any,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .trivial, .trivial, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 6,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[0], &program);

    const rewritten = functions[0].body[0].instructions;
    var saw_share = false;
    var saw_release_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .release => |r| if (r.value == 1) {
                saw_release_1 = true;
            },
            else => {},
        }
    }
    // Map.put slot 0 is a consume slot — pass refuses to elide.
    try std.testing.expect(saw_share);
    try std.testing.expect(saw_release_1);
}

test "arc_ownership: elideBorrowedPassThroughShares handles nested streams (if_expr arms)" {
    // The pass must recurse into if/case/switch/dispatch bodies — the
    // canonical spectral-norm pattern is a `share_value` for a
    // recursive call argument that lives inside an `else` arm of an
    // `if_expr`. Without recursion the elision misses every
    // recursive-step share and the optimisation never fires on the
    // benchmark hot paths.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    // Caller's if_expr:
    //   if cond %3 { then: %4 = 1 } else { share %5 <- %0; retain %5; call target(%5); release %5; %4 = 2 }
    const else_call_args = try arena.alloc(ir.LocalId, 1);
    else_call_args[0] = 5;
    const else_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    else_call_arg_modes[0] = .share;
    const else_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .share_value = .{ .dest = 5, .source = 0 } },
        .{ .retain = .{ .value = 5, .kind = .normal } },
        .{ .call_named = .{
            .dest = 6,
            .name = "Mod__target__1",
            .args = else_call_args,
            .arg_modes = else_call_arg_modes,
        } },
        .{ .release = .{ .value = 5 } },
        .{ .const_int = .{ .dest = 4, .value = 2, .type_hint = null } },
    });
    const then_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 4, .value = 1, .type_hint = null } },
    });
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_bool = .{ .dest = 3, .value = false } },
        .{ .if_expr = .{
            .dest = 4,
            .condition = 3,
            .then_instrs = then_instrs,
            .else_instrs = else_instrs,
            .then_result = 4,
            .else_result = 4,
        } },
        .{ .ret = .{ .value = 4 } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 1);
    caller_param_conv[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "src", .type_expr = .void, .type_id = null };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .trivial, .trivial, .trivial, .trivial, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .i64,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);

    // The share+retain+release must have been elided from the else arm.
    var saw_share = false;
    var saw_release_5 = false;
    var saw_borrow_dest_5 = false;
    const ScanCtx = struct {
        share: *bool,
        release: *bool,
        borrow: *bool,

        fn visit(ctx: *@This(), instr: *const ir.Instruction) void {
            switch (instr.*) {
                .share_value => ctx.share.* = true,
                .release => |r| if (r.value == 5) {
                    ctx.release.* = true;
                },
                .borrow_value => |bv| if (bv.dest == 5 and bv.source == 0) {
                    ctx.borrow.* = true;
                },
                else => {},
            }
        }
    };
    var scan_ctx = ScanCtx{ .share = &saw_share, .release = &saw_release_5, .borrow = &saw_borrow_dest_5 };
    ir.forEachInstruction(&functions[1], &scan_ctx, ScanCtx.visit);
    try std.testing.expect(!saw_share);
    try std.testing.expect(!saw_release_5);
    try std.testing.expect(saw_borrow_dest_5);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses when share dest has a second use" {
    // The safe Phase 8 slice is a single borrowed pass-through:
    // share/retain feeding exactly one borrowed call, then the paired
    // post-call release. If the share dest is used again, even by a
    // borrowed call, the pass must leave the original ownership shape
    // intact so later phases see the exact producer/use chain.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const first_call_args = try arena.alloc(ir.LocalId, 1);
    first_call_args[0] = 1;
    const first_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    first_call_arg_modes[0] = .share;
    const second_call_args = try arena.alloc(ir.LocalId, 1);
    second_call_args[0] = 1;
    const second_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    second_call_arg_modes[0] = .borrow;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = first_call_args,
            .arg_modes = first_call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .call_named = .{
            .dest = 3,
            .name = "Mod__target__1",
            .args = second_call_args,
            .arg_modes = second_call_arg_modes,
        } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 1);
    caller_param_conv[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "src", .type_expr = .void, .type_id = null };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .trivial, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);

    const rewritten = functions[1].body[0].instructions;
    var saw_share = false;
    var saw_retain_1 = false;
    var saw_release_1 = false;
    var saw_borrow_dest_1 = false;
    for (rewritten) |instr| {
        switch (instr) {
            .share_value => saw_share = true,
            .retain => |retain| if (retain.value == 1) {
                saw_retain_1 = true;
            },
            .release => |release| if (release.value == 1) {
                saw_release_1 = true;
            },
            .borrow_value => |borrow_value| if (borrow_value.dest == 1) {
                saw_borrow_dest_1 = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_share);
    try std.testing.expect(saw_retain_1);
    try std.testing.expect(saw_release_1);
    try std.testing.expect(!saw_borrow_dest_1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, functions[1].local_ownership[1]);
}

test "arc_ownership: elided borrowed pass-through does not receive stale scope-exit release" {
    // Prove the downstream contract: after elision rewrites the share
    // dest to borrow_value and local_ownership[dest] to .borrowed,
    // drop insertion must not synthesize a scope-exit release for that
    // dest even if stale liveness input still lists it before ret.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const target_param_conv = try arena.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = .borrowed;
    const target_params = try arena.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_func = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 1;
    const caller_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_arg_modes[0] = .share;
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = caller_args,
            .arg_modes = caller_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conv = try arena.alloc(ir.ParamConvention, 1);
    caller_param_conv[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "src", .type_expr = .void, .type_id = null };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .trivial,
    });
    const caller_func = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_func;
    functions[1] = caller_func;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[1], &program);
    try std.testing.expectEqual(ir.OwnershipClass.borrowed, functions[1].local_ownership[1]);

    var ownership: arc_liveness.ArcOwnership = .{};
    defer ownership.deinit(std.testing.allocator);
    var live_set: arc_liveness.ArcLocalSet = .empty;
    errdefer live_set.deinit(std.testing.allocator);
    try live_set.put(std.testing.allocator, 1, {});
    // Post-elision stream ids: param_get=0, borrow_value=1,
    // call_named=2, ret=3.
    try ownership.live_before_ret.putNoClobber(std.testing.allocator, 3, live_set);

    try arc_drop_insertion.insertScopeExitDrops(arena, &functions[1], &ownership);

    var releases_of_borrow_dest: usize = 0;
    for (functions[1].body[0].instructions) |instr| {
        if (instr == .release and instr.release.value == 1) {
            releases_of_borrow_dest += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), releases_of_borrow_dest);
}

const BorrowedPassThroughTestFixture = struct {
    functions: []ir.Function,
    program: ir.Program,
};

fn buildBorrowedPassThroughTestFixture(
    arena: std.mem.Allocator,
    caller_instrs: []const ir.Instruction,
    caller_local_ownership: []const ir.OwnershipClass,
) !BorrowedPassThroughTestFixture {
    const target_param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    const target_params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "x", .type_expr = .void, .type_id = null },
    });
    const target_blocks = try arena.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{.borrowed});
    const target_function = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conventions,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    const caller_params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "src", .type_expr = .void, .type_id = null },
    });
    const caller_function = ir.Function{
        .id = 200,
        .name = "Mod__caller__1",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = @intCast(caller_local_ownership.len),
        .param_conventions = caller_param_conventions,
        .local_ownership = try arena.dupe(ir.OwnershipClass, caller_local_ownership),
        .result_convention = .trivial,
    };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = target_function;
    functions[1] = caller_function;
    return .{
        .functions = functions,
        .program = .{ .functions = functions, .type_defs = &.{}, .entry = null },
    };
}

fn expectBorrowedPassThroughUnchanged(function: *const ir.Function, arg_local: ir.LocalId) !void {
    var saw_share = false;
    var saw_retain = false;
    var saw_release = false;
    var saw_borrow = false;
    for (function.body[0].instructions) |instr| {
        switch (instr) {
            .share_value => |share| if (share.dest == arg_local) {
                saw_share = true;
            },
            .retain => |retain| if (retain.value == arg_local) {
                saw_retain = true;
            },
            .release => |release| if (release.value == arg_local) {
                saw_release = true;
            },
            .borrow_value => |borrow_value| if (borrow_value.dest == arg_local) {
                saw_borrow = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_share);
    try std.testing.expect(saw_retain);
    try std.testing.expect(saw_release);
    try std.testing.expect(!saw_borrow);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses always-consuming call_builtin slots" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{ 1, 3 });
    const arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{ .share, .borrow });
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "List.cons",
            .args = args,
            .arg_modes = arg_modes,
            .result_type = .any,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = caller_instrs };
    const caller_local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned,
    });
    const caller_function = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = &.{},
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try arena.dupe(ir.Function, &[_]ir.Function{caller_function});
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    try elideBorrowedPassThroughShares(arena, &functions[0], &program);

    try expectBorrowedPassThroughUnchanged(&functions[0], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, functions[0].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses share dest with intervening definition" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .const_nil = 1 },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .owned, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, fixture.functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses try_call_named success_result use of share dest" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const try_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{});
    const try_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .try_call_named = .{
            .dest = 4,
            .name = "Mod__maybe__0",
            .args = try_args,
            .arg_modes = try_arg_modes,
            .input_local = 5,
            .handler_instrs = &.{},
            .handler_result = null,
            .success_instrs = &.{},
            .success_result = 1,
            .payload_local = null,
        } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .owned, .trivial, .trivial, .trivial, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, fixture.functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses try_call_named handler_result use of share dest" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const try_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{});
    const try_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .try_call_named = .{
            .dest = 4,
            .name = "Mod__maybe__0",
            .args = try_args,
            .arg_modes = try_arg_modes,
            .input_local = 5,
            .handler_instrs = &.{},
            .handler_result = 1,
            .success_instrs = &.{},
            .success_result = null,
            .payload_local = null,
        } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .owned, .trivial, .trivial, .trivial, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, fixture.functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses try_call_named payload_local reuse of share dest" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const try_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{});
    const try_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .try_call_named = .{
            .dest = 4,
            .name = "Mod__maybe__0",
            .args = try_args,
            .arg_modes = try_arg_modes,
            .input_local = 5,
            .handler_instrs = &.{},
            .handler_result = null,
            .success_instrs = &.{},
            .success_result = null,
            .payload_local = 1,
        } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .owned, .trivial, .trivial, .trivial, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, fixture.functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses optional_dispatch payload_local reuse of share dest" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .optional_dispatch = .{
            .scrutinee_param = 0,
            .payload_local = 1,
            .nil_instrs = &.{},
            .nil_result = null,
            .struct_instrs = &.{},
            .struct_result = null,
        } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .owned, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.owned, fixture.functions[1].local_ownership[1]);
}

test "arc_ownership: elideBorrowedPassThroughShares refuses non-owned share dest local" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const call_args = try arena.dupe(ir.LocalId, &[_]ir.LocalId{1});
    const call_arg_modes = try arena.dupe(ir.ValueMode, &[_]ir.ValueMode{.share});
    const caller_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .retain = .{ .value = 1, .kind = .normal } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = call_args,
            .arg_modes = call_arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    var fixture = try buildBorrowedPassThroughTestFixture(
        arena,
        caller_instrs,
        &[_]ir.OwnershipClass{ .borrowed, .trivial, .trivial },
    );

    try elideBorrowedPassThroughShares(arena, &fixture.functions[1], &fixture.program);

    try expectBorrowedPassThroughUnchanged(&fixture.functions[1], 1);
    try std.testing.expectEqual(ir.OwnershipClass.trivial, fixture.functions[1].local_ownership[1]);
}

// ============================================================
// arc-own-1--02: count-mutating-rewrite / stale-id consistency.
//
// `rewriteOwnedConsumeBuiltinSites` changes the instruction count
// (it drops the post-call `release` for a consumed receiver, and can
// expand a `borrow_value` into `copy_value`+`retain`). The downstream
// id-consuming passes — `classifyAndNormalizeWithProgram`'s three move
// gates and the second builtin-consume run — reconstruct InstructionIds
// purely positionally from the *current* IR. If they are handed the
// same ownership table the analyzer built against the *pre-mutation* IR,
// every id after the first count change is off by the count delta and
// the `last_use_map` / `last_use_sites` lookups are mis-keyed.
//
// The fix (compiler.zig) recomputes `ProgramArcOwnership` immediately
// after each count-mutating rewrite so the id-consuming pass keys into a
// table whose `record_count` matches the IR it walks. These tests pin
// the invariant `consumerWalkMatches` enforces: a table captured before
// the count mutation no longer matches the post-mutation walk (the bug),
// and a recomputed table does (the fix).

test "arc_ownership: rewriteOwnedConsumeBuiltinSites mutates instruction count, desyncing a pre-mutation ownership table" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Same shape as the canonical "Map.put at last-use" rewrite test:
    //   [0] const_int %0
    //   [1] share_value %1 <- %0
    //   [2] call_builtin "Map.put" args=[%1, %2, %3] dest=%4
    //   [3] release %1
    //   [4] ret
    // At %0's last-use the share becomes move_value and the release of
    // %1 is DROPPED, so the instruction count falls from 5 to 4.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 1;
    args[1] = 5;
    args[2] = 6;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .share;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial, .trivial, .owned, .trivial, .trivial,
    });
    var function = ir.Function{
        .id = 700,
        .name = "Mod__stale_id_guard__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 7,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    // Capture the instruction count the analyzer would have recorded
    // BEFORE any mutation, exactly as `computeArcOwnership` stamps
    // `record_count`. A real analysis would also populate
    // `last_use_sites`; the count is the load-bearing field for the
    // consistency invariant, so the synthetic table mirrors it.
    const pre_count = arc_liveness.countInstructionRecords(&function);
    try std.testing.expectEqual(@as(usize, 5), pre_count);

    var stale_ownership: arc_liveness.ArcOwnership = .{};
    defer stale_ownership.deinit(arena);
    try stale_ownership.last_use_map.put(arena, 0, 1);
    stale_ownership.record_count = pre_count;

    // A positional consumer walking the PRE-mutation IR matches.
    try std.testing.expect(arc_liveness.consumerWalkMatches(&stale_ownership, pre_count));

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &stale_ownership);

    // The rewrite dropped the release: the count is now strictly lower.
    const post_count = arc_liveness.countInstructionRecords(&function);
    try std.testing.expectEqual(@as(usize, 4), post_count);
    try std.testing.expect(post_count != pre_count);

    // THE BUG: an id-consuming pass (e.g. classify's StreamRewriter)
    // walking the post-mutation IR arrives at `post_count`, but the
    // stale table still records `pre_count`. The keys are desynced.
    try std.testing.expect(!arc_liveness.consumerWalkMatches(&stale_ownership, post_count));

    // THE FIX: a table recomputed against the post-mutation IR records
    // `post_count`, so the same id-consuming walk is back in sync.
    var fresh_ownership: arc_liveness.ArcOwnership = .{};
    defer fresh_ownership.deinit(arena);
    fresh_ownership.record_count = post_count;
    try std.testing.expect(arc_liveness.consumerWalkMatches(&fresh_ownership, post_count));
}

test "arc_ownership: borrow->copy expansion in builtin consume rewrite grows instruction count" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // `List.push(list, value)` always consumes its element argument.
    // When the element is a borrowed alias of a lifetime-extended cell,
    // the rewrite expands the `borrow_value` into `copy_value`+`retain`
    // (two instructions where there was one), so the count GROWS — the
    // `+K` insertion-shift direction the audit flags as the structurally
    // unsound side of the desync.
    //   [0] param_get %0        (the list receiver; borrowed param)
    //   [1] param_get %1        (the source cell; owned param, extended)
    //   [2] borrow_value %2 <- %1
    //   [3] call_builtin "List.push" args=[%0, %2] dest=%3
    //   [4] ret
    const push_args = try arena.alloc(ir.LocalId, 2);
    push_args[0] = 0;
    push_args[1] = 2;
    const push_modes = try arena.alloc(ir.ValueMode, 2);
    push_modes[0] = .borrow;
    push_modes[1] = .borrow;
    const instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .borrow_value = .{ .dest = 2, .source = 1 } },
        .{ .call_builtin = .{
            .dest = 3,
            .name = "List.push",
            .args = push_args,
            .arg_modes = push_modes,
        } },
        .{ .ret = .{ .value = null } },
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = instrs };
    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .borrowed, .owned, .borrowed, .owned,
    });
    const params = try arena.dupe(ir.Param, &[_]ir.Param{
        .{ .name = "list", .type_expr = .void, .type_id = null },
        .{ .name = "value", .type_expr = .void, .type_id = null },
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{ .borrowed, .owned });
    var function = ir.Function{
        .id = 701,
        .name = "Mod__push_borrow_copy__1",
        .scope_id = 0,
        .arity = 2,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    const pre_count = arc_liveness.countInstructionRecords(&function);
    try std.testing.expectEqual(@as(usize, 5), pre_count);

    var stale_ownership: arc_liveness.ArcOwnership = .{};
    defer stale_ownership.deinit(arena);
    stale_ownership.record_count = pre_count;

    try rewriteOwnedConsumeBuiltinSites(arena, &function, &stale_ownership);

    // borrow_value -> copy_value + retain: count grew by one.
    const post_count = arc_liveness.countInstructionRecords(&function);
    try std.testing.expectEqual(@as(usize, 6), post_count);
    try std.testing.expect(post_count > pre_count);

    // Stale table desynced in the growth direction too.
    try std.testing.expect(!arc_liveness.consumerWalkMatches(&stale_ownership, post_count));
}
