const std = @import("std");
const ir = @import("ir.zig");
const types_mod = @import("types.zig");

// ============================================================
// Unified Escape/Lifetime/Region Lattice
//
// Research plan §3: Product lattice for all SSA values:
//   ValueState = EscapeState × RegionMembership × OwnershipState
//
// Draws on: Tofte-Talpin region inference, Aiken non-lexical
// regions, Rust NLL/Polonius, Swift OSSA, Graal PEA, Koka
// Perceus, Lobster ownership inference, Go interprocedural EA.
// ============================================================

// ============================================================
// Section 1: Core IDs
// ============================================================

/// Unique identifier for an allocation site in the IR.
/// Each struct_init, tuple_init, list_init, map_init, make_closure,
/// or other allocating instruction gets a unique AllocSiteId.
pub const AllocSiteId = u32;

/// Unique identifier for a borrow site (borrowed reference creation).
pub const BorrowSiteId = u32;

/// Unique identifier for a pattern match site (for Perceus reuse).
pub const MatchSiteId = u32;

/// Block-scoped key for virtual object tracking in PEA.
pub const BlockVirtualKey = struct {
    block: ir.LabelId,
    alloc_site: AllocSiteId,
};

/// One step of nested-stream descent from a top-level block toward
/// a position inside one of its nested instruction streams. Used to
/// address positions inside `case_block` arms, `if_expr` then/else,
/// `optional_dispatch` nil/struct, etc. without packing the
/// navigation into a synthetic `instr_index`.
///
/// The previous design encoded nested-stream positions via formulas
/// like `instr_index +| (arm_idx * 100 + idx) +| 1` (see
/// `perceus.zig:617-665` history). The encoding never actually
/// fired at ZIR-emit time because `zir_builder.zig:3420` only
/// updates `current_instr_index` during the top-level block walk,
/// not during nested-stream emission — so synthetic-encoded
/// `InsertionPoint`s targeting nested positions never matched the
/// driver state. The optimization opportunity (Perceus reuse,
/// drop-specialization inside nested arms) was permanently dropped
/// for every program that exercised the nested path.
///
/// `StreamStep` and the new `path` field on `InsertionPoint`
/// replace that encoding with explicit descent. The materialization
/// pass walks the path through nested streams the same way
/// `arc_drop_insertion.zig`'s `StreamRebuilder` does. The
/// previously-broken optimization becomes correctly addressable
/// post-refactor.
pub const StreamStep = struct {
    /// Index within the parent stream of the instruction whose
    /// nested stream we descend into. This locates the parent
    /// instruction; `child` then selects which of its nested
    /// streams to enter.
    parent_instr_index: u32,
    /// Which nested stream of the parent instruction to enter.
    child: ChildSlot,

    /// Project onto the `ir`-owned `StreamPathStep` consumed by the
    /// shared coordinate resolver.
    pub fn toStreamPathStep(self: StreamStep) ir.StreamPathStep {
        return .{
            .parent_instr_index = self.parent_instr_index,
            .slot = self.child.toStreamSlot(),
        };
    }
};

/// Convert a stored `[]const StreamStep` coordinate path into the
/// `ir`-owned `[]ir.StreamPathStep` the shared resolver
/// (`ir.streamAtPath` / `ir.instructionAtPath`) consumes. The returned
/// slice is allocated with `allocator` and owned by the caller.
pub fn toStreamPath(
    allocator: std.mem.Allocator,
    path: []const StreamStep,
) ![]ir.StreamPathStep {
    const out = try allocator.alloc(ir.StreamPathStep, path.len);
    for (path, 0..) |step, i| out[i] = step.toStreamPathStep();
    return out;
}

/// Which child stream of an instruction with nested streams. Each
/// constructor is the IR-side parallel of a recursion case in
/// `arc_drop_insertion.zig`'s `rebuildChildren` switch.
pub const ChildSlot = union(enum) {
    if_expr_then,
    if_expr_else,
    case_block_pre,
    case_block_arm_cond: u32, // arm index within `case_block.arms`
    case_block_arm_body: u32, // arm index within `case_block.arms`
    case_block_default,
    switch_literal_case: u32, // case index within `switch_literal.cases`
    switch_literal_default,
    switch_return_case: u32, // case index within `switch_return.cases`
    switch_return_default,
    union_switch_case: u32, // case index within `union_switch.cases`
    /// `union_switch.else_instrs` — the catch-all `_` prong. Present
    /// only when `has_else` is set. Yielded after all `cases`,
    /// matching `ir.forEachChildStream`'s canonical order.
    union_switch_else,
    union_switch_return_case: u32, // case index within `union_switch_return.cases`
    try_call_named_success,
    try_call_named_handler,
    guard_block_body,
    optional_dispatch_nil,
    optional_dispatch_struct,

    /// Project onto the `ir`-owned `ChildStreamSlot` used by the shared
    /// coordinate resolver (`ir.streamAtPath` / `ir.instructionAtPath`).
    /// The two enumerations are kept in lock-step; this is the single
    /// crossing point from the analysis-side `ChildSlot` to `ir`'s
    /// canonical `ChildStreamKind`.
    pub fn toStreamSlot(self: ChildSlot) ir.ChildStreamSlot {
        return switch (self) {
            .if_expr_then => .{ .kind = .if_then },
            .if_expr_else => .{ .kind = .if_else },
            .case_block_pre => .{ .kind = .case_pre },
            .case_block_arm_cond => |idx| .{ .kind = .case_arm_cond, .index = idx },
            .case_block_arm_body => |idx| .{ .kind = .case_arm_body, .index = idx },
            .case_block_default => .{ .kind = .case_default },
            .switch_literal_case => |idx| .{ .kind = .switch_lit_case, .index = idx },
            .switch_literal_default => .{ .kind = .switch_lit_default },
            .switch_return_case => |idx| .{ .kind = .switch_ret_case, .index = idx },
            .switch_return_default => .{ .kind = .switch_ret_default },
            .union_switch_case => |idx| .{ .kind = .union_switch_case, .index = idx },
            .union_switch_else => .{ .kind = .union_switch_else },
            .union_switch_return_case => |idx| .{ .kind = .union_switch_ret_case, .index = idx },
            .try_call_named_success => .{ .kind = .try_success },
            .try_call_named_handler => .{ .kind = .try_handler },
            .guard_block_body => .{ .kind = .guard_body },
            .optional_dispatch_nil => .{ .kind = .optional_dispatch_nil },
            .optional_dispatch_struct => .{ .kind = .optional_dispatch_struct },
        };
    }

    /// Inverse of `toStreamSlot`: build the analysis-side `ChildSlot`
    /// from a canonical `ir.ChildStreamSlot`. Used by perceus discovery
    /// to record `StreamStep` paths directly from the slots
    /// `ir.forEachChildStreamWithSlot` yields, so the slot mapping is
    /// never hand-maintained at the discovery sites.
    pub fn fromStreamSlot(slot: ir.ChildStreamSlot) ChildSlot {
        return switch (slot.kind) {
            .if_then => .if_expr_then,
            .if_else => .if_expr_else,
            .case_pre => .case_block_pre,
            .case_arm_cond => .{ .case_block_arm_cond = slot.index },
            .case_arm_body => .{ .case_block_arm_body = slot.index },
            .case_default => .case_block_default,
            .switch_lit_case => .{ .switch_literal_case = slot.index },
            .switch_lit_default => .switch_literal_default,
            .switch_ret_case => .{ .switch_return_case = slot.index },
            .switch_ret_default => .switch_return_default,
            .union_switch_case => .{ .union_switch_case = slot.index },
            .union_switch_else => .union_switch_else,
            .union_switch_ret_case => .{ .union_switch_return_case = slot.index },
            .try_success => .try_call_named_success,
            .try_handler => .try_call_named_handler,
            .guard_body => .guard_block_body,
            .optional_dispatch_nil => .optional_dispatch_nil,
            .optional_dispatch_struct => .optional_dispatch_struct,
        };
    }
};

