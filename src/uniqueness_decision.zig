//! Shared uniqueness decision authority.
//!
//! This module is the SINGLE source of truth for the pure, stateless
//! decisions that the two copies of the uniqueness dataflow — the canonical
//! `uniqueness.Analyzer` and the `arc_param_convention.TentativeAnalyzer`
//! pre-flight — must agree on. Historically each analyzer carried its own
//! private copy of these helpers (`signatureWholeReturnPreservesUniqueness`,
//! `conventionPairResultUnique`, the fresh-allocator-wrapper scanner, the
//! owned-receiver-slot lookup, the `try_call_named` success-payload contract).
//! The copies drifted (audit follow-up FU-15): the scanners even diverged in
//! their recursion strategy (one used `ir.forEachChildStream`, the other a
//! hand-maintained variant list with an `else => {}` that silently dropped new
//! child-stream-bearing instructions). Drift in any of these is a soundness
//! hazard, because both analyzers gate refcount-sensitive rewrites and
//! `.borrowed -> .owned` parameter promotions on the answers.
//!
//! Everything here is a free function over explicit inputs (signatures table,
//! program / function reference, callee name, slot, pre-call per-arg
//! uniqueness). There is no analyzer state, so neither analyzer can give a
//! different answer than the other. The mechanical dataflow walk (snapshot /
//! restore / meet-both-arms) necessarily stays in each analyzer because the
//! concrete `unique` set type differs, but every classification DECISION the
//! walk consumes routes through this module.
//!
//! Import constraint: this is a leaf module relative to the
//! `arc_param_convention -> uniqueness_interprocedural -> uniqueness ->
//! uniqueness_interprocedural` cycle. It imports only `std`, `ir`,
//! `arc_liveness`, and `uniqueness_signature` — all of which sit below that
//! cycle — so both analyzers can depend on it without reintroducing a cycle.

const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const uniqueness_signature = @import("uniqueness_signature.zig");

// ============================================================
// Program lookups
// ============================================================

/// Resolve `name` to a function in `program` by its public `name` ONLY.
///
/// This is the resolution the fresh-allocator-wrapper scanner and the
/// owned-receiver-slot lookup use. It deliberately does NOT consult the
/// `local_name` alias: both analyzers' pre-consolidation copies of these
/// helpers matched `func.name` only, and the transitive fresh-wrapper scan's
/// termination cost depends on resolving exactly the public-name edges (a
/// broader name+local_name match enlarges the traversed call graph, which can
/// blow up the unmemoized transitive scan). Signature resolution — which DID
/// match the alias in both analyzers — uses `lookupFunctionByNameOrLocal`.
pub fn lookupFunctionByName(program: *const ir.Program, name: []const u8) ?*const ir.Function {
    for (program.functions) |*func| {
        if (std.mem.eql(u8, func.name, name)) return func;
    }
    return null;
}

/// Resolve `name` to a function in `program`, matching either the public
/// `name` or the `local_name` alias. This mirrors the pre-consolidation
/// `lookupByName` used by BOTH analyzers for SIGNATURE resolution inside the
/// convention-pair freshness gate (and only there). Returns null when
/// unresolvable.
pub fn lookupFunctionByNameOrLocal(program: *const ir.Program, name: []const u8) ?*const ir.Function {
    for (program.functions) |*func| {
        if (std.mem.eql(u8, func.name, name)) return func;
        if (func.local_name.len != 0 and std.mem.eql(u8, func.local_name, name)) return func;
    }
    return null;
}

/// Resolve `function_id` to a function in `program`. Returns null when absent.
pub fn lookupFunctionById(program: *const ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*func| {
        if (func.id == function_id) return func;
    }
    return null;
}

// ============================================================
// Owned-receiver convention pair
// ============================================================

/// Index of the first `.owned` parameter slot when `function` has at least
/// one such slot AND `result_convention == .owned`; null otherwise.
///
/// The `.owned` + `.owned` pair is the convention contract established by
/// `arc_param_convention.inferConventions`: the caller transferred a +1 into
/// the slot, the callee consumes it, and the result is a +1. NOTE this pair
/// alone does NOT prove the result is FRESH — see
/// `conventionPairResultUnique` for the uniqueness--04 freshness gate.
pub fn ownedReceiverSlot(function: *const ir.Function) ?usize {
    if (function.result_convention != .owned) return null;
    for (function.param_conventions, 0..) |conv, idx| {
        if (conv == .owned) return idx;
    }
    return null;
}

/// Resolve `name` in `program`, then return its owned-receiver slot.
pub fn ownedReceiverSlotByName(program: *const ir.Program, name: []const u8) ?usize {
    const func = lookupFunctionByName(program, name) orelse return null;
    return ownedReceiverSlot(func);
}

