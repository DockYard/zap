const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const uniqueness = @import("uniqueness.zig");
const uniqueness_signature = @import("uniqueness_signature.zig");

// ============================================================
// uniqueness Interprocedural — whole-program uniqueness fixpoint.
//
// Pipeline placement (per docs/dense-map-implementation-plan.md §1.5
// extended for interprocedural uniqueness):
//
//     ... → arc_liveness                        (last-use side table)
//          → arc_param_convention               (.borrowed → .owned)
//             → arc_ownership.rewriteOwnedConsumeBuiltinSites
//                → arc_ownership.classifyAndNormalize
//                   → arc_ownership.rewriteOwnedConsumeSites
//                      → uniqueness_interprocedural     (THIS PASS — produces
//                                                per-callee per-param
//                                                "unique-on-entry" map)
//                         → uniqueness       (per-function, consults
//                                                this pass's result on
//                                                `param_get`)
//                            → arc_ownership.rewriteUncheckedUniquenessSites
//                               → arc_verifier
//                                  → ...
//
// Why this pass exists:
//
// The intraprocedural uniqueness in `uniqueness.zig` is conservative on
// `param_get`: it cannot know whether the caller transferred a unique
// value, so it treats every parameter as potentially shared. The
// codegen agent's report identified this as the limiting factor for
// fannkuch-redux and k-nucleotide: their hot loops are accumulator-
// recursion patterns where the receiver is passed as a parameter
// through tail-recursive calls. Intraprocedural uniqueness stops at the
// callee's `param_get`, so the unchecked rewrite never fires.
//
// Lean 4 / Koka / Roc all close this gap with an interprocedural
// fixpoint over uniqueness contracts. The design here is a straight
// adaptation:
//
//   1. For each function F and each parameter slot i, we want the
//      predicate `unique_on_entry(F, i)` — "is F's slot i guaranteed
//      to be refcount=1 on entry across every reachable caller?"
//
//   2. The lattice is `bool` per slot, ordered with `true` (proven
//      unique) above `false` (could be shared). Optimistic init: every
//      ARC-managed parameter slot starts at `true`. The fixpoint can
//      only ever demote (`true → false`), never the reverse, so the
//      lattice has finite height (one demotion per slot per function),
//      guaranteeing termination.
//
//   3. For each call site `f(a0, a1, ..., aN)` inside some caller C,
//      slot i of f is unique-on-entry only if `ai` is provably unique
//      AT THE CALL SITE in C. "Provably unique at call site" is
//      computed by running the intraprocedural uniqueness forward dataflow on
//      C, where `param_get` for any of C's slots consults the CURRENT
//      fixpoint state for C — i.e., the analysis is parameterised on
//      the fixpoint result.
//
//   4. Iterate to fixpoint: each time a slot demotes, every caller of
//      that function may need to re-check (in the other direction —
//      the demotion at slot i of F doesn't directly trigger anything,
//      but if F's slot i feeds OUT of F into another callee G's slot,
//      G's demotion might cascade).
//
//      Concretely: when slot i of F demotes, we re-scan F's body. If
//      F passes `param_get(i)` (or an alias) into a callee G's slot j
//      whose state was relying on F's slot i being unique, G's slot j
//      may demote.
//
//      The simplest worklist approach is callee-driven: when slot i of
//      F demotes, push every function reachable from F into the
//      worklist. The fixpoint terminates after at most O(P) demotion
//      events where P is the total number of (function, slot) pairs.
//
// Soundness:
//
// We start from the optimistic assumption that every `.owned`-
// convention parameter is unique-on-entry. This is the maximally
// permissive starting point. The fixpoint can only ever reduce the
// proven-unique set, never grow it. When it converges, every slot
// marked `true` has been verified at every reachable call site;
// every slot marked `false` had at least one call site where the
// argument's uniqueness could not be proven.
//
// The verifier (`arc_verifier.runUniquenessCheck`) is the safety net: it re-runs
// the per-function uniqueness with the fixpoint result and rejects any
// `*_owned_unchecked` site whose receiver isn't proven unique. A wrong
// `true` here would surface as an `error.ArcInvariantViolation` at
// build time, not as runtime undefined behaviour.
//
// Conservative fallback at unresolvable sites:
//
// At call sites we can't statically resolve to a single callee
// (`call_builtin`, `call_dispatch`, `call_closure`), the fixpoint
// treats the argument as potentially shared from the callee's
// perspective. For the receiver of an owned-mutating builtin, this
// is irrelevant — the builtin's slot 0 isn't a Zap-fn parameter, so
// uniqueness is decided by the caller's intraprocedural dataflow.
// For other unresolvable shapes, we err on the side of demoting any
// uniqueness claim.
//
// ============================================================

