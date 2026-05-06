const std = @import("std");
const ir = @import("ir.zig");

// ============================================================
// ARC ownership verifier.
//
// Phase A of the Phase 6 redux plan introduced this module as a
// scaffold. Phase D wired the recursion structure through every
// nested instruction stream. Phase E (this commit) activates the
// invariant rules.
//
// Pipeline placement (per §2.2 of the plan):
//
//     ... → arc_ownership          (normalization)
//             → arc_verifier       (THIS PASS — invariant checks)
//                  → arc_drop_insertion
//                       → ...
//
// The verifier runs BEFORE drop insertion. At this pipeline
// position, the only `.release` instructions present are the
// post-call cleanup releases emitted by `IrBuilder` for
// `share_value`-driven calls. Scope-exit destroys (one per owned
// local at every ret-equivalent terminator) have not been
// inserted yet. Phase E's invariants are therefore framed around
// the IR shape AS IT EXISTS at this position:
//
//   V1. `.release{value=v}` MUST NOT target a local whose
//       `local_ownership` is `.borrowed`. A `.borrow_value`
//       does not bump the source cell; releasing it would
//       underflow the source's owner reference.
//   V2. `.release{value=v}` MUST NOT target a local whose
//       `local_ownership` is `.trivial`. Releasing a non-ARC
//       local is a refcount bug — there is no ARC cell to
//       decrement. (A `.trivial` local cannot be the source of
//       a `share_value` so this case represents a pass bug.)
//   V3. Borrowed values MUST NOT escape into aggregate storage.
//       For every `.struct_init`, `.list_init`, `.map_init`,
//       `.tuple_init`, `.list_cons`, and `.union_init`, every
//       operand local's `local_ownership` MUST NOT be `.borrowed`.
//       Storing a borrow into owned aggregate data would dangle
//       once the borrow scope ends.
//   V4. Function parameters of `.borrowed` convention MUST NOT
//       be released within the function body. Subsumed by V1
//       when Phase C correctly classifies the param-bound local
//       as `.borrowed`; verifier double-checks against
//       `param_conventions` directly to catch any pass that
//       updates `param_conventions` without updating
//       `local_ownership`.
//   V5. When `result_convention == .owned`, every ret-equivalent
//       value local MUST NOT be `.borrowed`. The caller's
//       post-call discipline assumes the returned value carries
//       a +1 retain that the caller is responsible for releasing;
//       returning a borrow would let the caller release a value
//       the callee was lending out.
//
// On any violation, `verify` emits a Swift-OSSA-style diagnostic
// via `std.log.err` and returns `error.ArcInvariantViolation`. The
// compiler propagates this as a hard build error — any pass that
// produces verifier-rejected IR has a bug to fix. The plan is
// emphatic (§3.E):
//
//   "The verifier must accept all currently-shipping IR. If it
//    rejects something, fix the upstream pass, don't disable the
//    rule."
//
// The verifier is bitset-light: every check is a per-instruction
// O(1) lookup against `function.local_ownership` and
// `function.param_conventions`. There is no CFG walk, no
// dataflow, no fixed-point iteration. The cost is proportional to
// the size of the function's instruction streams.
// ============================================================

/// Errors `verify` can return.
///
/// `ArcInvariantViolation` indicates the IR violated one of the
/// Phase E invariants. The offending site is reported via
/// `std.log.err` before the error is returned, with enough context
/// to localise the bug to a specific pass.
pub const VerifyError = error{
    OutOfMemory,
    ArcInvariantViolation,
};

/// Verify ownership invariants on `function`. Walks every
/// instruction stream (top-level body and every nested sub-stream)
/// and applies the per-instruction invariant checks in
/// `verifyInstruction`. Returns `error.ArcInvariantViolation` on
/// the first violation; subsequent violations would still be
/// reported via the diagnostic emission inside the check itself
/// but the function exits at the first failure to keep the
/// compile path predictable.
pub fn verify(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) VerifyError!void {
    _ = allocator;
    var ctx = VerifyContext{ .function = function };
    for (function.body) |block| {
        try verifyStream(&ctx, block.instructions);
    }
}

/// Per-verification context. Phase E carries only the function
/// pointer; all invariants are local to a single instruction. A
/// future tightening (per-CFG-path bitset dataflow for the
/// "destroyed exactly once" invariant) would extend this struct
/// with `live_owned` / `live_borrowed` bitsets.
const VerifyContext = struct {
    function: *const ir.Function,
};

