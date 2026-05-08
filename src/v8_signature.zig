const std = @import("std");
const ir = @import("ir.zig");

// ============================================================
// Per-function uniqueness signatures (Phase 1.1 of the escape-
// analysis plan in `research2.md`).
//
// Pipeline placement:
//
//     ... → arc_liveness                      (last-use side table)
//          → v8_fixpoint                      (THIS module's signatures
//                                              are computed here over an
//                                              SCC-iterated call graph)
//             → arc_param_convention          (consumer of FunctionSig
//                                              for the borrowed-source
//                                              veto lift — Phase 1.3
//                                              integration deferred,
//                                              see soundness notes)
//                → arc_ownership pipeline (V8 rewrite + verifier)
//                   → arc_drop_insertion
//
// Soundness notes for Phase 1.3 (deferred)
// ----------------------------------------
//
// Naively lifting the borrowed-source veto in `siteConsumesSlot`
// when `Sig(caller, slot) ∈ {CU, PU}` is *unsound* unless the entire
// chain of conventions can be promoted from `.borrowed` to `.owned`
// in lockstep. The runtime ABI mechanics are: a `.borrowed` slot in
// function F has its parent retain (`share_value`) before the call
// and release after; promoting only the *callee's* slot to `.owned`
// without also promoting F's slot leaves an extra `release` (the
// callee's scope-exit drop) without a matching `retain` — producing
// a use-after-free at the parent's post-call release.
//
// fannkuch-redux's `main_loop → advance_perm → rotate_loop` chain
// surfaces this: `count` is dual-used inside `main_loop` (the
// `advance_perm` call AND the recursive tail call), so `main_loop`'s
// retain-around-`advance_perm` cannot be elided. Promoting
// `rotate_loop`'s slot 1 alone produces the double-release bug
// described above.
//
// A sound Phase 1.3 must therefore include a global consistency
// pass: lift the veto optimistically, then audit the resulting
// chain; if any promotion's caller cannot also be promoted, demote
// the optimistic promotion. The `ProgramSignatures` table this
// module produces is the input to that future pass, but the audit
// itself is not yet implemented.
//
// Why this module exists:
//
// The current Boolean `unique_on_entry` lattice in `v8_interprocedural`
// is too coarse to capture the accumulator-recursion patterns at the
// heart of fannkuch-redux. Specifically, when a caller passes a
// uniquely-owned `pp` to `count_flips(pp, flips)` and `count_flips`
// recursively forwards `pp` through `reverse_range`, intraprocedural
// V8 cannot tell whether `count_flips` *preserves* uniqueness through
// the call (PU) or *consumes* it (CU). Both are required to lift the
// borrowed-source veto safely.
//
// The lattice `{CU, PU, AL, ⊤}` from research2 §1.1 captures these
// distinctions. For each parameter slot we infer:
//
//   - `consumes_uniquely` (CU): caller's uniqueness flows in, no live
//     alias remains after the call.
//   - `preserves_uniqueness` (PU): caller's uniqueness flows in AND
//     the same value (or its derivative through the return) is unique
//     on return.
//   - `aliases` (AL): the param escapes into an aggregate, closure,
//     global, or otherwise non-tracked location — uniqueness is lost.
//   - `top` (⊤): uniqueness can't be determined; conservative default.
//
// Plus a per-return-component witness `preserves_to_return_component`
// pointing back to the source parameter (if any) whose uniqueness
// the result inherits — needed for tuple returns like
// `count_flips(pp, flips) -> {VectorI64, i64}`.
//
// Ordering and join semantics
// ---------------------------
//
// The lattice has three non-⊥ elements:
//
//                         top
//                       /  |  \
//                     AL  PU  CU
//                       \ |  /
//                         ⊥   (initial)
//
// Two distinct non-⊥ elements join to `top` because they describe
// incompatible uses of the same parameter. The bottom (`⊥`) is the
// pre-analysis state — represented in `ParamSig.unobserved` — and
// joining `unobserved` with anything yields the other element.
//
// Monotonicity: signatures move only UPWARD (toward ⊤). The fixpoint
// iterates until no signature changes, at which point each parameter
// has its tightest lower bound that is still consistent with every
// observed flow.
//
// Soundness
// ---------
//
// The verifier (`arc_verifier.zig::runV8`) re-validates every
// emission of `*_owned_unchecked` against the post-fixpoint
// signatures. A buggy inference therefore surfaces as a compilation
// failure (verifier rejection), never a miscompilation.
//
// ============================================================