/// Output of `analyzeProgram`. For each function in the program,
/// records per-parameter-slot whether the slot is provably
/// unique-on-entry across every reachable caller.
///
/// The map is keyed by `FunctionId`. The value is a slice with the
/// same length as the function's `param_conventions`. Slots whose
/// convention is not `.owned` are always `false` (the slot is either
/// non-ARC or borrowed; uniqueness inference doesn't apply).
pub const ProgramUniqueness = struct {
    /// Per-function `unique_on_entry` slice. Empty for functions whose
    /// parameter list is empty.
    by_function: std.AutoHashMapUnmanaged(ir.FunctionId, []bool) = .empty,

    pub fn deinit(self: *ProgramUniqueness, allocator: std.mem.Allocator) void {
        var iter = self.by_function.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.by_function.deinit(allocator);
    }

    /// Look up the per-slot uniqueness for `function_id`.
    /// Returns an empty slice when the function is absent (treated as
    /// "no slots known unique" — the safe default).
    pub fn forFunction(
        self: *const ProgramUniqueness,
        function_id: ir.FunctionId,
    ) []const bool {
        return self.by_function.get(function_id) orelse &.{};
    }

    /// Convenience: is slot `slot_index` of `function_id` proven unique-
    /// on-entry? Returns `false` for absent functions or slot indices
    /// that exceed the recorded slice (the safe default).
    pub fn isUniqueOnEntry(
        self: *const ProgramUniqueness,
        function_id: ir.FunctionId,
        slot_index: usize,
    ) bool {
        const slots = self.forFunction(function_id);
        if (slot_index >= slots.len) return false;
        return slots[slot_index];
    }
};

/// Run the interprocedural uniqueness fixpoint across `program`. Returns a
/// per-function per-slot `unique_on_entry` map. Caller owns the
/// returned struct and must call `deinit`.
///
/// Algorithm:
///
///   1. Initialise: for every function and every `.owned`-convention
///      slot, set `unique_on_entry[i] = true` (optimistic).
///   2. Worklist seeded with every function.
///   3. While worklist non-empty:
///      - Pop function F.
///      - Run intraprocedural uniqueness on F, parameterised by the CURRENT
///        fixpoint state (so `param_get` of slot i of F is treated as
///        unique iff `unique_on_entry[F][i] == true`). The analysis
///        produces per-call-site uniqueness for owned-mutating sites
///        AND per-arg uniqueness for any callee-bound arguments.
///      - For each call site in F that targets a known function G:
///          For each arg slot j in G that has `unique_on_entry[G][j] == true`:
///            If F's intraprocedural uniqueness says the arg is NOT unique at
///            this call site, demote `unique_on_entry[G][j] = false`
///            and enqueue every caller of G.
///   4. Return when worklist drains.
///
/// Termination: each demotion permanently flips a `true` to `false`.
/// Total demotions are bounded by the sum of `.owned`-convention slots
/// across the program; once a slot is `false` it never re-enters the
/// worklist for the same reason.
pub fn analyzeProgram(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
) !ProgramUniqueness {
    return analyzeProgramFull(allocator, program, null, null);
}