/// Identifier for an insertion point in the IR for ARC operations.
///
/// Top-level positions: `path.len == 0`, `instr_index` indexes into
/// `function.body[<block_with_label>].instructions`.
///
/// Nested positions: `path[0]` describes the descent from the
/// top-level block; subsequent steps descend further. `instr_index`
/// indexes into the innermost stream reached by walking the path.
pub const InsertionPoint = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    /// Empty for positions in the top-level block. Each element
    /// descends one level of nesting (see `StreamStep`).
    path: []const StreamStep = &.{},
    /// Index within the final (innermost) stream reached by walking
    /// `path` from the top-level block.
    instr_index: u32,
    /// Whether to insert before or after the instruction at
    /// `instr_index`.
    position: enum { before, after },
    /// Mutation-resistant fingerprint of the *anchor* instruction this
    /// point was recorded against (the instruction at `instr_index`
    /// the operation inserts before/after). Captured at analysis time;
    /// the materializer re-resolves the coordinate against the final
    /// IR shape and refuses to act if the live instruction's
    /// fingerprint differs — the coordinate went stale because an
    /// intervening pass (ownership rewrite, drop insertion,
    /// contification) reshaped the stream (audit arc-param--01).
    /// `null` for points with no anchor instruction — an "append at
    /// end of stream" position (`instr_index == stream.len`) — or for
    /// records produced before identity capture was wired in (they
    /// fall back to bounds-only checking).
    expected_identity: ?ir.InstructionIdentity = null,
};

// ============================================================
// Section 2: Escape Lattice (Research Plan §3.2)
// ============================================================

/// Six-element escape lattice inspired by Choi et al. and Graal PEA.
/// Generalizes the existing closure-only lattice to ALL value shapes.
///
/// Lattice ordering (bottom to top):
///   bottom < no_escape < block_local < function_local < arg_escape_safe < global_escape
///
/// Height = 5. Guarantees fixpoint convergence in at most 5·|V|
/// iterations where |V| is the number of SSA values.
pub const EscapeState = enum(u4) {
    /// Value is never allocated (dead code, scalar-replaced, or eliminated).
    bottom = 0,

    /// Value never leaves the instruction that creates it.
    /// Candidate for scalar replacement (Graal-style).
    no_escape = 1,

    /// Value is used only within the creating block.
    /// Candidate for stack allocation at block scope.
    block_local = 2,

    /// Value is used across blocks but does not escape the function.
    /// Candidate for stack allocation at function scope.
    function_local = 3,

    /// Value is passed as an argument to a callee but the callee's summary
    /// proves it does not retain/store/return it.
    /// Candidate for caller-region or stack allocation with callee cooperation.
    arg_escape_safe = 4,

    /// Value is passed to a callee with no safe summary, or stored in a
    /// heap-reachable location, or returned from the function.
    /// Must be heap-allocated with ARC.
    global_escape = 5,

    /// Least upper bound (join) of two escape states.
    ///
    /// Join rules:
    ///   bottom ⊔ x = x
    ///   no_escape ⊔ block_local = block_local
    ///   no_escape ⊔ function_local = function_local
    ///   block_local ⊔ function_local = function_local
    ///   arg_escape_safe ⊔ function_local = function_local
    ///   anything ⊔ global_escape = global_escape
    pub fn join(a: EscapeState, b: EscapeState) EscapeState {
        const a_val = @intFromEnum(a);
        const b_val = @intFromEnum(b);
        // The enum values are ordered so max gives the LUB.
        // Special case: arg_escape_safe ⊔ function_local = function_local
        // This works because function_local(3) < arg_escape_safe(4),
        // but semantically function_local subsumes arg_escape_safe for
        // values that are also used across blocks.
        if (a == .arg_escape_safe and b == .function_local) return .function_local;
        if (b == .arg_escape_safe and a == .function_local) return .function_local;
        return @enumFromInt(@max(a_val, b_val));
    }

    /// Greatest lower bound (meet) of two escape states.
    pub fn meet(a: EscapeState, b: EscapeState) EscapeState {
        const a_val = @intFromEnum(a);
        const b_val = @intFromEnum(b);
        return @enumFromInt(@min(a_val, b_val));
    }

    /// Returns true if this state is at least as high as `other`.
    pub fn subsumes(self: EscapeState, other: EscapeState) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    /// Returns true if this value can be stack-allocated.
    pub fn isStackEligible(self: EscapeState) bool {
        return switch (self) {
            .bottom, .no_escape, .block_local, .function_local => true,
            .arg_escape_safe, .global_escape => false,
        };
    }

    /// Returns true if this value requires heap allocation with ARC.
    pub fn requiresHeap(self: EscapeState) bool {
        return self == .global_escape;
    }

    /// Returns true if this value can be entirely eliminated.
    pub fn isEliminable(self: EscapeState) bool {
        return self == .bottom;
    }
};

// ============================================================
// Section 3: Region Membership (Research Plan §3.3)
// ============================================================

/// Region identifier. Regions form a tree ordered by containment.
/// Inner regions have shorter lifetimes.
pub const RegionId = enum(u32) {
    /// The global/heap region. Values here live until ARC drops them.
    heap = 0,

    /// Function-scoped region. Deallocated at function return.
    /// Represented as stack frame space.
    function_frame = 1,

    /// Block-scoped regions identified by IR block label + 2.
    /// Deallocated at block exit.
    _,

    /// Create a block-scoped region from a block label.
    pub fn fromBlock(label: ir.LabelId) RegionId {
        return @enumFromInt(@as(u32, label) + 2);
    }

    /// Get the block label if this is a block-scoped region.
    pub fn toBlock(self: RegionId) ?ir.LabelId {
        const val = @intFromEnum(self);
        if (val < 2) return null;
        return @intCast(val - 2);
    }

    /// Returns true if this region outlives (contains) the other.
    /// heap outlives function_frame outlives any block region.
    pub fn outlives(self: RegionId, other: RegionId) bool {
        // Heap outlives everything.
        if (self == .heap) return true;
        if (other == .heap) return false;
        // Function frame outlives any block region.
        if (self == .function_frame) return true;
        if (other == .function_frame) return false;
        // Block regions: containment determined by dominator tree
        // (requires external context - conservative here).
        return @intFromEnum(self) <= @intFromEnum(other);
    }
};

/// Outlives constraint between two regions.
pub const OutlivesConstraint = struct {
    /// The region that must outlive the other.
    longer: RegionId,
    /// The region that must not outlive the other.
    shorter: RegionId,
    /// Reason for this constraint (for diagnostics).
    reason: OutlivesReason,
};

pub const OutlivesReason = enum {
    assignment,
    phi_merge,
    return_value,
    store_into_container,
    borrow_reference,
    call_argument,
};

// ============================================================
// Section 4: Ownership State (Research Plan §3.4)
// ============================================================

/// Ownership state for SSA values at merge points.
/// Uses types_mod.Ownership (shared/unique/borrowed) as the base.
pub const OwnershipState = types_mod.Ownership;

/// Result of ownership merge at a phi node.
pub const OwnershipMergeResult = union(enum) {
    /// Merge succeeded.
    ok: OwnershipState,
    /// Merge is illegal (e.g., borrowed ⊔ unique).
    illegal: OwnershipMergeError,
};

pub const OwnershipMergeError = enum {
    /// Cannot promote borrowed to owned at merge.
    borrowed_promoted_to_owned,
    /// Different unique bindings merged.
    different_unique_bindings,
};

/// Merge ownership states at a phi node.
///
/// Rules (Research Plan §3.4):
///   shared ⊔ shared = shared
///   unique ⊔ unique = unique (same binding) or error (different)
///   borrowed ⊔ borrowed = borrowed
///   unique ⊔ shared = shared (implicit conversion)
///   borrowed ⊔ shared = error
///   borrowed ⊔ unique = error
pub fn mergeOwnership(a: OwnershipState, b: OwnershipState) OwnershipMergeResult {
    if (a == b) return .{ .ok = a };

    // unique ⊔ shared = shared (implicit unique→shared conversion)
    if ((a == .unique and b == .shared) or (a == .shared and b == .unique)) {
        return .{ .ok = .shared };
    }

    // borrowed ⊔ anything_owning = error
    if (a == .borrowed or b == .borrowed) {
        return .{ .illegal = .borrowed_promoted_to_owned };
    }

    // Should not reach here, but be safe.
    return .{ .ok = .shared };
}

/// Check if ownership conversion is legal.
///
/// Conversions (Research Plan §3.4):
///   unique → shared:   allowed (share operation, inserts retain)
///   unique → borrowed:  allowed (temporary borrow)
///   shared → borrowed:  allowed (temporary borrow of shared value)
///   borrowed → shared:  FORBIDDEN
///   borrowed → unique:  FORBIDDEN
///   shared → unique:    FORBIDDEN
pub fn isOwnershipConversionLegal(from: OwnershipState, to: OwnershipState) bool {
    if (from == to) return true;
    return switch (from) {
        .unique => to == .shared or to == .borrowed,
        .shared => to == .borrowed,
        .borrowed => false,
    };
}