/// Visit every instruction in `stream` (and recursively in every
/// nested sub-stream). Each instruction is handed to
/// `verifyInstruction`. The recursion structure here mirrors
/// `arc_liveness.flattenChildren` and
/// `arc_drop_insertion.rebuildChildren` exactly; all three
/// traversals must agree on which streams contain checkable IR.
fn verifyStream(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) VerifyError!void {
    for (stream) |*instr| {
        try verifyInstruction(ctx, instr);
        try verifyChildren(ctx, instr);
    }
}

/// Recurse into every nested instruction stream owned by `instr`.
fn verifyChildren(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) VerifyError!void {
    switch (instr.*) {
        .if_expr => |ie| {
            try verifyStream(ctx, ie.then_instrs);
            try verifyStream(ctx, ie.else_instrs);
        },
        .case_block => |cb| {
            try verifyStream(ctx, cb.pre_instrs);
            for (cb.arms) |arm| {
                try verifyStream(ctx, arm.cond_instrs);
                try verifyStream(ctx, arm.body_instrs);
            }
            try verifyStream(ctx, cb.default_instrs);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| try verifyStream(ctx, c.body_instrs);
            try verifyStream(ctx, sl.default_instrs);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| try verifyStream(ctx, c.body_instrs);
            try verifyStream(ctx, sr.default_instrs);
        },
        .union_switch => |us| {
            for (us.cases) |c| try verifyStream(ctx, c.body_instrs);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| try verifyStream(ctx, c.body_instrs);
        },
        .try_call_named => |tc| {
            try verifyStream(ctx, tc.handler_instrs);
            try verifyStream(ctx, tc.success_instrs);
        },
        .guard_block => |gb| {
            try verifyStream(ctx, gb.body);
        },
        .optional_dispatch => |od| {
            try verifyStream(ctx, od.nil_instrs);
            try verifyStream(ctx, od.struct_instrs);
        },
        else => {},
    }
}