// ============================================================
// Fresh-allocator-wrapper recognition
// ============================================================

/// Maximum chain depth for transitive fresh-allocator recognition. In
/// practice the deepest legitimate chain is 1–2 hops (a user wrapper around a
/// runtime intrinsic); the cap defends against pathological IR shapes and
/// recursive cycles.
pub const FRESH_ALLOCATOR_MAX_DEPTH: usize = 8;

/// Is `function` a thin Zap-fn wrapper around a runtime fresh-allocator
/// intrinsic? The pattern:
///
///     pub fn new_filled(size :: i64, init :: i64) -> List(i64) {
///       :zig.List.new_filled(size, init)
///     }
///
/// lowers to a body containing exactly ONE allocator-producing call site and
/// zero other non-fresh calls. Such wrappers inherit the runtime's "fresh
/// allocation, refcount = 1" contract, so the uniqueness dataflow treats their
/// result as `definitely_unique` on every path.
///
/// Recognition is TRANSITIVE when `program` is non-null: a
/// `call_named`/`call_direct` whose target is itself a fresh-allocator wrapper
/// counts as an allocator call (bounded by `FRESH_ALLOCATOR_MAX_DEPTH`). This
/// is essential for benchmark patterns like
/// `ones(n) -> List.new_filled(n, 1.0)` where the user wraps the runtime
/// allocator in a thin Zap helper. When `program` is null, every non-builtin
/// call counts as "other" (no transitive recognition).
///
/// Returns `error.OutOfMemory` when the temporary program index or recursion
/// memo cannot be allocated. Infrastructure failure is never demoted to
/// "not fresh" because that would silently change uniqueness decisions.
pub fn isFreshAllocatorWrapper(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
) std.mem.Allocator.Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return try isFreshAllocatorWrapperWithAllocator(arena.allocator(), function, program);
}

fn isFreshAllocatorWrapperWithAllocator(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
) std.mem.Allocator.Error!bool {
    var ctx = try FreshAllocatorWrapperDecision.init(allocator, program);
    return try ctx.isFresh(function);
}

const FreshAllocatorWrapperState = enum {
    visiting,
    fresh,
    not_fresh,
};

const ProgramFunctionIndex = struct {
    allocator: std.mem.Allocator,
    by_name: std.StringHashMapUnmanaged(*const ir.Function) = .empty,
    by_id: std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function) = .empty,

    fn init(allocator: std.mem.Allocator, program: *const ir.Program) std.mem.Allocator.Error!ProgramFunctionIndex {
        var index = ProgramFunctionIndex{ .allocator = allocator };
        errdefer index.deinit();

        for (program.functions) |*func| {
            const name_entry = try index.by_name.getOrPut(allocator, func.name);
            if (!name_entry.found_existing) name_entry.value_ptr.* = func;

            const id_entry = try index.by_id.getOrPut(allocator, func.id);
            if (!id_entry.found_existing) id_entry.value_ptr.* = func;
        }
        return index;
    }

    fn deinit(self: *ProgramFunctionIndex) void {
        self.by_name.deinit(self.allocator);
        self.by_id.deinit(self.allocator);
    }

    fn lookupByName(self: *const ProgramFunctionIndex, name: []const u8) ?*const ir.Function {
        return self.by_name.get(name);
    }

    fn lookupById(self: *const ProgramFunctionIndex, function_id: ir.FunctionId) ?*const ir.Function {
        return self.by_id.get(function_id);
    }
};