/// Full-information variant of `analyzeProgram`. The optional
/// `signatures` and `ownerships` inputs let the per-function intraprocedural
/// uniqueness pass propagate per-component uniqueness through tuple
/// destructure idioms (see `uniqueness.zig`'s Phase 2.5 logic):
///
///   * `signatures` (Phase 2.1 per-callee return witnesses) lets the
///     intraprocedural walk synthesize a `tuple_pending` entry on the
///     dest of a tuple-returning call whose callee's
///     `return_components` table records per-component PU witnesses.
///     Without this, `pp_flips = count_flips(pp, 0)` followed by
///     `{pp', _} = pp_flips` fails to propagate `pp`'s uniqueness
///     through the destructure, and the subsequent tail call's per-arg
///     uniqueness is incorrectly reported as `false`, demoting the
///     callee's slot.
///
///   * `ownerships` (per-function last-use side table) lets the
///     intraprocedural walk recognise the `index_get + retain` destructure
///     idiom as a uniqueness-preserving move at the parent tuple's
///     last-use.
///
/// Passing `null` for either falls back to the conservative
/// intraprocedural behaviour (the legacy pre-Phase-2.5 form) for the
/// affected dataflow shapes.
///
/// Both inputs MUST have been computed against the same post-classify
/// IR shape the fixpoint walks. The `compiler.zig` pipeline orders
/// these passes correctly: `runProgramArcOwnership` and
/// `computeSignaturesWithOwnership` run BEFORE `analyzeProgramFull`.
pub fn analyzeProgramFull(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    signatures: ?*const uniqueness_signature.ProgramSignatures,
    ownerships: ?*const arc_liveness.ProgramArcOwnership,
) !ProgramUniqueness {
    var result: ProgramUniqueness = .{};
    errdefer result.deinit(allocator);

    // Step 1: initialise per-function uniqueness slices to optimistic
    // `true` for every `.owned`-convention slot, `false` otherwise.
    for (program.functions) |func| {
        if (func.param_conventions.len == 0) {
            try result.by_function.put(allocator, func.id, &.{});
            continue;
        }
        const slots = try allocator.alloc(bool, func.param_conventions.len);
        for (func.param_conventions, 0..) |conv, idx| {
            // Optimistic: every `.owned` slot starts proven unique.
            // `.borrowed` and `.trivial` slots stay `false` — they are
            // either non-ARC (no uniqueness concept) or share-by-default
            // (the caller doesn't transfer a +1).
            slots[idx] = (conv == .owned);
        }
        try result.by_function.put(allocator, func.id, slots);
    }

    // Step 2: build name→id lookup (used to resolve call_named sites
    // back to a target function in the program).
    var name_to_id: std.StringHashMapUnmanaged(ir.FunctionId) = .empty;
    defer name_to_id.deinit(allocator);
    for (program.functions) |func| {
        try name_to_id.put(allocator, func.name, func.id);
        if (func.local_name.len != 0) {
            const gop = try name_to_id.getOrPut(allocator, func.local_name);
            if (!gop.found_existing) gop.value_ptr.* = func.id;
        }
    }

    // Step 3: build reverse caller map. When slot j of function G
    // demotes, we need to re-process every caller of G — not because
    // their slots demote directly (callers are independent of G's
    // signature), but because their intraprocedural uniqueness result for the
    // call site at G might change, which can cascade to OTHER callees.
    //
    // Conceptually: re-running F's intraprocedural uniqueness after a callee's
    // signature changes can change F's per-call-site uniqueness, which
    // can in turn change demotions on F's other callees.
    var callers_of: std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)) = .empty;
    defer {
        var iter = callers_of.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        callers_of.deinit(allocator);
    }

    for (program.functions) |caller_func| {
        try collectCalleeFunctionIds(
            allocator,
            &caller_func,
            &name_to_id,
            &callers_of,
        );
    }

    // Step 4: worklist fixpoint. Seed with every function so the
    // initial pass observes any forced demotion (e.g., a function
    // whose body proves a slot non-unique on its own merits).
    var worklist: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
    defer worklist.deinit(allocator);
    for (program.functions) |func| {
        try worklist.append(allocator, func.id);
    }

    var in_worklist: std.AutoHashMapUnmanaged(ir.FunctionId, void) = .empty;
    defer in_worklist.deinit(allocator);
    for (program.functions) |func| {
        try in_worklist.put(allocator, func.id, {});
    }

    while (worklist.pop()) |func_id| {
        _ = in_worklist.remove(func_id);
        const caller = lookupFunction(program, func_id) orelse continue;

        // Run intraprocedural uniqueness on `caller`, parameterised by the
        // current fixpoint state. The shared dataflow in `uniqueness.zig`
        // produces a call-site→bool `sites` map AND a per-call-site
        // per-arg `arg_sites` map when `record_arg_sites=true`. The
        // Phase 2.5 logic (tuple_pending, index_get propagation,
        // callee return-component synthesis) runs automatically when
        // `signatures` and `ownerships` are provided.
        const fn_ownership: ?*const arc_liveness.ArcOwnership = blk: {
            if (ownerships) |program_ownership| break :blk program_ownership.get(caller.id);
            break :blk null;
        };
        var caller_uniqueness = try uniqueness.analyzeUniquenessFullEx(
            allocator,
            caller,
            program,
            &result,
            signatures,
            fn_ownership,
            true,
        );
        defer caller_uniqueness.deinit(allocator);

        // For each call site in `caller` that targets a known program
        // function, check whether the arg passed for each `.owned`
        // slot is unique. If not, demote that slot in the callee's
        // entry and enqueue the callee's callers.
        var demote_walker = DemotionWalker{
            .allocator = allocator,
            .caller = caller,
            .program = program,
            .name_to_id = &name_to_id,
            .uniqueness = &caller_uniqueness,
            .program_uniqueness = &result,
            .callers_of = &callers_of,
            .worklist = &worklist,
            .in_worklist = &in_worklist,
            .next_id = 0,
        };
        for (caller.body) |block| {
            try demote_walker.walkStream(block.instructions);
        }
    }

    return result;
}