// ============================================================
// Section 5: Allocation Strategy (Research Plan §4.4)
// ============================================================

/// Concrete allocation decision for an allocation site,
/// determined after escape analysis and region solving.
pub const AllocationStrategy = enum {
    /// Value never exists at runtime (eliminated or scalar-replaced).
    eliminated,

    /// Value lives in SSA registers (scalar replacement of aggregate).
    /// Fields decomposed into individual locals.
    scalar_replaced,

    /// Value lives on the stack in the creating block's frame.
    stack_block,

    /// Value lives on the stack in the function's frame.
    stack_function,

    /// Value lives in a caller-provided region (region-polymorphic).
    caller_region,

    /// Value lives on the heap with ARC management.
    heap_arc,
};

/// Multiplicity of a region (MLKit-inspired, Research Plan §4.5).
/// Determines how many values each region contains.
pub const Multiplicity = enum {
    /// Region is never written to (dead allocation, can be eliminated).
    zero,

    /// Exactly one value stored (finite region → single stack slot).
    one,

    /// Multiple values stored (infinite region → needs dynamic allocation).
    many,
};

/// Storage mode for multi-value regions (MLKit-inspired, Research Plan §4.6).
pub const StorageMode = enum {
    /// Preserve existing values, add new one. Default.
    attop,

    /// Reset the region (free all contents), then allocate.
    /// Applicable when all prior allocations in the region are dead
    /// at the new allocation point.
    atbot,
};

/// Map escape state + multiplicity to allocation strategy.
pub fn escapeToStrategy(escape: EscapeState, multiplicity: Multiplicity) AllocationStrategy {
    return switch (escape) {
        .bottom => .eliminated,
        .no_escape => if (multiplicity == .one) .scalar_replaced else .stack_block,
        .block_local => .stack_block,
        .function_local => .stack_function,
        .arg_escape_safe => .caller_region,
        .global_escape => .heap_arc,
    };
}

// ============================================================
// Section 6: Field-Sensitive Tracking (Research Plan §3.5)
// ============================================================

/// Per-field escape state map for composite types.
/// Index by field position for structs/tuples.
pub const FieldEscapeMap = struct {
    /// Per-field escape states.
    field_states: []EscapeState,

    /// Aggregate escape state (join of all field states).
    aggregate_state: EscapeState,

    /// Allocator used for field_states.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_fields: usize) !FieldEscapeMap {
        const states = try allocator.alloc(EscapeState, num_fields);
        @memset(states, .bottom);
        return .{
            .field_states = states,
            .aggregate_state = .bottom,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FieldEscapeMap) void {
        self.allocator.free(self.field_states);
    }

    /// Update a field's escape state and recompute aggregate.
    pub fn updateField(self: *FieldEscapeMap, field_idx: usize, state: EscapeState) void {
        if (field_idx >= self.field_states.len) return;
        self.field_states[field_idx] = EscapeState.join(self.field_states[field_idx], state);
        self.recomputeAggregate();
    }

    /// Join with another field escape map (e.g., at phi merge).
    pub fn joinWith(self: *FieldEscapeMap, other: *const FieldEscapeMap) void {
        const len = @min(self.field_states.len, other.field_states.len);
        for (0..len) |i| {
            self.field_states[i] = EscapeState.join(self.field_states[i], other.field_states[i]);
        }
        self.recomputeAggregate();
    }

    fn recomputeAggregate(self: *FieldEscapeMap) void {
        var agg: EscapeState = .bottom;
        for (self.field_states) |s| {
            agg = EscapeState.join(agg, s);
        }
        self.aggregate_state = agg;
    }

    /// Clone this map with a new allocator.
    pub fn clone(self: *const FieldEscapeMap, allocator: std.mem.Allocator) !FieldEscapeMap {
        const states = try allocator.alloc(EscapeState, self.field_states.len);
        @memcpy(states, self.field_states);
        return .{
            .field_states = states,
            .aggregate_state = self.aggregate_state,
            .allocator = allocator,
        };
    }
};

// ============================================================
// Section 7: Partial Escape Analysis - Virtual Objects (§3.6)
// ============================================================

/// Virtual object state for Graal-inspired partial escape analysis.
/// Objects are tracked as "virtual" (not yet allocated) until they
/// escape on a particular control-flow branch.
pub const VirtualObject = struct {
    /// Allocation site that produced this object.
    alloc_site: AllocSiteId,

    /// Per-field values (SSA value IDs tracking current field contents).
    /// Null entries mean the field has not been written.
    field_values: []?ir.LocalId,

    /// Whether this object has been materialized (actually allocated)
    /// on this branch.
    materialized: bool,

    /// Type of the virtual object (for layout/size info).
    type_id: types_mod.TypeId,

    /// Allocator used for field_values.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, alloc_site: AllocSiteId, num_fields: usize, type_id: types_mod.TypeId) !VirtualObject {
        const fields = try allocator.alloc(?ir.LocalId, num_fields);
        @memset(fields, null);
        return .{
            .alloc_site = alloc_site,
            .field_values = fields,
            .materialized = false,
            .type_id = type_id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VirtualObject) void {
        self.allocator.free(self.field_values);
    }

    /// Set a field's current SSA value.
    pub fn setField(self: *VirtualObject, field_idx: usize, value: ir.LocalId) void {
        if (field_idx < self.field_values.len) {
            self.field_values[field_idx] = value;
        }
    }

    /// Get a field's current SSA value (for scalar replacement).
    pub fn getField(self: *const VirtualObject, field_idx: usize) ?ir.LocalId {
        if (field_idx < self.field_values.len) {
            return self.field_values[field_idx];
        }
        return null;
    }

    /// Mark this object as materialized (escape point reached).
    pub fn materialize(self: *VirtualObject) void {
        self.materialized = true;
    }

    /// Clone for branch splitting in PEA.
    pub fn clone(self: *const VirtualObject, allocator: std.mem.Allocator) !VirtualObject {
        const fields = try allocator.alloc(?ir.LocalId, self.field_values.len);
        @memcpy(fields, self.field_values);
        return .{
            .alloc_site = self.alloc_site,
            .field_values = fields,
            .materialized = self.materialized,
            .type_id = self.type_id,
            .allocator = allocator,
        };
    }
};

// ============================================================
// Section 8: Interprocedural Summaries (Research Plan §6.1)
// ============================================================

/// Per-function summary consumed by callers for interprocedural analysis.
pub const FunctionSummary = struct {
    /// Per-parameter escape summary.
    param_summaries: []const ParamSummary,

    /// How the return value relates to parameters.
    return_summary: ReturnSummary,

    /// Whether the function may diverge (loop forever, panic).
    may_diverge: bool,

    /// Lambda sets for function-typed parameters.
    param_lambda_sets: []const LambdaSet,

    pub fn conservative(num_params: usize, allocator: std.mem.Allocator) !FunctionSummary {
        const params = try allocator.alloc(ParamSummary, num_params);
        errdefer allocator.free(params);
        @memset(params, ParamSummary.conservative());

        const lambda_sets = try allocator.alloc(LambdaSet, num_params);
        errdefer allocator.free(lambda_sets);
        @memset(lambda_sets, LambdaSet.empty());

        return .{
            .param_summaries = params,
            .return_summary = ReturnSummary.unknown(),
            .may_diverge = true,
            .param_lambda_sets = lambda_sets,
        };
    }

    /// Deep-clone every slice owned by this summary into `allocator`.
    pub fn clone(self: FunctionSummary, allocator: std.mem.Allocator) !FunctionSummary {
        const param_summaries = try allocator.dupe(ParamSummary, self.param_summaries);
        errdefer allocator.free(param_summaries);

        const return_summary = try self.return_summary.clone(allocator);
        errdefer {
            var owned_return_summary = return_summary;
            owned_return_summary.deinit(allocator);
        }

        const param_lambda_sets = try allocator.alloc(LambdaSet, self.param_lambda_sets.len);
        errdefer allocator.free(param_lambda_sets);

        var initialized_lambda_sets: usize = 0;
        errdefer {
            for (param_lambda_sets[0..initialized_lambda_sets]) |*lambda_set| {
                lambda_set.deinit(allocator);
            }
        }

        for (self.param_lambda_sets, 0..) |lambda_set, index| {
            param_lambda_sets[index] = try lambda_set.clone(allocator);
            initialized_lambda_sets += 1;
        }

        return .{
            .param_summaries = param_summaries,
            .return_summary = return_summary,
            .may_diverge = self.may_diverge,
            .param_lambda_sets = param_lambda_sets,
        };
    }

    /// Free slices owned by this summary.
    pub fn deinit(self: *FunctionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.param_summaries);
        self.param_summaries = &.{};

        self.return_summary.deinit(allocator);

        for (@constCast(self.param_lambda_sets)) |*lambda_set| {
            lambda_set.deinit(allocator);
        }
        allocator.free(self.param_lambda_sets);
        self.param_lambda_sets = &.{};

        self.may_diverge = false;
    }
};

