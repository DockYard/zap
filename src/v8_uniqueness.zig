const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");

// ============================================================
// V8 — static-uniqueness analysis (Phase 3 of the dense-map plan).
//
// Pipeline placement (per docs/dense-map-implementation-plan.md §1.5):
//
//     ... → arc_liveness                    (last-use side table)
//          → arc_param_convention           (.borrowed → .owned promotion)
//             → arc_ownership.rewriteOwnedConsumeBuiltinSites  (Phase 4)
//                → arc_ownership.classifyAndNormalize          (borrow/copy)
//                   → arc_ownership.rewriteOwnedConsumeSites   (Phase E.9.2)
//                      → v8_uniqueness  (THIS PASS — produces "uniqueness"
//                                       side table for codegen + verifier)
//                         → arc_verifier  (V1–V8)
//                            → arc_drop_insertion
//                               → ...
//
// Why V8 exists:
//
// Phase 4 (commit 0b41035) made the rc-1 fast path fire on every
// owned-mutating call to `Map.put`/`.delete`/`.merge` and
// `Vector.set`/`.push`/`.pop`/`.append` whose receiver is at last
// use. The fast path mutates the buffer in place and avoids the
// deep-retain clone that the shared (rc>1) path requires. But the
// runtime still pays a per-call cost: every `Map.put` enters the
// Zig runtime, atomically loads `header.ref_count` (.acquire), tests
// `count() == 1`, and branches. On 2-billion-call write-saturated
// workloads (fannkuch-redux Phase 6 port), the load+compare+branch
// adds ~32% to wall time.
//
// V8 closes that gap by proving — at the IR level — that a given
// owned-mutating call site receives a refcount-1 cell. When V8
// holds, the codegen can emit a runtime variant that mutates in
// place WITHOUT loading the refcount: `Map.put_owned_unchecked`,
// `Vector.set_owned_unchecked`, etc. These are zero-branch, in-place
// mutations.
//
// Soundness:
//
// V8 is a refinement of Phase 4's last-use predicate. Every V8 call
// site is also a last-use site (the receiver is dead after the call,
// so the move_value fired); the converse does not hold (last use
// alone does not prove the cell never had its refcount bumped before
// the call).
//
// Concretely, V8 proves `definitely_unique` along a forward dataflow:
//
//   * A local L is `unique` immediately after:
//     - A fresh allocation that returns rc=1 (Map.new, Vector.new_*,
//       any owned-mutating call's result, ...).
//     - A `move_value` from a `unique` source.
//
//   * A local L is `not unique` after any of:
//     - `share_value` (the source's refcount transiently went to 2;
//       even after a paired release the source's owns count returns
//       to 1, but the analysis observes the transient share at the
//       call site, where the receiver might still be aliased).
//     - `copy_value` (the runtime emits an explicit retain; both
//       source and dest refer to the same cell with refcount >= 2).
//     - Storage in any aggregate (`list_cons`, `map_init`,
//       `tuple_init`, `struct_init`, `union_init`, `list_init`).
//       The aggregate now holds a strong reference to L's cell,
//       so any later mutation through L is on a shared cell.
//     - Function parameter (`param_get`): the caller's refcount is
//       opaque to the callee; conservatively NOT unique.
//
// The analysis runs forward through every instruction stream
// (top-level body and nested arms), maintaining a per-LocalId
// `definitely_unique` bitset. At each owned-mutating call site, we
// snapshot whether the receiver slot is unique. The result is a
// per-call-site predicate keyed by the call's InstructionId.
//
// Two-edge call chain:
//
// User code calls `Map.put` (a Zap fn in `lib/map.zap`) which
// forwards to `:zig.Map.put` (a `call_builtin` to the runtime).
// V8 must hold at the user's call site OR at the wrapper's
// call_builtin to enable the unchecked variant. Since the analysis
// is per-function, we report uniqueness at every owned-mutating
// call site (regardless of whether it's `call_named` or
// `call_builtin`); the codegen layer that consumes V8 picks the
// site at which to emit the `_owned_unchecked` form.
//
// Conservative defaults: when in doubt, V8 is FALSE. A wrong TRUE
// would produce undefined behavior in the unchecked runtime variant
// (mutate a shared cell). A wrong FALSE costs only the runtime check
// (the existing Phase 4 path).
//
// ============================================================