fn lookupFunction(program: *const ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*func| {
        if (func.id == function_id) return func;
    }
    return null;
}

/// Per-function intraprocedural uniqueness output used inside the
/// fixpoint. Aliased to `uniqueness.Uniqueness` so the same dataflow
/// produces both the per-call-site receiver `sites` map AND the per-
/// call-site per-arg `arg_sites` map. The fixpoint enables the
/// `record_arg_sites` knob on the shared analyzer so the latter is
/// populated; the per-function rewrite pass leaves it disabled.
pub const FunctionUniqueness = uniqueness.Uniqueness;

/// Re-export for callers that want to refer to the per-arg witness
/// type by the historical `uniqueness_interprocedural` name.
pub const ArgUniqueness = uniqueness.ArgUniqueness;

/// Run the shared intraprocedural uniqueness dataflow on `function`
/// with `record_arg_sites=true`. The fixpoint uses this to obtain
/// per-call-site per-arg uniqueness for callee-slot demotion.
///
/// `signatures` and `ownership` are forwarded so Phase 2.5 (tuple
/// destructure / callee return-component synthesis) fires inside the
/// fixpoint exactly as it does for the per-function rewrite pass.
/// Without them the fixpoint observes the legacy conservative
/// behaviour and incorrectly demotes any callee slot that depends
/// on a destructured tuple component flowing through.
pub fn analyzeFunctionWithFixpoint(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    fixpoint: *const ProgramUniqueness,
) !FunctionUniqueness {
    return uniqueness.analyzeUniquenessFullEx(
        allocator,
        function,
        program,
        fixpoint,
        null,
        null,
        true,
    );
}

fn calleeFunctionOwnedReceiverSlot(function: *const ir.Function) ?usize {
    if (function.result_convention != .owned) return null;
    for (function.param_conventions, 0..) |conv, idx| {
        if (conv == .owned) return idx;
    }
    return null;
}

/// Walk a function's body and append the function id to `callers_of`
/// for every callee we can resolve.
fn collectCalleeFunctionIds(
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) !void {
    for (caller.body) |block| {
        try collectCalleesIntoStream(allocator, caller.id, block.instructions, name_to_id, callers_of);
    }
}

fn collectCalleesIntoStream(
    allocator: std.mem.Allocator,
    caller_id: ir.FunctionId,
    stream: []const ir.Instruction,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_named => |cn| {
                if (name_to_id.get(cn.name)) |target| {
                    try recordEdge(allocator, target, caller_id, callers_of);
                }
            },
            .call_direct => |cd| {
                try recordEdge(allocator, cd.function, caller_id, callers_of);
            },
            .try_call_named => |tcn| {
                if (name_to_id.get(tcn.name)) |target| {
                    try recordEdge(allocator, target, caller_id, callers_of);
                }
            },
            .tail_call => |tc| {
                if (name_to_id.get(tc.name)) |target| {
                    try recordEdge(allocator, target, caller_id, callers_of);
                }
            },
            .if_expr => |ie| {
                try collectCalleesIntoStream(allocator, caller_id, ie.then_instrs, name_to_id, callers_of);
                try collectCalleesIntoStream(allocator, caller_id, ie.else_instrs, name_to_id, callers_of);
            },
            .case_block => |cb| {
                try collectCalleesIntoStream(allocator, caller_id, cb.pre_instrs, name_to_id, callers_of);
                for (cb.arms) |arm| {
                    try collectCalleesIntoStream(allocator, caller_id, arm.cond_instrs, name_to_id, callers_of);
                    try collectCalleesIntoStream(allocator, caller_id, arm.body_instrs, name_to_id, callers_of);
                }
                try collectCalleesIntoStream(allocator, caller_id, cb.default_instrs, name_to_id, callers_of);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try collectCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
                try collectCalleesIntoStream(allocator, caller_id, sl.default_instrs, name_to_id, callers_of);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try collectCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
                try collectCalleesIntoStream(allocator, caller_id, sr.default_instrs, name_to_id, callers_of);
            },
            .union_switch => |us| {
                for (us.cases) |c| try collectCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try collectCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
            },
            .guard_block => |gb| {
                try collectCalleesIntoStream(allocator, caller_id, gb.body, name_to_id, callers_of);
            },
            .optional_dispatch => |od| {
                try collectCalleesIntoStream(allocator, caller_id, od.nil_instrs, name_to_id, callers_of);
                try collectCalleesIntoStream(allocator, caller_id, od.struct_instrs, name_to_id, callers_of);
            },
            else => {},
        }
    }
}