/// Per-parameter escape behavior summary.
pub const ParamSummary = struct {
    /// Parameter escapes to the heap.
    escapes_to_heap: bool,

    /// Parameter is returned (directly or transitively).
    returned: bool,

    /// Parameter is passed to another function without a safe summary.
    passed_to_unknown: bool,

    /// Parameter is used in a reset/reuse operation (needs ownership).
    used_in_reset: bool,

    /// Parameter is only read (never stored, returned, or passed unsafely).
    /// If true, the parameter can be borrowed.
    read_only: bool,

    /// Dereference depth at which the parameter escapes (Go-style).
    /// 0 = the value itself escapes; 1 = a value pointed to by it; etc.
    escape_deref_depth: i8,

    /// Return a conservative summary (worst case).
    pub fn conservative() ParamSummary {
        return .{
            .escapes_to_heap = true,
            .returned = true,
            .passed_to_unknown = true,
            .used_in_reset = false,
            .read_only = false,
            .escape_deref_depth = 0,
        };
    }

    /// Return a safe (best case) summary.
    pub fn safe() ParamSummary {
        return .{
            .escapes_to_heap = false,
            .returned = false,
            .passed_to_unknown = false,
            .used_in_reset = false,
            .read_only = true,
            .escape_deref_depth = -1,
        };
    }

    /// Does this parameter escape (need heap allocation at call site)?
    pub fn escapes(self: ParamSummary) bool {
        return self.escapes_to_heap or self.returned or self.passed_to_unknown;
    }

    /// Can this parameter be borrowed (no ownership needed)?
    pub fn canBorrow(self: ParamSummary) bool {
        return self.read_only and !self.used_in_reset;
    }

    /// Join two summaries (union of behaviors).
    pub fn join(a: ParamSummary, b: ParamSummary) ParamSummary {
        return .{
            .escapes_to_heap = a.escapes_to_heap or b.escapes_to_heap,
            .returned = a.returned or b.returned,
            .passed_to_unknown = a.passed_to_unknown or b.passed_to_unknown,
            .used_in_reset = a.used_in_reset or b.used_in_reset,
            .read_only = a.read_only and b.read_only,
            .escape_deref_depth = @max(a.escape_deref_depth, b.escape_deref_depth),
        };
    }
};

/// Return value provenance summary.
pub const ReturnSummary = struct {
    /// Which parameter indices flow to the return value.
    /// Empty if return is a fresh allocation or constant.
    param_sources: []const u32,

    /// Whether the return value is a fresh allocation.
    fresh_alloc: bool,

    pub fn unknown() ReturnSummary {
        return .{
            .param_sources = &.{},
            .fresh_alloc = false,
        };
    }

    pub fn freshAllocation() ReturnSummary {
        return .{
            .param_sources = &.{},
            .fresh_alloc = true,
        };
    }

    pub fn clone(self: ReturnSummary, allocator: std.mem.Allocator) !ReturnSummary {
        return .{
            .param_sources = try allocator.dupe(u32, self.param_sources),
            .fresh_alloc = self.fresh_alloc,
        };
    }

    pub fn deinit(self: *ReturnSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.param_sources);
        self.* = ReturnSummary.unknown();
    }
};

// ============================================================
// Section 9: Lambda Sets (Research Plan §5.1, §6.4)
// ============================================================

/// A lambda set enumerates every closure that could flow to a
/// call site. Used for defunctionalization/specialization.
///
/// GAP-P2R-02 — the set carries a `top` flag for the "unknown" lattice
/// element: a value whose closure provenance the analysis cannot fully
/// enumerate (e.g. a closure RETURNED from a `call_dispatch` over a clause
/// group, or read out of an opaque `call_builtin` result). A top set is NOT a
/// finite enumeration, so `specializationForLambdaSet` must never treat it as
/// a singleton and direct-dispatch it — it falls back to dynamic dispatch.
/// `top` strictly over-approximates: merging top with anything stays top, so a
/// real closure flowing into a merge with a top sibling can never collapse the
/// merge to a spurious singleton (the escape--01 hazard class).
pub const LambdaSet = struct {
    /// Function IDs of closures in this set.
    members: []const ir.FunctionId,
    /// GAP-P2R-02 — the "unknown/top" lattice element. When true, the set
    /// stands for an unbounded/unknowable collection of closures; `members`
    /// holds whatever subset was still enumerable but is NOT authoritative.
    top: bool = false,

    pub fn empty() LambdaSet {
        return .{ .members = &.{}, .top = false };
    }

    pub fn singleton(func: ir.FunctionId) LambdaSet {
        // Note: Caller must ensure the slice lives long enough.
        return .{ .members = &.{func}, .top = false };
    }

    pub fn clone(self: LambdaSet, allocator: std.mem.Allocator) !LambdaSet {
        return .{ .members = try allocator.dupe(ir.FunctionId, self.members), .top = self.top };
    }

    pub fn deinit(self: *LambdaSet, allocator: std.mem.Allocator) void {
        allocator.free(self.members);
        self.* = LambdaSet.empty();
    }

    pub fn size(self: LambdaSet) usize {
        return self.members.len;
    }

    /// A top set is never a singleton — even if exactly one member was
    /// enumerable, the unknown residual means the real callee set is unbounded.
    pub fn isSingleton(self: LambdaSet) bool {
        return !self.top and self.members.len == 1;
    }

    /// A top set is never empty (it stands for an unknown, possibly non-empty
    /// collection), so it is never classified as dead/unreachable.
    pub fn isEmpty(self: LambdaSet) bool {
        return !self.top and self.members.len == 0;
    }

    pub fn contains(self: LambdaSet, func: ir.FunctionId) bool {
        for (self.members) |m| {
            if (m == func) return true;
        }
        return false;
    }
};

/// Specialization decision for a call site based on lambda set size.
pub const SpecializationDecision = enum {
    /// Unreachable call site (empty lambda set → dead code).
    unreachable_call,

    /// Single possible closure → emit direct call (no dispatch).
    direct_call,

    /// Small set (2–SWITCH_THRESHOLD) → emit switch dispatch.
    switch_dispatch,

    /// Large set → fall back to DynClosure dispatch.
    dyn_closure_dispatch,

    /// Closure is only ever called (never stored) → contify to jump.
    contified,
};

/// Threshold for switch vs DynClosure dispatch.
pub const SWITCH_THRESHOLD: usize = 8;

/// Determine specialization from lambda set size.
///
/// GAP-P2R-02 — a `top` (unknown) set must fall back to full dynamic dispatch:
/// its callee set is not a finite enumeration, so neither the direct-call
/// singleton optimization nor the bounded switch is sound. `isSingleton`/
/// `isEmpty` already account for `top`, but a top set with an enumerable
/// subset of size 2..SWITCH_THRESHOLD would otherwise be mis-classified as a
/// (bounded) `switch_dispatch` — so check `top` explicitly first.
pub fn specializationForLambdaSet(set: LambdaSet, is_contifiable: bool) SpecializationDecision {
    if (is_contifiable) return .contified;
    if (set.top) return .dyn_closure_dispatch;
    if (set.isEmpty()) return .unreachable_call;
    if (set.isSingleton()) return .direct_call;
    if (set.size() <= SWITCH_THRESHOLD) return .switch_dispatch;
    return .dyn_closure_dispatch;
}

// ============================================================
// Section 10: Borrow Legality (Research Plan §4.7)
// ============================================================

/// Verdict on whether a borrowed reference is legal.
pub const BorrowVerdict = union(enum) {
    legal: BorrowLegalInfo,
    illegal: BorrowIllegalInfo,
};