const FreshAllocatorWrapperDecision = struct {
    allocator: std.mem.Allocator,
    index: ?ProgramFunctionIndex,
    memo: std.AutoHashMapUnmanaged(usize, FreshAllocatorWrapperState) = .empty,
    scan_count: ?*usize = null,

    fn init(
        allocator: std.mem.Allocator,
        program: ?*const ir.Program,
    ) std.mem.Allocator.Error!FreshAllocatorWrapperDecision {
        return .{
            .allocator = allocator,
            .index = if (program) |p| try ProgramFunctionIndex.init(allocator, p) else null,
        };
    }

    fn deinit(self: *FreshAllocatorWrapperDecision) void {
        if (self.index) |*index| index.deinit();
        self.memo.deinit(self.allocator);
    }

    fn isFresh(self: *FreshAllocatorWrapperDecision, function: *const ir.Function) std.mem.Allocator.Error!bool {
        defer self.deinit();
        return self.isFreshWithDepth(function, 0);
    }

    fn isFreshWithDepth(
        self: *FreshAllocatorWrapperDecision,
        function: *const ir.Function,
        depth: usize,
    ) std.mem.Allocator.Error!bool {
        if (function.result_convention != .owned) return false;
        if (depth >= FRESH_ALLOCATOR_MAX_DEPTH) return false;

        const key = @intFromPtr(function);
        const memo_entry = try self.memo.getOrPut(self.allocator, key);
        if (memo_entry.found_existing) {
            return switch (memo_entry.value_ptr.*) {
                .fresh => true,
                .not_fresh, .visiting => false,
            };
        }

        memo_entry.value_ptr.* = .visiting;
        const fresh = try self.scanFunction(function, depth);
        memo_entry.value_ptr.* = if (fresh) .fresh else .not_fresh;
        return fresh;
    }

    fn scanFunction(
        self: *FreshAllocatorWrapperDecision,
        function: *const ir.Function,
        depth: usize,
    ) std.mem.Allocator.Error!bool {
        if (self.scan_count) |count| count.* += 1;

        var allocator_count: usize = 0;
        var other_call_count: usize = 0;
        var scan = AllocatorWrapperScan{
            .decision = self,
            .allocator_count = &allocator_count,
            .other_call_count = &other_call_count,
            .depth = depth,
        };
        for (function.body) |block| {
            try scanAllocatorWrapperStream(block.instructions, &scan);
            if (allocator_count > 1 or other_call_count > 0) break;
        }
        return allocator_count == 1 and other_call_count == 0;
    }

    fn lookupByName(self: *const FreshAllocatorWrapperDecision, name: []const u8) ?*const ir.Function {
        if (self.index) |*index| return index.lookupByName(name);
        return null;
    }

    fn lookupById(self: *const FreshAllocatorWrapperDecision, function_id: ir.FunctionId) ?*const ir.Function {
        if (self.index) |*index| return index.lookupById(function_id);
        return null;
    }
};

fn isFreshAllocatorWrapperWithScanCount(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    scan_count: *usize,
) std.mem.Allocator.Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try FreshAllocatorWrapperDecision.init(arena.allocator(), program);
    ctx.scan_count = scan_count;
    return try ctx.isFresh(function);
}

fn isFreshAllocatorWrapperWithDepth(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: ?*const ir.Program,
    depth: usize,
) std.mem.Allocator.Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try FreshAllocatorWrapperDecision.init(arena.allocator(), program);
    defer ctx.deinit();
    return try ctx.isFreshWithDepth(function, depth);
}

/// Resolve `name` in `program` and decide whether it is a thin
/// fresh-allocator wrapper. Returns false when the name does not match, and
/// `error.OutOfMemory` when recognition state cannot be allocated.
pub fn isFreshAllocatorWrapperByName(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name: []const u8,
) std.mem.Allocator.Error!bool {
    const func = lookupFunctionByName(program, name) orelse return false;
    return try isFreshAllocatorWrapper(allocator, func, program);
}

const AllocatorWrapperScan = struct {
    decision: *FreshAllocatorWrapperDecision,
    allocator_count: *usize,
    other_call_count: *usize,
    /// Current recursion depth. Passed to nested calls so transitive chains
    /// observe the same cap.
    depth: usize = 0,
};

const allocator_wrapper_stream_inline_frame_capacity: usize = 64;
const allocator_wrapper_stream_inline_child_capacity: usize = 16;

const AllocatorWrapperStreamFrame = struct {
    stream: []const ir.Instruction,
    next_index: usize = 0,
    check_threshold_before_next: bool = false,
};

fn AllocatorWrapperInlineStack(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        inline_items: [inline_capacity]T = undefined,
        inline_len: usize = 0,
        spill: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.spill.deinit(allocator);
        }

        fn clearRetainingCapacity(self: *Self) void {
            self.inline_len = 0;
            self.spill.clearRetainingCapacity();
        }

        fn len(self: *const Self) usize {
            return self.inline_len + self.spill.items.len;
        }

        fn append(self: *Self, allocator: std.mem.Allocator, item: T) std.mem.Allocator.Error!void {
            if (self.spill.items.len == 0 and self.inline_len < inline_capacity) {
                self.inline_items[self.inline_len] = item;
                self.inline_len += 1;
                return;
            }
            try self.spill.append(allocator, item);
        }

        fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.len());
            if (index < self.inline_len) return self.inline_items[index];
            return self.spill.items[index - self.inline_len];
        }

        fn topPtr(self: *Self) *T {
            std.debug.assert(self.len() != 0);
            if (self.spill.items.len != 0) return &self.spill.items[self.spill.items.len - 1];
            return &self.inline_items[self.inline_len - 1];
        }

        fn pop(self: *Self) T {
            std.debug.assert(self.len() != 0);
            if (self.spill.items.len != 0) return self.spill.pop().?;
            self.inline_len -= 1;
            return self.inline_items[self.inline_len];
        }
    };
}