fn recordEdge(
    allocator: std.mem.Allocator,
    target: ir.FunctionId,
    caller: ir.FunctionId,
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) !void {
    const gop = try callers_of.getOrPut(allocator, target);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    // Avoid duplicate caller entries (multiple call sites in the same
    // caller don't need re-enqueueing more than once per pass).
    for (gop.value_ptr.items) |existing| {
        if (existing == caller) return;
    }
    try gop.value_ptr.append(allocator, caller);
}

const DemotionWalker = struct {
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    uniqueness: *const FunctionUniqueness,
    program_uniqueness: *ProgramUniqueness,
    callers_of: *const std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
    worklist: *std.ArrayListUnmanaged(ir.FunctionId),
    in_worklist: *std.AutoHashMapUnmanaged(ir.FunctionId, void),
    next_id: arc_liveness.InstructionId,

    fn walkStream(
        self: *DemotionWalker,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.maybeDemoteCallee(my_id);
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(
        self: *DemotionWalker,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            .if_expr => |ie| {
                try self.walkStream(ie.then_instrs);
                try self.walkStream(ie.else_instrs);
            },
            .case_block => |cb| {
                try self.walkStream(cb.pre_instrs);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                }
                try self.walkStream(cb.default_instrs);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try self.walkStream(c.body_instrs);
                try self.walkStream(sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try self.walkStream(c.body_instrs);
                try self.walkStream(sr.default_instrs);
            },
            .union_switch => |us| {
                for (us.cases) |c| try self.walkStream(c.body_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try self.walkStream(c.body_instrs);
            },
            .try_call_named => |tcn| {
                try self.walkStream(tcn.handler_instrs);
                try self.walkStream(tcn.success_instrs);
            },
            .guard_block => |gb| {
                try self.walkStream(gb.body);
            },
            .optional_dispatch => |od| {
                try self.walkStream(od.nil_instrs);
                try self.walkStream(od.struct_instrs);
            },
            else => {},
        }
    }

    fn maybeDemoteCallee(
        self: *DemotionWalker,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        const arg_info = self.uniqueness.arg_sites.get(my_id) orelse return;
        const callee = lookupFunction(self.program, arg_info.target) orelse return;

        // For each `.owned` slot of the callee that is currently
        // believed unique-on-entry, check whether THIS caller passed a
        // unique value.
        const callee_slots = self.program_uniqueness.by_function.get(callee.id) orelse return;
        for (callee.param_conventions, 0..) |conv, slot_idx| {
            if (slot_idx >= callee_slots.len) break;
            if (conv != .owned) continue;
            if (!callee_slots[slot_idx]) continue; // already demoted
            if (slot_idx >= arg_info.per_arg.len) {
                // Fewer args than slots — the call's arity doesn't
                // match. Conservatively demote.
                callee_slots[slot_idx] = false;
                try self.enqueueCallers(callee.id);
                continue;
            }
            if (!arg_info.per_arg[slot_idx]) {
                callee_slots[slot_idx] = false;
                try self.enqueueCallers(callee.id);
            }
        }
    }

    fn enqueueCallers(
        self: *DemotionWalker,
        callee_id: ir.FunctionId,
    ) error{OutOfMemory}!void {
        const list = self.callers_of.get(callee_id) orelse return;
        for (list.items) |caller_id| {
            // Re-enqueue the caller so its intraprocedural uniqueness is
            // recomputed under the demoted state. The callee itself is
            // also enqueued so subsequent demotions cascade.
            if (!self.in_worklist.contains(caller_id)) {
                try self.worklist.append(self.allocator, caller_id);
                try self.in_worklist.put(self.allocator, caller_id, {});
            }
        }
        // Also re-process the callee — its body might transitively
        // pass `param_get(slot)` to ANOTHER callee, whose state
        // depended on the now-demoted slot.
        if (!self.in_worklist.contains(callee_id)) {
            try self.worklist.append(self.allocator, callee_id);
            try self.in_worklist.put(self.allocator, callee_id, {});
        }
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const TestProgram = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,

    fn init(parent: std.mem.Allocator) TestProgram {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .program = .{ .functions = &.{}, .type_defs = &.{}, .entry = null },
        };
    }

    fn deinit(self: *TestProgram) void {
        self.arena.deinit();
    }

    fn allocator(self: *TestProgram) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn buildFunction(
    arena: std.mem.Allocator,
    id: ir.FunctionId,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_count: u32,
    param_conventions: []const ir.ParamConvention,
    result_convention: ir.ResultConvention,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, local_count);
    for (ownership) |*o| o.* = .owned;

    const params = try arena.alloc(ir.Param, param_conventions.len);
    for (params, 0..) |*p, i| {
        p.* = .{ .name = "_p", .type_expr = .void };
        _ = i;
    }
    return ir.Function{
        .id = id,
        .name = name,
        .scope_id = 0,
        .arity = @intCast(param_conventions.len),
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
        .param_conventions = try arena.dupe(ir.ParamConvention, param_conventions),
        .local_ownership = ownership,
        .result_convention = result_convention,
    };
}

test "uniqueness_interprocedural: empty program produces empty fixpoint" {
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    try testing.expect(u.by_function.count() == 0);
}

test "uniqueness_interprocedural: function with no .owned params has all-false slots" {
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    const conventions = [_]ir.ParamConvention{ .borrowed, .trivial };
    const fn0 = try buildFunction(
        arena,
        0,
        "borrowed_only",
        &.{.{ .ret = .{ .value = null } }},
        2,
        &conventions,
        .trivial,
    );
    const funcs = try arena.alloc(ir.Function, 1);
    funcs[0] = fn0;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    const slots = u.forFunction(0);
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expect(!slots[0]);
    try testing.expect(!slots[1]);
}

test "uniqueness_interprocedural: leaf function with .owned param starts unique-on-entry" {
    // A leaf function (no callers visible in the program) with an
    // `.owned` param is OPTIMISTICALLY assumed unique-on-entry. The
    // assumption is sound because the verifier (`runUniquenessCheck`) catches any
    // erroneous unchecked rewrite if the caller is outside the
    // visible program (it isn't, in this test).
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    const conventions = [_]ir.ParamConvention{.owned};
    const fn0 = try buildFunction(
        arena,
        0,
        "leaf",
        &.{
            .{ .param_get = .{ .dest = 0, .index = 0 } },
            .{ .ret = .{ .value = null } },
        },
        1,
        &conventions,
        .owned,
    );
    const funcs = try arena.alloc(ir.Function, 1);
    funcs[0] = fn0;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    const slots = u.forFunction(0);
    try testing.expectEqual(@as(usize, 1), slots.len);
    try testing.expect(slots[0]); // optimistic — proven unique
}

test "uniqueness_interprocedural: caller passes fresh map -> wrapper's param is unique-on-entry" {
    // Caller body:
    //   [0] map_init %0
    //   [1] move_value %1 <- %0
    //   [2] call_named "wrapper" args=[%1] dest=%2
    //   [3] ret
    //
    // Wrapper body (slot 0 .owned, .owned result):
    //   [0] param_get %0 <- param[0]
    //   [1] move_value %1 <- %0
    //   [2] call_builtin "Map.put" args=[%1, k=fake, v=fake] dest=%2
    //   [3] ret
    //
    // Expected: wrapper's slot 0 stays unique-on-entry (true).
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    // Wrapper. Convention: .owned slot 0, .owned result.
    const wrapper_conventions = [_]ir.ParamConvention{.owned};
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 1;
    put_args[1] = 2;
    put_args[2] = 3;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const wrapper_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const wrapper = try buildFunction(
        arena,
        0,
        "wrapper",
        &wrapper_instrs,
        5,
        &wrapper_conventions,
        .owned,
    );

    // Caller. No params; calls wrapper with a fresh map.
    const call_args = try arena.alloc(ir.LocalId, 1);
    call_args[0] = 1;
    const call_modes = try arena.alloc(ir.ValueMode, 1);
    call_modes[0] = .move;
    const caller_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "wrapper",
            .args = call_args,
            .arg_modes = call_modes,
        } },
        .{ .ret = .{ .value = 2 } },
    };
    const caller_conventions = [_]ir.ParamConvention{};
    const caller = try buildFunction(
        arena,
        1,
        "caller",
        &caller_instrs,
        3,
        &caller_conventions,
        .owned,
    );

    const funcs = try arena.alloc(ir.Function, 2);
    funcs[0] = wrapper;
    funcs[1] = caller;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    // Wrapper's slot 0 should be proven unique-on-entry.
    try testing.expect(u.isUniqueOnEntry(0, 0));
}