/// Output of `analyzeUniqueness`. Maps owned-mutating call sites to
/// whether the receiver is provably uniquely owned at the call.
///
/// Keyed by the `InstructionId` of the owned-mutating call (the
/// `call_builtin`, `call_named`, `call_direct`, or `try_call_named`
/// instruction itself). The InstructionId mirrors the depth-first
/// traversal order used by `arc_liveness.assignInstructionIds`, so
/// the verifier and codegen can resolve their site queries by the
/// same id space the rest of the ARC pipeline uses.
///
/// Absence from the map means "not an owned-mutating call site" or
/// "could not be analysed" — both are equivalent to V8 = false (the
/// verifier rejects unchecked variants whose call site is absent;
/// the codegen falls back to the checked variant).
pub const Uniqueness = struct {
    /// Per-call-site uniqueness predicate. `true` means the receiver
    /// is provably unique at the call; `false` (or absence) means the
    /// caller cannot prove uniqueness and the checked runtime variant
    /// must fire.
    sites: std.AutoHashMapUnmanaged(arc_liveness.InstructionId, bool) = .empty,

    pub fn deinit(self: *Uniqueness, allocator: std.mem.Allocator) void {
        self.sites.deinit(allocator);
    }

    /// Look up the predicate for a specific owned-mutating call site.
    /// Returns `false` for sites that are absent from the map (the
    /// safe default — the call site was not classified as unique).
    pub fn isUnique(self: *const Uniqueness, instr_id: arc_liveness.InstructionId) bool {
        return self.sites.get(instr_id) orelse false;
    }
};

