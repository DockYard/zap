//! Comptime `@target` condition folding — the shared, single-source recognition
//! and evaluation of `@target.<field>` comparisons used by BOTH the HIR builder
//! (`src/hir.zig`, which elides comptime-dead `@target` branches before ZIR
//! lowering) and the type checker (`src/types.zig`, which must NOT resolve into
//! a comptime-dead `@target` branch — otherwise a capability-gated reference in
//! a branch that is dead for this target would wrongly produce the
//! `target_capability` diagnostic, defeating the portability escape hatch).
//!
//! Both layers need the SAME notion of "what does `@target.os == :wasi` evaluate
//! to for this build's target?", so that notion lives here once. The HIR fold
//! and the type-checker's dead-branch skip are then provably consistent — the
//! escape hatch (a gated reference guarded by a comptime-`@target` `if`/`case`)
//! is elided at exactly the same point in both passes.
//!
//! See `docs/target-capability-model-plan.md` (Phase 1 introduced the HIR fold;
//! Phase 2 requires the type-checker to honor the same fold so the gate fires
//! only on LIVE references).

const std = @import("std");
const ast = @import("ast.zig");
const target_triple = @import("target_triple.zig");

/// True when `expr` is the bare `@target` intrinsic — an `attr_ref` named
/// `target`. The `@target.<field>` access is a `field_access` whose object is
/// this bare reference.
pub fn isTargetAttrRef(expr: *const ast.Expr, interner: *const ast.StringInterner) bool {
    if (expr.* != .attr_ref) return false;
    return std.mem.eql(u8, interner.get(expr.attr_ref.name), "target");
}

/// Resolve `@target.<field>` to its comptime atom NAME for the resolved target,
/// or null when `expr` is not a `@target.{os,arch,abi}` access (or the target
/// is unknown / the field is unrecognized). PURE: never emits a diagnostic — a
/// bad field (`@target.bogus`) is reported once by the HIR field-access
/// lowering, not here. Callers use this to test operands/scrutinees without
/// risking a double diagnostic.
pub fn peekTargetFieldAtom(
    expr: *const ast.Expr,
    atoms: target_triple.TargetAtoms,
    interner: *const ast.StringInterner,
) ?[]const u8 {
    if (expr.* != .field_access) return null;
    const fa = expr.field_access;
    if (!isTargetAttrRef(fa.object, interner)) return null;
    const field_name = interner.get(fa.field);
    if (std.mem.eql(u8, field_name, "os")) return atoms.os;
    if (std.mem.eql(u8, field_name, "arch")) return atoms.arch;
    if (std.mem.eql(u8, field_name, "abi")) return atoms.abi;
    return null;
}

/// Evaluate a binary `==`/`!=` whose operands are a `@target.<field>` access and
/// an atom literal (in EITHER order), e.g. `@target.os == :wasi` or
/// `:wasi != @target.os`, to its comptime boolean value for the resolved
/// target. Returns null when `expr` is not such a comparison — the caller then
/// treats the condition as runtime (HIR lowers it normally; the type-checker
/// checks both branches). This is the SINGLE definition the HIR fold and the
/// type-checker's dead-branch skip both consult.
pub fn evalTargetEqualityCondition(
    expr: *const ast.Expr,
    atoms: target_triple.TargetAtoms,
    interner: *const ast.StringInterner,
) ?bool {
    if (expr.* != .binary_op) return null;
    const bo = expr.binary_op;
    const is_eq = bo.op == .equal;
    const is_neq = bo.op == .not_equal;
    if (!is_eq and !is_neq) return null;

    const target_atom, const literal_expr = blk: {
        if (peekTargetFieldAtom(bo.lhs, atoms, interner)) |name| break :blk .{ name, bo.rhs };
        if (peekTargetFieldAtom(bo.rhs, atoms, interner)) |name| break :blk .{ name, bo.lhs };
        return null;
    };
    if (literal_expr.* != .atom_literal) return null;

    const literal_name = interner.get(literal_expr.atom_literal.value);
    const equal = std.mem.eql(u8, target_atom, literal_name);
    return if (is_eq) equal else !equal;
}