pub const BorrowLegalInfo = struct {
    reason: BorrowLegalReason,
};

pub const BorrowIllegalInfo = struct {
    reason: BorrowIllegalReason,
    /// The escape path that caused illegality (for diagnostics).
    escape_path: ?EscapePath,
};

pub const BorrowLegalReason = enum {
    /// Borrowed capture in immediate-call closure.
    immediate_call,
    /// Borrowed value used only within creating block.
    block_local_closure,
    /// Passed to callee with safe summary.
    known_safe_callee,
    /// Value is loop-invariant (defined before loop, not modified).
    loop_invariant,
};

pub const BorrowIllegalReason = enum {
    /// Borrowed value returned from function.
    returned_from_function,
    /// Borrowed value stored in escaping container.
    stored_in_escaping_container,
    /// Borrowed value passed to callee with no safe summary.
    passed_to_unknown_callee,
    /// Borrowed value crosses loop boundary.
    crosses_loop_boundary,
    /// Borrowed value crosses merge where source was moved.
    crosses_merge_with_moved_source,
};

/// Path through which a value escapes (for diagnostic messages).
pub const EscapePath = struct {
    /// Sequence of instructions forming the escape path.
    steps: []const EscapeStep,
};

pub const EscapeStep = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    instr_index: u32,
    kind: EscapeStepKind,
};

pub const EscapeStepKind = enum {
    assigned_to,
    passed_as_argument,
    stored_in_field,
    returned,
    captured_by_closure,
    merged_at_phi,
};

// ============================================================
// Section 11: ARC Operations (Research Plan §8.4)
// ============================================================

/// Describes an ARC operation to be inserted during codegen.
pub const ArcOperation = struct {
    kind: ArcOpKind,
    value: ir.LocalId,
    insertion_point: InsertionPoint,
    reason: ArcReason,
};

pub const ArcOpKind = enum {
    /// Increment reference count.
    retain,
    /// Decrement reference count (and free if zero).
    release,
    /// Perceus: if RC=1, make memory available for reuse; else release.
    reset,
    /// Perceus: if reuse token available, reuse; else fresh alloc.
    reuse_alloc,
    /// Ownership transfer, no RC change.
    move_transfer,
    /// unique → shared conversion, inserts retain.
    share,
};

pub const ArcReason = enum {
    /// Value flows to a new shared binding.
    shared_binding,
    /// Value is captured by a closure.
    closure_capture,
    /// Value goes out of scope.
    scope_exit,
    /// Value is returned from function.
    function_return,
    /// Value is passed as owned argument.
    call_argument,
    /// Perceus reuse at pattern match site.
    perceus_reuse,
    /// Perceus drop specialization.
    perceus_drop,
    /// Loop-hoisted operation.
    loop_hoist,
};

// ============================================================
// Section 12: Perceus Reuse/Drop (Research Plan §7)
// ============================================================

/// A reset operation at a pattern match deconstruction site.
pub const ResetOp = struct {
    /// Reuse token destination.
    dest: ir.LocalId,
    /// Value being deconstructed.
    source: ir.LocalId,
    /// Type being deconstructed (for size/layout info).
    source_type: types_mod.TypeId,
};

/// A reuse allocation operation.
pub const ReuseAllocOp = struct {
    /// Allocated value destination.
    dest: ir.LocalId,
    /// Reuse token from a prior Reset (null → fresh allocation).
    token: ?ir.LocalId,
    /// Canonical insertion point for reuse-aware constructor lowering.
    insertion_point: InsertionPoint,
    /// Constructor tag for tagged unions.
    constructor_tag: u32,
    /// Type being constructed.
    dest_type: types_mod.TypeId,
};

/// A reuse pair linking a deconstruction to a construction.
pub const ReusePair = struct {
    /// The match/deconstruction site.
    match_site: MatchSiteId,
    /// The allocation site that can reuse.
    alloc_site: AllocSiteId,
    /// The reset operation to insert.
    reset: ResetOp,
    /// The reuse operation to insert.
    reuse: ReuseAllocOp,
    /// Whether the reuse is static (unique → guaranteed) or
    /// dynamic (shared → RC=1 runtime check).
    kind: ReuseKind,
};

pub const ReuseKind = enum {
    /// Unique value: guaranteed in-place reuse at compile time.
    static_reuse,
    /// Shared value: runtime RC=1 check for reuse.
    dynamic_reuse,
};

pub const FieldDrop = struct {
    field_name: []const u8,
    field_index: u32,
    needs_recursive_drop: bool,
    local: ?ir.LocalId = null,
    /// `.deep` (default) emits a `releaseAny` that walks the value's
    /// indirect-storage Arc'd fields and decrements every child's
    /// refcount. `.shallow` emits `freeAny` and does no children
    /// walk — used by the destructive-optional-dispatch path where
    /// every indirect-storage child of the scrutinee was already
    /// extracted-and-consumed (its ownership transferred to a
    /// callee), so the parent must only reclaim its own allocation
    /// without dereferencing the now-freed child pointers.
    kind: Kind = .deep,

    pub const Kind = enum { deep, shallow };
};

pub const DropSpecialization = struct {
    match_site: MatchSiteId,
    constructor_tag: u32,
    field_drops: []const FieldDrop,
    function: ir.FunctionId,
    insertion_point: InsertionPoint,
};

// ============================================================
// Section 13: Allocation Site Summary (Research Plan §8.2)
// ============================================================

/// Complete summary for a single allocation site.
pub const AllocSiteSummary = struct {
    site_id: AllocSiteId,
    type_id: types_mod.TypeId,
    escape: EscapeState,
    region: RegionId,
    multiplicity: Multiplicity,
    storage_mode: StorageMode,
    strategy: AllocationStrategy,
    field_escape: ?FieldEscapeMap,
    reuse_token: ?ir.LocalId,

    pub fn init(site_id: AllocSiteId, type_id: types_mod.TypeId) AllocSiteSummary {
        return .{
            .site_id = site_id,
            .type_id = type_id,
            .escape = .bottom,
            .region = .function_frame,
            .multiplicity = .zero,
            .storage_mode = .attop,
            .strategy = .eliminated,
            .field_escape = null,
            .reuse_token = null,
        };
    }
};

// ============================================================
// Section 14: Closure Environment Tiers (Research Plan §5.2)
// ============================================================

/// Closure environment representation tier, selected by escape analysis.
pub const ClosureEnvTier = enum {
    /// Tier 0: Lambda Lifting. Non-capturing def becomes top-level function.
    /// Captures passed as extra parameters at call sites.
    lambda_lifted,

    /// Tier 1: Immediate Invocation. No environment object.
    /// Captures forwarded directly as arguments to lifted function.
    immediate_invocation,

    /// Tier 2: Block-Local. Flat env struct on the stack.
    /// Captures stored as fields. Deallocated at block exit.
    block_local,

    /// Tier 3: Function-Local. Flat env struct on function's stack frame.
    /// Same as Tier 2 but lifetime extends to function return.
    function_local,

    /// Tier 4: Escaping. Heap-allocated flat env with ARC.
    /// Wrapped in DynClosure for generic callable interface.
    escaping,
};

/// Identity of a closure call site, keyed by the STABLE local that holds the
/// callee closure within its function — NOT by a positional `(block,
/// instr_index)` coordinate.
///
/// audit findings escape--03 / zirb-1--01: the previous positional key was
/// produced by the lambda-set analyzer with a broken nested-stream encoding
/// (`outer_index + body_offset`) and consumed by the ZIR builder using only
/// the TOP-LEVEL block index (`current_instr_index` is never updated during
/// nested-stream emission). The two could not agree: a nested `call_closure`
/// either missed its record entirely or collided with an unrelated call's,
/// binding the call to the WRONG target function. Worse, the positional key
/// also went stale across the count-mutating ARC passes that run between
/// lambda-set analysis and ZIR emission (the same arc-param--01 staleness
/// class), so even a correctly-encoded path would not survive to emission.
///
/// A closure call's specialization depends only on the lambda set of the
/// callee local, which the analyzer keys by `(function, local)` — the same
/// `ValueKey` the per-binding consumer (`getLambdaSet`) already uses. Keying
/// the call-site map by that identity makes producer and consumer read the
/// SAME field of the SAME instruction, so they cannot disagree, and the key
/// is collision-free (distinct callees in distinct branches → distinct keys;
/// the same callee called twice correctly shares one decision) and immune to
/// instruction-position shifts. `callee` is the `call_closure.callee` local
/// (a `LocalId`, monotonically unique within its function and preserved
/// across every IR-mutating pass).
pub const CallSiteKey = struct {
    function: ir.FunctionId,
    callee: ir.LocalId,
};