fn scanAllocatorWrapperStream(
    stream: []const ir.Instruction,
    ctx: *AllocatorWrapperScan,
) std.mem.Allocator.Error!void {
    var walker = AllocatorWrapperStreamWalker.init(ctx.decision.allocator);
    defer walker.deinit();
    try walker.scan(stream, ctx);
}

fn scanAllocatorWrapperInstruction(
    instr: *const ir.Instruction,
    ctx: *AllocatorWrapperScan,
) std.mem.Allocator.Error!void {
    switch (instr.*) {
        .call_builtin => |cb| {
            if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                ctx.allocator_count.* += 1;
            } else {
                ctx.other_call_count.* += 1;
            }
        },
        // Transitive recognition: a call to another fresh-allocator wrapper
        // counts as an allocator call when the program is available. Mutual
        // recursion is rejected by the decision context's `.visiting` state
        // instead of repeatedly rescanning.
        .call_named => |cn| {
            if (ctx.decision.lookupByName(cn.name)) |target| {
                if (try ctx.decision.isFreshWithDepth(target, ctx.depth + 1)) {
                    ctx.allocator_count.* += 1;
                    return;
                }
            }
            ctx.other_call_count.* += 1;
        },
        .call_direct => |cd| {
            if (ctx.decision.lookupById(cd.function)) |target| {
                if (try ctx.decision.isFreshWithDepth(target, ctx.depth + 1)) {
                    ctx.allocator_count.* += 1;
                    return;
                }
            }
            ctx.other_call_count.* += 1;
        },
        .try_call_named, .call_dispatch, .call_closure, .tail_call => {
            ctx.other_call_count.* += 1;
        },
        else => {},
    }
}

fn allocatorWrapperScanThresholdReached(ctx: *const AllocatorWrapperScan) bool {
    return ctx.allocator_count.* > 1 or ctx.other_call_count.* > 0;
}

const AllocatorWrapperStreamWalker = struct {
    allocator: std.mem.Allocator,
    stack: AllocatorWrapperInlineStack(AllocatorWrapperStreamFrame, allocator_wrapper_stream_inline_frame_capacity) = .{},
    child_streams: AllocatorWrapperInlineStack([]const ir.Instruction, allocator_wrapper_stream_inline_child_capacity) = .{},

    fn init(allocator: std.mem.Allocator) AllocatorWrapperStreamWalker {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *AllocatorWrapperStreamWalker) void {
        self.stack.deinit(self.allocator);
        self.child_streams.deinit(self.allocator);
    }

    fn scan(
        self: *AllocatorWrapperStreamWalker,
        root_stream: []const ir.Instruction,
        ctx: *AllocatorWrapperScan,
    ) std.mem.Allocator.Error!void {
        self.stack.clearRetainingCapacity();
        self.child_streams.clearRetainingCapacity();
        if (root_stream.len == 0) return;

        try self.stack.append(self.allocator, .{ .stream = root_stream });
        while (self.stack.len() != 0) {
            const frame = self.stack.topPtr();
            if (frame.check_threshold_before_next) {
                frame.check_threshold_before_next = false;
                if (allocatorWrapperScanThresholdReached(ctx)) {
                    _ = self.stack.pop();
                    continue;
                }
            }

            if (frame.next_index >= frame.stream.len) {
                _ = self.stack.pop();
                continue;
            }

            const instr = &frame.stream[frame.next_index];
            frame.next_index += 1;

            try scanAllocatorWrapperInstruction(instr, ctx);
            frame.check_threshold_before_next = true;
            try self.pushInstructionChildren(instr);
        }
    }

    fn pushInstructionChildren(
        self: *AllocatorWrapperStreamWalker,
        instr: *const ir.Instruction,
    ) std.mem.Allocator.Error!void {
        self.child_streams.clearRetainingCapacity();

        const ChildStreamCollector = struct {
            walker: *AllocatorWrapperStreamWalker,
            err: ?std.mem.Allocator.Error = null,

            fn onStream(collector: *@This(), child: ir.ChildStream) void {
                if (collector.err != null or child.stream.len == 0) return;
                collector.walker.child_streams.append(collector.walker.allocator, child.stream) catch |err| {
                    collector.err = err;
                };
            }
        };

        var collector = ChildStreamCollector{ .walker = self };
        ir.forEachChildStream(instr, &collector, ChildStreamCollector.onStream);
        if (collector.err) |err| return err;

        var child_index = self.child_streams.len();
        while (child_index > 0) {
            child_index -= 1;
            try self.stack.append(self.allocator, .{ .stream = self.child_streams.get(child_index) });
        }
    }
};