/// Four-element lattice plus an `unobserved` ⊥ marker.
///
/// `unobserved` is the pre-analysis state for a parameter slot whose
/// flows have not been seen yet (e.g. before the intraprocedural
/// pass touches the function body, or for parameter slots with no
/// uses in the body). Joining `unobserved` with any other element
/// yields that element.
///
/// `top` is the conservative ⊤ — uniqueness can't be proven. The
/// caller-side check (in `arc_param_convention.siteConsumesSlot`)
/// must NOT relax the borrowed-source veto on a `top` slot.
pub const UniquenessClass = enum(u8) {
    unobserved,
    consumes_uniquely,
    preserves_uniqueness,
    aliases,
    top,
};

/// Per-parameter-slot signature element.
///
/// `class` is the lattice element. `preserves_to_return_component`
/// is meaningful only when `class == .preserves_uniqueness` and
/// records which return-tuple component the parameter's uniqueness
/// flows through (or `null` if the function's return is a single
/// non-aggregate value or the parameter doesn't appear in any
/// returned aggregate).
pub const ParamSig = struct {
    class: UniquenessClass = .unobserved,
    /// For PU: which component of a tuple/struct return preserves
    /// this parameter's uniqueness. Currently used as informational
    /// metadata for caller-side analysis. `null` means "the entire
    /// return value preserves uniqueness" (single-result functions)
    /// OR "uniqueness is not preserved through the return."
    preserves_to_return_component: ?u8 = null,

    /// Initial signature for an as-yet-unobserved slot.
    pub fn initial() ParamSig {
        return .{ .class = .unobserved, .preserves_to_return_component = null };
    }

    /// Convenience: a "consumes uniquely" signature.
    pub fn consumesUniquely() ParamSig {
        return .{ .class = .consumes_uniquely, .preserves_to_return_component = null };
    }

    /// Convenience: a "preserves uniqueness" signature.
    pub fn preservesUniqueness(component: ?u8) ParamSig {
        return .{ .class = .preserves_uniqueness, .preserves_to_return_component = component };
    }

    /// Convenience: an "aliases" signature.
    pub fn aliasesOut() ParamSig {
        return .{ .class = .aliases, .preserves_to_return_component = null };
    }

    /// Convenience: ⊤ — unknown / conservative.
    pub fn unknown() ParamSig {
        return .{ .class = .top, .preserves_to_return_component = null };
    }
};

/// Whole-function signature.
///
/// `params[i]` describes parameter `i`'s flow through the body.
/// `return_components[k]` (when present) names the parameter index
/// whose uniqueness preserves through return-tuple component `k`,
/// or `null` if the return component is fresh / aliased / unknown.
///
/// The slices live for the lifetime of the surrounding
/// `ProgramSignatures`; callers must not free them independently.
pub const FunctionSig = struct {
    params: []ParamSig = &.{},
    return_components: []const ?u8 = &.{},
};