pub const CallSiteSpecialization = struct {
    decision: SpecializationDecision,
    lambda_set: LambdaSet,

    pub fn empty() CallSiteSpecialization {
        return .{
            .decision = .dyn_closure_dispatch,
            .lambda_set = LambdaSet.empty(),
        };
    }
};

/// Map escape state to closure environment tier.
pub fn escapeToClosureTier(escape: EscapeState, has_captures: bool) ClosureEnvTier {
    if (!has_captures) return .lambda_lifted;
    return switch (escape) {
        .bottom, .no_escape => .immediate_invocation,
        .block_local => .block_local,
        .function_local => .function_local,
        .arg_escape_safe => .function_local,
        .global_escape => .escaping,
    };
}

// ============================================================
// Section 15: Analysis Context (Research Plan §8.1)
// ============================================================

/// Central analysis context holding all analysis results.
/// Populated incrementally by the analysis pipeline phases.
pub const AnalysisContext = struct {
    allocator: std.mem.Allocator,

    /// Per-SSA-value escape state (indexed by function+local).
    escape_states: std.AutoHashMap(ValueKey, EscapeState),

    /// Per-SSA-value region assignment.
    region_assignments: std.AutoHashMap(ValueKey, RegionId),

    /// Per-SSA-value ownership state (third dimension of the product lattice).
    ownership_states: std.AutoHashMap(ValueKey, OwnershipState),

    /// Per-allocation-site summary.
    alloc_summaries: std.AutoHashMap(AllocSiteId, AllocSiteSummary),

    /// Reverse map: ValueKey of an allocating instruction → its AllocSiteId.
    /// Populated by `GeneralizedEscapeAnalyzer`. Lets ARC and other downstream
    /// passes resolve "what alloc site does this value come from?" without
    /// re-walking the IR.
    alloc_site_for_value: std.AutoHashMap(ValueKey, AllocSiteId),

    /// Per-function interprocedural summary. Values stored here are deep-owned
    /// clones; insert through `putFunctionSummaryClone`.
    function_summaries: std.AutoHashMap(ir.FunctionId, FunctionSummary),

    /// Lambda sets per function-typed binding.
    lambda_sets: std.AutoHashMap(ValueKey, LambdaSet),

    /// Virtual object states for partial escape analysis (per block).
    virtual_objects: std.AutoHashMap(BlockVirtualKey, VirtualObject),

    /// Field escape maps for composite types.
    field_escapes: std.AutoHashMap(ValueKey, FieldEscapeMap),

    /// Borrow legality verdicts.
    borrow_verdicts: std.AutoHashMap(BorrowSiteId, BorrowVerdict),

    /// Reuse pairs discovered by Perceus.
    reuse_pairs: std.ArrayList(ReusePair),

    /// Drop specializations discovered by Perceus.
    drop_specializations: std.ArrayList(DropSpecialization),

    /// Allocation strategy decisions.
    alloc_strategies: std.AutoHashMap(AllocSiteId, AllocationStrategy),

    /// ARC operation placement.
    arc_ops: std.ArrayList(ArcOperation),

    /// Outlives constraints (for diagnostics and region solving).
    outlives_constraints: std.ArrayList(OutlivesConstraint),

    /// Closure environment tier decisions.
    closure_tiers: std.AutoHashMap(ir.FunctionId, ClosureEnvTier),

    /// Per-call-site specialization decisions.
    call_specializations: std.AutoHashMap(CallSiteKey, CallSiteSpecialization),

    /// Functions whose `optional_dispatch` struct branch destructively
    /// reads every indirect-storage child of the scrutinee — every
    /// recursive child is extracted and immediately consumed by a call
    /// (transferring ownership), so the parent never observes those
    /// child pointers again. Maps function id → scrutinee param index.
    /// The ZIR backend uses this map to:
    ///   * suppress the `retainAnyOpt` at indirect-storage `field_get`
    ///     reads of the scrutinee — there is no second owner to balance
    ///     against, the inner consumer takes the only handle;
    ///   * emit a shallow `freeAny` at the optional-dispatch drop
    ///     point instead of the deep `releaseAny`, because walking the
    ///     children would dereference the now-freed pointers.
    /// `Binarytrees.check` is the canonical case: t.left and t.right are
    /// both extracted-and-passed; the extracted Trees are owned by the
    /// recursive callee, so check itself only reclaims its own
    /// allocation.
    destructive_optional_dispatch: std.AutoHashMap(ir.FunctionId, u32),

    pub fn init(allocator: std.mem.Allocator) AnalysisContext {
        return .{
            .allocator = allocator,
            .escape_states = std.AutoHashMap(ValueKey, EscapeState).init(allocator),
            .region_assignments = std.AutoHashMap(ValueKey, RegionId).init(allocator),
            .ownership_states = std.AutoHashMap(ValueKey, OwnershipState).init(allocator),
            .alloc_summaries = std.AutoHashMap(AllocSiteId, AllocSiteSummary).init(allocator),
            .alloc_site_for_value = std.AutoHashMap(ValueKey, AllocSiteId).init(allocator),
            .function_summaries = std.AutoHashMap(ir.FunctionId, FunctionSummary).init(allocator),
            .lambda_sets = std.AutoHashMap(ValueKey, LambdaSet).init(allocator),
            .virtual_objects = std.AutoHashMap(BlockVirtualKey, VirtualObject).init(allocator),
            .field_escapes = std.AutoHashMap(ValueKey, FieldEscapeMap).init(allocator),
            .borrow_verdicts = std.AutoHashMap(BorrowSiteId, BorrowVerdict).init(allocator),
            .reuse_pairs = .empty,
            .drop_specializations = .empty,
            .alloc_strategies = std.AutoHashMap(AllocSiteId, AllocationStrategy).init(allocator),
            .arc_ops = .empty,
            .outlives_constraints = .empty,
            .closure_tiers = std.AutoHashMap(ir.FunctionId, ClosureEnvTier).init(allocator),
            .call_specializations = std.AutoHashMap(CallSiteKey, CallSiteSpecialization).init(allocator),
            .destructive_optional_dispatch = std.AutoHashMap(ir.FunctionId, u32).init(allocator),
        };
    }

    pub fn deinit(self: *AnalysisContext) void {
        self.escape_states.deinit();
        self.region_assignments.deinit();
        self.ownership_states.deinit();
        self.alloc_summaries.deinit();
        self.alloc_site_for_value.deinit();

        var summary_iter = self.function_summaries.iterator();
        while (summary_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.function_summaries.deinit();

        // Clean up lambda set member slices (allocated by toLambdaSet).
        {
            var ls_iter = self.lambda_sets.iterator();
            while (ls_iter.next()) |entry| {
                const ls = entry.value_ptr.*;
                if (ls.members.len > 0) {
                    // Only free if not a static/comptime slice.
                    // Dynamically allocated slices from toLambdaSet use self.allocator.
                    self.allocator.free(ls.members);
                }
            }
        }
        self.lambda_sets.deinit();

        // Clean up virtual objects (they own memory).
        var vo_iter = self.virtual_objects.iterator();
        while (vo_iter.next()) |entry| {
            var vo = entry.value_ptr.*;
            vo.deinit();
        }
        self.virtual_objects.deinit();

        // Clean up field escape maps.
        var fe_iter = self.field_escapes.iterator();
        while (fe_iter.next()) |entry| {
            var fe = entry.value_ptr.*;
            fe.deinit();
        }
        self.field_escapes.deinit();

        self.borrow_verdicts.deinit();
        for (self.reuse_pairs.items) |pair| {
            self.allocator.free(pair.reuse.insertion_point.path);
        }
        self.reuse_pairs.deinit(self.allocator);
        for (self.drop_specializations.items) |ds| {
            self.allocator.free(ds.field_drops);
            self.allocator.free(ds.insertion_point.path);
        }
        self.drop_specializations.deinit(self.allocator);
        self.alloc_strategies.deinit();
        for (self.arc_ops.items) |op| {
            self.allocator.free(op.insertion_point.path);
        }
        self.arc_ops.deinit(self.allocator);
        self.outlives_constraints.deinit(self.allocator);
        self.closure_tiers.deinit();

        {
            var cs_iter = self.call_specializations.iterator();
            while (cs_iter.next()) |entry| {
                const spec = entry.value_ptr.*;
                if (spec.lambda_set.members.len > 0) {
                    self.allocator.free(spec.lambda_set.members);
                }
            }
        }
        self.call_specializations.deinit();
        self.destructive_optional_dispatch.deinit();
    }

    // --------------------------------------------------------
    // Query helpers
    // --------------------------------------------------------

    /// Get the escape state for a value, defaulting to bottom.
    pub fn getEscape(self: *const AnalysisContext, key: ValueKey) EscapeState {
        return self.escape_states.get(key) orelse .bottom;
    }

    /// Get the region for a value, defaulting to function_frame.
    pub fn getRegion(self: *const AnalysisContext, key: ValueKey) RegionId {
        return self.region_assignments.get(key) orelse .function_frame;
    }

    /// Get the ownership state for a value, defaulting to shared.
    pub fn getOwnership(self: *const AnalysisContext, key: ValueKey) OwnershipState {
        return self.ownership_states.get(key) orelse .shared;
    }

    /// Get the allocation strategy for an alloc site.
    pub fn getAllocStrategy(self: *const AnalysisContext, site: AllocSiteId) AllocationStrategy {
        return self.alloc_strategies.get(site) orelse .heap_arc;
    }

    /// Get function summary, or null if not yet computed.
    pub fn getFunctionSummary(self: *const AnalysisContext, func: ir.FunctionId) ?FunctionSummary {
        return self.function_summaries.get(func);
    }

    /// Get closure environment tier for a function.
    pub fn getClosureTier(self: *const AnalysisContext, func: ir.FunctionId) ClosureEnvTier {
        return self.closure_tiers.get(func) orelse .escaping;
    }

    /// Get lambda set for a value.
    pub fn getLambdaSet(self: *const AnalysisContext, key: ValueKey) ?LambdaSet {
        return self.lambda_sets.get(key);
    }

    pub fn getCallSiteSpecialization(self: *const AnalysisContext, key: CallSiteKey) ?CallSiteSpecialization {
        return self.call_specializations.get(key);
    }

    /// Get borrow verdict for a borrow site.
    pub fn getBorrowVerdict(self: *const AnalysisContext, site: BorrowSiteId) ?BorrowVerdict {
        return self.borrow_verdicts.get(site);
    }

    // --------------------------------------------------------
    // Mutation helpers
    // --------------------------------------------------------

    /// Set or join the escape state for a value. Returns true if changed.
    pub fn joinEscape(self: *AnalysisContext, key: ValueKey, state: EscapeState) !bool {
        const result = try self.escape_states.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = state;
            return true;
        }
        const joined = EscapeState.join(result.value_ptr.*, state);
        if (joined != result.value_ptr.*) {
            result.value_ptr.* = joined;
            return true;
        }
        return false;
    }

    /// Set the ownership state for a value.
    pub fn setOwnership(self: *AnalysisContext, key: ValueKey, ownership: OwnershipState) !void {
        try self.ownership_states.put(key, ownership);
    }

    /// Record an allocation site summary.
    pub fn putAllocSummary(self: *AnalysisContext, summary: AllocSiteSummary) !void {
        try self.alloc_summaries.put(summary.site_id, summary);
    }

    /// Record a function summary.
    pub fn putFunctionSummary(self: *AnalysisContext, func: ir.FunctionId, summary: FunctionSummary) !void {
        try self.putFunctionSummaryClone(func, summary);
    }

    /// Record a deep-owned clone of a function summary.
    pub fn putFunctionSummaryClone(self: *AnalysisContext, func: ir.FunctionId, summary: FunctionSummary) !void {
        var owned_summary = try summary.clone(self.allocator);
        errdefer owned_summary.deinit(self.allocator);

        const entry = try self.function_summaries.getOrPut(func);
        if (entry.found_existing) {
            entry.value_ptr.deinit(self.allocator);
        }
        entry.value_ptr.* = owned_summary;
    }

    /// Record a borrow verdict.
    pub fn putBorrowVerdict(self: *AnalysisContext, site: BorrowSiteId, verdict: BorrowVerdict) !void {
        try self.borrow_verdicts.put(site, verdict);
    }

    /// Add an ARC operation.
    pub fn addArcOp(self: *AnalysisContext, op: ArcOperation) !void {
        try self.arc_ops.append(self.allocator, op);
    }

    pub fn addReusePair(self: *AnalysisContext, pair: ReusePair) !void {
        try self.reuse_pairs.append(self.allocator, pair);
    }

    pub fn addDropSpecialization(self: *AnalysisContext, spec: DropSpecialization) !void {
        try self.drop_specializations.append(self.allocator, spec);
    }

    /// Add an outlives constraint.
    pub fn addOutlivesConstraint(self: *AnalysisContext, constraint: OutlivesConstraint) !void {
        try self.outlives_constraints.append(self.allocator, constraint);
    }
};