/// Look up `local_id`'s ownership class. Returns `.trivial` for
/// any local id past the table's length — the table is sized to
/// `local_count` so every legitimate local has an entry; the
/// fallback exists for defensive robustness only (a misnumbered
/// LocalId would otherwise crash the verifier with an out-of-
/// bounds read instead of producing a clean diagnostic).
fn ownershipOf(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ir.OwnershipClass {
    if (local_id >= function.local_ownership.len) return .trivial;
    return function.local_ownership[local_id];
}

/// Look up `local_id`'s parameter convention if the local is a
/// parameter binding, otherwise `null`. Parameter LocalIds occupy
/// the first `param_conventions.len` slots in the function's
/// local-id space (the IR builder allocates them in order via
/// `param_get` instructions before any other locals).
fn paramConventionOf(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ?ir.ParamConvention {
    if (local_id >= function.param_conventions.len) return null;
    return function.param_conventions[local_id];
}

/// Test-mode flag suppressing diagnostic output. Negative tests
/// expect a violation and don't need the verifier to spam the
/// test runner's stderr; setting this to `true` for the duration
/// of the call keeps logs clean. Production code paths leave it
/// at its default `false` so user-facing compiler errors get
/// surfaced via `std.debug.print` to stderr.
threadlocal var suppress_diagnostics: bool = false;

/// Emit a Swift-OSSA-style diagnostic for an ARC invariant
/// violation. The diagnostic identifies the function, the rule
/// that was violated, the offending local id, and the
/// instruction tag. The caller returns
/// `error.ArcInvariantViolation` after this helper. Output goes
/// to stderr via `std.debug.print` to match the rest of the
/// compiler's diagnostic surface (other passes use the same
/// channel for stage-progress output, and the Zig test runner
/// treats `std.log.err` as a failure even when the test expects
/// the error path — `std.debug.print` does not).
fn emitDiagnostic(
    function: *const ir.Function,
    rule: []const u8,
    detail: []const u8,
    local_id: ir.LocalId,
    instr_tag: []const u8,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates ARC invariant {s}: {s} (local %{d}, instruction .{s})\n",
        .{ function.name, rule, detail, local_id, instr_tag },
    );
}

/// Per-instruction invariant check.
fn verifyInstruction(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) VerifyError!void {
    const function = ctx.function;
    switch (instr.*) {
        // V1 + V2 + V4: `.release` semantics.
        .release => |r| {
            const class = ownershipOf(function, r.value);
            switch (class) {
                .borrowed => {
                    emitDiagnostic(
                        function,
                        "V1",
                        "borrowed local must not be released within its borrow scope",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                },
                .trivial => {
                    emitDiagnostic(
                        function,
                        "V2",
                        "release targets a non-ARC (trivial) local — refcount bookkeeping bug",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                },
                .owned => {},
            }
            // V4 — defensive double-check: even if `local_ownership`
            // somehow drifted to `.owned` for a parameter local, the
            // parameter's calling convention is the source of truth
            // for "who owns this value." A borrowed-convention param
            // is owned by the caller; releasing it on the callee
            // side would double-free.
            if (paramConventionOf(function, r.value)) |conv| {
                if (conv == .borrowed) {
                    emitDiagnostic(
                        function,
                        "V4",
                        "borrowed-convention parameter must not be released by callee",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                }
            }
        },

        // V3: borrows must not escape into aggregate storage.
        .struct_init => |si| {
            for (si.fields) |field| {
                try checkAggregateOperand(function, field.value, "struct_init");
            }
        },
        .list_init => |li| {
            for (li.elements) |elem| {
                try checkAggregateOperand(function, elem, "list_init");
            }
        },
        .list_cons => |lc| {
            try checkAggregateOperand(function, lc.head, "list_cons");
            try checkAggregateOperand(function, lc.tail, "list_cons");
        },
        .map_init => |mi| {
            for (mi.entries) |entry| {
                try checkAggregateOperand(function, entry.key, "map_init");
                try checkAggregateOperand(function, entry.value, "map_init");
            }
        },
        .tuple_init => |ti| {
            for (ti.elements) |elem| {
                try checkAggregateOperand(function, elem, "tuple_init");
            }
        },
        .union_init => |ui| {
            try checkAggregateOperand(function, ui.value, "union_init");
        },

        // V5: returned values must match the function's result
        // convention.
        .ret => |r| {
            if (r.value) |v| try checkReturnValue(function, v, "ret");
        },
        .cond_return => |cr| {
            if (cr.value) |v| try checkReturnValue(function, v, "cond_return");
        },
        // Multi-arm terminators carry per-arm return values.
        .switch_return => |sr| {
            for (sr.cases) |c| {
                if (c.return_value) |v| try checkReturnValue(function, v, "switch_return");
            }
            if (sr.default_result) |v| try checkReturnValue(function, v, "switch_return");
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| {
                if (c.return_value) |v| try checkReturnValue(function, v, "union_switch_return");
            }
        },

        else => {},
    }
}

/// V3 helper: assert `operand` is not a borrowed local.
fn checkAggregateOperand(
    function: *const ir.Function,
    operand: ir.LocalId,
    instr_tag: []const u8,
) VerifyError!void {
    if (ownershipOf(function, operand) == .borrowed) {
        emitDiagnostic(
            function,
            "V3",
            "borrowed local must not escape into aggregate storage; promote via copy_value first",
            operand,
            instr_tag,
        );
        return error.ArcInvariantViolation;
    }
}

/// V5 helper: assert `value` matches `function.result_convention`.
fn checkReturnValue(
    function: *const ir.Function,
    value: ir.LocalId,
    instr_tag: []const u8,
) VerifyError!void {
    if (function.result_convention != .owned) return;
    // For `.owned` result convention, the returned local must NOT
    // carry `.borrowed` ownership. `.owned` and `.trivial` are both
    // accepted — `.trivial` covers the rare path where a non-ARC
    // local flows into an ARC-typed return slot (the caller will
    // wrap it in the appropriate `Term` shape; ARC-cell semantics
    // do not apply). The plan's load-bearing constraint is the
    // borrow-promotion: a borrow returned without a matching
    // `copy_value` would let the caller release a value the
    // callee is lending out.
    if (ownershipOf(function, value) == .borrowed) {
        emitDiagnostic(
            function,
            "V5",
            "result_convention is .owned but the returned local is .borrowed; promote via copy_value at the return site",
            value,
            instr_tag,
        );
        return error.ArcInvariantViolation;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-crafted verifier tests.
/// Caller owns the slices and is responsible for freeing them with
/// the same allocator after the test concludes.
fn buildTestFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_ownership: []const ir.OwnershipClass,
    param_conventions: []const ir.ParamConvention,
    result_convention: ir.ResultConvention,
) !ir.Function {
    const blocks = try allocator.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try allocator.dupe(ir.Instruction, instructions),
    };
    const ownership_copy = try allocator.dupe(ir.OwnershipClass, local_ownership);
    const conventions_copy = try allocator.dupe(ir.ParamConvention, param_conventions);
    const params = try allocator.alloc(ir.Param, param_conventions.len);
    for (params) |*p| p.* = .{ .name = "p", .type_expr = .void, .type_id = null };
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = @intCast(param_conventions.len),
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = @intCast(local_ownership.len),
        .param_conventions = conventions_copy,
        .local_ownership = ownership_copy,
        .result_convention = result_convention,
    };
}

fn freeTestFunction(allocator: std.mem.Allocator, function: *ir.Function) void {
    allocator.free(function.body[0].instructions);
    allocator.free(function.body);
    allocator.free(function.local_ownership);
    allocator.free(function.param_conventions);
    allocator.free(function.params);
}

/// RAII guard that suppresses verifier diagnostics for the
/// duration of a negative test, then restores the previous
/// setting on scope exit. Each negative test instantiates one
/// before invoking `verify`.
const SuppressDiagnostics = struct {
    prev: bool,

    fn init() SuppressDiagnostics {
        const prev = suppress_diagnostics;
        suppress_diagnostics = true;
        return .{ .prev = prev };
    }

    fn deinit(self: *SuppressDiagnostics) void {
        suppress_diagnostics = self.prev;
    }
};

test "arc_verifier: rejects release of borrowed local (V1)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V1: a `.release` targeting a local whose `local_ownership` is
    // `.borrowed` is a refcount bug. The borrow does not bump the
    // source cell, so releasing it would underflow the source's
    // owner reference.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .borrowed };
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v1",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects release of trivial local (V2)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V2: a `.release` targeting a trivial local cannot represent a
    // legitimate refcount decrement — there is no ARC cell to
    // decrement. The verifier reports this as a pass bug.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.trivial};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v2",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects release of borrowed-convention parameter (V4)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V4: a parameter local whose `param_conventions` is `.borrowed`
    // is owned by the caller. Releasing it on the callee side would
    // double-free against the caller's post-call release. The check
    // is defensive: even if `local_ownership` drifted to `.owned`,
    // the parameter convention is the source of truth.
    const allocator = testing.allocator;
    // Local 0 is a parameter; its local_ownership says .owned but
    // its param_conventions says .borrowed.
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v4",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed local stored into struct_init (V3)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V3: a `.borrow_value` dest stored into a struct field would
    // dangle once the borrow scope ends. The classifier must
    // promote the borrow via `.copy_value` first; the verifier
    // rejects any IR where this promotion was missed.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 1, .type_name = "T", .fields = &fields } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v3",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed local stored into list_init (V3)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const elements = [_]ir.LocalId{0};
    const instrs = [_]ir.Instruction{
        .{ .list_init = .{ .dest = 1, .elements = &elements, .element_type = .any } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v3_list",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed return when result_convention is owned (V5)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V5: a function declared to return `.owned` must promote any
    // borrowed return value via `.copy_value` at the return site.
    // Returning a borrow as-is would let the caller release a value
    // the callee was lending out.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.borrowed};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v5",
        &instrs,
        &ownership,
        &conventions,
        .owned,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: accepts release of owned local" {
    // Positive control for V1/V2: an `.owned` local is the legitimate
    // target of a `.release`.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_release",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verify(allocator, &function);
}

test "arc_verifier: accepts owned local stored into struct_init" {
    // Positive control for V3: an `.owned` local in a struct_init
    // operand is the legitimate aggregate-init shape.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 1, .type_name = "T", .fields = &fields } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_struct",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verify(allocator, &function);
}

test "arc_verifier: accepts owned return with owned result_convention" {
    // Positive control for V5: an `.owned` local returned under
    // `.owned` result convention is the canonical case.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_ret",
        &instrs,
        &ownership,
        &conventions,
        .owned,
    );
    defer freeTestFunction(allocator, &function);

    try verify(allocator, &function);
}

test "arc_verifier: trivial result_convention skips V5 entirely" {
    // V5 only fires under `.owned` result_convention. A function
    // returning a trivial value has no borrow-promotion obligation
    // because the caller does not perform a post-call release on a
    // trivial result.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.borrowed};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_trivial_ret",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verify(allocator, &function);
}

test "arc_verifier: recurses into optional_dispatch arms" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // Phase D's recursion structure is exercised via Phase E's
    // invariants: a violation buried inside an optional_dispatch arm
    // body must still be reported. The negative payload local 0 is
    // borrowed; releasing it inside the struct arm violates V1.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const arm_instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    const instrs = [_]ir.Instruction{
        .{ .optional_dispatch = .{
            .scrutinee_param = 0,
            .payload_local = 1,
            .nil_instrs = &.{},
            .nil_result = null,
            .struct_instrs = &arm_instrs,
            .struct_result = null,
        } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_recursion",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verify(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: stub function signature compiles" {
    // Pin the exported symbol so accidental signature drift surfaces
    // at compile time instead of as a downstream wiring failure.
    const fn_ptr: *const @TypeOf(verify) = &verify;
    _ = fn_ptr;
}