test "uniqueness_interprocedural: parked-then-passed caller demotes wrapper's slot" {
    // Caller body:
    //   [0] map_init %0
    //   [1] const_nil %1
    //   [2] list_cons %2 = [%0 | %1]    -- parks %0 in a list
    //   [3] move_value %3 <- %0          -- but %0 lost uniqueness
    //   [4] call_named "wrapper" args=[%3] dest=%4
    //
    // Expected: wrapper's slot 0 demoted to false because the caller
    // can't prove it's unique at the call site.
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    const wrapper_conventions = [_]ir.ParamConvention{.owned};
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 1;
    put_args[1] = 2;
    put_args[2] = 3;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const wrapper_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const wrapper = try buildFunction(
        arena,
        0,
        "wrapper",
        &wrapper_instrs,
        5,
        &wrapper_conventions,
        .owned,
    );

    const call_args = try arena.alloc(ir.LocalId, 1);
    call_args[0] = 3;
    const call_modes = try arena.alloc(ir.ValueMode, 1);
    call_modes[0] = .move;
    const caller_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_named = .{
            .dest = 4,
            .name = "wrapper",
            .args = call_args,
            .arg_modes = call_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const caller_conventions = [_]ir.ParamConvention{};
    const caller = try buildFunction(
        arena,
        1,
        "caller",
        &caller_instrs,
        5,
        &caller_conventions,
        .owned,
    );

    const funcs = try arena.alloc(ir.Function, 2);
    funcs[0] = wrapper;
    funcs[1] = caller;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUniqueOnEntry(0, 0));
}