/// Key for per-value lookups: (function, local) pair.
/// Necessary because LocalIds are scoped per function.
pub const ValueKey = struct {
    function: ir.FunctionId,
    local: ir.LocalId,
};

// ============================================================
// Section 16: Tests
// ============================================================

test "EscapeState join is commutative" {
    const cases = [_]EscapeState{ .bottom, .no_escape, .block_local, .function_local, .arg_escape_safe, .global_escape };
    for (cases) |a| {
        for (cases) |b| {
            try std.testing.expectEqual(EscapeState.join(a, b), EscapeState.join(b, a));
        }
    }
}

test "EscapeState join is associative" {
    const cases = [_]EscapeState{ .bottom, .no_escape, .block_local, .function_local, .arg_escape_safe, .global_escape };
    for (cases) |a| {
        for (cases) |b| {
            for (cases) |c| {
                try std.testing.expectEqual(
                    EscapeState.join(EscapeState.join(a, b), c),
                    EscapeState.join(a, EscapeState.join(b, c)),
                );
            }
        }
    }
}

test "EscapeState join with bottom is identity" {
    const cases = [_]EscapeState{ .bottom, .no_escape, .block_local, .function_local, .arg_escape_safe, .global_escape };
    for (cases) |a| {
        try std.testing.expectEqual(a, EscapeState.join(a, .bottom));
        try std.testing.expectEqual(a, EscapeState.join(.bottom, a));
    }
}

test "EscapeState join with global_escape is absorbing" {
    const cases = [_]EscapeState{ .bottom, .no_escape, .block_local, .function_local, .arg_escape_safe, .global_escape };
    for (cases) |a| {
        try std.testing.expectEqual(EscapeState.global_escape, EscapeState.join(a, .global_escape));
    }
}

test "EscapeState arg_escape_safe join function_local is function_local" {
    try std.testing.expectEqual(EscapeState.function_local, EscapeState.join(.arg_escape_safe, .function_local));
    try std.testing.expectEqual(EscapeState.function_local, EscapeState.join(.function_local, .arg_escape_safe));
}

test "EscapeState stack eligibility" {
    try std.testing.expect(EscapeState.bottom.isStackEligible());
    try std.testing.expect(EscapeState.no_escape.isStackEligible());
    try std.testing.expect(EscapeState.block_local.isStackEligible());
    try std.testing.expect(EscapeState.function_local.isStackEligible());
    try std.testing.expect(!EscapeState.arg_escape_safe.isStackEligible());
    try std.testing.expect(!EscapeState.global_escape.isStackEligible());
}

test "ownership merge rules" {
    // Same ownership merges to itself.
    try std.testing.expectEqual(OwnershipMergeResult{ .ok = .shared }, mergeOwnership(.shared, .shared));
    try std.testing.expectEqual(OwnershipMergeResult{ .ok = .unique }, mergeOwnership(.unique, .unique));
    try std.testing.expectEqual(OwnershipMergeResult{ .ok = .borrowed }, mergeOwnership(.borrowed, .borrowed));

    // unique ⊔ shared = shared
    try std.testing.expectEqual(OwnershipMergeResult{ .ok = .shared }, mergeOwnership(.unique, .shared));
    try std.testing.expectEqual(OwnershipMergeResult{ .ok = .shared }, mergeOwnership(.shared, .unique));

    // borrowed ⊔ owned = error
    try std.testing.expectEqual(
        OwnershipMergeResult{ .illegal = .borrowed_promoted_to_owned },
        mergeOwnership(.borrowed, .shared),
    );
    try std.testing.expectEqual(
        OwnershipMergeResult{ .illegal = .borrowed_promoted_to_owned },
        mergeOwnership(.borrowed, .unique),
    );
}