/// Select the live `case` clause index for a comptime-decidable `@target` case
/// over the resolved target, or null when the case is NOT comptime-decidable
/// from `@target` (the caller then treats the whole case as runtime — both
/// arms type-checked, all arms lowered). This is the single liveness oracle the
/// HIR fold and the type-checker's dead-clause skip both consult, so the dead
/// `@target` branch is elided at exactly the same point in both passes (the
/// load-bearing portability escape hatch).
///
/// Two shapes are decidable, matching how `if`/`case` reach this pass:
///
///   1. **Atom-scrutinee** — `case @target.<field> { :atom -> … ; _ -> … }`.
///      The scrutinee is a bare `@target.<field>` access; every clause is a
///      guard-free bare atom-literal or wildcard. The clause whose atom equals
///      the resolved target's atom wins (first-match); a wildcard matches if no
///      atom did.
///
///   2. **Bool-scrutinee** — `case (@target.<field> ==/!= :atom) { true -> … ;
///      false -> … }`. This is what the Kernel `if`/`unless` macro expands a
///      `if @target.os != :wasi { … }` guard into (`lib/kernel.zap`), so the
///      canonical escape-hatch idiom arrives here as a bool-scrutinee case, NOT
///      an `if_expr`. The scrutinee comparison folds to a comptime bool via
///      `evalTargetEqualityCondition`; every clause is a guard-free `bool_lit`
///      or wildcard; the clause whose bool equals the folded value wins.
///
/// Conservative + sound: any guard, binding, or structured/other-literal
/// pattern makes the outcome not statically decidable, so the whole case falls
/// through to normal handling. A decidable case with no matching clause and no
/// wildcard returns null (the caller handles the non-exhaustive case as it
/// always did — the HIR fold reports it, the type-checker checks every clause).
pub fn selectLiveTargetCaseClause(
    scrutinee: *const ast.Expr,
    clauses: []const ast.CaseClause,
    atoms: target_triple.TargetAtoms,
    interner: *const ast.StringInterner,
) ?usize {
    // Shape 1: atom-scrutinee `case @target.<field> { :atom -> … }`.
    if (peekTargetFieldAtom(scrutinee, atoms, interner)) |target_atom| {
        for (clauses) |clause| {
            if (clause.guard != null) return null;
            switch (clause.pattern.*) {
                .wildcard => {},
                .literal => |lit| if (lit != .atom) return null,
                else => return null,
            }
        }
        for (clauses, 0..) |clause, idx| {
            switch (clause.pattern.*) {
                .wildcard => return idx,
                .literal => |lit| {
                    if (std.mem.eql(u8, interner.get(lit.atom.value), target_atom)) return idx;
                },
                else => unreachable,
            }
        }
        return null;
    }

    // Shape 2: bool-scrutinee `case (@target.<f> ==/!= :atom) { true -> … }`
    // — the desugared `if @target… { … }` form.
    if (evalTargetEqualityCondition(scrutinee, atoms, interner)) |scrutinee_value| {
        for (clauses) |clause| {
            if (clause.guard != null) return null;
            switch (clause.pattern.*) {
                .wildcard => {},
                .literal => |lit| if (lit != .bool_lit) return null,
                else => return null,
            }
        }
        for (clauses, 0..) |clause, idx| {
            switch (clause.pattern.*) {
                .wildcard => return idx,
                .literal => |lit| {
                    if (lit.bool_lit.value == scrutinee_value) return idx;
                },
                else => unreachable,
            }
        }
        return null;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeAtoms(os: []const u8) target_triple.TargetAtoms {
    return .{ .os = os, .arch = "wasm32", .abi = "musl" };
}

test "evalTargetEqualityCondition: == and != fold for the resolved target" {
    var interner = ast.StringInterner.init(testing.allocator);
    defer interner.deinit();
    const target_id = try interner.intern("target");
    const os_id = try interner.intern("os");
    const wasi_id = try interner.intern("wasi");

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const attr = ast.Expr{ .attr_ref = .{ .meta = .{ .span = span }, .name = target_id } };
    const field = ast.Expr{ .field_access = .{ .meta = .{ .span = span }, .object = &attr, .field = os_id } };
    const lit = ast.Expr{ .atom_literal = .{ .meta = .{ .span = span }, .value = wasi_id } };

    const eq = ast.Expr{ .binary_op = .{ .meta = .{ .span = span }, .op = .equal, .lhs = &field, .rhs = &lit } };
    const neq = ast.Expr{ .binary_op = .{ .meta = .{ .span = span }, .op = .not_equal, .lhs = &field, .rhs = &lit } };

    // On wasi: `@target.os == :wasi` is true, `!= :wasi` is false.
    try testing.expectEqual(@as(?bool, true), evalTargetEqualityCondition(&eq, makeAtoms("wasi"), &interner));
    try testing.expectEqual(@as(?bool, false), evalTargetEqualityCondition(&neq, makeAtoms("wasi"), &interner));
    // On macos: inverted.
    try testing.expectEqual(@as(?bool, false), evalTargetEqualityCondition(&eq, makeAtoms("macos"), &interner));
    try testing.expectEqual(@as(?bool, true), evalTargetEqualityCondition(&neq, makeAtoms("macos"), &interner));
}

test "evalTargetEqualityCondition: non-@target comparison returns null" {
    var interner = ast.StringInterner.init(testing.allocator);
    defer interner.deinit();
    const wasi_id = try interner.intern("wasi");
    const x_id = try interner.intern("x");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const var_ref = ast.Expr{ .var_ref = .{ .meta = .{ .span = span }, .name = x_id } };
    const lit = ast.Expr{ .atom_literal = .{ .meta = .{ .span = span }, .value = wasi_id } };
    const cmp = ast.Expr{ .binary_op = .{ .meta = .{ .span = span }, .op = .equal, .lhs = &var_ref, .rhs = &lit } };
    try testing.expectEqual(@as(?bool, null), evalTargetEqualityCondition(&cmp, makeAtoms("wasi"), &interner));
}

test "selectLiveTargetCaseClause: atom-scrutinee `case @target.os { … }`" {
    var interner = ast.StringInterner.init(testing.allocator);
    defer interner.deinit();
    const target_id = try interner.intern("target");
    const os_id = try interner.intern("os");
    const wasi_id = try interner.intern("wasi");
    const macos_id = try interner.intern("macos");

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const attr = ast.Expr{ .attr_ref = .{ .meta = .{ .span = span }, .name = target_id } };
    const scrutinee = ast.Expr{ .field_access = .{ .meta = .{ .span = span }, .object = &attr, .field = os_id } };

    // case @target.os { :wasi -> … ; :macos -> … ; _ -> … }
    const pat_wasi = ast.Pattern{ .literal = .{ .atom = .{ .meta = .{ .span = span }, .value = wasi_id } } };
    const pat_macos = ast.Pattern{ .literal = .{ .atom = .{ .meta = .{ .span = span }, .value = macos_id } } };
    const pat_wild = ast.Pattern{ .wildcard = .{ .meta = .{ .span = span } } };
    const clauses = [_]ast.CaseClause{
        .{ .meta = .{ .span = span }, .pattern = &pat_wasi, .type_annotation = null, .guard = null, .body = &.{} },
        .{ .meta = .{ .span = span }, .pattern = &pat_macos, .type_annotation = null, .guard = null, .body = &.{} },
        .{ .meta = .{ .span = span }, .pattern = &pat_wild, .type_annotation = null, .guard = null, .body = &.{} },
    };

    // On wasi the first clause is live; on macos the second; a non-listed os
    // (linux) selects the wildcard.
    try testing.expectEqual(@as(?usize, 0), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("wasi"), &interner));
    try testing.expectEqual(@as(?usize, 1), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("macos"), &interner));
    try testing.expectEqual(@as(?usize, 2), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("linux"), &interner));
}