// ============================================================
// uniqueness--04 — whole-return-preserves-uniqueness signature witness
// ============================================================

/// uniqueness--04 — does the callee `function_id`'s signature prove that its
/// `slot` parameter's uniqueness flows WHOLE-RETURN through to the result?
///
/// True only when the per-slot signature class is `preserves_uniqueness` AND
/// the witness is the whole return value (`preserves_to_return_component ==
/// null`, i.e. the result is the parameter itself or its rc=1 derivative — NOT
/// one component of a tuple return). This is the soundness witness the
/// `.owned`/`.owned` convention pair lacks: the convention pair establishes
/// only that the caller transferred a +1 and receives a +1 back, never that
/// the returned cell is fresh/unaliased. A function that returns its `.owned`
/// receiver unchanged (an accumulator base case) is PU but its result is the
/// SAME cell the caller passed — unique only when that cell was unique on
/// entry.
///
/// Returns false when no signature table is wired (`signatures == null`, test
/// scaffolding / non-production callers), no entry exists for the function, or
/// the slot is out of range: the safe, conservative default.
pub fn signatureWholeReturnPreservesUniqueness(
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    function_id: ir.FunctionId,
    slot: usize,
) bool {
    const sigs = signatures orelse return false;
    const sig = sigs.forFunction(function_id) orelse return false;
    if (slot >= sig.params.len) return false;
    const param_sig = sig.params[slot];
    return param_sig.class == .preserves_uniqueness and
        param_sig.preserves_to_return_component == null;
}

/// uniqueness--04 — whether a call whose callee matches the `.owned` receiver
/// slot + `.owned` result convention pair (slot `slot`, resolved by `name`)
/// produces a PROVABLY-UNIQUE result, given the pre-call per-arg uniqueness
/// snapshot.
///
/// The convention pair alone is insufficient (uniqueness--04): a callee can
/// legitimately have an `.owned` receiver and `.owned` result yet `return` an
/// alias of that receiver (or a captured/shared value) rather than a freshly
/// produced cell. The result is provably unique only when the callee's
/// signature proves whole-return PU AND the receiver was actually unique at
/// this call site (`pre_arg_unique[slot]`):
///   * PU whole-return + receiver unique → result inherits the receiver's
///     (proven) uniqueness → unique.
///   * PU whole-return + receiver shared → the result may be the shared cell
///     (alias case) → NOT unique.
/// When signatures are absent (`signatures == null`), falls back to NOT unique
/// (conservative).
pub fn conventionPairResultUnique(
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    program: *const ir.Program,
    name: []const u8,
    slot: usize,
    pre_arg_unique: []const bool,
) bool {
    if (slot >= pre_arg_unique.len) return false;
    if (!pre_arg_unique[slot]) return false;
    // Signature resolution matches the alias too (mirrors the pre-consolidation
    // `lookupByName` both analyzers used here).
    const function_id = (lookupFunctionByNameOrLocal(program, name) orelse return false).id;
    return signatureWholeReturnPreservesUniqueness(signatures, function_id, slot);
}

/// Convention-pair result-unique decision for a `call_direct` callee already
/// resolved to a concrete function. Mirrors `conventionPairResultUnique` but
/// keys the signature lookup on `function.id` directly.
pub fn conventionPairResultUniqueByFunction(
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    function: *const ir.Function,
    slot: usize,
    pre_arg_unique: []const bool,
) bool {
    if (slot >= pre_arg_unique.len) return false;
    if (!pre_arg_unique[slot]) return false;
    return signatureWholeReturnPreservesUniqueness(signatures, function.id, slot);
}

// ============================================================
// uniqueness--03 — try_call_named success-payload contract + receiver slot
// ============================================================

/// uniqueness--03 / uniqueness--04 — whether the SUCCESS-path result of
/// calling `name` is unique by the callee's runtime contract, given the
/// pre-call per-arg uniqueness snapshot.
///
/// This is the single authority for the success-callee classification, shared
/// by the regular `call_named` dest path and the `try_call_named` success arm
/// (in BOTH analyzers) so they agree by construction. The three contract
/// shapes:
///   1. owned-mutating builtin (`ownedMutatingBuiltinSlot != null`) — the
///      runtime contract guarantees a fresh rc=1 result.
///   2. fresh-allocator wrapper (rc=1 by construction).
///   3. Zap fn convention pair (`.owned` receiver slot + `.owned` result) —
///      uniqueness--04: unique ONLY when the callee's signature proves
///      whole-return PU AND the receiver was unique at the call site
///      (`conventionPairResultUnique`). The convention pair alone does NOT
///      prove result freshness.
///
/// Returns `error.OutOfMemory` if fresh-wrapper recognition cannot allocate
/// its temporary index or memo.
pub fn calleeContractResultUnique(
    allocator: std.mem.Allocator,
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    program: *const ir.Program,
    name: []const u8,
    pre_arg_unique: []const bool,
) std.mem.Allocator.Error!bool {
    if (arc_liveness.ownedMutatingBuiltinSlot(name) != null) return true;
    if (try isFreshAllocatorWrapperByName(allocator, program, name)) return true;
    if (ownedReceiverSlotByName(program, name)) |slot| {
        return conventionPairResultUnique(signatures, program, name, slot, pre_arg_unique);
    }
    return false;
}