/// Run the V8 forward dataflow on `function` and produce a per-
/// owned-mutating-call uniqueness predicate.
///
/// `program` is consulted only to resolve the callee's
/// `param_conventions` for `call_named`/`call_direct` sites: when the
/// receiver slot's convention is `.owned`, the call consumes the
/// receiver's `+1` and the result is fresh-rc=1, so the result is
/// unique by construction. Without a program reference (e.g. test
/// scaffolding), the analysis still classifies fresh-allocation and
/// `call_builtin` results conservatively.
///
/// The pass does NOT mutate the IR. It only produces the side table.
pub fn analyzeUniqueness(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
) !Uniqueness {
    var analyzer = Analyzer{
        .allocator = allocator,
        .function = function,
        .program = program,
        .unique = .empty,
        .next_id = 0,
        .result = .{},
    };
    defer analyzer.unique.deinit(allocator);

    errdefer analyzer.result.deinit(allocator);

    for (function.body) |block| {
        try analyzer.walkStream(block.instructions);
    }

    return analyzer.result;
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    /// Set of LocalIds proven `definitely_unique` at the current
    /// program point. Updated by `applyEffect` as the walker visits
    /// each instruction in depth-first order.
    unique: std.AutoHashMapUnmanaged(ir.LocalId, void),
    /// Running InstructionId, mirrored from the depth-first traversal
    /// order used by `arc_liveness.assignInstructionIds`. Both walks
    /// must agree on id assignment so the verifier and codegen can
    /// cross-reference their per-instruction queries.
    next_id: arc_liveness.InstructionId,
    /// Output table — populated during the walk.
    result: Uniqueness,

    fn walkStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.classifyCallSiteIfApplicable(instr, my_id);
            try self.applyEffect(instr);
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        // The forward dataflow inside a structural arm starts from
        // the parent stream's current `unique` set. Different arms of
        // an if/switch can leave different sets; for the purposes of
        // V8 (which is a per-call-site predicate, not a join-set
        // predicate), we walk every arm but reset the uniqueness set
        // back to the parent's snapshot after each arm so that
        // subsequent instructions in the parent stream observe the
        // pre-branch state. This is conservative — a local that
        // becomes unique inside one arm but not another would be
        // tracked as still-unique inside the arm and reset at the
        // arm boundary, which is correct for any owned-mutating call
        // site INSIDE the arm.
        switch (instr.*) {
            .if_expr => |ie| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(ie.then_instrs);
                try self.restore(&snap);
                try self.walkStream(ie.else_instrs);
                try self.restore(&snap);
            },
            .case_block => |cb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(cb.pre_instrs);
                const post_pre = try self.snapshot();
                defer post_pre.deinit(self.allocator);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                    try self.restore(&post_pre);
                }
                try self.walkStream(cb.default_instrs);
                try self.restore(&snap);
            },
            .switch_literal => |sl| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sl.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sl.default_instrs);
                try self.restore(&snap);
            },
            .switch_return => |sr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sr.default_instrs);
                try self.restore(&snap);
            },
            .union_switch => |us| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (us.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .union_switch_return => |usr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (usr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .try_call_named => |tcn| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(tcn.handler_instrs);
                try self.restore(&snap);
                try self.walkStream(tcn.success_instrs);
                try self.restore(&snap);
            },
            .guard_block => |gb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(gb.body);
                try self.restore(&snap);
            },
            .optional_dispatch => |od| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(od.nil_instrs);
                try self.restore(&snap);
                try self.walkStream(od.struct_instrs);
                try self.restore(&snap);
            },
            else => {},
        }
    }

    fn snapshot(self: *Analyzer) error{OutOfMemory}!Snapshot {
        var copy: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        var iter = self.unique.keyIterator();
        while (iter.next()) |k| {
            try copy.put(self.allocator, k.*, {});
        }
        return Snapshot{ .set = copy };
    }

    fn restore(
        self: *Analyzer,
        snap: *const Snapshot,
    ) error{OutOfMemory}!void {
        self.unique.clearRetainingCapacity();
        var iter = snap.set.keyIterator();
        while (iter.next()) |k| {
            try self.unique.put(self.allocator, k.*, {});
        }
    }

    /// Before applying the instruction's effect to the dataflow set,
    /// classify whether this instruction is an owned-mutating call
    /// site. If so, snapshot the receiver's uniqueness as observed
    /// in the PRE-call dataflow state and store it in the result map.
    ///
    /// Why classify pre-effect: V8 asks "was the receiver unique when
    /// it entered the call?" The call's own effect (consume the
    /// receiver, produce a fresh result) is applied AFTER this
    /// classification; classifying after-effect would describe the
    /// call's result, not its receiver.
    fn classifyCallSiteIfApplicable(
        self: *Analyzer,
        instr: *const ir.Instruction,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        const slot_and_recv = self.callSiteOwnedMutating(instr) orelse return;
        const recv = slot_and_recv.receiver;
        const is_unique = self.unique.contains(recv);
        try self.result.sites.put(self.allocator, my_id, is_unique);
    }

    const CallSiteInfo = struct {
        receiver: ir.LocalId,
    };

    /// If `instr` is an owned-mutating call site (per
    /// `arc_liveness.ownedMutatingBuiltinSlot` for `call_builtin`,
    /// or a `call_named` / `call_direct` whose name matches an owned-
    /// mutating builtin pattern), return the receiver LocalId at the
    /// receiver slot. Otherwise null.
    ///
    /// We accept both `call_builtin` (the post-monomorph runtime
    /// intrinsic) and `call_named` whose name matches the same
    /// pattern (the user-facing Zap-fn wrapper, e.g. `Map.put`).
    /// Either site is a candidate for the unchecked-variant codegen
    /// in a follow-up session.
    ///
    /// `call_direct` requires a program reference to resolve the
    /// `FunctionId` to a name; without a program, we skip
    /// `call_direct` sites. The codegen targets are typed
    /// `call_builtin` and `call_named`, so this is not a meaningful
    /// loss in practice.
    fn callSiteOwnedMutating(
        self: *Analyzer,
        instr: *const ir.Instruction,
    ) ?CallSiteInfo {
        switch (instr.*) {
            .call_builtin => |cb| {
                const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name) orelse return null;
                if (slot >= cb.args.len) return null;
                return .{ .receiver = cb.args[slot] };
            },
            .call_named => |cn| {
                const slot = arc_liveness.ownedMutatingBuiltinSlot(cn.name) orelse return null;
                if (slot >= cn.args.len) return null;
                return .{ .receiver = cn.args[slot] };
            },
            .call_direct => |cd| {
                const name = self.lookupFunctionName(cd.function) orelse return null;
                const slot = arc_liveness.ownedMutatingBuiltinSlot(name) orelse return null;
                if (slot >= cd.args.len) return null;
                return .{ .receiver = cd.args[slot] };
            },
            .try_call_named => |tcn| {
                const slot = arc_liveness.ownedMutatingBuiltinSlot(tcn.name) orelse return null;
                if (slot >= tcn.args.len) return null;
                return .{ .receiver = tcn.args[slot] };
            },
            else => return null,
        }
    }

    fn lookupFunctionName(self: *const Analyzer, function_id: ir.FunctionId) ?[]const u8 {
        const program = self.program orelse return null;
        for (program.functions) |func| {
            if (func.id == function_id) return func.name;
        }
        return null;
    }

    /// Apply the dataflow transfer function for `instr`. Updates
    /// `self.unique` in place. The contract is forward-dataflow:
    /// after this call, `self.unique` contains the LocalIds that
    /// are proven `definitely_unique` IMMEDIATELY AFTER `instr`
    /// executes.
    ///
    /// Effect rules (see top-of-file documentation for the why):
    ///
    ///   Sets dest unique:
    ///     * Fresh allocations: aggregate inits (the cell is freshly
    ///       allocated by the IR builder, so refcount = 1 by
    ///       construction; this matches the runtime's `bufferAlloc`
    ///       contract).
    ///     * Owned-mutating call results (`call_builtin` /
    ///       `call_named` / `call_direct` matching the owned-
    ///       mutating builtin pattern): the runtime contract is
    ///       "result is a buffer with refcount = 1" — either the
    ///       rc-1 fast path returned the same cell (now unique
    ///       because we consumed our share), or the shared path
    ///       returned a fresh clone. Both are unique.
    ///     * `move_value` from a unique source: dest takes over the
    ///       source's +1; source is no longer the live owner.
    ///
    ///   Clears (or fails to set) dest unique:
    ///     * `share_value`, `copy_value`: the value's refcount went
    ///       up; both source and dest see the bumped count.
    ///     * `borrow_value`: dest is a borrow, not an owner.
    ///     * `param_get`: callers are responsible for the refcount;
    ///       conservatively NOT unique.
    ///     * Storage in aggregates: any LocalId stored as part of
    ///       a `list_cons`, `map_init`, `tuple_init`, `struct_init`,
    ///       `union_init`, `list_init` element loses uniqueness —
    ///       the aggregate now holds a permanent retain.
    ///
    /// Locals not explicitly handled (control flow, releases,
    /// retains, returns): no effect on uniqueness.
    fn applyEffect(
        self: *Analyzer,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            // ----- Producers of unique values -----
            .tuple_init => |ti| {
                // Aggregate INITS produce a fresh aggregate cell
                // (refcount = 1). However, every operand stored
                // INTO that aggregate loses uniqueness because the
                // aggregate holds a permanent retain on it.
                for (ti.elements) |elem| _ = self.unique.remove(elem);
                try self.unique.put(self.allocator, ti.dest, {});
            },
            .list_init => |li| {
                for (li.elements) |elem| _ = self.unique.remove(elem);
                try self.unique.put(self.allocator, li.dest, {});
            },
            .list_cons => |lc| {
                _ = self.unique.remove(lc.head);
                _ = self.unique.remove(lc.tail);
                try self.unique.put(self.allocator, lc.dest, {});
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    _ = self.unique.remove(entry.key);
                    _ = self.unique.remove(entry.value);
                }
                try self.unique.put(self.allocator, mi.dest, {});
            },
            .struct_init => |si| {
                for (si.fields) |f| _ = self.unique.remove(f.value);
                try self.unique.put(self.allocator, si.dest, {});
            },
            .union_init => |ui| {
                _ = self.unique.remove(ui.value);
                try self.unique.put(self.allocator, ui.dest, {});
            },

            // Owned-mutating call results are unique by runtime contract
            // (see top-of-file). Non-mutating calls are conservatively
            // not classified as unique.
            .call_builtin => |cb| {
                if (arc_liveness.ownedMutatingBuiltinSlot(cb.name) != null) {
                    if (cb.args.len > 0) {
                        // The receiver was consumed by the move_value
                        // that fed args[0]; clear its bit here so any
                        // stale alias doesn't leak forward.
                        const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name).?;
                        if (slot < cb.args.len) {
                            _ = self.unique.remove(cb.args[slot]);
                        }
                    }
                    try self.unique.put(self.allocator, cb.dest, {});
                } else {
                    // Other call_builtin results: conservatively not
                    // unique (we don't know the runtime's refcount
                    // contract for arbitrary builtins).
                    _ = self.unique.remove(cb.dest);
                }
            },
            .call_named => |cn| {
                try self.applyOwnedMutatingCallEffect(cn.name, cn.args, cn.dest);
            },
            .call_direct => |cd| {
                if (self.lookupFunctionName(cd.function)) |name| {
                    try self.applyOwnedMutatingCallEffect(name, cd.args, cd.dest);
                } else {
                    _ = self.unique.remove(cd.dest);
                }
            },
            .try_call_named => |tcn| {
                try self.applyOwnedMutatingCallEffect(tcn.name, tcn.args, tcn.dest);
            },

            // ----- Move transfers uniqueness -----
            .move_value => |mv| {
                if (self.unique.contains(mv.source)) {
                    _ = self.unique.remove(mv.source);
                    try self.unique.put(self.allocator, mv.dest, {});
                } else {
                    // Move from a non-unique source — dest is also
                    // not unique. Clear in case a stale entry from a
                    // prior alias is sitting in the set.
                    _ = self.unique.remove(mv.dest);
                }
            },

            // ----- Shares / copies / borrows clear uniqueness -----
            .share_value => |sv| {
                // share_value{dest, source}: emits a retain on source.
                // Both source and dest now refer to a cell with
                // refcount >= 2 — neither is unique afterwards.
                _ = self.unique.remove(sv.source);
                _ = self.unique.remove(sv.dest);
            },
            .copy_value => |cv| {
                // copy_value: source kept (caller's refcount stays);
                // dest takes a new retain. After this point dest is
                // observably an alias, not the unique owner.
                _ = self.unique.remove(cv.dest);
            },
            .borrow_value => |bv| {
                // borrow_value: dest is a borrow, never an owner.
                _ = self.unique.remove(bv.dest);
            },

            // ----- Local aliasing: conservatively clear dest -----
            .local_get => |lg| {
                _ = self.unique.remove(lg.dest);
            },
            .local_set => |ls| {
                _ = self.unique.remove(ls.dest);
            },
            .param_get => |pg| {
                // Parameters: the caller controls the refcount.
                // Even an `.owned`-convention parameter could have
                // been retained by an upstream caller (the convention
                // says nothing about the caller's strategy beyond
                // "the callee takes the +1"). Conservatively NOT
                // unique.
                _ = self.unique.remove(pg.dest);
            },

            // ----- Control flow / non-data-producing instructions -----
            .release,
            .retain,
            .ret,
            .cond_return,
            .switch_tag,
            .branch,
            .cond_branch,
            .jump,
            .match_fail,
            .match_error_return,
            .case_break,
            .tail_call,
            .set_safety,
            => {},

            // ----- Other instructions: no effect on uniqueness -----
            // The set of instruction tags above is exhaustive for the
            // ARC pipeline's existing test corpus. New IR opcodes
            // that produce values should explicitly opt in here.
            else => {},
        }
    }

    fn applyOwnedMutatingCallEffect(
        self: *Analyzer,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
    ) error{OutOfMemory}!void {
        if (arc_liveness.ownedMutatingBuiltinSlot(name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
        } else {
            // Non-mutating call: result not classified.
            _ = self.unique.remove(dest);
        }
    }
};

