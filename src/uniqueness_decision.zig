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
pub fn isFreshAllocatorWrapper(function: *const ir.Function, program: ?*const ir.Program) bool {
    return isFreshAllocatorWrapperWithDepth(function, program, 0);
}

fn isFreshAllocatorWrapperWithDepth(
    function: *const ir.Function,
    program: ?*const ir.Program,
    depth: usize,
) bool {
    if (function.result_convention != .owned) return false;
    if (depth >= FRESH_ALLOCATOR_MAX_DEPTH) return false;
    var allocator_count: usize = 0;
    var other_call_count: usize = 0;
    var ctx = AllocatorWrapperScan{
        .allocator_count = &allocator_count,
        .other_call_count = &other_call_count,
        .program = program,
        .depth = depth,
    };
    for (function.body) |block| {
        scanAllocatorWrapperStream(block.instructions, &ctx);
    }
    return allocator_count == 1 and other_call_count == 0;
}

/// Resolve `name` in `program` and decide whether it is a thin
/// fresh-allocator wrapper. False when the name does not match.
pub fn isFreshAllocatorWrapperByName(program: *const ir.Program, name: []const u8) bool {
    const func = lookupFunctionByName(program, name) orelse return false;
    return isFreshAllocatorWrapper(func, program);
}

const AllocatorWrapperScan = struct {
    allocator_count: *usize,
    other_call_count: *usize,
    /// Optional program reference. When non-null, `call_named`/`call_direct`
    /// targets are resolved and (transitively) checked. When null, every
    /// non-builtin call counts as "other".
    program: ?*const ir.Program = null,
    /// Current recursion depth. Passed to nested calls so transitive chains
    /// observe the same cap.
    depth: usize = 0,
};

fn scanAllocatorWrapperStream(stream: []const ir.Instruction, ctx: *AllocatorWrapperScan) void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_builtin => |cb| {
                if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                    ctx.allocator_count.* += 1;
                } else {
                    ctx.other_call_count.* += 1;
                }
            },
            // Transitive recognition: a call to another fresh-allocator
            // wrapper counts as an allocator call when the program is
            // available. Mutual recursion is bounded by the depth cap.
            .call_named => |cn| {
                if (ctx.program) |program| {
                    if (lookupFunctionByName(program, cn.name)) |target| {
                        if (isFreshAllocatorWrapperWithDepth(target, ctx.program, ctx.depth + 1)) {
                            ctx.allocator_count.* += 1;
                            continue;
                        }
                    }
                }
                ctx.other_call_count.* += 1;
            },
            .call_direct => |cd| {
                if (ctx.program) |program| {
                    if (lookupFunctionById(program, cd.function)) |target| {
                        if (isFreshAllocatorWrapperWithDepth(target, ctx.program, ctx.depth + 1)) {
                            ctx.allocator_count.* += 1;
                            continue;
                        }
                    }
                }
                ctx.other_call_count.* += 1;
            },
            .try_call_named, .call_dispatch, .call_closure, .tail_call => {
                ctx.other_call_count.* += 1;
            },
            else => {},
        }
        // Recurse into every nested sub-stream via the canonical enumerator
        // (covers e.g. union_switch.else_instrs). The call-counting arms above
        // are leaf instructions with no child streams, so this is a no-op for
        // them. Using `forEachChildStream` keeps the scan exhaustive: the
        // comptime child-stream exhaustiveness guard (`ir.zig`) fails
        // compilation if a new child-stream-bearing variant is added without a
        // branch, so this recursion can never silently drop a sub-stream.
        const Recurse = struct {
            ctx: *AllocatorWrapperScan,
            fn onStream(self: *@This(), child: ir.ChildStream) void {
                scanAllocatorWrapperStream(child.stream, self.ctx);
            }
        };
        var rec = Recurse{ .ctx = ctx };
        ir.forEachChildStream(instr, &rec, Recurse.onStream);
    }
}

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
pub fn calleeContractResultUnique(
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    program: *const ir.Program,
    name: []const u8,
    pre_arg_unique: []const bool,
) bool {
    if (arc_liveness.ownedMutatingBuiltinSlot(name) != null) return true;
    if (isFreshAllocatorWrapperByName(program, name)) return true;
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
    try testing.expect(calleeContractResultUnique(&signatures, &program, "accum", &[_]bool{true}));
    try testing.expect(!calleeContractResultUnique(&signatures, &program, "accum", &[_]bool{false}));

    // Owned-mutating builtin: unconditionally fresh (receiver uniqueness
    // irrelevant). "Map.put" is the canonical owned-mutating builtin.
    try testing.expect(calleeContractResultUnique(&signatures, &program, "Map.put", &[_]bool{false}));

    // Receiver slot for an owned-mutating builtin try_call is the builtin's
    // owned slot; for the convention-pair callee it is slot 0.
    try testing.expectEqual(arc_liveness.ownedMutatingBuiltinSlot("Map.put"), calleeReceiverSlotForTryCall(&program, "Map.put"));
    try testing.expectEqual(@as(?usize, 0), calleeReceiverSlotForTryCall(&program, "accum"));
}