/// uniqueness--03 — the receiver slot that a `try_call_named` to `name`
/// consumes, when its success-callee contract is owned-mutating (an
/// owned-mutating builtin OR a Zap function with an `.owned` receiver slot +
/// `.owned` result). Returns null when no slot is consumed (e.g. a
/// fresh-allocator wrapper or a non-mutating call). Used by each analyzer's
/// `try_call_named` arg-effect to clear the consumed receiver's uniqueness,
/// matching the plain-call receiver removal.
pub fn calleeReceiverSlotForTryCall(program: *const ir.Program, name: []const u8) ?usize {
    if (arc_liveness.ownedMutatingBuiltinSlot(name)) |slot| return slot;
    if (ownedReceiverSlotByName(program, name)) |slot| return slot;
    return null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn buildCalleeWithConventions(
    arena: std.mem.Allocator,
    id: ir.FunctionId,
    name: []const u8,
    param_conv: ir.ParamConvention,
    result_conv: ir.ResultConvention,
) !ir.Function {
    const conv = try arena.alloc(ir.ParamConvention, 1);
    conv[0] = param_conv;
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = &.{} };
    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "receiver", .type_expr = .void };
    return ir.Function{
        .id = id,
        .name = name,
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 0,
        .param_conventions = conv,
        .local_ownership = try arena.alloc(ir.OwnershipClass, 0),
        .result_convention = result_conv,
    };
}

fn builtinCall(name: []const u8) ir.Instruction {
    return .{ .call_builtin = .{
        .dest = 0,
        .name = name,
        .args = &.{},
        .arg_modes = &.{},
    } };
}

fn namedCall(name: []const u8) ir.Instruction {
    return .{ .call_named = .{
        .dest = 0,
        .name = name,
        .args = &.{},
        .arg_modes = &.{},
    } };
}

fn directCall(function_id: ir.FunctionId) ir.Instruction {
    return .{ .call_direct = .{
        .dest = 0,
        .function = function_id,
        .args = &.{},
        .arg_modes = &.{},
    } };
}

fn buildWrapperCandidate(
    arena: std.mem.Allocator,
    id: ir.FunctionId,
    name: []const u8,
    instructions: []const ir.Instruction,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    return ir.Function{
        .id = id,
        .name = name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = &.{},
        .local_ownership = &.{},
        .result_convention = .owned,
    };
}

fn buildProgram(arena: std.mem.Allocator, functions: []const ir.Function) !ir.Program {
    return .{
        .functions = try arena.dupe(ir.Function, functions),
        .type_defs = &.{},
        .entry = null,
    };
}

fn buildDeepGuardInstructionStream(
    allocator: std.mem.Allocator,
    depth: usize,
    leaf: ir.Instruction,
) ![]ir.Instruction {
    const instructions = try allocator.alloc(ir.Instruction, depth + 1);
    instructions[depth] = leaf;

    var index = depth;
    while (index > 0) {
        const child_index = index;
        index -= 1;
        instructions[index] = .{ .guard_block = .{
            .condition = 0,
            .body = instructions[child_index .. child_index + 1],
        } };
    }

    return instructions;
}

test "uniqueness_decision: fresh allocator wrapper recognizes a single builtin allocator call" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{builtinCall("List.new_empty")};
    const function = try buildWrapperCandidate(arena, 0, "new_list", &instrs);

    try testing.expect(try isFreshAllocatorWrapper(testing.allocator, &function, null));
}

test "uniqueness_decision: fresh allocator wrapper scans deeply nested child streams iteratively" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const depth: usize = 16 * 1024;

    const instructions = try buildDeepGuardInstructionStream(arena, depth, builtinCall("List.new_empty"));
    const function = try buildWrapperCandidate(arena, 0, "deep_new_list", instructions[0..1]);

    try testing.expect(try isFreshAllocatorWrapper(testing.allocator, &function, null));
}