const Snapshot = struct {
    set: std.AutoHashMapUnmanaged(ir.LocalId, void),

    fn deinit(self: *const Snapshot, allocator: std.mem.Allocator) void {
        var mut = self.*;
        mut.set.deinit(allocator);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-rolled V8 analysis tests.
/// Caller owns the slices and is responsible for freeing them.
fn buildTestFunction(
    arena: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_count: u32,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, local_count);
    for (ownership) |*o| o.* = .owned;
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
        .param_conventions = &.{},
        .local_ownership = ownership,
        .result_convention = .trivial,
    };
}

test "v8_uniqueness: fresh-alloc receiver immediately mutated is unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}            -- fresh allocation, unique
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0          -- transfer uniqueness
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //
    // Expected: V8 holds at the call_builtin (id 4). Receiver %3 is
    // unique because it was move_value'd from a fresh map_init.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
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
    };
    var function = try buildTestFunction(arena, "fresh_alloc_then_put", &instrs, 5);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The call_builtin is at id 4 (the 5th instruction in the stream).
    try testing.expect(u.isUnique(4));
}

test "v8_uniqueness: receiver parked via list_cons before mutation is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}             -- fresh allocation, unique
    //   [1] const_nil %1                  -- trivial nil tail
    //   [2] list_cons %2 = [%0 | %1]     -- aggregate retain on %0
    //   [3] const_int %3 = 0
    //   [4] const_int %4 = 0
    //   [5] move_value %5 <- %0          -- but %0 is no longer unique
    //   [6] call_builtin "Map.put" args=[%5, %3, %4] dest=%6
    //
    // Expected: V8 fails at the call_builtin (id 6). Receiver %5 was
    // sourced from %0, which lost uniqueness when stored in the
    // list_cons at id 2.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 5;
    args[1] = 3;
    args[2] = 4;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
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
    };
    var function = try buildTestFunction(arena, "parked_then_put", &instrs, 7);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The call_builtin is at id 6.
    try testing.expect(!u.isUnique(6));
}