test "uniqueness_interprocedural: copy-then-passed caller demotes wrapper's slot" {
    // Caller body:
    //   [0] map_init %0
    //   [1] copy_value %1 <- %0        -- retains an alias of %0
    //   [2] move_value %2 <- %0        -- source is no longer unique
    //   [3] call_named "wrapper" args=[%2] dest=%3
    //
    // Expected: wrapper's slot 0 demoted to false because a copied
    // value increments the source's runtime refcount before the call.
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    const wrapper_conventions = [_]ir.ParamConvention{.owned};
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 1;
    put_args[1] = 2;
    put_args[2] = 3;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const wrapper_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const wrapper = try buildFunction(
        arena,
        0,
        "wrapper",
        &wrapper_instrs,
        5,
        &wrapper_conventions,
        .owned,
    );

    const call_args = try arena.alloc(ir.LocalId, 1);
    call_args[0] = 2;
    const call_modes = try arena.alloc(ir.ValueMode, 1);
    call_modes[0] = .move;
    const caller_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .copy_value = .{ .dest = 1, .source = 0 } },
        .{ .move_value = .{ .dest = 2, .source = 0 } },
        .{ .call_named = .{
            .dest = 3,
            .name = "wrapper",
            .args = call_args,
            .arg_modes = call_modes,
        } },
        .{ .ret = .{ .value = 3 } },
    };
    const caller_conventions = [_]ir.ParamConvention{};
    const caller = try buildFunction(
        arena,
        1,
        "caller",
        &caller_instrs,
        4,
        &caller_conventions,
        .owned,
    );

    const funcs = try arena.alloc(ir.Function, 2);
    funcs[0] = wrapper;
    funcs[1] = caller;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    try testing.expect(!u.isUniqueOnEntry(0, 0));
}