test "uniqueness_decision: fresh allocator wrapper propagates OOM from child-stream stack growth" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const depth = allocator_wrapper_stream_inline_frame_capacity + 1;

    const instructions = try buildDeepGuardInstructionStream(arena, depth, builtinCall("List.new_empty"));

    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var decision = FreshAllocatorWrapperDecision{
        .allocator = failing_allocator.allocator(),
        .index = null,
    };
    defer decision.deinit();

    var allocator_count: usize = 0;
    var other_call_count: usize = 0;
    var scan = AllocatorWrapperScan{
        .decision = &decision,
        .allocator_count = &allocator_count,
        .other_call_count = &other_call_count,
    };

    try testing.expectError(
        error.OutOfMemory,
        scanAllocatorWrapperStream(instructions[0..1], &scan),
    );
    try testing.expect(failing_allocator.has_induced_failure);
}

test "uniqueness_decision: fresh allocator wrapper rejects non-allocator calls" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{builtinCall("List.length")};
    const function = try buildWrapperCandidate(arena, 0, "length", &instrs);

    const is_fresh = try isFreshAllocatorWrapper(testing.allocator, &function, null);
    try testing.expect(!is_fresh);
}

test "uniqueness_decision: fresh allocator wrapper propagates OOM from recognition allocations" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const instrs = [_]ir.Instruction{builtinCall("List.new_empty")};
    const function = try buildWrapperCandidate(arena, 0, "new_list", &instrs);

    var memo_failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        isFreshAllocatorWrapper(memo_failing_allocator.allocator(), &function, null),
    );
    try testing.expect(memo_failing_allocator.has_induced_failure);

    const functions = [_]ir.Function{function};
    const program = try buildProgram(arena, &functions);
    var index_failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        isFreshAllocatorWrapperByName(index_failing_allocator.allocator(), &program, "new_list"),
    );
    try testing.expect(index_failing_allocator.has_induced_failure);
}

test "uniqueness_decision: fresh allocator wrapper recognizes public-name and direct-id transitive wrappers" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const base_instrs = [_]ir.Instruction{builtinCall("List.new_empty")};
    const named_instrs = [_]ir.Instruction{namedCall("base")};
    const direct_instrs = [_]ir.Instruction{directCall(0)};
    const functions = [_]ir.Function{
        try buildWrapperCandidate(arena, 0, "base", &base_instrs),
        try buildWrapperCandidate(arena, 1, "named_outer", &named_instrs),
        try buildWrapperCandidate(arena, 2, "direct_outer", &direct_instrs),
    };
    const program = try buildProgram(arena, &functions);

    try testing.expect(try isFreshAllocatorWrapper(testing.allocator, &program.functions[1], &program));
    try testing.expect(try isFreshAllocatorWrapper(testing.allocator, &program.functions[2], &program));
}

test "uniqueness_decision: fresh allocator wrapper does not resolve transitive edges through local aliases" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const base_instrs = [_]ir.Instruction{builtinCall("List.new_empty")};
    const alias_instrs = [_]ir.Instruction{namedCall("base_alias")};
    var base = try buildWrapperCandidate(arena, 0, "base", &base_instrs);
    base.local_name = "base_alias";
    const functions = [_]ir.Function{
        base,
        try buildWrapperCandidate(arena, 1, "alias_outer", &alias_instrs),
    };
    const program = try buildProgram(arena, &functions);

    const is_fresh = try isFreshAllocatorWrapper(testing.allocator, &program.functions[1], &program);
    try testing.expect(!is_fresh);
}

test "uniqueness_decision: fresh allocator wrapper rejects recursive cycles without repeated rescanning" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const a_instrs = [_]ir.Instruction{namedCall("b")};
    const b_instrs = [_]ir.Instruction{namedCall("a")};
    const functions = [_]ir.Function{
        try buildWrapperCandidate(arena, 0, "a", &a_instrs),
        try buildWrapperCandidate(arena, 1, "b", &b_instrs),
    };
    const program = try buildProgram(arena, &functions);

    var scan_count: usize = 0;
    const is_fresh = try isFreshAllocatorWrapperWithScanCount(testing.allocator, &program.functions[0], &program, &scan_count);
    try testing.expect(!is_fresh);
    try testing.expect(scan_count <= functions.len);
}