test "v8_uniqueness: result of owned-mutating call is unique (chains)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Map.put" args=[%3, %1, %2] dest=%4
    //   [5] const_int %5 = 1
    //   [6] const_int %6 = 1
    //   [7] move_value %7 <- %4
    //   [8] call_builtin "Map.put" args=[%7, %5, %6] dest=%8
    //
    // Expected: V8 holds at BOTH calls (id 4 and id 8). The second
    // call's receiver %7 is unique because it was move_value'd from
    // %4, the result of an owned-mutating call (which is unique by
    // runtime contract).
    const args1 = try arena.alloc(ir.LocalId, 3);
    args1[0] = 3;
    args1[1] = 1;
    args1[2] = 2;
    const arg_modes1 = try arena.alloc(ir.ValueMode, 3);
    arg_modes1[0] = .move;
    arg_modes1[1] = .borrow;
    arg_modes1[2] = .borrow;
    const args2 = try arena.alloc(ir.LocalId, 3);
    args2[0] = 7;
    args2[1] = 5;
    args2[2] = 6;
    const arg_modes2 = try arena.alloc(ir.ValueMode, 3);
    arg_modes2[0] = .move;
    arg_modes2[1] = .borrow;
    arg_modes2[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = args1,
            .arg_modes = arg_modes1,
        } },
        .{ .const_int = .{ .dest = 5, .value = 1 } },
        .{ .const_int = .{ .dest = 6, .value = 1 } },
        .{ .move_value = .{ .dest = 7, .source = 4 } },
        .{ .call_builtin = .{
            .dest = 8,
            .name = "Map.put",
            .args = args2,
            .arg_modes = arg_modes2,
        } },
    };
    var function = try buildTestFunction(arena, "chained_puts", &instrs, 9);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(u.isUnique(4));
    try testing.expect(u.isUnique(8));
}

