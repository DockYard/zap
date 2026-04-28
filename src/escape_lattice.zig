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

/// Identifier for an insertion point in the IR for ARC operations.
pub const InsertionPoint = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    /// Index within the block's instruction list.
    instr_index: u32,
    /// Whether to insert before or after the instruction.
    position: enum { before, after },
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
        @memset(params, ParamSummary.conservative());
        const lambda_sets = try allocator.alloc(LambdaSet, num_params);
        @memset(lambda_sets, LambdaSet.empty());
        return .{
            .param_summaries = params,
            .return_summary = ReturnSummary.unknown(),
            .may_diverge = true,
            .param_lambda_sets = lambda_sets,
        };
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
};

// ============================================================
// Section 9: Lambda Sets (Research Plan §5.1, §6.4)
// ============================================================

/// A lambda set enumerates every closure that could flow to a
/// call site. Used for defunctionalization/specialization.
pub const LambdaSet = struct {
    /// Function IDs of closures in this set.
    members: []const ir.FunctionId,

    pub fn empty() LambdaSet {
        return .{ .members = &.{} };
    }

    pub fn singleton(func: ir.FunctionId) LambdaSet {
        // Note: Caller must ensure the slice lives long enough.
        return .{ .members = &.{func} };
    }

    pub fn size(self: LambdaSet) usize {
        return self.members.len;
    }

    pub fn isSingleton(self: LambdaSet) bool {
        return self.members.len == 1;
    }

    pub fn isEmpty(self: LambdaSet) bool {
        return self.members.len == 0;
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
pub fn specializationForLambdaSet(set: LambdaSet, is_contifiable: bool) SpecializationDecision {
    if (is_contifiable) return .contified;
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

pub const CallSiteKey = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    instr_index: u32,
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

    /// Per-function interprocedural summary.
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
        };
    }

    pub fn deinit(self: *AnalysisContext) void {
        self.escape_states.deinit();
        self.region_assignments.deinit();
        self.ownership_states.deinit();
        self.alloc_summaries.deinit();
        self.alloc_site_for_value.deinit();
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
        self.reuse_pairs.deinit(self.allocator);
        for (self.drop_specializations.items) |ds| {
            self.allocator.free(ds.field_drops);
        }
        self.drop_specializations.deinit(self.allocator);
        self.alloc_strategies.deinit();
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
        try self.function_summaries.put(func, summary);
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