test "selectLiveTargetCaseClause: bool-scrutinee (desugared `if @target.os != :wasi`)" {
    var interner = ast.StringInterner.init(testing.allocator);
    defer interner.deinit();
    const target_id = try interner.intern("target");
    const os_id = try interner.intern("os");
    const wasi_id = try interner.intern("wasi");

    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    const attr = ast.Expr{ .attr_ref = .{ .meta = .{ .span = span }, .name = target_id } };
    const field = ast.Expr{ .field_access = .{ .meta = .{ .span = span }, .object = &attr, .field = os_id } };
    const lit = ast.Expr{ .atom_literal = .{ .meta = .{ .span = span }, .value = wasi_id } };
    // scrutinee = `@target.os != :wasi` (what `if @target.os != :wasi {…}`
    // desugars its condition to).
    const scrutinee = ast.Expr{ .binary_op = .{ .meta = .{ .span = span }, .op = .not_equal, .lhs = &field, .rhs = &lit } };

    // case (@target.os != :wasi) { true -> THEN ; false -> ELSE }
    const pat_true = ast.Pattern{ .literal = .{ .bool_lit = .{ .meta = .{ .span = span }, .value = true } } };
    const pat_false = ast.Pattern{ .literal = .{ .bool_lit = .{ .meta = .{ .span = span }, .value = false } } };
    const clauses = [_]ast.CaseClause{
        .{ .meta = .{ .span = span }, .pattern = &pat_true, .type_annotation = null, .guard = null, .body = &.{} },
        .{ .meta = .{ .span = span }, .pattern = &pat_false, .type_annotation = null, .guard = null, .body = &.{} },
    };

    // On wasi `os != :wasi` is false → the `false` clause (index 1, the ELSE)
    // is live, the `true` clause (THEN, holding the gated call) is DEAD.
    try testing.expectEqual(@as(?usize, 1), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("wasi"), &interner));
    // On macos `os != :wasi` is true → the `true` clause (index 0, the THEN)
    // is live.
    try testing.expectEqual(@as(?usize, 0), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("macos"), &interner));
}

test "selectLiveTargetCaseClause: a guarded or non-@target case is not decidable" {
    var interner = ast.StringInterner.init(testing.allocator);
    defer interner.deinit();
    const x_id = try interner.intern("x");
    const span = ast.SourceSpan{ .start = 0, .end = 0 };
    // A plain variable scrutinee is neither a @target field access nor a
    // foldable @target comparison → null (runtime case).
    const scrutinee = ast.Expr{ .var_ref = .{ .meta = .{ .span = span }, .name = x_id } };
    const pat_wild = ast.Pattern{ .wildcard = .{ .meta = .{ .span = span } } };
    const clauses = [_]ast.CaseClause{
        .{ .meta = .{ .span = span }, .pattern = &pat_wild, .type_annotation = null, .guard = null, .body = &.{} },
    };
    try testing.expectEqual(@as(?usize, null), selectLiveTargetCaseClause(&scrutinee, &clauses, makeAtoms("wasi"), &interner));
}