test "uniqueness_interprocedural: tail-recursive accumulator stays unique-on-entry" {
    // Pattern: count_flips(arr, ...). The function calls itself
    // recursively, passing the result of an owned-mutating call as
    // the receiver. After Phase 4's move-on-last-use rewrite, the
    // tail_call passes the freshly-mutated map by move.
    //
    // Function body of `count_flips` (slot 0 .owned, .owned result):
    //   [0] param_get %0 <- param[0]   -- map
    //   [1] move_value %1 <- %0
    //   [2] const_int %2 = 0
    //   [3] const_int %3 = 0
    //   [4] call_builtin "Map.put" args=[%1, %2, %3] dest=%4
    //   [5] tail_call "count_flips" args=[%4]   -- pass the unique result
    //
    // Expected: slot 0 stays unique-on-entry. The tail call's arg %4
    // is the result of an owned-mutating call (unique by runtime
    // contract), so the per-arg uniqueness check at the tail_call
    // site says true, no demotion fires.
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    const conventions = [_]ir.ParamConvention{.owned};
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 1;
    put_args[1] = 2;
    put_args[2] = 3;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const tail_args = try arena.alloc(ir.LocalId, 1);
    tail_args[0] = 4;
    const fn0_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
        .{ .tail_call = .{
            .name = "count_flips",
            .args = tail_args,
        } },
    };
    const fn0 = try buildFunction(
        arena,
        0,
        "count_flips",
        &fn0_instrs,
        5,
        &conventions,
        .owned,
    );

    const funcs = try arena.alloc(ir.Function, 1);
    funcs[0] = fn0;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    try testing.expect(u.isUniqueOnEntry(0, 0));
}

test "uniqueness_interprocedural: mixed callers — one shared, slot demotes" {
    // wrapper has slot 0 .owned. Two callers:
    //   caller_unique: passes a fresh map (unique).
    //   caller_shared: parks the map in a list, then passes the
    //                  shared alias.
    //
    // Expected: even one bad caller demotes wrapper's slot 0.
    var p = TestProgram.init(testing.allocator);
    defer p.deinit();
    const arena = p.allocator();

    // wrapper: same shape as before.
    const wrapper_conventions = [_]ir.ParamConvention{.owned};
    const put_args = try arena.alloc(ir.LocalId, 3);
    put_args[0] = 1;
    put_args[1] = 2;
    put_args[2] = 3;
    const put_modes = try arena.alloc(ir.ValueMode, 3);
    put_modes[0] = .move;
    put_modes[1] = .borrow;
    put_modes[2] = .borrow;
    const wrapper_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put",
            .args = put_args,
            .arg_modes = put_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const wrapper = try buildFunction(
        arena,
        0,
        "wrapper",
        &wrapper_instrs,
        5,
        &wrapper_conventions,
        .owned,
    );

    // caller_unique: passes fresh map.
    const u_args = try arena.alloc(ir.LocalId, 1);
    u_args[0] = 1;
    const u_modes = try arena.alloc(ir.ValueMode, 1);
    u_modes[0] = .move;
    const caller_unique_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "wrapper",
            .args = u_args,
            .arg_modes = u_modes,
        } },
        .{ .ret = .{ .value = 2 } },
    };
    const caller_conventions = [_]ir.ParamConvention{};
    const caller_unique = try buildFunction(
        arena,
        1,
        "caller_unique",
        &caller_unique_instrs,
        3,
        &caller_conventions,
        .owned,
    );

    // caller_shared: parks the map first.
    const s_args = try arena.alloc(ir.LocalId, 1);
    s_args[0] = 3;
    const s_modes = try arena.alloc(ir.ValueMode, 1);
    s_modes[0] = .move;
    const caller_shared_instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_named = .{
            .dest = 4,
            .name = "wrapper",
            .args = s_args,
            .arg_modes = s_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const caller_shared = try buildFunction(
        arena,
        2,
        "caller_shared",
        &caller_shared_instrs,
        5,
        &caller_conventions,
        .owned,
    );

    const funcs = try arena.alloc(ir.Function, 3);
    funcs[0] = wrapper;
    funcs[1] = caller_unique;
    funcs[2] = caller_shared;
    p.program.functions = funcs;

    var u = try analyzeProgram(testing.allocator, &p.program);
    defer u.deinit(testing.allocator);

    // Even one bad caller demotes the slot.
    try testing.expect(!u.isUniqueOnEntry(0, 0));
}