test "ownership conversion legality" {
    // Legal conversions.
    try std.testing.expect(isOwnershipConversionLegal(.unique, .shared));
    try std.testing.expect(isOwnershipConversionLegal(.unique, .borrowed));
    try std.testing.expect(isOwnershipConversionLegal(.shared, .borrowed));

    // Illegal conversions.
    try std.testing.expect(!isOwnershipConversionLegal(.borrowed, .shared));
    try std.testing.expect(!isOwnershipConversionLegal(.borrowed, .unique));
    try std.testing.expect(!isOwnershipConversionLegal(.shared, .unique));
}

test "escape to allocation strategy mapping" {
    try std.testing.expectEqual(AllocationStrategy.eliminated, escapeToStrategy(.bottom, .zero));
    try std.testing.expectEqual(AllocationStrategy.scalar_replaced, escapeToStrategy(.no_escape, .one));
    try std.testing.expectEqual(AllocationStrategy.stack_block, escapeToStrategy(.no_escape, .many));
    try std.testing.expectEqual(AllocationStrategy.stack_block, escapeToStrategy(.block_local, .one));
    try std.testing.expectEqual(AllocationStrategy.stack_function, escapeToStrategy(.function_local, .one));
    try std.testing.expectEqual(AllocationStrategy.caller_region, escapeToStrategy(.arg_escape_safe, .one));
    try std.testing.expectEqual(AllocationStrategy.heap_arc, escapeToStrategy(.global_escape, .one));
}

test "closure environment tier mapping" {
    // No captures → lambda lifted.
    try std.testing.expectEqual(ClosureEnvTier.lambda_lifted, escapeToClosureTier(.no_escape, false));
    try std.testing.expectEqual(ClosureEnvTier.lambda_lifted, escapeToClosureTier(.global_escape, false));

    // With captures.
    try std.testing.expectEqual(ClosureEnvTier.immediate_invocation, escapeToClosureTier(.no_escape, true));
    try std.testing.expectEqual(ClosureEnvTier.block_local, escapeToClosureTier(.block_local, true));
    try std.testing.expectEqual(ClosureEnvTier.function_local, escapeToClosureTier(.function_local, true));
    try std.testing.expectEqual(ClosureEnvTier.escaping, escapeToClosureTier(.global_escape, true));
}

test "lambda set specialization decisions" {
    const empty = LambdaSet.empty();
    try std.testing.expectEqual(SpecializationDecision.unreachable_call, specializationForLambdaSet(empty, false));

    // Contifiable always wins.
    try std.testing.expectEqual(SpecializationDecision.contified, specializationForLambdaSet(empty, true));
}

test "GAP-P2R-02: a top (unknown) lambda set is never a singleton/empty and falls back to dynamic dispatch" {
    // A top set with NO enumerable members must NOT be classified empty
    // (`unreachable_call`) — it stands for an unknown, possibly non-empty
    // collection — and must fall back to dynamic dispatch.
    const top_empty = LambdaSet{ .members = &.{}, .top = true };
    try std.testing.expect(!top_empty.isEmpty());
    try std.testing.expect(!top_empty.isSingleton());
    try std.testing.expectEqual(SpecializationDecision.dyn_closure_dispatch, specializationForLambdaSet(top_empty, false));

    // A top set with exactly ONE enumerable member must NOT be mistaken for a
    // singleton (`direct_call`): the unknown residual means the real callee
    // set is unbounded. This is the precise spurious-singleton hazard the
    // top element exists to prevent.
    const top_one = LambdaSet{ .members = &.{7}, .top = true };
    try std.testing.expect(!top_one.isSingleton());
    try std.testing.expectEqual(SpecializationDecision.dyn_closure_dispatch, specializationForLambdaSet(top_one, false));

    // A top set with a small enumerable subset (2..SWITCH_THRESHOLD) must NOT
    // be classified as a bounded `switch_dispatch` either — `top` is checked
    // before the size-based arms.
    const top_two = LambdaSet{ .members = &.{ 7, 9 }, .top = true };
    try std.testing.expectEqual(SpecializationDecision.dyn_closure_dispatch, specializationForLambdaSet(top_two, false));

    // Contifiable still wins even over top (a closure proven called-only is
    // contified regardless of provenance uncertainty).
    try std.testing.expectEqual(SpecializationDecision.contified, specializationForLambdaSet(top_empty, true));

    // A genuine singleton (NOT top) is still a direct call — no pessimization.
    const real_one = LambdaSet{ .members = &.{7}, .top = false };
    try std.testing.expect(real_one.isSingleton());
    try std.testing.expectEqual(SpecializationDecision.direct_call, specializationForLambdaSet(real_one, false));
}

test "AnalysisContext clones function summaries and owns slices" {
    const allocator = std.testing.allocator;

    var source = try FunctionSummary.conservative(2, allocator);
    errdefer source.deinit(allocator);

    source.return_summary = .{
        .param_sources = try allocator.dupe(u32, &.{ 0, 1 }),
        .fresh_alloc = false,
    };

    const source_param_summaries = @constCast(source.param_summaries);
    source_param_summaries[0] = ParamSummary.safe();
    source_param_summaries[1] = ParamSummary.conservative();

    const source_lambda_sets = @constCast(source.param_lambda_sets);
    source_lambda_sets[1] = .{
        .members = try allocator.dupe(ir.FunctionId, &.{ 42, 99 }),
    };

    var context = AnalysisContext.init(allocator);
    defer context.deinit();
    try context.putFunctionSummaryClone(7, source);

    source_param_summaries[0].read_only = false;
    @constCast(source.return_summary.param_sources)[0] = 1;
    @constCast(source_lambda_sets[1].members)[0] = 123;
    source.deinit(allocator);

    const stored = context.getFunctionSummary(7).?;
    try std.testing.expect(stored.param_summaries[0].read_only);
    try std.testing.expectEqual(@as(u32, 0), stored.return_summary.param_sources[0]);
    try std.testing.expectEqual(@as(ir.FunctionId, 42), stored.param_lambda_sets[1].members[0]);
}

test "AnalysisContext deinitializes replaced function summary" {
    const allocator = std.testing.allocator;

    var first = try FunctionSummary.conservative(1, allocator);
    defer first.deinit(allocator);
    var second = try FunctionSummary.conservative(2, allocator);
    defer second.deinit(allocator);

    var context = AnalysisContext.init(allocator);
    defer context.deinit();

    try context.putFunctionSummaryClone(3, first);
    try context.putFunctionSummaryClone(3, second);

    const stored = context.getFunctionSummary(3).?;
    try std.testing.expectEqual(@as(usize, 2), stored.param_summaries.len);
}

test "FieldEscapeMap join" {
    const alloc = std.testing.allocator;

    var map_a = try FieldEscapeMap.init(alloc, 3);
    defer map_a.deinit();
    var map_b = try FieldEscapeMap.init(alloc, 3);
    defer map_b.deinit();

    map_a.updateField(0, .no_escape);
    map_a.updateField(1, .block_local);
    map_a.updateField(2, .function_local);

    map_b.updateField(0, .block_local);
    map_b.updateField(1, .no_escape);
    map_b.updateField(2, .global_escape);

    map_a.joinWith(&map_b);

    try std.testing.expectEqual(EscapeState.block_local, map_a.field_states[0]);
    try std.testing.expectEqual(EscapeState.block_local, map_a.field_states[1]);
    try std.testing.expectEqual(EscapeState.global_escape, map_a.field_states[2]);
    try std.testing.expectEqual(EscapeState.global_escape, map_a.aggregate_state);
}

test "ParamSummary join" {
    const safe = ParamSummary.safe();
    const conservative = ParamSummary.conservative();

    // safe ⊔ safe = safe
    const both_safe = ParamSummary.join(safe, safe);
    try std.testing.expect(both_safe.read_only);
    try std.testing.expect(!both_safe.escapes_to_heap);

    // safe ⊔ conservative = conservative (effectively)
    const mixed = ParamSummary.join(safe, conservative);
    try std.testing.expect(!mixed.read_only);
    try std.testing.expect(mixed.escapes_to_heap);
    try std.testing.expect(mixed.returned);
}