test "v8_uniqueness: function-parameter receiver is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Simulated body of `Map.put` (lib/map.zap) — receives the map
    // as parameter index 0 and forwards to :zig.Map.put.
    //
    //   [0] param_get %0 = param[0]      -- map parameter
    //   [1] param_get %1 = param[1]      -- key parameter
    //   [2] param_get %2 = param[2]      -- value parameter
    //   [3] move_value %3 <- %0          -- but %0 is a parameter, not unique
    //   [4] call_builtin ":zig.Map.put" args=[%3, %1, %2] dest=%4
    //
    // Expected: V8 fails at id 4 — the receiver %3's source is a
    // parameter, whose refcount the callee cannot prove. The user-
    // facing wrapper's call site must use the checked variant.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
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
    };
    var function = try buildTestFunction(arena, "param_then_put", &instrs, 5);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(4));
}

test "v8_uniqueness: receiver share_value'd to a borrowed call then mutated is NOT unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                  -- fresh, unique
    //   [1] share_value %1 <- %0              -- transient share, %0 no longer unique
    //   [2] call_builtin "Map.size" args=[%1] dest=%2  -- borrowed call, no consume
    //   [3] release %1
    //   [4] const_int %3 = 0
    //   [5] const_int %4 = 0
    //   [6] move_value %5 <- %0               -- %0 was already cleared by share_value
    //   [7] call_builtin "Map.put" args=[%5, %3, %4] dest=%5
    //
    // Expected: V8 fails at id 7 — %0 lost uniqueness at the share_value.
    // (Runtime: the share path saw refcount=2, which decreased to 1 after
    // the release at id 3 — but the analysis is conservative and treats
    // the transient bump as "permanently" non-unique.)
    const size_args = try arena.alloc(ir.LocalId, 1);
    size_args[0] = 1;
    const size_modes = try arena.alloc(ir.ValueMode, 1);
    size_modes[0] = .share;
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 5;
    put_args[1] = 3;
    put_args[2] = 4;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "Map.size",
            .args = size_args,
            .arg_modes = size_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
    };
    var function = try buildTestFunction(arena, "shared_then_put", &instrs, 7);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // The Map.put call_builtin is at id 7.
    try testing.expect(!u.isUnique(7));
}