test "uniqueness_decision: fresh allocator wrapper memoizes cross-linked transitive calls" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const root_instrs = [_]ir.Instruction{
        namedCall("left"),
        namedCall("right"),
    };
    const left_instrs = [_]ir.Instruction{namedCall("shared")};
    const right_instrs = [_]ir.Instruction{namedCall("shared")};
    const shared_instrs = [_]ir.Instruction{namedCall("leaf")};
    const leaf_instrs = [_]ir.Instruction{builtinCall("List.new_empty")};
    const functions = [_]ir.Function{
        try buildWrapperCandidate(arena, 0, "root", &root_instrs),
        try buildWrapperCandidate(arena, 1, "left", &left_instrs),
        try buildWrapperCandidate(arena, 2, "right", &right_instrs),
        try buildWrapperCandidate(arena, 3, "shared", &shared_instrs),
        try buildWrapperCandidate(arena, 4, "leaf", &leaf_instrs),
    };
    const program = try buildProgram(arena, &functions);

    var scan_count: usize = 0;
    const is_fresh = try isFreshAllocatorWrapperWithScanCount(testing.allocator, &program.functions[0], &program, &scan_count);
    try testing.expect(!is_fresh);
    try testing.expect(scan_count <= functions.len);
}

test "uniqueness_decision: ownedReceiverSlot recognizes the .owned/.owned pair" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const owned = try buildCalleeWithConventions(arena, 0, "f", .owned, .owned);
    try testing.expectEqual(@as(?usize, 0), ownedReceiverSlot(&owned));

    const borrowed_result = try buildCalleeWithConventions(arena, 1, "g", .owned, .borrowed);
    try testing.expectEqual(@as(?usize, null), ownedReceiverSlot(&borrowed_result));

    const borrowed_param = try buildCalleeWithConventions(arena, 2, "h", .borrowed, .owned);
    try testing.expectEqual(@as(?usize, null), ownedReceiverSlot(&borrowed_param));
}

test "uniqueness_decision: conventionPairResultUnique gates on receiver uniqueness AND whole-return PU" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const callee = try buildCalleeWithConventions(arena, 0, "accum", .owned, .owned);
    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = callee;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var signatures = uniqueness_signature.ProgramSignatures.init(testing.allocator);
    defer signatures.deinit(testing.allocator);
    const sig_arena = signatures.arena.allocator();
    const params = try sig_arena.alloc(uniqueness_signature.ParamSig, 1);
    params[0] = uniqueness_signature.ParamSig.preservesUniqueness(null);
    try signatures.by_function.put(testing.allocator, 0, .{
        .params = params,
        .return_components = &.{},
    });

    // Receiver unique + whole-return PU → unique.
    try testing.expect(conventionPairResultUnique(&signatures, &program, "accum", 0, &[_]bool{true}));
    // Receiver shared + whole-return PU → NOT unique (alias hazard).
    try testing.expect(!conventionPairResultUnique(&signatures, &program, "accum", 0, &[_]bool{false}));

    // No signature → conservative NOT unique even with a unique receiver.
    var empty_sigs = uniqueness_signature.ProgramSignatures.init(testing.allocator);
    defer empty_sigs.deinit(testing.allocator);
    try testing.expect(!conventionPairResultUnique(&empty_sigs, &program, "accum", 0, &[_]bool{true}));
}

test "uniqueness_decision: calleeContractResultUnique routes owned-mutating builtins, wrappers, and the convention pair" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const callee = try buildCalleeWithConventions(arena, 0, "accum", .owned, .owned);
    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = callee;
    const program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var signatures = uniqueness_signature.ProgramSignatures.init(testing.allocator);
    defer signatures.deinit(testing.allocator);
    const sig_arena = signatures.arena.allocator();
    const params = try sig_arena.alloc(uniqueness_signature.ParamSig, 1);
    params[0] = uniqueness_signature.ParamSig.preservesUniqueness(null);
    try signatures.by_function.put(testing.allocator, 0, .{
        .params = params,
        .return_components = &.{},
    });

    // Convention-pair callee: gated by receiver uniqueness.
    try testing.expect(try calleeContractResultUnique(testing.allocator, &signatures, &program, "accum", &[_]bool{true}));
    const shared_receiver_unique = try calleeContractResultUnique(testing.allocator, &signatures, &program, "accum", &[_]bool{false});
    try testing.expect(!shared_receiver_unique);

    // Owned-mutating builtin: unconditionally fresh (receiver uniqueness
    // irrelevant). "Map.put" is the canonical owned-mutating builtin.
    try testing.expect(try calleeContractResultUnique(testing.allocator, &signatures, &program, "Map.put", &[_]bool{false}));

    // Receiver slot for an owned-mutating builtin try_call is the builtin's
    // owned slot; for the convention-pair callee it is slot 0.
    try testing.expectEqual(arc_liveness.ownedMutatingBuiltinSlot("Map.put"), calleeReceiverSlotForTryCall(&program, "Map.put"));
    try testing.expectEqual(@as(?usize, 0), calleeReceiverSlotForTryCall(&program, "accum"));
}