/// Whole-program signature table.
///
/// Maps each function id to its computed signature. Empty for
/// functions absent from the analysis (treated as ⊤ across the
/// board — the conservative default).
pub const ProgramSignatures = struct {
    /// Heap-allocated per-function signatures. Each `params` slice
    /// is owned by `arena`; the whole table is freed by `deinit`.
    by_function: std.AutoHashMapUnmanaged(ir.FunctionId, FunctionSig) = .empty,
    /// Backing arena for all `params` and `return_components` slices.
    /// Using a single arena keeps lifetime management trivial — the
    /// fixpoint allocates per-function and frees everything in one
    /// shot at `deinit`.
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ProgramSignatures {
        return .{
            .by_function = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ProgramSignatures, allocator: std.mem.Allocator) void {
        self.by_function.deinit(allocator);
        self.arena.deinit();
    }

    /// Look up the signature for `function_id`, returning a default
    /// "all top" signature when absent.
    pub fn forFunction(
        self: *const ProgramSignatures,
        function_id: ir.FunctionId,
    ) ?FunctionSig {
        return self.by_function.get(function_id);
    }

    /// Convenience: look up `parameter_index`'s class for `function_id`.
    /// Returns `.top` for absent functions or out-of-range indices —
    /// matches the conservative default.
    pub fn classOf(
        self: *const ProgramSignatures,
        function_id: ir.FunctionId,
        parameter_index: usize,
    ) UniquenessClass {
        const sig = self.by_function.get(function_id) orelse return .top;
        if (parameter_index >= sig.params.len) return .top;
        return sig.params[parameter_index].class;
    }

    /// Did the fixpoint prove `parameter_index` of `function_id` is
    /// either CU or PU? Either result lifts the borrowed-source veto
    /// in `arc_param_convention.siteConsumesSlot`.
    pub fn isCuOrPu(
        self: *const ProgramSignatures,
        function_id: ir.FunctionId,
        parameter_index: usize,
    ) bool {
        return switch (self.classOf(function_id, parameter_index)) {
            .consumes_uniquely, .preserves_uniqueness => true,
            else => false,
        };
    }
};

/// Monotone join over the four-element lattice (plus the ⊥
/// `unobserved` marker).
///
/// Rules:
///   - `unobserved` joined with `x` is `x` (⊥ ⊔ x = x).
///   - `top` joined with `x` is `top`.
///   - `x` joined with `x` is `x`.
///   - Distinct non-⊥, non-⊤ elements join to `top` (incompatible
///     observations of the same parameter — the only safe upper
///     bound is `top`).
///
/// `preserves_to_return_component` is preserved when both inputs
/// agree on PU and on the same component; otherwise it is dropped.
pub fn join(a: ParamSig, b: ParamSig) ParamSig {
    if (a.class == .unobserved) return b;
    if (b.class == .unobserved) return a;
    if (a.class == .top or b.class == .top) {
        return ParamSig.unknown();
    }
    if (a.class == b.class) {
        // Same class: keep, but only retain the component witness
        // when both inputs witnessed the same component.
        if (a.class == .preserves_uniqueness) {
            const same_component = blk: {
                if (a.preserves_to_return_component == null) {
                    break :blk b.preserves_to_return_component == null;
                }
                if (b.preserves_to_return_component == null) break :blk false;
                break :blk a.preserves_to_return_component.? == b.preserves_to_return_component.?;
            };
            return .{
                .class = .preserves_uniqueness,
                .preserves_to_return_component = if (same_component) a.preserves_to_return_component else null,
            };
        }
        return .{ .class = a.class, .preserves_to_return_component = null };
    }
    // Distinct non-⊥, non-⊤ — incompatible. Lift to ⊤.
    return ParamSig.unknown();
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "v8_signature: join with unobserved returns the other element" {
    const u = ParamSig.initial();
    const cu = ParamSig.consumesUniquely();
    try testing.expectEqual(UniquenessClass.consumes_uniquely, join(u, cu).class);
    try testing.expectEqual(UniquenessClass.consumes_uniquely, join(cu, u).class);
}

test "v8_signature: join with top yields top" {
    const t = ParamSig.unknown();
    const cu = ParamSig.consumesUniquely();
    try testing.expectEqual(UniquenessClass.top, join(t, cu).class);
    try testing.expectEqual(UniquenessClass.top, join(cu, t).class);
}

test "v8_signature: join of identical class preserves class" {
    const cu_a = ParamSig.consumesUniquely();
    const cu_b = ParamSig.consumesUniquely();
    try testing.expectEqual(UniquenessClass.consumes_uniquely, join(cu_a, cu_b).class);

    const al_a = ParamSig.aliasesOut();
    const al_b = ParamSig.aliasesOut();
    try testing.expectEqual(UniquenessClass.aliases, join(al_a, al_b).class);
}

test "v8_signature: join of distinct non-trivial classes yields top" {
    const cu = ParamSig.consumesUniquely();
    const al = ParamSig.aliasesOut();
    const pu = ParamSig.preservesUniqueness(null);
    try testing.expectEqual(UniquenessClass.top, join(cu, al).class);
    try testing.expectEqual(UniquenessClass.top, join(cu, pu).class);
    try testing.expectEqual(UniquenessClass.top, join(pu, al).class);
}

test "v8_signature: join of PU with same component preserves component" {
    const pu_a = ParamSig.preservesUniqueness(0);
    const pu_b = ParamSig.preservesUniqueness(0);
    const result = join(pu_a, pu_b);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, result.class);
    try testing.expectEqual(@as(?u8, 0), result.preserves_to_return_component);
}

test "v8_signature: join of PU with different components drops component witness" {
    const pu_a = ParamSig.preservesUniqueness(0);
    const pu_b = ParamSig.preservesUniqueness(1);
    const result = join(pu_a, pu_b);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, result.class);
    try testing.expectEqual(@as(?u8, null), result.preserves_to_return_component);
}

test "v8_signature: ProgramSignatures default lookups return top class" {
    var allocator_buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buffer);
    var sigs = ProgramSignatures.init(fba.allocator());
    defer sigs.deinit(fba.allocator());

    try testing.expectEqual(UniquenessClass.top, sigs.classOf(42, 0));
    try testing.expect(!sigs.isCuOrPu(42, 0));
}