test "v8_uniqueness: copy_value clears uniqueness on dest" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] copy_value %1 <- %0           -- emits retain; both refer to refcount>=2 cell
    //   [2] const_int %2 = 0
    //   [3] const_int %3 = 0
    //   [4] move_value %4 <- %1           -- %1 is not unique
    //   [5] call_builtin "Map.put" args=[%4, %2, %3] dest=%5
    //
    // Expected: V8 fails at id 5.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 4;
    args[1] = 2;
    args[2] = 3;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .copy_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .move_value = .{ .dest = 4, .source = 1 } },
        .{ .call_builtin = .{
            .dest = 5,
            .name = "Map.put",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "copy_then_put", &instrs, 6);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(5));
}

test "v8_uniqueness: Vector.set and Vector.push fresh-alloc chain is unique" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream simulating `let mut v = Vector.new(...); Vector.set(v, 0, 42)` after
    // Phase 4's move-on-last-use rewrite:
    //
    //   [0] call_builtin "Vector.new_filled" -> %0     -- runtime returns rc=1
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 42
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Vector.set" args=[%3, %1, %2] dest=%4
    //
    // Expected: V8 holds at id 4. Vector.new_filled is not in the
    // owned-mutating list (it's a constructor), but Vector.new_filled
    // returns rc=1 by contract. We ALSO need to recognize allocator-
    // style call_builtin results as unique. For the analysis to be
    // useful in real Zap programs the producer-classification has to
    // be expansive enough to cover these constructors.
    //
    // For this phase, recognising Vector.new_filled as a unique-result
    // builtin is OPTIONAL — the analysis is conservative and falls
    // back to false. The important contract is: AFTER an owned-
    // mutating call, the result IS unique. So this test focuses on
    // the chain Vector.set → Vector.push:
    //
    //   [5] move_value %5 <- %4
    //   [6] const_int %6 = 99
    //   [7] call_builtin "Vector.push" args=[%5, %6] dest=%7
    //
    // V8 must hold at id 7 (the Vector.push receives the result of
    // an owned-mutating Vector.set, so V8 holds by chain-reasoning).
    const set_args = try arena.alloc(ir.LocalId, 3);
    set_args[0] = 3;
    set_args[1] = 1;
    set_args[2] = 2;
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
    const ctor_args = try arena.alloc(ir.LocalId, 0);
    const ctor_modes = try arena.alloc(ir.ValueMode, 0);
    const instrs = [_]ir.Instruction{
        .{ .call_builtin = .{
            .dest = 0,
            .name = "Vector.new_filled",
            .args = ctor_args,
            .arg_modes = ctor_modes,
        } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 42 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Vector.set",
            .args = set_args,
            .arg_modes = set_modes,
        } },
        .{ .move_value = .{ .dest = 5, .source = 4 } },
        .{ .const_int = .{ .dest = 6, .value = 99 } },
        .{ .call_builtin = .{
            .dest = 7,
            .name = "Vector.push",
            .args = push_args,
            .arg_modes = push_modes,
        } },
    };
    var function = try buildTestFunction(arena, "vec_chain", &instrs, 8);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    // Vector.push at id 7 — V8 holds because its source is the
    // result of an owned-mutating Vector.set.
    try testing.expect(u.isUnique(7));
}

test "v8_uniqueness: non-owned-mutating call sites are absent from the result" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] share_value %1 <- %0
    //   [2] call_builtin "Map.size" args=[%1] dest=%2
    //
    // Expected: id 2 is NOT in the uniqueness result map (Map.size
    // is not owned-mutating). isUnique returns false for absent ids.
    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 1;
    const arg_modes = try arena.alloc(ir.ValueMode, 1);
    arg_modes[0] = .share;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 2,
            .name = "Map.size",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    var function = try buildTestFunction(arena, "map_size_only", &instrs, 3);

    var u = try analyzeUniqueness(testing.allocator, &function, null);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUnique(2));
    try testing.expect(!u.sites.contains(2));
}
